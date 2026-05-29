use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::Haiku : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'haiku';
    }
    state %cache;

    method syscall_write ($arch) {
        return $self->haiku_syscall( '_kern_write', $arch );
    }

    method syscall_exit ($arch) {
        return $self->haiku_syscall( '_kern_exit_team', $arch );
    }

    method syscall_wait4 ($arch) {
        return $self->haiku_syscall( '_kern_wait_for_child', $arch );
    }

    # Haiku-specific syscall argument setup for _kern_wait_for_child
    # The signature is likely: _kern_wait_for_child(thread_id, ...)
    # I suspect it needs status, options, etc.
    method syscall_fork ($arch) {
        return $self->haiku_syscall( '_kern_fork', $arch );
    }

    method haiku_syscall ( $name, $arch = 'x64' ) {
        my $key = "$name|$arch";
        return $cache{$key} if exists $cache{$key};
        my $num = 0;
        if ( -e '/boot/system/lib/libroot.so' ) {
            my $dump = `objdump -d /boot/system/lib/libroot.so 2>/dev/null | grep -A 5 "<$name>:"`;
            if ( $arch eq 'x64' ) {
                if ( $dump =~ /movl?\s+\$0x([0-9a-f]+),%[er]?ax/i ) {
                    $num = hex($1);
                }
                elsif ( $dump =~ /movl?\s+%[er]?ax,\s*(?:0x)?([0-9a-f]+)/i ) {
                    $num = hex($1);
                }
                elsif ( $dump =~ /mov\s+eax,\s*0x([0-9a-f]+)/i ) {
                    $num = hex($1);
                }
            }
            elsif ( $arch eq 'arm64' ) {
                if ( $dump =~ /mov\s+x8,\s*#?0x([0-9a-f]+)/i ) {
                    $num = hex($1);
                }
            }
            elsif ( $arch eq 'riscv64' ) {
                if ( $dump =~ /li\s+a7,\s*#?0x([0-9a-f]+)/i ) {
                    $num = hex($1);
                }
            }
        }
        if ( !$num ) {
            my $fallbacks = { '_kern_write' => 151, '_kern_exit_team' => 41, '_kern_wait_for_child' => 45, '_kern_fork' => 47, };
            $num = $fallbacks->{$name} // 0;
        }
        return $cache{$key} = $num;
    }

    method write_syscall_args ( $as, $arch, $data_rva, $off, $text_rva, $len ) {
        if ( $arch eq 'arm64' ) {
            $as->mov_imm( 'x1', -1 );
            $as->lea_rva( 'x2', $data_rva + $off, $text_rva );
            $as->mov_imm( 'x3', $len );
        }
        elsif ( $arch eq 'riscv64' ) {
            $as->mov_imm( 'a0', -1 );
            $as->lea_rva( 'a1', $data_rva + $off, $text_rva );
            $as->mov_imm( 'a2', $len );
        }
        else {
            $as->mov_imm( 'rsi', -1 );
            $as->lea_rva( 'rdx', $data_rva + $off, $text_rva );
            $as->mov_imm( 'r10', $len );
        }
    }
}
1;
