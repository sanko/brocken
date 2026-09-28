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

# Promotion is a MIR-level decision, so it can be asserted without wasmtime: a
# function whose slots are all address-not-taken scalars must not emit an alloca,
# and must not touch linear memory for them at all. fib's only slot is its i64
# parameter, so any alloca here means promotion regressed.
{
    my $module  = Brocken::Compiler->new->compile( <<'BROCKEN' );
sub fib(i64 $n) -> i64 {
    if ($n < 2) { return $n; }
    return fib($n - 1) + fib($n - 2);
}
BROCKEN
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my ($fn) = grep { $_->name eq 'fib' } $module->functions->@*;
    ok( $fn, 'the module lowers the fib function' );
    my $mf = $lowerer->lower($fn);
    my ( $allocas, $stores, $loads ) = ( 0, 0, 0 );
    for my $mbb ( $mf->blocks->@* ) {
        for my $mi ( $mbb->instructions->@* ) {
            $allocas++ if $mi->comment =~ /^alloca/;
            $stores++  if $mi->opcode =~ /^i(?:32|64)_store$/;
            $loads++   if $mi->opcode =~ /^i(?:32|64)_load$/;
        }
    }
    is( $allocas, 0, 'an address-not-taken scalar slot emits no alloca' );
    is( $stores,  0, 'a promoted slot is never written through memory' );
    is( $loads,   0, 'a promoted slot is never read through memory' );
}

# An array base is offset by getelementptr, so its address escapes and it has to
# stay in linear memory -- promotion must not take it.
{
    my $module  = Brocken::Compiler->new->compile( <<'BROCKEN' );
sub main() -> i64 {
    my [i64; 4] $a;
    $a[0] = 5;
    $a[1] = 7;
    return $a[0] + $a[1];
}
BROCKEN
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my ($fn) = grep { $_->name eq 'main' } $module->functions->@*;
    ok( $fn, 'the module lowers the array function' );
    my $mf = $lowerer->lower($fn);
    my $allocas = 0;
    for my $mbb ( $mf->blocks->@* ) {
        for my $mi ( $mbb->instructions->@* ) {
            $allocas++ if $mi->comment =~ /^alloca/;
        }
    }
    ok( $allocas, 'an array base still allocates in linear memory' );
}

# An index is an i64 in the IR while a wasm32 address is i32, so the scale,
# multiply and add have to see a narrowed index. Without the wrap the sequence is
# `local.get` (i64) then `i32.mul`, and wasmtime rejects the whole module with
# "type mismatch: expected i32, found i64" -- so a *variable* index produced an
# invalid module while a constant index, folded into a displacement, worked.
{
    my $module  = Brocken::Compiler->new->compile( <<'BROCKEN' );
sub main() -> i64 {
    my [i64; 16] $a;
    my i64 $i = 3;
    $a[$i] = 10;
    return $a[$i];
}
BROCKEN
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my ($fn) = grep { $_->name eq 'main' } $module->functions->@*;
    my $mf = $lowerer->lower($fn);
    my ( $wraps, $geps ) = ( 0, 0 );
    for my $mbb ( $mf->blocks->@* ) {
        for my $mi ( $mbb->instructions->@* ) {
            $geps++  if ( $mi->comment // '' ) =~ /gep: idx/;
            $wraps++ if ( $mi->comment // '' ) =~ /gep: wrap index/;
        }
    }
    ok( $geps,  'a variable array index goes through the gep path' );
    is( $wraps, $geps, 'every variable index is narrowed to the i32 address space' );
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

# fib(n) invokes fib 2*fib(n+1)-1 times. While each frame's parameter was spilled
# to the bump cursor, that made memory scale with the *total* number of calls and
# nothing ever gave the space back, so the depth that fit was bounded by the single
# 64KB page the linker declares: fib(17) needed 41336 bytes and fit, fib(18) needed
# 66888 and trapped. Promotion holds a parameter in a wasm local instead, which is
# the engine's own per-invocation slot, so the cost tracks the live depth and
# fib(25) -- 242785 calls, 3MB under the old scheme -- no longer touches memory.
my @cases = (
    { name => 'fib base case',   prog => $FIB,  tail => 'return fib(0);',   want => 0 },
    { name => 'fib(1)',          prog => $FIB,  tail => 'return fib(1);',   want => 1 },
    { name => 'fib(5)',          prog => $FIB,  tail => 'return fib(5);',   want => 5 },
    { name => 'fib(10)',         prog => $FIB,  tail => 'return fib(10);',  want => 55 },
    { name => 'fib(15)',         prog => $FIB,  tail => 'return fib(15);',  want => 610 },
    { name => 'fib(20) past the old 64KB spill ceiling', prog => $FIB, tail => 'return fib(20);', want => 6765 },
    { name => 'fib(25) 3MB of frames, no linear memory', prog => $FIB, tail => 'return fib(25);', want => 75025 },
    { name => 'fact(5)',         prog => $FACT, tail => 'return fact(5);',  want => 120 },
    { name => 'fact(10)',        prog => $FACT, tail => 'return fact(10);', want => 3628800 },
    { name => 'mutual recursion down', prog => $FIB, tail => 'return fib(12) + fib(9);', want => 144 + 34 },
);

# A local object used to be handed out by the *spill* cursor while the runtime's own
# allocator kept a second cursor at the same base, so the two overlapped and the
# class case read garbage (7*6 came back as 6240). Scalars no longer allocate, so the
# spill cursor is idle and the object comes from the runtime allocator alone.
push @cases,
    {
    name => 'local object after promotion',
    prog => <<'BROCKEN',
class Point { field i64 $x :param :reader; }
BROCKEN
    tail => 'my ptr $p = Point->new(7); return $p->x() * 6;',
    want => 42,
    };

# A local object *declared inside a loop body* is the one shape that still needed
# the spill cursor while promotion was restricted to the entry block. That put the
# slot at `heap_base + 16` -- the same base `bump_alloc` hands the instance out
# from -- so the pointer and the object overlapped and the loop summed garbage
# (10760 instead of 45). Promoting in any block fixes it, because a wasm local is
# per-invocation rather than per-block. The same program is correct on x86_64, so
# this is Wasm-specific and silent, which is why it is worth its own case.
push @cases,
    {
    name => 'object declared in a loop body',
    prog => <<'BROCKEN',
class P { field i64 $x :param :reader; }
BROCKEN
    tail => <<'BROCKEN',
my i64 $t = 0;
my i64 $i = 0;
while ($i < 10) { my ptr $p = P->new($i); $t = $t + $p->x(); $i = $i + 1; }
return $t;
BROCKEN
    want => 45,
    },
    {
    name => 'array store and load with a variable index',
    prog => '',
    tail => 'my [i64; 16] $a; my i64 $i = 3; $a[$i] = 10; return $a[$i];',
    want => 10,
    };

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
