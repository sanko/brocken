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

# A class pointer could not be handed to a function and used there.
# `resolve_class_name` infers a receiver's class four ways: a literal class
# name (`P->new`), a local recorded in `$var_class` from a constructor, a
# function listed in `$function_return_class`, and finally `$current_class` so
# that `$self` works inside a method. A parameter matched none of them -- it is
# a Var with no `$var_class` entry, and a plain `sub` has no `$current_class` --
# so `sub g(ptr $q) { return $q->x(); }` died in the lowerer with "Cannot
# determine class for field or method access", before any backend ran and on
# every target equally.
#
# "A class travels with a pointer" was already half-built: it worked for return
# types and not for parameters. The cheap first step, taken here, is a
# `$param_class` table alongside `$function_return_class`, and a class name is
# now accepted in a parameter's type position, exactly as it already was in a
# return type position. The class is a pointer at runtime, so nothing about the
# ABI changes; what changes is that the lowerer knows what the pointer points
# at.
#
# Note this is an explicit annotation, not an inference. A bare `ptr` parameter
# still cannot be resolved, and saying so with a hint beats silently guessing.

my $POINT = <<'BROCKEN';
class P { field i64 $x :param :reader; }
BROCKEN

my @cases = (
    {
        name => 'a class-typed parameter reads a field',
        src  => $POINT . <<'BROCKEN',
sub get_x(P $q) -> i64 { return $q->x(); }
my ptr $p = P->new(42);
return get_x($p);
BROCKEN
        want => 42,
    },
    {
        name => 'the class is the parameter, not the enclosing class',
        src  => $POINT . <<'BROCKEN',
sub describe(P $q) -> i64 { return $q->x() * 2; }
my ptr $p = P->new(21);
return describe($p);
BROCKEN
        want => 42,
    },
    {
        name => 'two parameters of two different classes',
        src  => <<'BROCKEN',
class A { field i64 $a :param :reader; }
class B { field i64 $b :param :reader; }
sub mix(A $x, B $y) -> i64 { return $x->a() * 10 + $y->b(); }
my ptr $p = A->new(4);
my ptr $q = B->new(2);
return mix($p, $q);
BROCKEN
        want => 42,
    },
    {
        name => 'a class-typed parameter alongside a plain one',
        src  => $POINT . <<'BROCKEN',
sub scale(P $q, i64 $k) -> i64 { return $q->x() * $k; }
my ptr $p = P->new(7);
return scale($p, 6);
BROCKEN
        want => 42,
    },
    {
        name => 'a class-typed parameter passed on to another one',
        src  => $POINT . <<'BROCKEN',
sub inner(P $q) -> i64 { return $q->x(); }
sub outer(P $q) -> i64 { return inner($q); }
my ptr $p = P->new(42);
return outer($p);
BROCKEN
        want => 42,
    },
    {
        name => 'a class-typed parameter that is not used as an object',
        src  => $POINT . <<'BROCKEN',
sub zero(P $q) -> i64 { return 0; }
my ptr $p = P->new(9);
return zero($p);
BROCKEN
        want => 0,
    },
    {
        name => 'the class is known per function, not per name',

        # Both functions have a parameter called $q, and only one of them is
        # class-typed. If the table leaked by name, the second would borrow
        # the first's class and compile.
        src  => <<'BROCKEN',
class A { field i64 $a :param :reader; }
class B { field i64 $b :param :reader; }
sub typed(A $q) -> i64 { return $q->a(); }
sub untyped(ptr $q) -> i64 { return 0; }
my ptr $p = A->new(42);
return typed($p) + untyped($p);
BROCKEN
        want => 42,
    },
    {
        name => 'a class-typed parameter to a class method',
        src  => $POINT . <<'BROCKEN',
sub call_x(P $q) -> i64 { return $q->x(); }
my ptr $p = P->new(42);
return call_x($p);
BROCKEN
        want => 42,
    },
);

# --- IR shape -----------------------------------------------------------------
#
# A class-typed parameter has to arrive at the backend as a plain pointer; a
# `P` reaching an encoder as an unknown type would fail much later and much less
# clearly than it does here.

{
    my $module = Brocken::Compiler->new->compile( $POINT . <<'BROCKEN' );
sub get_x(P $q) -> i64 { return $q->x(); }
BROCKEN
    my ($get_x) = grep { $_->name eq 'get_x' } $module->functions->@*;
    ok( $get_x, 'the function with a class-typed parameter was registered' );

    my ($param) = $get_x->params->@*;
    is( $param->name,          '%q',     'the parameter is passed in the usual way' );
    is( $param->type->kind,    'ptr',    'a class-typed parameter lowers to a pointer' );
    is( $get_x->return_type->bits, 64,   'the i64 return type is untouched' );

    # The parameter must not be confused for a field offset or an extra arg.
    is( scalar( $get_x->params->@* ), 1, 'a class-typed parameter is still one parameter' );
}

# --- Negative -----------------------------------------------------------------

{
    my $module = eval {
        Brocken::Compiler->new->compile(
            $POINT . "sub get_x(ptr \$q) -> i64 { return \$q->x(); }\nreturn 0;\n" );
    };
    ok( !$module, 'a bare ptr parameter still cannot be resolved' );
    like( $@, qr/Cannot determine class for field or method access/,
        'and still says so' );
    like( $@, qr/declare the parameter with its class/,
        'and now suggests the class annotation that would fix it' );
}

{
    my $module = eval {
        Brocken::Compiler->new->compile("sub f(Nope \$q) -> i64 { return 0; }\nreturn 0;\n" );
    };
    ok( !$module, 'a parameter type naming no known class is rejected' );
    like( $@, qr/Unknown type 'Nope'/, 'reported as an unknown type' );
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
        is( run_wasm( $case->{src}, 'class_param_wasm' ), $case->{want}, "wasm: $case->{name}" );
    }
}

# --- Native -------------------------------------------------------------------

{
    my $brocken = Brocken->new();
    SKIP: {
        skip 'Not native', scalar @cases unless $brocken->platform->is_native;

        for my $case (@cases) {
            my $module = Brocken::Compiler->new->compile( $case->{src} );
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $file   = $brocken->tmpdir . '/class_param' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            system $file;
            is( $? >> 8, $case->{want}, "native: $case->{name}" );
        }
    }
}

done_testing;
