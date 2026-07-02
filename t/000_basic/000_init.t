use v5.40;
use lib '../../lib', 'lib';
use Brocken;
use Brocken::Target::OS;
use Test2::V0;
my $p         = Brocken->new();
my $plat      = $p->platform;
my %os_map    = ( windows => 'win64', darwin => 'macos', dragonflybsd => 'dragonfly' );
my $os_name   = $os_map{ $plat->os } // $plat->os;
my %arch_map  = ( x86_64 => 'x64', aarch64 => 'arm64' );
my $arch_name = $arch_map{ $plat->arch } // $plat->arch;
diag 'Detected OS: ' . $os_name . ' Arch: ' . $arch_name;
my $os         = Brocken::Target::OS->from_name($os_name);
my %arch_class = (
    x64     => 'Brocken::Target::Architecture::X64',
    arm64   => 'Brocken::Target::Architecture::ARM64',
    riscv64 => 'Brocken::Target::Architecture::RISCV64'
);
my $arch_class = $arch_class{$arch_name} or die "Unknown arch: $arch_name";
eval "require $arch_class"               or die $@;
my $as = $arch_class->new;

if ( $os_name eq 'win64' ) {
    if ( $arch_name eq 'x64' ) {
        $as->sub_imm( 'rsp', 56 );
    }
    elsif ( $arch_name eq 'arm64' ) {
        $as->sub_imm( 'sp', 48 );
    }
}
my $data = '';
my %cc   = (
    x64     => { lt => 0xC, ge => 0xD, eq => 0x4, ne => 0x5, le => 0xE, gt => 0xF },
    arm64   => { lt => 0xB, ge => 0xA, eq => 0x0, ne => 0x1, le => 0xD, gt => 0xC },
    riscv64 => { lt => 0xB, ge => 0xA, eq => 0x0, ne => 0x1, le => 0xD, gt => 0xC },
);
my %loop_reg = ( x64 => 'rbx', arm64 => 'x19', riscv64 => 's0' );
my $ps       = sub { my ($m) = @_; my $o = length $data; $data .= $m; $as->emit_print_str( $os, $o, length $m ) };
$ps->("# Brocken AOT Engine Starting...\n");
$as->mov_imm( $loop_reg{$arch_name}, 1 );
$as->mark_label('loop');
$ps->("# -> Inside Loop Iteration\n");
$as->add_imm( $loop_reg{$arch_name}, 1 );
$as->cmp_reg_imm( $loop_reg{$arch_name}, 4 );
$as->jcc( $cc{$arch_name}{lt}, 'loop' );
$ps->("# Done! Exiting with status 42.\n");
$as->emit_exit_proc( $os, 42 );
$as->resolve();
my $fmt_class = "Brocken::Target::Format::" . ( $os_name eq 'win64' ? 'PE' : $os_name eq 'macos' ? 'MachO' : 'ELF' );
eval "require $fmt_class" or die $@;
my $fmt = $fmt_class->new;
my $out = $os->exe_name('pulse_output');
$fmt->write_bin( $out, $as->code, $data, $arch_name, $os_name );
my $runexe = $out;
$runexe =~ s{^\./}{} if $^O eq 'MSWin32';

if ( $os_name =~ /bsd/ ) {
    system 'readelf -Wl ' . $runexe;
    system 'ktrace', $runexe;
    system 'kdump';
    system 'dmesg | tail -n 20';
}
my $status = system($runexe);
if ( $status == -1 ) {
    fail 'Failed to execute: ' . $!;
}
elsif ( $status & 127 ) {
    fail sprintf 'Child died with signal %d, %s coredump', ( $status & 127 ), ( $status & 128 ) ? 'with' : 'without';
}
else {
    is $status >> 8, 42, 'exit code is 42';
}
done_testing;
