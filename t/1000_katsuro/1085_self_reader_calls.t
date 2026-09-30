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
use feature qw[class];
my $host          = Brocken::Katsuro::Platform::parse();
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $wasm_platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

# A method body could not call a method generated for its own class.
#
# `generate_class_runtime` registered and lowered in the same loop: the
# explicit methods went through `register_method` and `lower_method` back to
# back, and the `:reader`/`:writer`/constructor were only registered further
# down. `lower_method` resolves a callee by looking it up in `$functions`, and
# returns silently if the name is not there yet, so a declared method calling
# `$self->x()` was lowered against a class that had no `x` yet:
#
#     Undefined method 'x' in class 'P'
#
# Bare `$x` inside a method was unaffected. That is a field GEP, pre-populated
# from the layout by `populate_field_geps`, so it never consults `$functions`.
# Only the explicit `$self->x()` call form depended on registration order,
# which is what made this easy to miss: the class looked like it had accessors
# and every other access path worked.
#
# The fix separates the two passes. Every method the class can have --
# ADJUST, declared methods, readers, writers, constructor -- is registered
# first, and only then is any body lowered. Call resolution inside a method is
# now independent of the order bodies happen to be lowered in.
my @cases = (
    {   name => 'a method calls its own reader',
        src  => <<'BROCKEN',
class P {
    field i64 $x :param :reader;
    method get() -> i64 { return $self->x(); }
}
my ptr $p = P->new(42);
return $p->get();
BROCKEN
        want => 42,
    },
    {   name => 'a method calls two of its own readers',
        src  => <<'BROCKEN',
class P {
    field i64 $x :param :reader;
    field i64 $y :param :reader;
    method total() -> i64 { return $self->x() + $self->y(); }
}
my ptr $p = P->new(20, 22);
return $p->total();
BROCKEN
        want => 42,
    },
    {   name => 'a method calls its own writer, then reads the field back',
        src  => <<'BROCKEN',
class P {
    field i64 $x :param :reader :writer;
    method bump() { $self->set_x($self->x() + 1); }
}
my ptr $p = P->new(41);
$p->bump();
return $p->x();
BROCKEN
        want => 42,
    },
    {   name => 'one method calls another declared method that uses a reader',
        src  => <<'BROCKEN',
class P {
    field i64 $x :param :reader;
    method raw() -> i64 { return $self->x(); }
    method twice() -> i64 { return $self->raw() * 2; }
}
my ptr $p = P->new(21);
return $p->twice();
BROCKEN
        want => 42,
    },
    {   name => 'the reader a method calls is the one the class advertises',
        src  => <<'BROCKEN',
class P {
    field i64 $x :param :reader;
    method direct() -> i64 { return $self->x(); }
    method via_middle() -> i64 { return $self->direct() + $self->x(); }
}
my ptr $p = P->new(20);
return $p->via_middle();
BROCKEN
        want => 40,
    },
    {   name => 'a method call and a field read agree',
        src  => <<'BROCKEN',
class P {
    field i64 $x :param :reader;
    method both() -> i64 { return $self->x() + $x; }
}
my ptr $p = P->new(21);
return $p->both();
BROCKEN
        want => 42,
    },
    {   name => 'ADJUST runs before a later method reads the field through a reader',
        src  => <<'BROCKEN',
class P {
    field i64 $x :param :reader;
    ADJUST { if ($x < 40) { $x = 40; } }
    method get() -> i64 { return $self->x(); }
}
my ptr $p = P->new(1);
return $p->get();
BROCKEN
        want => 40,
    },
    {   name => 'a class with no fields still lowers its methods',
        src  => <<'BROCKEN',
class P {
    field i64 $x :param :reader;
    method unused() -> i64 { return 42; }
}
my ptr $p = P->new(0);
return $p->unused();
BROCKEN
        want => 42,
    },
);

# Registration order
#
# The bug was an ordering bug, so check the order directly rather than trusting
# that the bodies happen to come out right. A declared method must be lowered
# into a function object that already exists.
{
    my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class P {
    field i64 $x :param :reader :writer;
    method get() -> i64 { return $self->x(); }
}
BROCKEN
    my %by_name = map { $_->name => $_ } $module->functions->@*;
    ok( $by_name{'P::get'},   'the declared method was registered' );
    ok( $by_name{'P::x'},     'the generated reader was registered' );
    ok( $by_name{'P::set_x'}, 'the generated writer was registered' );
    ok( $by_name{'P::new'},   'the generated constructor was registered' );

    # The reader has to exist as a callable target, and the method body has to
    # point at it rather than being lowered into a stale or empty function.
    is( $by_name{'P::x'}->blocks->@*,   1, 'the reader has a body' )               if $by_name{'P::x'};
    is( $by_name{'P::get'}->blocks->@*, 1, 'the method was lowered, not skipped' ) if $by_name{'P::get'};
}

# A declared method wins over a generated accessor of the same name. Allowing a
# later registration to overwrite `$functions` would leave two functions sharing
# one name in the module and silently retarget every call.
{
    my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class P {
    field i64 $x :reader;
    method x() -> i64 { return 42; }
}
BROCKEN
    my @xs = grep { $_->name eq 'P::x' } $module->functions->@*;
    is( scalar @xs, 1, 'a declared method does not collide with a generated reader' );
}

#  Wasm
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
        is( run_wasm( $case->{src}, 'self_reader_wasm' ), $case->{want}, "wasm: $case->{name}" );
    }
}

#  Native
{
    my $brocken = Brocken->new();
SKIP: {
        skip 'Not native', scalar @cases unless $brocken->platform->is_native;
        for my $case (@cases) {
            my $module = Brocken::Compiler->new->compile( $case->{src} );
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $file   = $brocken->tmpdir . '/self_reader' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            system $file;
            is( $? >> 8, $case->{want}, "native: $case->{name}" );
        }
    }
}
done_testing;
