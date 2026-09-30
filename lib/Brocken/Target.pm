use v5.40;
use feature 'class';
no warnings qw[portable experimental::class experimental];
use Config ();
use POSIX  ();

# The abstract base of the format layer, so that the class this file selects is
# already loaded by the time anything asks for it.
builtin::load_module 'Brocken::Target::Format';

# Picks the architecture, ABI, and object file format classes for a target and
# exposes them through one object.
#
# The selection logic is not new. It was open-coded at each call site, in
# t/000_basic/000_init.t and in the hand-written per-target script, as a name
# map plus a conditional that chose PE on win64, MachO on macos, and ELF
# everywhere else. It lives here so there is one copy of it.
class Brocken::Target v0.0.1 {
    field $os           : param : reader;
    field $arch         : param : reader;
    field $format_name  : param : reader;
    field $arch_class   : param : reader;
    field $format_class : param : reader;
    field $abi_class    : param : reader;

    # The architecture spellings differ between perl, the assembler classes,
    # and the compiler toolchains, and all three turn up in the wild, so more
    # than one is accepted and translated here. That is the only place the
    # translation happens.
    my %ARCH_CLASS = (
        x64     => 'Brocken::Target::Architecture::X64',
        x86_64  => 'Brocken::Target::Architecture::X64',
        amd64   => 'Brocken::Target::Architecture::X64',
        arm64   => 'Brocken::Target::Architecture::ARM64',
        aarch64 => 'Brocken::Target::Architecture::ARM64',
        riscv64 => 'Brocken::Target::Architecture::RISCV64'
    );

    # The format follows from the OS, because there is no way to produce an ELF
    # for Windows or a PE for macOS. Anything not named here gets ELF, which
    # covers every POSIX system in the hierarchy.
    my %FORMAT_FOR_OS = ( win64 => 'PE', macos => 'MachO' );
    my $ABI_CLASS     = 'Brocken::Target::ABI';

    # This is the constructor to use. It resolves the classes and loads them,
    # then hands the names to new() as parameters.
    sub for ( $class, $os_name, $arch_name ) {
        my $format_name  = $FORMAT_FOR_OS{$os_name} // 'ELF';
        my $arch_class   = $ARCH_CLASS{$arch_name} or die "Unknown arch: $arch_name";
        my $format_class = "Brocken::Target::Format::$format_name";
        for my $to_load ( 'Brocken::Target::OS', $arch_class, $format_class, $ABI_CLASS ) {
            builtin::load_module($to_load);
        }
        return $class->new(
            os           => $os_name,
            arch         => $arch_name,
            format_name  => $format_name,
            arch_class   => $arch_class,
            format_class => $format_class,
            abi_class    => $ABI_CLASS
        );
    }
    method os_object () { Brocken::Target::OS->from_name( $self->os ) }
    method arch_asm ()  { $self->arch_class->new }
    method format ()    { $self->format_class->new }
    method abi ()       { $self->abi_class->new }

    # The name to give an executable built from $base, which is the one thing
    # most callers wanted and had to reach through the OS object for.
    method exe_name ($base) { $self->os_object->exe_name($base) }

    # An OS to target with the architecture defaulting to this host's.
    sub from_name ( $class, $os_name, $arch_name = undef ) {
        $arch_name //= $class->detect_host->{arch};
        return $class->for( $os_name, $arch_name );
    }

    sub for_host ($class) {
        my $host = $class->detect_host;
        return $class->for( $host->{os}, $host->{arch} );
    }

    # Returns { os => ..., arch => ... } for this machine.
    #
    # The OS comes from Brocken::Target::OS::detect_host, which already knows
    # that perl spells DragonFly as dragonflybsd and Windows as MSWin32. The
    # architecture is taken from uname where that is available and from
    # Config's archname otherwise, which is the fallback order
    # Brocken::Katsuro::Platform uses.
    sub detect_host ($class) {
        my $os   = Brocken::Target::OS->detect_host->name;
        my $arch = 'unknown';
        if ( $^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys' ) {
            my $win = $ENV{PROCESSOR_ARCHITEW6432} || $ENV{PROCESSOR_ARCHITECTURE} // '';
            $arch = 'aarch64' if $win =~ /^ARM64$/i;
            $arch = 'x86_64'  if $win =~ /^(?:AMD64|x86_64)$/i;
        }
        else {
            my @uname = eval { POSIX::uname() };
            $arch = $uname[4] // 'unknown' if @uname;
        }
        if ( !defined $arch || $arch eq '' || $arch eq 'unknown' ) {
            $arch = $Config::Config{archname} // 'unknown';
            $arch =~ s/-.*//;
        }
        $arch = lc $arch;
        $arch = 'x86_64'  if $arch eq 'amd64';
        $arch = 'aarch64' if $arch =~ /^(?:aarch64|arm64)$/;
        return { os => $os, arch => $arch };
    }
} 1;
