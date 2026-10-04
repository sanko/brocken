use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Katsuro::Platform::Haiku v0.0.1 : isa(Brocken::Katsuro::Platform) {
    my %cache;
    method is_haiku()    {1}
    method libc_name()   {'libroot.so'}
    method interpreter() {'/boot/system/runtime_loader'}
    method exit_name()   {'exit'}

    # Haiku's syscall numbers are unstable and not officially exposed.
    # We use a heuristic by disassembling libroot.so functions to find the 'mov eax, imm' instruction that precedes the
    # syscall.
    sub _detect_syscall( $class, $name, $arch ) {
        my $lib = '/boot/system/lib/libroot.so';
        return undef unless -e $lib;
        my $stub //= {
            write  => '_kern_write',
            exit   => '_kern_exit_team',
            fork   => '_kern_fork',
            wait4  => '_kern_wait_for_child',
            read   => '_kern_read',
            open   => '_kern_open',
            close  => '_kern_close',
            getpid => '_kern_getpid'
        };
        my $fn  = $stub->{$name} or return undef;
        my $dis = '';
        no warnings 'exec';
        if ( open my $fh, '-|', 'objdump', '-d', $lib ) {
            my $output = do { local $/; <$fh> };
            close $fh;
            my @lines   = split /\n/, $output;
            my $capture = 0;
            for my $line (@lines) {
                if ( $line =~ /<\Q$fn\E>:/ ) {
                    $capture = 21;
                }
                elsif ( $capture > 0 ) {
                    $dis .= $line . "\n";
                    $capture--;
                }
                last if $capture == 0;
            }
        }
        return undef unless length $dis;
        if ( $arch =~ /x86_64|x64|amd64/i ) {
            return hex($1) if $dis =~ /mov\s+\$0x([0-9a-f]+),\s*%[er]?ax/i || $dis =~ /mov\s+[er]?ax,\s*0x([0-9a-f]+)/i;
        }
        elsif ( $arch =~ /aarch64|arm64/i ) { return hex($1) if $dis =~ /mov\s+x8,\s*#0x([0-9a-f]+)/i }
        elsif ( $arch =~ /riscv64|riscv/i ) { return hex($1) if $dis =~ /li\s+a7,\s*#?0x([0-9a-f]+)/i }
        return undef;
    }

    method syscall($name) {
        return $cache{ $self->arch }{$name} if exists $cache{ $self->arch }{$name};
        my $num;
        $num = _detect_syscall( ref($self), $name, $self->arch ) if $self->is_native;
        unless ( defined $num ) {

            # Fallback syscall numbers for Haiku R1/beta4
            state $fallback //= {
                x86_64 => {
                    write     => 144,
                    exit      => 38,
                    fork      => 47,
                    wait4     => 45,
                    read      => 148,
                    open      => 83,
                    close     => 42,
                    getpid    => 46,
                    mmap      => 103,
                    nanosleep => 156,
                    brk       => 110
                },
                aarch64 => {
                    write     => 144,
                    exit      => 38,
                    fork      => 47,
                    wait4     => 45,
                    read      => 148,
                    open      => 83,
                    close     => 42,
                    getpid    => 46,
                    mmap      => 103,
                    nanosleep => 156,
                    brk       => 110
                },
                riscv64 => {
                    write     => 144,
                    exit      => 38,
                    fork      => 47,
                    wait4     => 45,
                    read      => 148,
                    open      => 83,
                    close     => 42,
                    getpid    => 46,
                    mmap      => 103,
                    nanosleep => 156,
                    brk       => 110
                }
            };
            $num = $fallback->{ $self->arch }{$name};
        }
        $cache{ $self->arch }{$name} = $num;
        return $num;
    }
} 1;
