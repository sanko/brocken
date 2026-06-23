use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;

class Brocken::Jenny::Linker::ELF64 : isa(Brocken::Jenny::Linker) {
    use Brocken::Jenny::Codegen::ARM64::Inst;
    use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC O_RDWR);

=pod

=head1 NAME

Brocken::Jenny::Linker::ELF64 - 64-bit Executable and Linkable Format Generator

=cut

    # Structurally compliant segment layout grouping all read-only sections
    # in the RX segment, and keeping only writable sections in the RW segment.
    method _setup_layout( $layout, $text_size, $data_size, $arch, $os, $dbg = 0 ) {

        # Flags: 1=alloc, 2=write, 4=execute
        $layout->add_section( '.text', $text_size, 5 );    # RX (Alloc + Execute)
        my $brk_sym_size = $self->brk_sym_size();
        $layout->add_section( '.brk_sym', $brk_sym_size, 2 ) if $brk_sym_size > 0;

        # Read-only metadata sections (strictly mapped to RX segment)
        $layout->add_section( '.interp',   512,  2 ) if $self->type eq 'exe';
        $layout->add_section( '.dynstr',   4096, 2 );
        $layout->add_section( '.dynsym',   4096, 2 );
        $layout->add_section( '.rela.dyn', 4096, 2 );
        $layout->add_section( '.hash',     4096, 2 );

        # Writable data and dynamic linking tables (mapped to RW segment)
        $layout->add_section( '.dynamic', 4096,       3 );    # RW (Alloc + Write)
        $layout->add_section( '.data',    $data_size, 6 );    # RW (Alloc + Write + Unknown flag 4)
        $layout->add_section( '.got',     512,        6 );    # RW

        # Non-alloc symbol and string tables for static linking/debugging (nm)
        $layout->add_section( '.symtab', 4096, 0 );
        $layout->add_section( '.strtab', 4096, 0 );
        #
        if ( $dbg >= 1 ) {
            $layout->add_section( '.debug_line',     4096, 0 );
            $layout->add_section( '.debug_info',     4096, 0 );
            $layout->add_section( '.debug_abbrev',   4096, 0 );
            $layout->add_section( '.debug_aranges',  4096, 0 );
            $layout->add_section( '.debug_pubnames', 4096, 0 );
            $layout->add_section( '.debug_names',    4096, 0 );
            $layout->add_section( '.debug_str',      4096, 0 );
            $layout->add_section( '.eh_frame',       4096, 0 );
        }
    }

    method import_rva($name) {

        # GOT slot offsets for dynamic linker imports:
        #   dlopen         = +24  (offset 3, index 3)
        #   dlsym          = +32  (offset 4, index 4)
        #   pthread_create = +40  (offset 5, index 5)
        #   exit / _exit   = +48  (offset 6, index 6)
        # Slot 0-2 reserved (0, DYNAMIC, LINK_MAP).
        my $imports = { dlopen => 24, dlsym => 32, pthread_create => 40, exit => 48, _exit => 48 };
        return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die 'Unknown ELF import: ' . $name );
    }

    # Standard Linux x86_64 static image base; PIE/BSD use base 0 for ASLR.
    method image_base () { return $self->type eq 'shared' ? 0 : 0x400000; }

    method write_executable ( $output_file, $code_data, $platform, $shared = false, $debug_bytes = undef ) {
        $platform = Brocken::Katsuro::Platform::parse($platform) unless ref $platform;
        my @func_fixups;
        my %func_offsets;
        my $code_bytes;
        if ( ref $code_data eq 'ARRAY' ) {
            my @blobs;
            my $offset = 0;
            for my $fd ( $code_data->@* ) {
                $func_offsets{ $fd->{name} } = $offset;
                push @blobs, $fd->{bytes};
                for my $fixup ( $fd->{fixups}->@* ) {
                    push @func_fixups, { %$fixup, base_offset => $offset };
                }
                $offset += length( $fd->{bytes} );
            }
            $code_bytes = join( '', @blobs );
            for my $name ( $self->exported_funcs->@* ) {
                $self->labels->{"E_$name"} //= $func_offsets{$name};
            }
        }
        else {
            $code_bytes = $code_data;
        }
        if ( !defined $self->layout ) {
            my $extra_data = $platform->is_bsd ? 32 : ( $platform->is_haiku ? 8 : 0 );
            my $entry_stub_len = $self->type eq 'exe' ? 20 : 0;
            $self->pre_layout( length($code_bytes) + $entry_stub_len, $extra_data, $platform );
        }
        my $l          = $self->layout;
        my $is_pie     = ( $platform->is_bsd || $platform->is_haiku ) && !$shared;
        my $base       = $is_pie ? 0 : $self->image_base;
        my $elf_type   = $shared ? 3 : ( $is_pie ? 3 : 2 );    # ET_DYN (3) for PIE, ET_EXEC (2) for static
        my $text_rva   = $self->layout->get('.text')->{rva};
        my $got_rva    = $self->layout->get('.got')->{rva};
        my $page_align = $self->layout->section_align;
        my $text       = $code_bytes;
        my $entry_stub = '';

        if ( $self->type eq 'exe' ) {
            if ( $platform->is_arm64 ) {

                # ARM64 entry: bl main -> adrp x8, exit-GOT-page -> ldr x8, [x8, exit-GOT-off] -> blr x8 -> brk #0
                my $got_exit = $self->import_rva('exit');
                my $bl_main  = bl( 20 + ( $func_offsets{main} // 0 ) );
                my $adrp     = adrp( 8, $got_exit, $text_rva + 4 );
                my $pimm     = $got_exit & 0xFFF;
                my $ldr      = ldr_64( 8, 8, $pimm );
                my $blr      = blr(8);
                my $brk      = brk(0);
                $entry_stub = pack 'V5', $bl_main, $adrp, $ldr, $blr, $brk;
            }
            elsif ( $platform->is_riscv64 ) {

                # RISC-V entry: jal main -> auipc t0, exit-GOT-hi -> ld t0, [t0, exit-GOT-lo] -> jalr zero, t0, 0 -> ebreak
                my $got_exit   = $self->import_rva('exit');
                my $auipc_pc   = $text_rva + 4;
                my $diff       = $got_exit - $auipc_pc;
                my $hi20       = ( $diff + 0x800 ) >> 12;
                my $lo12       = $diff & 0xFFF;
                my $auipc      = ( ( $hi20 & 0xFFFFF ) << 12 ) | ( 5 << 7 ) | 0x17;
                my $ld         = ( ( $lo12 & 0xFFF ) << 20 ) | ( 5 << 15 ) | ( 3 << 12 ) | ( 5 << 7 ) | 0x03;
                my $jalr       = ( 0 << 20 ) | ( 5 << 15 ) | ( 0 << 12 ) | ( 0 << 7 ) | 0x67;
                my $jal_offset = 20 + ( $func_offsets{main} // 0 );
                my $halfword   = $jal_offset >> 1;
                my $jal_imm    = ( ( $halfword >> 19 ) & 1 ) << 31 | ( ( $halfword & 0x3FF ) << 21 ) | ( ( $halfword >> 10 ) & 1 ) << 20
                    | ( ( $halfword >> 11 ) & 0xFF ) << 12;
                my $jal    = $jal_imm | ( 1 << 7 ) | 0x6F;
                my $ebreak = 0x00100073;
                $entry_stub = pack( 'V5', $jal, $auipc, $ld, $jalr, $ebreak );
            }
            else {
                # x86_64 Dynamic Exit Stub with System V RSP alignment
                my $got_exit = $self->import_rva('exit');
                my $next_ip  = $text_rva + 18;
                my $rel32    = $got_exit - $next_ip;
                my $main_rel = 11 + ( $func_offsets{main} // 0 );
                $entry_stub = pack( 'C4', 0x48, 0x83, 0xE4, 0xF0 );    # and rsp, -16
                $entry_stub .= pack( 'C V',   0xE8, $main_rel );       # call main (rel32)
                $entry_stub .= pack( 'C3',    0x48, 0x89, 0xC7 );      # mov rdi, rax (return value -> exit arg1)
                $entry_stub .= pack( 'C2 l<', 0xFF, 0x15, $rel32 );    # call [rip + got_exit] (indirect)
                $entry_stub .= pack( 'C2',    0x0F, 0x0B );            # ud2 (safety barrier)
            }
            $text = $entry_stub . $code_bytes;
            $self->layout->get('.text')->{size} = length($text);
        }

        # Resolve cross-function call fixups at link time
        my $entry_size = $self->type eq 'exe' ? length($entry_stub) : 0;
        for my $ff (@func_fixups) {
            my $target_off = $func_offsets{ $ff->{target} };
            die "write_executable: undefined function '$ff->{target}'" unless defined $target_off;
            my $src_pos = $entry_size + $ff->{base_offset} + $ff->{offset};
            die "fixup offset $src_pos out of bounds" if $src_pos + 4 > length($text);
            if ( $ff->{type} eq 'call_rel32' ) {
                my $rel = ( $entry_size + $target_off ) - ( $src_pos + 5 );
                substr( $text, $src_pos + 1, 4, pack( 'V', $rel & 0xFFFFFFFF ) );
            }
            elsif ( $ff->{type} eq 'jmp_func_rel32' ) {
                my $rel = ( $entry_size + $target_off ) - ( $src_pos + 5 );
                substr( $text, $src_pos + 1, 4, pack( 'V', $rel & 0xFFFFFFFF ) );
            }
            elsif ( $ff->{type} eq 'lea_rel32' ) {
                my $rel = ( $entry_size + $target_off ) - ( $src_pos + 4 );
                substr( $text, $src_pos, 4, pack( 'V', $rel & 0xFFFFFFFF ) );
            }
            elsif ( $ff->{type} eq 'call_bl' ) {
                my $rel  = ( $entry_size + $target_off ) - $src_pos;
                my $word = unpack( 'V', substr( $text, $src_pos, 4 ) );
                $word = ( $word & 0xFC000000 ) | ( ( $rel >> 2 ) & 0x3FFFFFF );
                substr( $text, $src_pos, 4, pack( 'V', $word ) );
            }
            elsif ( $ff->{type} eq 'call_jal' ) {
                my $rel  = ( $entry_size + $target_off ) - $src_pos;
                my $half = $rel >> 1;
                my $enc
                    = ( ( $half >> 19 ) & 1 ) << 31 | ( ( $half & 0x3FF ) << 21 ) | ( ( $half >> 10 ) & 1 ) << 20 | ( ( $half >> 11 ) & 0xFF ) << 12;
                my $word = unpack( 'V', substr( $text, $src_pos, 4 ) );
                $word = ( $word & 0x00000FFF ) | $enc;
                substr( $text, $src_pos, 4, pack( 'V', $word ) );
            }
            elsif ( $ff->{type} eq 'adr' ) {
                my $rel  = ( $entry_size + $target_off ) - $src_pos;
                my $word = unpack( 'V', substr( $text, $src_pos, 4 ) );
                my $rd   = $word & 0x1F;
                my $lo   = $rel & 3;
                my $hi   = ( $rel >> 2 ) & 0x7FFFF;
                $word = 0x10000000 | ( $lo << 29 ) | ( $hi << 5 ) | $rd;
                substr( $text, $src_pos, 4, pack( 'V', $word ) );
            }
            elsif ( $ff->{type} eq 'auipc_pcrel' ) {
                my $rel   = ( $entry_size + $target_off ) - $src_pos;
                my $auipc = unpack( 'V', substr( $text, $src_pos, 4 ) );
                my $rd    = ( $auipc >> 7 ) & 0x1F;
                my $hi    = ( ( $rel + 0x800 ) >> 12 ) & 0xFFFFF;
                $auipc = ( $hi << 12 ) | ( $rd << 7 ) | 0x17;
                substr( $text, $src_pos, 4, pack( 'V', $auipc ) );
                my $lo   = $rel & 0xFFF;
                my $addi = ( $lo << 20 ) | ( $rd << 15 ) | ( 0 << 12 ) | ( $rd << 7 ) | 0x13;
                substr( $text, $src_pos + 4, 4, pack( 'V', $addi ) );
            }
        }

        # Deterministic OSABI and ABI notes explicitly defined per platform.
        # OSABI constants: 0=ELFOSABI_NONE, 2=ELFOSABI_NETBSD, 9=ELFOSABI_FREEBSD
        # Note format: namesz, descsz, type=NT_VERSION(1), name, desc (OS version integer)
        my $osabi        = 0;
        my $note_data    = '';
        my $has_pintable = 0;
        if ( $platform->is_freebsd ) {
            $osabi     = 9;
            $note_data = pack( 'L<3 a8 L<', 8, 4, 1, "FreeBSD\0", 1400097 );
        }
        elsif ( $platform->is_midnightbsd ) {
            $osabi     = 9;
            $note_data = pack( 'L<3 a12 L<', 12, 4, 1, "MidnightBSD\0", 300000 );
        }
        elsif ( $platform->is_netbsd ) {
            $osabi     = 2;
            $note_data = pack( 'L<3 a8 L<', 7, 4, 1, "NetBSD\0\0", 1099000000 );
            $note_data .= pack( 'L<3 a4 L<', 4, 4, 3, "PaX\0", 0x0a );
        }
        elsif ( $platform->is_openbsd ) {
            $osabi        = 0;
            $note_data    = pack( 'L<3 a8 L<', 8, 4, 1, "OpenBSD\0", 0 );
            $has_pintable = 1;
        }
        elsif ( $platform->is_dragonflybsd ) {
            $osabi     = 9;
            $note_data = pack( 'L<3 a12 L<', 10, 4, 1, "DragonFly\0\0\0", 600400 );
        }
        my %interp_map = (
            linux        => '/lib64/ld-linux-x86-64.so.2',
            linux_arm    => '/lib/ld-linux-aarch64.so.1',
            linux_riscv  => '/lib/ld-linux-riscv64-lp64d.so.1',
            freebsd      => '/libexec/ld-elf.so.1',
            netbsd       => '/usr/libexec/ld.elf_so',
            openbsd      => '/usr/libexec/ld.so',
            dragonfly    => '/usr/libexec/ld-elf.so.2',
            dragonflybsd => '/usr/libexec/ld-elf.so.2',
            solaris      => '/lib/64/ld.so.1',
            midnightbsd  => '/libexec/ld-elf.so.1',
            haiku        => '/boot/system/runtime_loader'
        );
        my %libc_map = (
            linux        => 'libc.so.6',
            linux_arm    => 'libc.so.6',
            linux_riscv  => 'libc.so.6',
            freebsd      => 'libc.so.7',
            netbsd       => 'libc.so.12',
            openbsd      => 'libc.so.98.1',
            dragonfly    => 'libc.so.8',
            dragonflybsd => 'libc.so.8',
            solaris      => 'libc.so.1',
            midnightbsd  => 'libc.so.7',
            haiku        => 'libroot.so'
        );
        my $pintable_data = '';
        if ( $has_pintable && $platform->is_openbsd ) {
            my $pos             = 0;
            my $text_rva_actual = $self->layout->get('.text')->{rva};
            my $exit_sys        = $platform->syscall('exit') // 1;
            if ( $platform->is_x64 ) {
                while ( ( my $idx = index( $text, "\x0F\x05", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_rva_actual + $idx;
                    $pintable_data .= pack( 'Q< L< x4', $vaddr, $exit_sys );
                    $pos = $idx + 2;
                }
            }
            else {
                while ( ( my $idx = index( $text, "\x01\x00\x00\xd4", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_rva_actual + $idx;
                    $pintable_data .= pack( 'Q< L< x4', $vaddr, $exit_sys );
                    $pos = $idx + 4;
                }
            }
        }
        my $interp     = '';
        my $has_interp = 0;
        my $os_base    = ( $platform->os =~ /^([A-Za-z]+)/ )[0] // $platform->os;
        if ( $self->type eq 'exe' ) {
            my $interp_key
                = ( $platform->is_arm64 && $platform->is_linux ) ? 'linux_arm' :
                ( $platform->is_riscv64 && $platform->is_linux ) ? 'linux_riscv' :
                $os_base;
            my $ipath = $interp_map{$interp_key} // '/lib/ld.so.1';
            if ( length $ipath ) {
                $interp                               = $ipath . "\0";
                $self->layout->get('.interp')->{size} = length($interp);
                $has_interp                           = 1;
            }
        }
        my @exports   = @{ $self->exported_funcs // [] };
        my $exit_name = $platform->is_haiku ? 'exit' : '_exit';
        my @imports   = ( 'dlopen', 'dlsym', 'pthread_create', $exit_name );
        my $libc      = $libc_map{$os_base} // 'libc.so';

        # Probe the exact dynamic libc.so name on the host filesystem when running natively
        if ( $platform->is_native ) {
            my @search_paths = (
                '/usr/lib', '/lib', '/lib64', '/usr/lib64',
                '/usr/lib/x86_64-linux-gnu', '/usr/lib/aarch64-linux-gnu', '/usr/lib/riscv64-linux-gnu',
            );
            my @found;
            for my $dir (@search_paths) {
                next unless -d $dir;
                my @matches;
                if ( opendir my $dh, $dir ) {
                    @matches = map {"$dir/$_"} grep {/^libc\.so\.\d/} readdir $dh;
                    closedir $dh;
                }
                for my $m (@matches) {
                    next if $m =~ /_p\.so/;
                    push @found, $m;
                }
            }
            if (@found) {
                my $best = (
                    sort {
                        my ( $amaj, $amin ) = $a =~ /libc\.so\.(\d+)(?:\.(\d+))?/;
                        my ( $bmaj, $bmin ) = $b =~ /libc\.so\.(\d+)(?:\.(\d+))?/;
                        ( $amaj // 0 ) <=> ( $bmaj // 0 ) || ( ( $amin // 0 ) <=> ( $bmin // 0 ) );
                    } @found
                )[-1];
                if ($best) {
                    require File::Basename;
                    $libc = File::Basename::basename($best);
                }
            }
        }
        my @libs = ($libc);
        if ( !$platform->is_haiku && !$platform->is_solaris ) {
            my $libpthread = $platform->is_freebsd || $platform->is_midnightbsd ? 'libthr.so.3' : 'libpthread.so.0';
            $libpthread = 'libpthread.so' if $platform->is_openbsd || $platform->is_netbsd || $platform->is_dragonflybsd;
            if ( $platform->is_native ) {
                my @search_paths = (
                    '/usr/lib', '/lib', '/lib64', '/usr/lib64',
                    '/usr/lib/x86_64-linux-gnu', '/usr/lib/aarch64-linux-gnu', '/usr/lib/riscv64-linux-gnu',
                );
                my @found;
                my $prefix = $platform->is_freebsd || $platform->is_midnightbsd ? 'libthr' : 'libpthread';
                for my $dir (@search_paths) {
                    next unless -d $dir;
                    my @matches;
                    if ( opendir my $dh, $dir ) {
                        @matches = map {"$dir/$_"} grep {/^\Q$prefix\E\.so\.\d/} readdir $dh;
                        closedir $dh;
                    }
                    for my $m (@matches) {
                        next if $m =~ /_p\.so/;
                        push @found, $m;
                    }
                }
                if (@found) {
                    my $best = (
                        sort {
                            my ( $amaj, $amin ) = $a =~ /\.so\.(\d+)(?:\.(\d+))?/;
                            my ( $bmaj, $bmin ) = $b =~ /\.so\.(\d+)(?:\.(\d+))?/;
                            ( $amaj // 0 ) <=> ( $bmaj // 0 ) || ( ( $amin // 0 ) <=> ( $bmin // 0 ) );
                        } @found
                    )[-1];
                    if ($best) {
                        require File::Basename;
                        $libpthread = File::Basename::basename($best);
                    }
                }
            }
            push @libs, $libpthread;
        }
        my $dynstr = "\0";
        my %str_off;
        for my $s ( @libs, @imports, @exports ) {
            next if exists $str_off{$s};
            $str_off{$s} = length($dynstr);
            $dynstr .= $s . "\0";
        }

        # Map BSD internal symbols
        if ( $platform->is_bsd && $self->type eq 'exe' ) {
            $str_off{'__progname'} = length($dynstr);
            $dynstr .= '__progname' . "\0";
            $str_off{'environ'} = length($dynstr);
            $dynstr .= 'environ' . "\0";
        }
        if ( $platform->is_haiku ) {
            $str_off{'_gSharedObjectHaikuABI'} = length($dynstr);
            $dynstr .= "_gSharedObjectHaikuABI\0";
            $str_off{'_gSharedObjectHaikuVersion'} = length($dynstr);
            $dynstr .= "_gSharedObjectHaikuVersion\0";
        }
        $self->layout->get('.dynstr')->{size} = length($dynstr);
        my $dynsym  = pack( 'L< C C S< Q< Q<', 0, 0, 0, 0, 0, 0 );
        my $sym_idx = 1;
        my %sym_indices;
        for my $name (@imports) {
            $sym_indices{$name} = $sym_idx++;
            $dynsym .= pack( 'L< C C S< Q< Q<', $str_off{$name}, 0x12, 0, 0, 0, 0 );
        }
        if ( $self->type eq 'shared' ) {
            for my $name (@exports) {
                my $rva = $self->layout->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
                $sym_indices{$name} = $sym_idx++;
                $dynsym .= pack( 'L< C C S< Q< Q<', $str_off{$name}, 0x12, 0, 1, $base + $rva, 0 );
            }
        }
        if ( $platform->is_bsd && $self->type eq 'exe' ) {
            my $progname_off = $str_off{'__progname'};
            if ( defined $progname_off ) {
                $sym_indices{'__progname'} = $sym_idx++;
                my $data_sec_idx;
                my $sec_i = 1;
                for my $s ( $self->layout->sections ) {
                    if ( $s->{name} eq '.data' ) {
                        $data_sec_idx = $sec_i;
                        last;
                    }
                    $sec_i++;
                }
                my $data_sec = $self->layout->get('.data');
                $dynsym .= pack( 'L< C C S< Q< Q<', $progname_off, 0x11, 0, $data_sec_idx // 0, $base + $data_sec->{rva} + 16, 8 );
            }
        }
        if ( $platform->is_bsd && $self->type eq 'exe' ) {
            my $environ_off = $str_off{'environ'};
            if ( defined $environ_off ) {
                $sym_indices{'environ'} = $sym_idx++;
                my $data_sec_idx;
                my $sec_i = 1;
                for my $s ( $self->layout->sections ) {
                    if ( $s->{name} eq '.data' ) {
                        $data_sec_idx = $sec_i;
                        last;
                    }
                    $sec_i++;
                }
                my $data_sec = $self->layout->get('.data');
                $dynsym .= pack( 'L< C C S< Q< Q<', $environ_off, 0x11, 0, $data_sec_idx // 0, $base + $data_sec->{rva} + 8, 8 );
            }
        }
        if ( $platform->is_haiku ) {
            my $abi_off = $str_off{'_gSharedObjectHaikuABI'};
            my $ver_off = $str_off{'_gSharedObjectHaikuVersion'};
            my $data_sec_idx;
            my $sec_i = 1;
            for my $s ( $self->layout->sections ) {
                if ( $s->{name} eq '.data' ) {
                    $data_sec_idx = $sec_i;
                    last;
                }
                $sec_i++;
            }
            my $data_sec = $self->layout->get('.data');
            $dynsym .= pack( 'L< C C S< Q< Q<', $abi_off, 0x11, 0, $data_sec_idx // 0, $base + $data_sec->{rva}, 4 );
            $sym_indices{'_gSharedObjectHaikuABI'} = $sym_idx++;
            $dynsym .= pack( 'L< C C S< Q< Q<', $ver_off, 0x11, 0, $data_sec_idx // 0, $base + $data_sec->{rva} + 4, 4 );
        }
        $self->layout->get('.dynsym')->{size} = length($dynsym);

        # Relocation type per architecture:
        #   ARM64:   R_AARCH64_GLOB_DAT   = 1025
        #   RISC-V:  R_RISCV_64           = 2
        #   x86_64:  R_X86_64_GLOB_DAT    = 6
        my $rel_type       = $platform->is_arm64 ? 1025 : ( $platform->is_riscv64 ? 2 : 6 );
        my $rela_dyn       = '';
        my $dlopen_slot    = $base + $self->import_rva('dlopen');
        my $dlopen_sym_idx = $sym_indices{'dlopen'};
        $rela_dyn .= pack( 'Q< Q< q<', $dlopen_slot, ( $dlopen_sym_idx << 32 ) | $rel_type, 0 );
        my $dlsym_slot    = $base + $self->import_rva('dlsym');
        my $dlsym_sym_idx = $sym_indices{'dlsym'};
        $rela_dyn .= pack( 'Q< Q< q<', $dlsym_slot, ( $dlsym_sym_idx << 32 ) | $rel_type, 0 );
        my $pthread_slot    = $base + $self->import_rva('pthread_create');
        my $pthread_sym_idx = $sym_indices{'pthread_create'};
        $rela_dyn .= pack( 'Q< Q< q<', $pthread_slot, ( $pthread_sym_idx << 32 ) | $rel_type, 0 );
        my $exit_slot    = $base + $self->import_rva('exit');
        my $exit_sym_idx = $sym_indices{$exit_name};
        $rela_dyn .= pack( 'Q< Q< q<', $exit_slot, ( $exit_sym_idx << 32 ) | $rel_type, 0 );
        $self->layout->get('.rela.dyn')->{size} = length($rela_dyn);

        # GOT layout: [0]=reserved, [1]=DT_DEBUG, [2]=LINK_MAP, [3]=dlopen, [4]=dlsym, [5]=pthread_create, [6]=exit
        my $got = pack( 'Q< Q< Q< Q< Q< Q< Q<', 0, 0, 0, 0, 0, 0, 0 );
        $self->layout->get('.got')->{size} = length($got);
        my $elf_hash = sub {
            my $name = shift;
            my $h    = 0;
            for my $c ( split //, $name ) {
                $h = ( $h << 4 ) + ord($c);
                $h &= 0xffffffff;
                my $g = $h & 0xf0000000;
                if ($g) { $h ^= ( $g >> 24 ); }
                $h &= 0x0fffffff;
            }
            return $h;
        };
        my $nbucket = 3;
        my $nchain  = $sym_idx;
        my @buckets = (0) x $nbucket;
        my @chains  = (0) x $nchain;
        for my $name ( keys %sym_indices ) {
            my $idx = $sym_indices{$name};
            my $h   = $elf_hash->($name);
            my $b   = $h % $nbucket;
            $chains[$idx] = $buckets[$b];
            $buckets[$b]  = $idx;
        }
        my $hash = pack( 'L<*', $nbucket, $nchain, @buckets, @chains );
        $self->layout->get('.hash')->{size}   = length($hash);
        $self->layout->get('.symtab')->{size} = length($dynsym);
        $self->layout->get('.strtab')->{size} = length($dynstr);
        $self->layout->calculate($page_align);
        my $dyn_rva        = $self->layout->get('.dynamic')->{rva};
        my $str_rva        = $self->layout->get('.dynstr')->{rva};
        my $sym_rva        = $self->layout->get('.dynsym')->{rva};
        my $hash_rva       = $self->layout->get('.hash')->{rva};
        my $rela_rva       = $self->layout->get('.rela.dyn')->{rva};
        my $got_rva_actual = $self->layout->get('.got')->{rva};
        my $dynamic        = '';

        # Dynamic section entries (d_tag, d_val/d_ptr):
        #   DT_NEEDED=1, DT_PLTGOT=3, DT_HASH=4, DT_STRTAB=5, DT_SYMTAB=6,
        #   DT_RELA=7, DT_RELASZ=8, DT_RELAENT=9, DT_STRSZ=10, DT_SYMENT=11
        for my $lib (@libs) {
            $dynamic .= pack( 'Q< Q<', 1, $str_off{$lib} );    # DT_NEEDED
        }
        $dynamic .= pack( 'Q< Q<', 4,  $base + $hash_rva );          # DT_HASH
        $dynamic .= pack( 'Q< Q<', 5,  $base + $str_rva );           # DT_STRTAB
        $dynamic .= pack( 'Q< Q<', 6,  $base + $sym_rva );           # DT_SYMTAB
        $dynamic .= pack( 'Q< Q<', 10, length($dynstr) );            # DT_STRSZ
        $dynamic .= pack( 'Q< Q<', 11, 24 );                         # DT_SYMENT (sizeof(Elf64_Sym))
        $dynamic .= pack( 'Q< Q<', 7,  $base + $rela_rva );          # DT_RELA
        $dynamic .= pack( 'Q< Q<', 8,  length($rela_dyn) );          # DT_RELASZ
        $dynamic .= pack( 'Q< Q<', 9,  24 );                         # DT_RELAENT (sizeof(Elf64_Rela))
        $dynamic .= pack( 'Q< Q<', 3,  $base + $got_rva_actual );    # DT_PLTGOT

        if ($is_pie) {

            # DT_GNU_PRELINKED=0x6ffffffb: flags=0x08000000 (DF_1_PIE)
            $dynamic .= pack( 'Q< Q<', 0x6ffffffb, 0x08000000 );
        }
        $dynamic .= pack( 'Q< Q<', 0, 0 );
        $self->layout->get('.dynamic')->{size} = length($dynamic);
        $self->layout->calculate($page_align);
        my $shstrtab = "\0";
        my %sh_name_off;
        for my $s ( $self->layout->sections ) {
            $sh_name_off{ $s->{name} } = length($shstrtab);
            $shstrtab .= $s->{name} . "\0";
        }
        $sh_name_off{'.shstrtab'} = length($shstrtab);
        $shstrtab .= ".shstrtab\0";
        $sh_name_off{'.note.GNU-stack'} = length($shstrtab);
        $shstrtab .= ".note.GNU-stack\0";
        my $sec_idx = 1;
        my %sec_indices;
        for my $s ( $self->layout->sections ) { $sec_indices{ $s->{name} } = $sec_idx++; }
        sysopen my $fh, $output_file, O_WRONLY | O_CREAT | O_TRUNC or die $!;
        binmode $fh;

        for my $s ( $self->layout->sections ) {
            my $payload = "\0" x $s->{size};
            if ( $s->{name} eq '.text' ) {
                $payload = $text;
            }
            elsif ( $s->{name} eq '.brk_sym' ) {
                $payload = $self->build_brk_sym();
            }
            elsif ( $s->{name} eq '.interp' ) {
                $payload = $interp;
            }
            elsif ( $s->{name} eq '.dynstr' ) {
                $payload = $dynstr;
            }
            elsif ( $s->{name} eq '.dynsym' || $s->{name} eq '.symtab' ) {
                $payload = $dynsym;
            }
            elsif ( $s->{name} eq '.strtab' ) {
                $payload = $dynstr;
            }
            elsif ( $s->{name} eq '.rela.dyn' ) {
                $payload = $rela_dyn;
            }
            elsif ( $s->{name} eq '.hash' ) {
                $payload = $hash;
            }
            elsif ( $s->{name} eq '.dynamic' ) {
                $payload = $dynamic;
            }
            elsif ( $s->{name} eq '.got' ) {
                $payload = $got;
            }
            elsif ( $s->{name} eq '.data' ) {
                if ( $platform->is_bsd && $s->{size} >= 32 ) {
                    my $empty_env_addr = $base + $s->{rva};
                    my $empty_str_addr = $base + $s->{rva} + 24;
                    $payload = pack( 'Q< Q< Q<', 0, $empty_env_addr, $empty_str_addr );
                }
                elsif ( $platform->is_haiku && $s->{size} >= 8 ) {
                    $payload = pack( 'L< L<', 4, 0 );
                }
            }
            elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                $payload = $self->debug_section( $s->{name} ) || "\0";
            }
            if ( length($payload) > $s->{size} ) {
                die sprintf "Internal error: %s payload (%d B) exceeds section size (%d B)", $s->{name}, length($payload), $s->{size};
            }
            $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
            seek( $fh, $s->{off}, 0 );
            print $fh $payload;
        }
        my $shstrtab_off = tell($fh);
        print $fh $shstrtab;
        my $shoff = tell($fh);
        my @shdrs = ();
        push @shdrs, pack( 'L< L< Q< Q< Q< Q< L< L< Q< Q<', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );
        for my $s ( $self->layout->sections ) {
            my $type       = 1;
            my $flags      = 0;
            my $sh_link    = 0;
            my $sh_info    = 0;
            my $sh_entsize = 0;
            if ( $s->{name} eq '.text' ) {
                $flags = 6;
            }
            elsif ( $s->{name} eq '.brk_sym' ) {
                $type  = 1;
                $flags = 2;
            }
            elsif ( $s->{name} eq '.data' ) {
                $flags = 3;
            }
            elsif ( $s->{name} eq '.interp' ) {
                $type  = 1;
                $flags = 2;
            }
            elsif ( $s->{name} eq '.dynstr' ) {
                $type  = 3;
                $flags = 2;
            }
            elsif ( $s->{name} eq '.dynsym' ) {
                $type       = 11;
                $flags      = 2;
                $sh_link    = $sec_indices{'.dynstr'} // 0;
                $sh_info    = 1;
                $sh_entsize = 24;
            }
            elsif ( $s->{name} eq '.symtab' ) {
                $type       = 2;
                $flags      = 0;
                $sh_link    = $sec_indices{'.strtab'} // 0;
                $sh_info    = 1;
                $sh_entsize = 24;
            }
            elsif ( $s->{name} eq '.strtab' ) {
                $type  = 3;
                $flags = 0;
            }
            elsif ( $s->{name} eq '.rela.dyn' ) {
                $type       = 4;
                $flags      = 2;
                $sh_link    = $sec_indices{'.dynsym'} // 0;
                $sh_entsize = 24;
            }
            elsif ( $s->{name} eq '.hash' ) {
                $type       = 5;
                $flags      = 2;
                $sh_link    = $sec_indices{'.dynsym'} // 0;
                $sh_entsize = 4;
            }
            elsif ( $s->{name} eq '.dynamic' ) {
                $type       = 6;
                $flags      = ( $platform->is_dragonflybsd ) ? 2 : 3;
                $sh_link    = $sec_indices{'.dynstr'} // 0;
                $sh_entsize = 16;
            }
            elsif ( $s->{name} eq '.got' ) {
                $type       = 1;
                $flags      = 3;
                $sh_entsize = 8;
            }
            elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                $flags = 0;
            }
            push @shdrs,
                pack(
                'L< L< Q< Q< Q< Q< L< L< Q< Q<',
                $sh_name_off{ $s->{name} },
                $type,     $flags, ( $flags & 2 ? $base + $s->{rva} : 0 ),
                $s->{off}, $s->{size}, $sh_link, $sh_info, 1, $sh_entsize
                );
        }
        my $shstrtab_idx = scalar(@shdrs);
        push @shdrs, pack( 'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{'.shstrtab'}, 3, 0, 0, $shstrtab_off, length($shstrtab), 0, 0, 1, 0 );
        push @shdrs, pack( 'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{'.note.GNU-stack'}, 1, 0, 0, 0, 0, 0, 1, 0 );
        seek( $fh, $shoff, 0 );
        print $fh $_ for @shdrs;
        my $num_ph = 5;
        $num_ph++ if $has_interp;
        $num_ph++ if $note_data;
        $num_ph++ if $pintable_data;
        $num_ph++ if $is_pie;
        my @phdrs     = ();
        my $extra_off = 64 + ( $num_ph * 56 );

        # PT_PHDR=6: program header table self-reference
        push @phdrs, pack( 'L< L< Q< Q< Q< Q< Q< Q<', 6, 4, 64, $base + 64, $base + 64, $num_ph * 56, $num_ph * 56, 8 );
        if ($has_interp) {
            my $interp_sec = $self->layout->get('.interp');

            # PT_INTERP=3
            push @phdrs,
                pack(
                'L< L< Q< Q< Q< Q< Q< Q<',
                3, 4, $interp_sec->{off},
                $base + $interp_sec->{rva},
                $base + $interp_sec->{rva},
                $interp_sec->{size}, $interp_sec->{size}, 1
                );
        }
        my $hash_sec  = $self->layout->get('.hash');
        my $rx_p_off  = 0;
        my $rx_p_size = $hash_sec->{off} + $hash_sec->{size};

        # PT_LOAD=1, flags=RX(5): maps .text through .hash
        push @phdrs, pack( 'L< L< Q< Q< Q< Q< Q< Q<', 1, 5, $rx_p_off, $base, $base, $rx_p_size, $rx_p_size, $page_align );
        my $dyn_sec  = $self->layout->get('.dynamic');
        my $got_sec  = $self->layout->get('.got');
        my $rw_p_off = $dyn_sec->{off} & ~( $page_align - 1 );
        my $rw_size  = ( $got_sec->{off} + $got_sec->{size} ) - $rw_p_off;

        # PT_LOAD=1, flags=RW(6): maps .dynamic through .got (page-aligned to cover zero-fill gap)
        push @phdrs,
            pack( 'L< L< Q< Q< Q< Q< Q< Q<', 1, 6, $rw_p_off, $base + $dyn_sec->{rva}, $base + $dyn_sec->{rva}, $rw_size, $rw_size, $page_align );

        # PT_DYNAMIC=2: points to .dynamic section
        push @phdrs,
            pack(
            'L< L< Q< Q< Q< Q< Q< Q<',
            2, 6, $dyn_sec->{off},
            $base + $dyn_sec->{rva},
            $base + $dyn_sec->{rva},
            $dyn_sec->{size}, $dyn_sec->{size}, 8
            );
        if ($is_pie) {

            # PT_GNU_RELRO=0x6474e552: make .dynamic read-only after relocation
            my $relro_start = $dyn_sec->{off} & ~( $page_align - 1 );
            my $relro_size  = ( $dyn_sec->{off} + $dyn_sec->{size} - $relro_start + $page_align - 1 ) & ~( $page_align - 1 );
            push @phdrs,
                pack(
                'L< L< Q< Q< Q< Q< Q< Q<',
                0x6474e552, 4, $relro_start,
                $base + ( $dyn_sec->{rva} & ~( $page_align - 1 ) ),
                $base + ( $dyn_sec->{rva} & ~( $page_align - 1 ) ),
                $relro_size, $relro_size, 1
                );
        }
        if ($note_data) {

            # PT_NOTE=4: ABI note
            push @phdrs,
                pack( 'L< L< Q< Q< Q< Q< Q< Q<', 4, 4, $extra_off, $base + $extra_off, $base + $extra_off, length($note_data), length($note_data),
                4 );
            $extra_off += length($note_data);
        }
        if ($pintable_data) {

            # PT_OPENBSD_PINTABLE=0x65a3dbe9: system call pinning table
            push @phdrs,
                pack(
                'L< L< Q< Q< Q< Q< Q< Q<',
                0x65a3dbe9, 4, $extra_off,
                $base + $extra_off,
                $base + $extra_off,
                length($pintable_data), length($pintable_data), 4
                );
            $extra_off += length($pintable_data);
        }

        # PT_GNU_STACK=0x6474e551: flags=6 (RW, no exec) for non-executable stack
        push @phdrs, pack( 'L< L< Q< Q< Q< Q< Q< Q<', 0x6474e551, 6, 0, 0, 0, 0, 0, 0x10 );
        my $entry_point = $self->type eq 'shared' ? 0 : $base + $self->layout->get('.text')->{rva};

# ELF64 header (e_ident + e_type/e_machine/e_version + e_entry/e_phoff/e_shoff + e_flags + e_ehsize/e_phentsize/e_phnum/e_shentsize/e_shnum/e_shstrndx)
# e_machine: EM_AARCH64=183, EM_RISCV=243, EM_X86_64=62
# e_flags: RISC-V EF_RISCV_RVC=0x0004 (compressed insns), else 0
        my $ehdr = pack(
            'A4 C C C C C x7 S< S< L< Q< Q< Q< L< S< S< S< S< S< S<',
            "\x7fELF", 2, 1, 1, $osabi, 0, $elf_type, ( $platform->is_arm64 ? 183 : ( $platform->is_riscv64 ? 243 : 62 ) ),
            1,         $entry_point, 64, $shoff, ( $platform->is_riscv64 ? 0x0004 : 0 ),
            64,        56, $num_ph, 64, scalar(@shdrs), $shstrtab_idx
        );
        seek( $fh, 0, 0 );
        print $fh $ehdr, @phdrs, $note_data, $pintable_data;
        close $fh;
        chmod 0755, $output_file;
        return $output_file;
    }
}
1;
