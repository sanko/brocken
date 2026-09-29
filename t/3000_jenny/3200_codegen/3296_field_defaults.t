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

# A field default, `field i16 $b :param :reader = 5;`, and what the compiler has
# to do about it.
#
# A constructor's signature is fixed at one parameter per `:param` field, in
# declaration order. That signature is the whole difficulty: the constructor has
# no way to tell an argument the caller omitted from one the caller passed as
# zero, so it cannot apply the default itself and neither can it leave the slot
# alone. It stores the parameter unconditionally, and a default sitting on the
# same field was unreachable behind that branch.
#
# The gap therefore has to be filled at the call site, which does know what was
# passed. For every `:param` field past the last argument supplied, the call site
# passes the field's default, or a zero of the right type when the field has no
# default. That fixes two failures at once, one per backend:
#
#   * natively, the omitted argument arrived as an uninitialized register, so
#     the field read back as whatever happened to be there;
#   * on wasm it was worse than a wrong answer, because the callee declared one
#     more parameter than the call site supplied. The validator rejected the
#     module outright ("expected i32 but nothing on stack") rather than emitting
#     something wrong.
#
# Zero-filling a parameterless default is not a flourish. Without it the same
# uninitialized read is still there for a field that has no default at all, so
# omitting an argument has to mean "zero" whether or not a default exists.

# The call site is the only place that knows, so the number the constructor
# actually receives is read back out of the generated call. These assert the
# substitution directly rather than inferring it from a run.
#
# A literal does not carry the type of the slot it lands in, so a substituted
# default usually arrives as a cast of a constant rather than as a constant
# (a synthesized zero needs no cast, since it is built at the right width
# already). Either way the value is followed back down to the literal underneath,
# which lets each expectation name the width as well as the value -- the width is
# half the contract, since a default of 5 in a 4-byte slot is a different bug
# from the same default in a 2-byte one.
sub literal_value {
    my ($v) = @_;
    return $v->value if $v->isa('Brocken::Lindsay::IR::Constant');
    for my $cast (qw[Trunc Sext Zext]) {
        next unless $v->isa("Brocken::Lindsay::IR::Instruction::$cast");
        return literal_value( $v->operands->[0] );
    }
    return undef;
}

# A call instruction keeps its callee beside the operands rather than in them, so
# the argument list is the operands and nothing has to be trimmed off the end.
# The leading object pointer is dropped, since it is not a field.
sub ctor_args_for {
    my ($src) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    for my $f ( $module->functions->@* ) {
        next if $f->name =~ /^P::/;
        for my $b ( $f->blocks->@* ) {
            for my $i ( $b->instructions->@* ) {
                next unless $i->isa('Brocken::Lindsay::IR::Instruction::Call');
                next unless $i->callee->name eq 'P::new';
                my @args = $i->operands->@*;
                shift @args;
                my @text;
                for my $a (@args) {
                    my $lit = literal_value($a);
                    push @text, defined $lit ? $a->type->as_string . " $lit" : $a->as_string;
                }
                return join ',', @text;
            }
        }
    }
    return undef;
}

is(
    ctor_args_for('class P { field i16 $b :param :reader = 5; } my ptr $p = P->new();'),
    'i16 5',
    'an omitted :param with a default passes the default, not zero'
);

is(
    ctor_args_for('class P { field i8 $a :param :reader = 1; field i16 $b :param :reader = 2; } my ptr $p = P->new();'),
    'i8 1,i16 2',
    'every omitted :param is filled, in declaration order'
);

is(
    ctor_args_for('class P { field i32 $c :param :reader; } my ptr $p = P->new();'),
    'i32 0',
    'an omitted :param with no default passes a zero of its own type'
);

is(
    ctor_args_for('class P { field i16 $b :param :reader = 5; } my ptr $p = P->new(9);'),
    'i16 9',
    'a supplied argument is passed through and the default is not consulted'
);

# Filling the gap after `b` also has to fill `c` after it: the signature is
# positional, so there is no argument that could mean "skip the one in front of
# me". A supplied first argument is still the one it was, and a later omission
# still gets a zero.
is(
    ctor_args_for('class P { field i16 $b :param :reader = 5; field i32 $c :param :reader; } my ptr $p = P->new(3);'),
    'i16 3,i32 0',
    'a supplied first argument is untouched and the one after it is zeroed'
);

# The default is kept as an expression and re-lowered per call rather than
# pre-lowered into the class table, so it cannot be captured from whichever
# function happened to be compiled when the class was registered.
{
    my $ast    = Brocken::Compiler->new->parse_only('class P { field i16 $b :param :reader = 2 + 3; }');
    my ($decl) = grep { $_->isa('Brocken::Katsuro::AST::Stmt::ClassDecl') } $ast->statements->@*;
    my ($f)    = $decl->fields->@*;
    ok( $f->default, 'a field default is present on the AST' );
    is( $f->default_op, '=', "the default's operator is recorded as '='" );
}

# --- Behaviour ----------------------------------------------------------------
#
# A substitution that reads back correctly in IR can still store the wrong width
# or the wrong offset, so each program returns 42 when every field reads back and
# 1 otherwise, because a native exit code is a single byte and cannot carry -7.

my @cases = (
    {
        name => 'an omitted :param with a default reads the default',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader = 5; }
my ptr $p = P->new();
if ($p->b() == 5) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a default is an expression, evaluated per construction',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader = 2 + 3; }
my ptr $p = P->new();
if ($p->b() == 5) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a negative default is sign-extended into an i8',
        src  => <<'BROCKEN',
class P { field i8 $b :param :reader = -7; }
my ptr $p = P->new();
if ($p->b() == -7) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a default on a field that is not a :param still applies',
        src  => <<'BROCKEN',
class P { field i16 $b :reader = 5; }
my ptr $p = P->new();
if ($p->b() == 5) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'an omitted :param with no default reads zero',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader = 5; field i32 $c :param :reader; }
my ptr $p = P->new();
if ($p->c() == 0) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'defaults for several omitted fields, of every width',
        src  => <<'BROCKEN',
class P {
    field i8  $a :param :reader = 1;
    field i16 $b :param :reader = 2;
    field i32 $c :param :reader = 3;
    field i64 $d :param :reader = 4;
}
my ptr $p = P->new();
if ($p->a() == 1) {
    if ($p->b() == 2) {
        if ($p->c() == 3) {
            if ($p->d() == 4) { return 42; }
        }
    }
}
return 1;
BROCKEN
    },
    {
        name => 'a supplied argument beats the default',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader = 5; }
my ptr $p = P->new(9);
if ($p->b() == 9) { return 42; }
return 1;
BROCKEN
    },
    {
        # `=` means "use the default when the argument is missing", not "use it
        # when the value is false", so an explicit zero has to survive. A
        # `//=`-style test would fail here, and would have caught the original
        # bug had the constructor been the thing doing the substituting.
        name => 'a supplied zero is not replaced by the default',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader = 5; }
my ptr $p = P->new(0);
if ($p->b() == 0) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'a default and an explicit ADJUST compose',
        src  => <<'BROCKEN',
class P {
    field i16 $b :param :reader = 5;
    ADJUST { if ($b < 10) { $b = 10; } }
}
my ptr $p = P->new();
if ($p->b() == 10) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'two classes, one of them omitting an argument',
        src  => <<'BROCKEN',
class A { field i16 $x :param :reader = 11; }
class B { field i16 $y :param :reader = 22; }
my ptr $a = A->new();
my ptr $b = B->new(5);
if ($a->x() == 11) {
    if ($b->y() == 5) { return 42; }
}
return 1;
BROCKEN
    },
    {
        # The fill happens in whichever function the call sits in, so a
        # constructor reached from a method body has to be filled too.
        name => 'a default applies to a construction inside a method body',
        src  => <<'BROCKEN',
class P { field i16 $b :param :reader = 5; }
class Maker {
    method make() -> ptr {
        my ptr $p = P->new();
        return $p;
    }
}
my ptr $m = Maker->new();
my ptr $p = $m->make();
if ($p->b() == 5) { return 42; }
return 1;
BROCKEN
    },
);

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
        is( run_wasm( $case->{src}, 'def_wasm' ), 42, "wasm: $case->{name}" );
    }
}

{
    my $brocken = Brocken->new;
    SKIP: {
        skip 'Not native', scalar @cases unless $brocken->platform->is_native;

        for my $case (@cases) {
            my $module = Brocken::Compiler->new->compile( $case->{src} );
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $file   = $brocken->tmpdir . '/def' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            system $file;
            is( $? >> 8, 42, "native: $case->{name}" );
        }
    }
}

done_testing;
