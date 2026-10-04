use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::Wasm;
use Test2::Tools::Brocken qw[temp_path];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Where Wasm frames come from, and where they go when the call returns.
#
# 3321_wasm_frame_layout.t pins down that the frame bump pointer is a module
# global, so a callee carries on from where its caller stopped rather than
# handing out the same addresses again. That fixes the collision, but it leaves
# two faults behind, and both are about which addresses the pointer covers and
# whether it ever moves back.
#
# The pointer was seeded at `%__heap_base` itself. That address is the ICB: 144
# bytes of runtime state, with the Immix block header starting immediately after
# it. So the first frames were carved straight over the runtime's own fields.
# The one that shows up in a result rather than a trap is the fuel counter at
# base+64, which every function reads to decide whether to keep going: eight
# frames of 24 bytes reach the end of the header, and the ninth lands on the
# fuel the next call is about to read. The symptom is a threshold rather than a
# failure -- fib(8) returned 21 and fib(9) returned 0 -- which is why it reads as
# a recursion limit instead of a memory bug, and why adding an `& 255` to the
# expectation hides it: the mask is one more instruction and one more frame slot,
# which moves every address and no longer lands on the counter.
#
# Nothing lowered the pointer back, so it only ever grew. A loop that called a
# function forty thousand times walked it off the end of the 1MB heap and trapped
# with "out of bounds memory access", however little the program itself needed.
#
# So the entry seeds the pointer at the arena base -- 144 + 16, which is where
# Brocken::Runtime::_init puts the heap cursor -- and every other function keeps
# the pointer it was called with and restores it before returning.
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $brocken  = Brocken->new( platform => $platform );
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;

# Returns the entry's i64, which wasmtime prints as its last line.
sub answers ( $src, $want, $name ) {
    skip_all('wasmtime not available') unless $wasmtime && -f $wasmtime;
    my $module = eval { $brocken->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return }
    my $file = temp_path('wasm_reclaim') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $brocken->codegen->emit_functions( $module->functions ), $platform );
    my $output = qx["$wasmtime" run --invoke _BROCKEN_ENTRY "$file" 1024 2>&1];
    my @lines  = grep {/\S/} split /\n/, $output;
    unlink $file if -e $file;
    my $got = @lines ? $lines[-1] : '';
    is( $got, $want, $name ) or diag $output;
    return;
}
subtest 'the frame region starts above the runtime state' => sub {

    # Recursion deep enough for the frames to reach past the ICB. Eight levels
    # fit inside it by luck; this one does not, and reads the fuel counter back
    # as 0 once they do.
    answers( 'sub fib(i64 $n) -> i64 { if ($n < 2) { return $n; } return fib($n - 1) + fib($n - 2); } return fib(12);',
        144, 'a recursion deeper than the ICB still gets its fuel' );

    # The same shape one frame at a time, so the frames cannot all be live at
    # once and only the address they are handed matters.
    answers(
        'sub d(i64 $n) -> i64 { my i64 $a = $n; my i64 $b = $a + 1; return $b; }
              my i64 $i = 0; my i64 $t = 0; while ($i < 500) { $t = d($i); $i = $i + 1; } return $t;', 500,
        'repeated calls past the ICB keep their own frames'
    );
};
subtest 'a frame is reclaimed when the call returns' => sub {

    # The regression this file exists for. Each call takes a 24 byte frame, so
    # 100000 of them is 2.4MB against a 1MB heap: with nothing restoring the
    # pointer this traps with "out of bounds memory access" long before the end.
    answers(
        'sub f(i64 $n) -> i64 { my i64 $a = $n; my i64 $b = $a + 1; my i64 $c = $b + 1; return $c; }
              my i64 $i = 0; my i64 $t = 0; while ($i < 100000) { $t = f($i); $i = $i + 1; } return $t & 255;', 100001 & 255,
        '100000 calls in a loop do not walk off the heap'
    );

    # Recursion is the same allocator from the other side: the frames have to
    # nest and come back, rather than all being live at once.
    answers( 'sub f(i64 $n) -> i64 { if ($n <= 0) { return 0; } return 1 + f($n - 1); } return f(5000) & 255;',
        5000 & 255, 'a 5000 deep recursion still nests and unwinds' );
};
subtest 'the pointer moves back' => sub {

    # The structural half. A restore is a `global.set` of the saved pointer, and
    # the entry's seed is the other end of the same pair, so a module that only
    # ever grows would still have a `global.set` -- 3311 already checks for that.
    # What distinguishes them is that a function which hands its frame back has
    # to read the pointer before it starts allocating, so the read has to be a
    # `global.get` of index 0 rather than a load from its own frame.
    my $file = temp_path('wasm_reclaim') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $file,
        $brocken->codegen->emit_functions( $brocken->compile('sub f(i64 $n) -> i64 { my i64 $a = $n; return $a; } return f(1);')->functions ),
        $platform );
    my $bytes = do { open my $fh, '<:raw', $file or die $!; local $/; <$fh> };
    unlink $file if -e $file;

    # 0x23 is global.get and 0x24 global.set, both with the one-based LEB index
    # of the global that follows.
    my $gets = () = $bytes =~ /\x23\x00/g;
    my $sets = () = $bytes =~ /\x24\x00/g;
    ok( $gets >= 1, 'the pointer is read through global.get' );
    ok( $sets >= 2, 'it is written at least twice: the seed and a restore' );
    done_testing();
};
done_testing;
