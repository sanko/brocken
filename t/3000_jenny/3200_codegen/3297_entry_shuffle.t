use v5.42;
use Test2::V0 '!subtest';
use blib;
use Brocken;
use Brocken::Katsuro;
use Brocken::Katsuro::Platform;
use Brocken::Lindsay;
use Brocken::Jenny;
use Test2::Tools::Brocken qw[run_exec cross_available temp_path];
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
# Those captures do not run in isolation.  They all read the caller's registers before any of them is overwritten, so
# they are one parallel move, and the register allocator is free to pick a destination that is still a pending source --
# which is what it did with four integer parameters, producing the cycle `rcx <- rdi, rdx <- rsi, rsi <- rdx, rdi <-
# rcx`.
#
# Parking every clobbered source in one temp and then emitting the consumers
# does not work: both parks are emitted before both consumers, so the second park overwrites the first and the fourth
# argument arrives holding the second.
# A temp that is not reserved from allocation is worse still: it can itself be picked as a capture destination.  The
# shuffle is scheduled as a real parallel move instead, so a group of any size can be ordered.
#
# A free function is the honest way to pin this down: no field layout, no sub-word store width, no constructor, just the
# argument registers themselves.
# It has to be swept by arity rather than tested at one width, since the failing arity is whatever fills the argument
# register set -- four on Win64, six on SysV, and a cycle at the point where the allocator starts permuting them at all.
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

# The same parallel move spans both register files, and that is where a capture
# can hide behind traffic that looks like it does not belong to the move.  An
# integer argument past the integer registers is read from the stack at the top
# of the function, and a floating-point capture declared after it still has to be
# part of the same move: its destination can be a register an earlier
# floating-point capture read, so leaving it out lets the earlier one win.
# The arguments interleave so a float capture follows an integer stack read, and
# the counts run past each register file so both a stack read and a spill occur.
#
# SysV is where the shape appears -- six integer and eight floating-point
# registers, and stack arguments read below the register captures -- so the
# sweep is pinned to it and executed natively or under emulation, whichever the
# host offers.
SKIP: {
    my $target = Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu');
    my $gp     = scalar $target->abi->param_registers->@*;
    my $fp     = scalar $target->abi->fp_param_registers->@*;
    my $limit  = ( $gp > $fp ? $gp : $fp ) + 4;
    skip 'x86_64 SysV not executable here', $limit unless cross_available($target);
    my $cross = Brocken->new( platform => $target );
    for my $n ( 1 .. $limit ) {
        my ( @params, @args, @terms );
        my $sum        = 0;
        my ( $ni, $nf ) = ( $n, $n );
        for my $k ( 0 .. 2 * $n - 1 ) {
            if ( $k % 2 || $ni == 0 ) {
                my $v = $nf--;
                push @params, "f64 \$f$v";
                push @args,   "$v.0";
                push @terms,  "\$f$v";
                $sum += $v;
            }
            else {
                my $v = $ni--;
                push @params, "i64 \$i$v";
                push @args,   "$v";
                push @terms,  "\$i$v";
                $sum += $v;
            }
        }
        my $params = join ', ', @params;
        my $terms  = join ' + ', @terms;
        my $call   = join ', ', @args;
        my $src    = <<"BROCKEN";
sub g( $params ) -> i64 {
    my f64 \$s = $terms;
    my i64 \$j = \$s;
    return \$j;
}
if ( g( $call ) == $sum ) { return 42; }
return 1;
BROCKEN
        my $module = $cross->compile($src);
        my $funcs  = $cross->codegen->emit_functions( $module->functions );
        my $out    = temp_path( 'shuffle_mixed' . $cross->ext );
        $cross->linker->write_executable( $out, $funcs, $target );
        run_exec(
            $out,
            expected_exit => 42,
            platform      => $target,
            name          => "x86_64 SysV: $n interleaved integer/float argument(s)",
        );
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
