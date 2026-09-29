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

# Arguments arriving in registers at all.
#
# The lowerer captures each incoming argument by copying it out of its
# calling-convention register at the very top of the function:
#
#     mov <dst>, rdi      # arg 0
#     mov <dst>, rsi      # arg 1
#     mov <dst>, rdx      # arg 2
#     mov <dst>, rcx      # arg 3
#
# Those captures do not run in isolation. They all read the caller's registers
# before any of them is overwritten, so they are one parallel move, and the
# register allocator is free to pick a destination that is still a pending
# source -- which is what it did with four integer parameters, producing the
# cycle `rcx <- rdi, rdx <- rsi, rsi <- rdx, rdi <- rcx`.
#
# The shuffle fix parks a clobbered source in the one spill register the
# allocator holds, which only works if the temp is free again before its next
# use. Handling the hazards one at a time does not achieve that: both parks
# are emitted before both consumers, so the second park overwrites the first
# and the fourth argument arrives holding the second. The symptom was an
# argument silently reading back as a neighbour, and because a constructor
# takes one register argument per field it took four fields to reach:
#
#     field i8 $a;  field i8 $b;  field i8 $c;  field i64 $d;
#
# so every test before this one passed at arity three and said nothing.
#
# A free function is the honest way to pin this down: no field layout, no
# sub-word store width, no constructor, just the argument registers themselves.
# It has to be swept by arity rather than tested at one width, since the
# failing arity is whatever fills the argument register set -- four on Win64,
# six on SysV, and a cycle at the point where the allocator starts permuting
# them at all.

my $brocken = Brocken->new;

SKIP: {
    skip 'Not native', 1 unless $brocken->platform->is_native;

    my $gp_args = scalar $brocken->platform->abi->param_registers->@*;

    for my $n ( 1 .. $gp_args ) {
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
        is( run($free), 42, "native: free function with $n argument(s), all in registers" );
    }

    # A constructor spends one of the argument registers on its own receiver, so
    # the field that fills the register set is already passing on the stack. That
    # is the case that used to be left out: five fields fills the SysV register
    # set exactly, and from there the caller needs two simultaneously live
    # reloads, which `insert_spill_code` emitted through the one spill temp it
    # had. The second reload clobbered the first, so the store landed through an
    # integer instead of the object address.
    for my $n ( 1 .. $gp_args ) {
        my @args = map { $_ + 1 } 0 .. $n - 1;
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
        is( run($ctor), 42, "native: constructor with $n argument field(s)" );
    }
}

done_testing;

sub run {
    my ($src) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/shuffle' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
