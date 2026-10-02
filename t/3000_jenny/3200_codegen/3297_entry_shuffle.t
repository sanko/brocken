use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

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
# Those captures do not run in isolation.  They all read the caller's registers
# before any of them is overwritten, so they are one parallel move, and the
# register allocator is free to pick a destination that is still a pending
# source -- which is what it did with four integer parameters, producing the
# cycle `rcx <- rdi, rdx <- rsi, rsi <- rdx, rdi <- rcx`.
#
# Parking every clobbered source in one temp and then emitting the consumers
# does not work: both parks are emitted before both consumers, so the second
# park overwrites the first and the fourth argument arrives holding the second.
# A temp that is not reserved from allocation is worse still: it can itself be
# picked as a capture destination.  The shuffle is scheduled as a real parallel
# move instead, so a group of any size can be ordered.
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
        my @params = map {"i64 \$v$_"} 0 .. $n - 1;
        my @args   = map { $_ + 1 } 0 .. $n - 1;
        my $sum    = join( ' + ', map {"\$v$_"} 0 .. $n - 1 );
        my $total  = 0;
        $total += $_ for @args;
        my $free = <<"BROCKEN";
sub f( @{[ join ', ', @params ]} ) -> i64 { return $sum; }
if ( f( @{[ join ', ', @args ]} ) == $total ) { return 42; }
return 1;
BROCKEN
        is( run($free), 42, "native: free function with $n argument(s), all in registers" );
    }
}
done_testing;

sub run {
    my ($src)  = @_;
    my $module = Brocken->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/shuffle' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
