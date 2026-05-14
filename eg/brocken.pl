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
my $exe = $p->write_bin('pulse_output');
$exe = "./$exe" if $^O ne 'MSWin32';
my $status = system($exe);
if ( $status == -1 ) {
    say "Failed to execute: $!";
}
elsif ( $status & 127 ) {
    printf 'Child died with signal %d, %s coredump', ( $status & 127 ), ( $status & 128 ) ? 'with' : 'without';
}
else {
    printf 'Exit code: %d', $status >> 8;
}
