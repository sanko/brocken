use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

# Arguments that arrive on the stack.
#
# The x86_64 lowerer only ever captured arguments out of the calling-convention
# registers, so past the register count it did not capture them at all: the
# callee read whatever the register happened to hold, and the caller put nothing
# where the callee would look. Both directions are covered here, because a fix
# that moves one without the other produces a function that runs.
#
# The stack area is reserved at the bottom of the callee's frame and is never
# moved at run time. That keeps the outgoing arguments at a fixed displacement
# from the hardware stack pointer, which matters because three different things
# want to be positioned against that same pointer: the outgoing arguments, the
# allocator's spill and caller-save slots, and an alloca. Reserving one area at
# the bottom and shifting the other two above it is what lets all three coexist
# without a frame pointer on the stack-passing path.
#
# Swept by arity rather than tested at one width. The register count is where
# the failure starts, and it differs per ABI, so the sweep is derived from the
# platform rather than hard-coded: six integer registers on SysV, four on Win64,
# where the shadow space pushes the first stack argument out to offset 32.

my $brocken = Brocken->new;

SKIP: {
    skip 'Not native', 1 unless $brocken->platform->is_native;

    my $abi = $brocken->platform->abi;
    my $gp  = scalar $abi->param_registers->@*;

    # A free function swept from the first argument that cannot fit in a
    # register up to well past it, so a frame that is too small to hold the
    # whole argument block still has to survive.
    for my $n ( $gp + 1 .. $gp + 4 ) {
        my @params = map { "i64 \$v$_" } 0 .. $n - 1;
        my @args   = map { $_ + 1 } 0 .. $n - 1;
        my $sum    = join( ' + ', map { "\$v$_" } 0 .. $n - 1 );
        my $total  = 0;
        $total += $_ for @args;

        my $free = <<"BROCKEN";
sub f( @{[ join ', ', @params ]} ) -> i64 { return $sum; }
if ( f( @{[ join ', ', @args ]} ) == $total ) { return 42; }
return 1;
BROCKEN
        is( run($free), 42, "native: free function with $n argument(s), $n - $gp on the stack" );
    }

    # A constructor spends the first argument register on its own receiver, so
    # the field count that reaches the stack is one lower than for a free
    # function. The receiver travels with them, which is the part a fix that
    # only handles plain calls gets wrong: the object address is live across
    # every field store, so it is the first thing to be clobbered.
    for my $n ( $gp .. $gp + 3 ) {
        my @args   = map { $_ + 1 } 0 .. $n - 1;
        my @fields = map { "field i8 \$f$_ :param :reader;" } 0 .. $n - 1;
        my $reads = join( "\n", map { "if (\$p->f$_() == " . ( $_ + 1 ) . ") {" } 0 .. $n - 1 )
            . "\nreturn 42;\n"
            . join( "\n", map { '}' } 0 .. $n - 1 );
        my $ctor = <<"BROCKEN";
class P {
    @{[ join "\n", @fields ]}
}
my ptr \$p = P->new( @{[ join ', ', @args ]} );
$reads
return 1;
BROCKEN
        is( run($ctor), 42, "native: constructor with $n argument field(s), some on the stack" );
    }

    # Narrow types in the stack region. The slot is eight bytes wide but the
    # argument is not, so a store of the wrong width either writes past the
    # argument or leaves the neighbouring one holding part of the previous
    # value. Mixing the widths is the point: a uniform i64 sweep cannot see it.
    {
        my @params = ( "i8 \$a", "i16 \$b", "i32 \$c" );
        push @params, map { "i64 \$v$_" } 0 .. 2;
        push @params, "i8 \$d", "i16 \$e", "i32 \$f";
        my $src = <<"BROCKEN";
sub mix( @{[ join ', ', @params ]} ) -> i64 {
    my i64 \$t = 0;
    \$t = \$t + \$a;
    \$t = \$t + \$b;
    \$t = \$t + \$c;
    \$t = \$t + \$v0;
    \$t = \$t + \$v1;
    \$t = \$t + \$v2;
    \$t = \$t + \$d;
    \$t = \$t + \$e;
    \$t = \$t + \$f;
    return \$t;
}
if ( mix( 1, 2, 3, 4, 5, 6, 7, 8, 9 ) == 45 ) { return 42; }
return 1;
BROCKEN
        is( run($src), 42, "native: narrow arguments past the register set" );
    }
}

done_testing;

sub run {
    my ($src) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/stackarg' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
