use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
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
my $wasm_platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

# Sub-word memory access was a full word wide on every backend.
#
# Both backends picked the access width from "is this 64-bit or not", so an
# i8 or i16 field went through a 4-byte access. Every one of these fields holds
# a sign-extended value in its lane, so a lone sub-word access read and wrote
# correctly as often as not -- the low byte landed in the right place and the
# comparison that followed was against the same sign-extended constant. That
# is why the bug survived: the cases that looked like they covered it were the
# ones that could not see it.
#
# What it took to see it was a *neighbouring* access. An i8 write also wrote
# the three bytes above it, which under C-style layout is the padding in front
# of the next field, so the next field's own read returned the wrong value.
# A struct holding nothing but an i8 was worse still, because the access ran
# off the end of the object into whatever the allocator placed next.
#
#   * x86-64 `load` now uses MOVSX r32, r/m8 and MOVSX r32, r/m16 (0F BE, 0F
#     BF). MOVSX rather than MOVZX because a sub-word value is carried
#     sign-extended in the whole register and arithmetic on it is plain 32-bit
#     arithmetic; zero-extending turned -7 into 0xF9 and abs() of that into
#     249. Not the one-byte 0x8A either, which reads one byte but writes only
#     the low 8 bits of the register and leaves the upper 56 stale.
#   * x86-64 `store` uses 0x88 for a byte and a 66-prefixed 0x89 for a word.
#   * x86-64 `store_imm` uses 0xC6 for a byte and a 66-prefixed 0xC7 for a
#     word, with the immediate truncated to the access width -- 0xC6
#     sign-extends its byte, and a 16-bit 0xC7 only has room for the low half.
#     A constant initialiser is the easiest way to hit this, because the
#     constructor stores every field.
#   * Wasm uses i32.load8_s / i32.load16_s and i32.store8 / i32.store16.
#
# Two encoding details cost a round of debugging and are worth stating, since
# both produce plausible-looking bytes that only misbehave in one case:
#
#   * The 66 operand-size prefix is a legacy prefix and has to precede REX. A
#     REX byte first silently changes the meaning of register ids 0-3, and
#     spl/bpl/dil/sil/bpl are simply unreachable without one.
#   * In the immediate-store form the immediate follows the displacement, so it
#     has to be emitted *after* the displacement bytes. Moving it in front
#     mis-encodes every access with a non-empty displacement, at every width
#     including 32- and 64-bit, which is what it did on the first attempt.
#
# The load is sized from the *destination* type and the store from the *value*
# type, matching how the rest of the encoder picks an operand width.

# A native exit code is a single byte, so a case cannot assert a field value of
# 258, -300 or 8589934592 by returning it. Each program returns 42 when the
# check holds and 1 when it does not, which keeps the expectation readable on
# both backends and still fails loudly with a distinct value.

my @cases = (
    {
        name => 'an i8 write does not clobber the i16 after it',
        src  => <<'BROCKEN',
class P {
    field i8 $a :param :reader :writer;
    field i16 $b :param :reader;
}
my ptr $p = P->new(1, 258);
$p->set_a(1);
if ($p->b() == 258) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'an i8 constant write does not clobber the i16 after it',
        src  => <<'BROCKEN',
class P {
    field i8 $a :reader :writer;
    field i16 $b :param :reader;
}
my ptr $p = P->new(258);
$p->set_a(1);
if ($p->b() == 258) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a negative i16 survives a neighbouring i8 write',
        src  => <<'BROCKEN',
class P {
    field i8 $a :param :reader :writer;
    field i16 $b :param :reader;
}
my ptr $p = P->new(1, -300);
$p->set_a(1);
if ($p->b() == -300) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'two adjacent i8 fields each keep their own value',
        src  => <<'BROCKEN',
class P {
    field i8 $a :param :reader :writer;
    field i8 $b :param :reader;
}
my ptr $p = P->new(11, 22);
$p->set_a(33);
if ($p->a() == 33) {
    if ($p->b() == 22) { return 42; }
}
return 1;
BROCKEN
    },
    {
        name => 'an i32 keeps its own value past an i8',
        src  => <<'BROCKEN',
class P {
    field i8 $a :param :reader :writer;
    field i32 $b :param :reader;
}
my ptr $p = P->new(1, 70000);
$p->set_a(1);
if ($p->b() == 70000) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'an i64 keeps its own value past an i8',
        src  => <<'BROCKEN',
class P {
    field i8 $a :param :reader :writer;
    field i64 $b :param :reader;
}
my ptr $p = P->new(1, 8589934592);
$p->set_a(1);
if ($p->b() == 8589934592) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a lone i8 does not disturb the next object',
        src  => <<'BROCKEN',
class A { field i8 $v :param :reader :writer; }
class B { field i16 $w :param :reader; }
my ptr $a = A->new(1);
my ptr $b = B->new(258);
$a->set_v(1);
if ($b->w() == 258) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a negative i8 field stays sign-extended in arithmetic',
        src  => <<'BROCKEN',
class P { field i8 $a :param :reader; }
my ptr $p = P->new(-7);
my i8 $x = $p->a();
my i8 $y = $x - 1;
if ($y == -8) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a negative i16 field stays sign-extended in arithmetic',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader; }
my ptr $p = P->new(-300);
my i16 $x = $p->b();
my i16 $y = $x - 1;
if ($y == -301) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a negative i8 field widens to the right value',
        src  => <<'BROCKEN',
class P { field i8 $a :param :reader; }
my ptr $p = P->new(-7);
my i64 $x = $p->a();
if ($x == -7) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a negative i16 field widens to the right value',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader; }
my ptr $p = P->new(-300);
my i64 $x = $p->b();
if ($x == -300) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a lone i8 field keeps its own value',
        src  => <<'BROCKEN',
class P { field i8 $a :param :reader :writer; }
my ptr $p = P->new(7);
$p->set_a(7);
if ($p->a() == 7) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a lone i16 field keeps its own value',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader :writer; }
my ptr $p = P->new(999);
$p->set_b(999);
if ($p->b() == 999) { return 42; }
return 1;
BROCKEN
    },
);

# --- Field layout -------------------------------------------------------------
#
# The struct layout is C's, because that is what an FFI caller allocates and
# indexes by. Fields are laid out in declaration order at the next offset that
# satisfies their natural alignment, and the struct's size is rounded up to its
# own alignment. Overlaying fields on top of each other -- what this compiler
# used to do -- only worked because every sub-word access was widened to
# clobber the neighbour it overlapped.
#
# Sizes are therefore observable independently of any access-width bug, so they
# are checked on their own here rather than inferred from a field read.
#
# The offsets are read back out of the lowerer's own class table, by way of the
# displacement each generated accessor bakes into its field GEP. That is the
# number the backend will use, not a second computation of it.

sub offsets_for {
    my ($src) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my %out;
    for my $f ( $module->functions->@* ) {
        next unless $f->name =~ /^P::(\w+)$/;
        my $m = $1;
        for my $b ( $f->blocks->@* ) {
            for my $i ( $b->instructions->@* ) {
                next unless $i->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr');
                my $disp = $i->operands->[1];
                next unless $disp->isa('Brocken::Lindsay::IR::Constant');
                $out{$m} = $disp->value;
            }
        }
    }
    return \%out;
}

for my $case (
    [ 'i8 then i16'     => 'class P { field i8 $a :reader; field i16 $b :reader; }',                        { a => 0, b => 2 } ],
    [ 'i8 then i32'     => 'class P { field i8 $a :reader; field i32 $b :reader; }',                        { a => 0, b => 4 } ],
    [ 'i8 then i64'     => 'class P { field i8 $a :reader; field i64 $b :reader; }',                        { a => 0, b => 8 } ],
    [ 'i16 i8 i16'      => 'class P { field i16 $a :reader; field i8 $b :reader; field i16 $c :reader; }',   { a => 0, b => 2, c => 4 } ],
    [ 'two i8'          => 'class P { field i8 $a :reader; field i8 $b :reader; }',                         { a => 0, b => 1 } ],
    [ 'three i8'        => 'class P { field i8 $a :reader; field i8 $b :reader; field i8 $c :reader; }',     { a => 0, b => 1, c => 2 } ],
    [ 'i32 then i8'     => 'class P { field i32 $a :reader; field i8 $b :reader; }',                       { a => 0, b => 4 } ],
    [ 'i8 i32 i8'       => 'class P { field i8 $a :reader; field i32 $b :reader; field i8 $c :reader; }',    { a => 0, b => 4, c => 8 } ],
    [ 'i8 i16 i32 i64'  => 'class P { field i8 $a :reader; field i16 $b :reader; field i32 $c :reader; field i64 $d :reader; }', { a => 0, b => 2, c => 4, d => 8 } ],
) {
    my ( $name, $decl, $want ) = @$case;
    my $got = offsets_for($decl);
    my @bad;
    for my $m ( sort keys %$want ) {
        push @bad, "$m: want $want->{$m}, got " . ( defined $got->{$m} ? $got->{$m} : 'undef' )
            if !defined $got->{$m} || $got->{$m} != $want->{$m};
    }
    is( scalar @bad, 0, "C layout: $name" ) or diag join( '; ', @bad );
}

# --- Wasm ---------------------------------------------------------------------

sub run_wasm {
    my ( $src, $name ) = @_;
    my $module  = Brocken::Compiler->new->compile($src);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $wasm_platform );
    my $out     = temp_path($name) . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $codegen->emit_functions( $module->functions ), $wasm_platform );
    my $r = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$out" 1024 2>&1];
    $r =~ s/^warning: using .*$//mg;
    $r =~ s/^\s+|\s+$//g;
    unlink $out;
    return $r;
}

for my $case (@cases) {
    SKIP: {
        skip 'wasmtime not available', 1 unless $wasmtime_path && -f $wasmtime_path;
        is( run_wasm( $case->{src}, 'subword_wasm' ), 42, "wasm: $case->{name}" );
    }
}

# --- Native -------------------------------------------------------------------

{
    my $brocken = Brocken->new;
    SKIP: {
        skip 'Not native', scalar @cases unless $brocken->platform->is_native;

        for my $case (@cases) {
            my $module = Brocken::Compiler->new->compile( $case->{src} );
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $file   = $brocken->tmpdir . '/subword' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            system $file;
            is( $? >> 8, 42, "native: $case->{name}" );
        }
    }
}

done_testing;
