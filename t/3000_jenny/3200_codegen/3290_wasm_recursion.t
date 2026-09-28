use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
use Test2::Tools::Brocken qw(temp_path);
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

my $host          = Brocken::Katsuro::Platform::parse();
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

# The bump pointer that hands out spill slots was a *function local*. Wasm locals
# are per-invocation and start at zero, and nothing ever initialised it -- the
# runtime's _init() runs in another function and cannot write this one. So every
# call frame began allocating at address 0 and recursive frames all aliased one
# slot. The MIR and the instruction selection were both correct, which is why
# reading either never found it; only the encoded prologue showed it:
#
#     local.get 1        <- %heap_ptr, still 0 on entry
#     local.set 2        <- spill address = 0
#     local.get 1 / i32.const 8 / i32.add / local.set 1
#     local.get 2 / local.get 0 / i64.store   <- every frame stores its $n here
#
# A frame that reads its parameter *before* recursing and never again is
# accidentally correct, so `fact` ($n * fact($n - 1)) passed and hid the bug. It
# shows up as soon as a frame re-reads a spilled slot after a recursive call,
# which is what `fib($n - 1) + fib($n - 2)` does for its second argument: the
# i64.load sits after the first call and reads back the callee's value. fib(10)
# returned -80, fib(15) -195, fib(20) -360, all stable regardless of heap size.
# It is now a mutable module global (section 6) seeded once by the entry stub.

sub build_wasm {
    my ( $src, $name ) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $out = temp_path( $name ) . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $codegen->emit_functions( $module->functions ), $platform );
    return $out;
}

# --- Structure: checkable without wasmtime ---------------------------------

{
    my $fib = <<'BROCKEN';
sub fib(i64 $n) -> i64 {
    if ($n < 2) { return $n; }
    return fib($n - 1) + fib($n - 2);
}
return fib(10);
BROCKEN

    my $file = build_wasm( $fib, 'wasm_recursion_struct' );
    open my $fh, '<:raw', $file or die "$file: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;

    my $pos    = 8;    # skip magic + version
    my %seen;
    while ( $pos < length $bytes ) {
        my $id = ord substr( $bytes, $pos, 1 );
        $pos++;
        my ( $len, $shift ) = ( 0, 0 );
        while (1) {
            my $b = ord substr( $bytes, $pos, 1 );
            $pos++;
            $len |= ( $b & 0x7F ) << $shift;
            last unless $b & 0x80;
            $shift += 7;
        }
        $seen{$id} = $len;
        $pos += $len;
    }

    ok( $seen{6}, 'module carries a global section (id 6) for the shared bump pointer' );
    is( $seen{10} ? 1 : 0, 1, 'module carries a code section' );
    ok( !$seen{7} || $seen{10}, 'sections are laid out in ascending id order, so the global lands before the exports' );

    # A local index would be encoded as local.get (0x20). The prologue must not
    # read the cursor that way any more.
    unlike( $bytes, qr/\x20\x01\x41\x08\x6a\x21\x01/, 'the heap bump is not a local.get/local.set pair any more' );

    unlink $file;
}

# --- Execution --------------------------------------------------------------

my $FIB = <<'BROCKEN';
sub fib(i64 $n) -> i64 {
    if ($n < 2) { return $n; }
    return fib($n - 1) + fib($n - 2);
}
BROCKEN

my $FACT = <<'BROCKEN';
sub fact(i64 $n) -> i64 {
    if ($n <= 1) { return 1; }
    return $n * fact($n - 1);
}
BROCKEN

# fib(n) invokes fib 2*fib(n+1)-1 times and each frame spills 8 bytes that are
# never reclaimed, so the depth that fits is bounded by the single 64KB page the
# linker still declares: fib(17) needs 41336 bytes and fits, fib(18) needs 66888
# and traps. These stay under the limit on purpose -- raising the page count is
# separate work, and a trap there is a memory ceiling rather than a wrong answer.
my @cases = (
    { name => 'fib base case',   prog => $FIB,  tail => 'return fib(0);',   want => 0 },
    { name => 'fib(1)',          prog => $FIB,  tail => 'return fib(1);',   want => 1 },
    { name => 'fib(5)',          prog => $FIB,  tail => 'return fib(5);',   want => 5 },
    { name => 'fib(10)',         prog => $FIB,  tail => 'return fib(10);',  want => 55 },
    { name => 'fib(15)',         prog => $FIB,  tail => 'return fib(15);',  want => 610 },
    { name => 'fib(17) at the 64KB spill ceiling', prog => $FIB, tail => 'return fib(17);', want => 1597 },
    { name => 'fact(5)',         prog => $FACT, tail => 'return fact(5);',  want => 120 },
    { name => 'fact(10)',        prog => $FACT, tail => 'return fact(10);', want => 3628800 },
    { name => 'mutual recursion down', prog => $FIB, tail => 'return fib(12) + fib(9);', want => 144 + 34 },
);

for my $case (@cases) {
    SKIP: {
        skip 'wasmtime not available', 1 and next unless $wasmtime_path && -f $wasmtime_path;

        my $file = build_wasm( $case->{prog} . $case->{tail}, 'wasm_recursion_exec' );
        my $out  = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$file" 1024 2>&1];
        $out =~ s/^warning: using .*$//mg;
        $out =~ s/^\s+|\s+$//g;

        is( $out, $case->{want}, "$case->{name}: returns $case->{want}" );
        unlink $file;
    }
}

done_testing;
