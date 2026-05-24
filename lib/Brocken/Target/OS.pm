use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS {
    field $name : param : reader;
    ADJUST {
        die "Invalid OS: $name" unless $name =~ /^(?:linux|win64|macos|freebsd|openbsd|netbsd|solaris|dragonfly|midnightbsd|haiku)$/;
    }

    method is_posix () {
        return $self->name ne 'win64';
    }

    method is_bsd_like () {
        return $self->name =~ /^(?:macos|freebsd|openbsd|netbsd|dragonfly|solaris|midnightbsd)$/;
    }

    method uses_syscalls () {
        return $self->is_posix;
    }

    method exe_ext () {
        return $self->name eq 'win64' ? '.exe' : '';
    }

    method lib_ext () {
        return { win64 => '.dll', macos => '.dylib' }->{ $self->name } // '.so';
    }

    method exe_name ($base) {
        return $self->name eq 'win64' ? "./$base.exe" : "./$base";
    }

    method lib_name ($base) {
        my $ext = $self->lib_ext;
        return "$base$ext";
    }

    method syscall_write ($arch) {
        my $n = $self->name;
        return 0x2000004 if $n eq 'macos';
        return 1         if $n eq 'linux'      && $arch eq 'x64';
        return 64        if $n eq 'linux'      && $arch eq 'arm64';
        return 4         if $self->is_bsd_like && $arch eq 'x64';
        return 4         if $self->is_bsd_like && $arch eq 'arm64';
        return undef;
    }

    method syscall_exit ($arch) {
        my $n = $self->name;
        return 0x2000001 if $n eq 'macos';
        return 60        if $n eq 'linux' && $arch eq 'x64';
        return 93        if $n eq 'linux' && $arch eq 'arm64';
        return 1         if $self->is_bsd_like;
        return undef;
    }

    method syscall_num_reg ($arch) {
        return 'rax' if $arch eq 'x64';
        return 'x8'  if $arch eq 'arm64';
        return undef;
    }

    method page_size ($arch) {
        return 0x1000;
    }

    method write_syscall_args ( $as, $arch, $data_rva, $off, $text_rva, $len ) {
        if ( $arch eq 'arm64' ) {
            $as->lea_rva( 'x1', $data_rva + $off, $text_rva );
            $as->mov_imm( 'x2', $len );
        }
        else {
            $as->lea_rva( 'rsi', $data_rva + $off, $text_rva );
            $as->mov_imm( 'rdx', $len );
        }
    }

    method haiku_syscall ( $name, $arch = 'x64' ) {
        return undef;
    }

    sub detect_host ($class) {
        my $n = 'linux';
        $n = 'win64'       if $^O eq 'MSWin32' || $^O eq 'cygwin';
        $n = 'macos'       if $^O eq 'darwin';
        $n = 'freebsd'     if $^O eq 'freebsd';
        $n = 'openbsd'     if $^O eq 'openbsd';
        $n = 'netbsd'      if $^O eq 'netbsd';
        $n = 'solaris'     if $^O eq 'solaris';
        $n = 'dragonfly'   if $^O eq 'dragonfly';
        $n = 'midnightbsd' if $^O eq 'midnightbsd';
        $n = 'haiku'       if $^O eq 'haiku';
        return $class->from_name($n);
    }

    sub from_name ( $class, $n ) {
        my $subclass = {
            linux       => 'Brocken::Target::OS::Linux',
            win64       => 'Brocken::Target::OS::Win64',
            macos       => 'Brocken::Target::OS::MacOS',
            freebsd     => 'Brocken::Target::OS::FreeBSD',
            openbsd     => 'Brocken::Target::OS::OpenBSD',
            netbsd      => 'Brocken::Target::OS::NetBSD',
            solaris     => 'Brocken::Target::OS::Solaris',
            dragonfly   => 'Brocken::Target::OS::Dragonfly',
            midnightbsd => 'Brocken::Target::OS::MidnightBSD',
            haiku       => 'Brocken::Target::OS::Haiku',
        }->{$n} // return __PACKAGE__->new( name => $n );
        eval "require $subclass" or die $@;
        return $subclass->new( name => $n );
    }
}
1;
