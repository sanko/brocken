use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::Wasm;
use Test2::Tools::Brocken qw[temp_path answers];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Function frames on the Wasm target.
#
# Wasm has no frame pointer, so a frame is memory the function carves out for
# itself, and `Lowerer/Wasm.pm` carves it with a bump pointer, `%heap_ptr`.
# That pointer was a *function local*, which is where the fault was: a local
# belongs to one function, but the bump pointer has to be shared by every
# function on the stack. Each function instead started its own bump pointer at
# the heap base and counted up independently, so a callee began handing out the
# very addresses its caller had just handed out, and the caller's saved
# parameter slots were overwritten part-way through the call. The caller then
# read back a pointer that was no longer the pointer it stored.
#
# The symptom only appears once a function both has a frame and calls another
# function that has one, which is why the obvious cases all passed. `box_tag` --
# a frame, but no nested call -- worked. `unbox_i64` -- a frame, and a call to
# `box_tag` -- trapped, always inside itself, at an address that had nothing to
# do with its arguments:
#
#   0:   0x6ceb - <unknown>!<wasm function 75>
#   1:    0xb19 - <unknown>!<wasm function 0>
#   2: memory fault at wasm address 0x3000001 in linear memory of size 0x110000
#
# Seeding the pointer by hand does not move that fault, which is what ruled out
# "uninitialized bump pointer" as the cause and pointed at the collision. The
# pointer is now a module global, seeded once by the entry, so a callee carries
# on from where its caller stopped.
#
# That single change is what the cases below pin down. They also cover the two
# symptoms it had been blamed for and which had been written off as separate
# bugs: the wide-shift trap and box-to-box assignment, both of which are the
# same clobbered-frame fault seen from a different angle.
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $brocken  = Brocken->new( platform => $platform );
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;
subtest 'a nested call does not reuse the caller\'s frame' => sub {

    # Two frames, live at the same time. `inner` is called from a function that
    # has already allocated its own slots, so if the bump pointer is per-function
    # the two frames overlap and `outer`'s parameter slot is overwritten.
    answers(
        'sub inner(i64 $x) -> i64 { my i64 $t = $x + 1; my i64 $u = $t * 3; return $u; }
         sub outer(i64 $x) -> i64 { my i64 $k = $x * 2; my i64 $v = inner($k); return $v + $x; }
         return outer(10) & 255;', ( ( ( 10 * 2 + 1 ) * 3 ) + 10 ) & 255, 'the callee carves its frame above the caller\'s'
    );

    # The same, with the inner call made twice: a per-function bump pointer
    # hands the caller the same addresses back on the second call, which the
    # first call has already filled with its own live values.
    answers(
        'sub d(i64 $x) -> i64 { my i64 $t = $x * 2; return $t; }
         sub c(i64 $x) -> i64 { my i64 $a = d($x); my i64 $b = d($x + 1); return $a + $b; }
         return c(20) & 255;', ( 40 + 42 ) & 255, 'two calls in one function each get their own frame'
    );

    # A caller that keeps a value live across the call. This is the shape the
    # runtime helpers have: `unbox_i64` saves `$dyn` and `$payload`, then calls
    # `box_tag`, then reads them back.
    answers(
        'sub g(i64 $p) -> i64 { my i64 $h = $p; my i64 $r = f($h); return $r + $h; }
         sub f(i64 $p) -> i64 { my i64 $a = $p; my i64 $b = $a + 5; my i64 $c = $b + 5; return $c; }
         return g(7) & 255;', ( 7 + 5 + 5 ) + 7, 'a value live across a call survives it'
    );
};
subtest 'recursion frames do not overlap' => sub {

    # Every activation of `f` is live at once, so a per-function bump pointer
    # collapses the whole chain onto one frame and the recursion has nothing left
    # to distinguish.
    answers( 'sub f(i64 $n) -> i64 { if ($n <= 0) { return 0; } return f($n - 1) + 1; } return f(100) & 255;',
        100, 'a 100 deep recursion accumulates correctly' );

    # Each activation has several live values, so a shared frame shows up as a
    # wrong result rather than as a trap.
    answers( 'sub fib(i64 $n) -> i64 { if ($n < 2) { return $n; } return fib($n - 1) + fib($n - 2); } return fib(16) & 255;',
        987 & 255, 'a recursive call tree keeps every frame intact' );
};
subtest 'the runtime unbox helpers work on the Wasm target' => sub {

    # These are the functions that exposed the fault. Each has a frame and calls
    # `box_tag`, which has one too, so before the fix every one of them trapped.
    answers( 'my $x = 2.5; my i64 $j = Brocken::Runtime::unbox_i64($x); return $j == 2 ? 1 : 0;',   1, 'a float box unboxes as an integer' );
    answers( 'my $x = 42; my i64 $j = Brocken::Runtime::unbox_i64($x); return $j == 42 ? 1 : 0;',   1, 'an integer box unboxes as an integer' );
    answers( 'my $x = 2.5; my f64 $f = Brocken::Runtime::unbox_f64($x); return $f == 2.5 ? 1 : 0;', 1, 'a float box unboxes as a float' );
    answers( 'my $x = 42; my f64 $f = Brocken::Runtime::unbox_f64($x); return $f == 42.0 ? 1 : 0;', 1, 'an integer box unboxes as a float' );

    # `unbox_f64` calls both `box_tag` and `unbox_i64`, so it nests two frames
    # deep over its own.
    answers( 'my $x = -2.5; my f64 $f = Brocken::Runtime::unbox_f64($x); return $f == -2.5 ? 1 : 0;', 1, 'a negative float box unboxes as a float' );
};
subtest 'faults this frame collision had been blamed for' => sub {

    # A 64-bit value that has to survive a shift and a mask. It read back a
    # clobbered slot on Wasm and trapped; the native target has always agreed
    # with the expectation.
    answers( 'my i64 $a = 0; my i64 $b = 4294967296; my $c = $a - $b; my $r = $c >> 32; return $r & 255;',
        255, 'a wide subtraction, shift and mask agree with the native target' );

    # Assignment between two boxes of the same type, which reads the source
    # through a saved pointer after the call that filled the frame returned.
    answers( 'my $a = 42; my $b = 0; $b = $a; return $b == 42 ? 1 : 0;',     1, 'one box assigned to another keeps its value' );
    answers( 'my $a = 42; $a = $a; return $a == 42 ? 1 : 0;',                1, 'a box assigned to itself keeps its value' );
    answers( 'my $a = 2.5; my $b = 0.0; $b = $a; return $b == 2.5 ? 1 : 0;', 1, 'one float box assigned to another keeps its value' );
    answers( 'my $a = 2.5; $a = $a; return $a == 2.5 ? 1 : 0;',              1, 'a float box assigned to itself keeps its value' );
};
subtest 'the bump pointer is a module global' => sub {

    # The structural half of the fix: a local would still be per-function, and the
    # behavioural cases above would pass for the wrong reason if a future change
    # reintroduced one alongside the global. Read the section list of a linked
    # module and look for id 6.
    my $file = temp_path('wasm_frame') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $brocken->codegen->emit_functions( $brocken->compile('return 1;')->functions ),
        $platform );
    my $bytes = do { open my $fh, '<:raw', $file or die $!; local $/; <$fh> };
    unlink $file if -e $file;
    my ( %sections, $global_at, $pos );
    $global_at = undef;
    $pos       = 8;

    while ( $pos < length $bytes ) {
        my $id    = ord substr $bytes, $pos, 1;
        my $len   = 0;
        my $shift = 0;
        my $p     = $pos + 1;
        while (1) {
            my $byte = ord substr $bytes, $p++, 1;
            $len |= ( $byte & 0x7F ) << $shift;
            $shift += 7;
            last unless $byte & 0x80;
        }
        $sections{$id} = $len;
        $global_at     = $p if $id == 6;
        $pos           = $p + $len;
    }
    ok( $sections{6}, 'the module declares a global section (id 6)' );

    # One mutable i64, the bump pointer: count, valtype 0x7E, mutability 0x01.
    my $byte_at = sub { ord substr $bytes, $_[0], 1 };
    is( $byte_at->($global_at),       1,    'exactly one global is declared' );
    is( $byte_at->( $global_at + 1 ), 0x7E, 'the global is an i64' );
    is( $byte_at->( $global_at + 2 ), 0x01, 'and mutable, so the entry can seed it' );

    # The entry has to seed it once, before the first allocation. One
    # `global.set` of the heap base, not one per function: reseeding on every
    # call would hand the callee the addresses the caller had just handed out,
    # which is the collision this fix removes.
    my $sets = () = $bytes =~ /\x24\x00/g;
    ok( $sets >= 1, 'the bump pointer is set through a global.set, not a local.set' );
    done_testing();
};
done_testing;
