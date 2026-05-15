use v5.40;
use lib '../lib', 'lib';
use Brocken;
my $p = Brocken->new();
say 'Detected OS: ' . $p->os . ' Arch: ' . $p->arch;
my $as = $p->as;
#
if ( $p->os eq 'win64' ) {
    if ( $p->arch eq 'x64' ) {
        $as->sub_imm( 'rsp', 56 );
    }
    elsif ( $p->arch eq 'arm64' ) {    # Idk what else it *could* be but might as well be safe...
        $as->sub_imm( 'sp', 48 );
    }
}
$p->print_str("Pulse AOT Engine Starting...\n");
my $loop_reg = ( $p->arch eq 'arm64' ) ? 'x19' : 'rbx';
$as->mov_imm( $loop_reg, 1 );
$as->mark_label('loop');
$p->print_str(" -> Inside Loop Iteration\n");
$as->add_imm( $loop_reg, 1 );
$as->cmp_reg_imm( $loop_reg, 4 );
$as->jcc( $p->cc('lt'), 'loop' );
$p->print_str("Done! Exiting with status 42.\n");
$p->exit_proc(42);
$as->resolve();
#
my $exe    = $p->write_bin('pulse_output');
my $runexe = $exe;
$runexe =~ s{^\./}{} if $^O eq 'MSWin32';
if ( $p->os =~ /bsd/ ) {
    system 'readelf -Wl ' . $runexe;
    system 'ktrace', $runexe;
    system 'kdump';
    system 'dmesg | tail -n 20';
}
my $status = system($runexe);
if ( $status == -1 ) {
    say "Failed to execute: $!";
    exit 1;
}
elsif ( $status & 127 ) {
    printf 'Child died with signal %d, %s coredump', ( $status & 127 ), ( $status & 128 ) ? 'with' : 'without';
    exit 1;
}
else {
    my $exit_code = $status >> 8;
    printf 'Exit code: %d', $exit_code;
    exit( $exit_code == 42 ? 0 : 1 );
}
