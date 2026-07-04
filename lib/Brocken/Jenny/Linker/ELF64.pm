use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;

class Brocken::Jenny::Linker::ELF64 : isa(Brocken::Jenny::Linker) {
    use Brocken::Jenny::Codegen::ARM64::Inst;
    use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC O_RDWR);
    field $_extern_got_offsets : reader = {};

=pod

=head1 NAME

Brocken::Jenny::Linker::ELF64 - 64-bit Executable and Linkable Format Generator

=cut

    # Structurally compliant segment layout grouping all read-only sections
    # in the RX segment, and keeping only writable sections in the RW segment.
    method _setup_layout( $layout, $text_size, $data_size, $arch, $os, $dbg = 0 ) {

        # Flags: 1=alloc, 2=write, 4=execute
        $layout->add_section( '.text', $text_size, 5 );    # RX (Alloc + Execute)
        my $rodata_size = length( join( '', map { $self->rodata->{$_} } sort keys $self->rodata->%* ) );
        $layout->add_section( '.rodata', $rodata_size || 1, 2 ) if $rodata_size > 0;
        my $brk_sym_size = $self->brk_sym_size();
        $layout->add_section( '.brk_sym', $brk_sym_size, 2 ) if $brk_sym_size > 0;

        # Read-only metadata sections (strictly mapped to RX segment)
        $layout->add_section( '.interp',   512,  2 ) if $self->type eq 'exe';
        $layout->add_section( '.dynstr',   4096, 2 );
        $layout->add_section( '.dynsym',   4096, 2 );
        $layout->add_section( '.rela.dyn', 4096, 2 );
        $layout->add_section( '.hash',     4096, 2 );
        $layout->add_section( '.gnu.hash', 4096, 2 ) if $os eq 'dragonflybsd';
        $layout->add_section( '.init',     16,   5 ) if $os eq 'dragonflybsd';
        $layout->add_section( '.fini',     16,   5 ) if $os eq 'dragonflybsd';

        # Writable data and dynamic linking tables (mapped to RW segment)
        $layout->add_section( '.dynamic', 4096,       3 );    # RW (Alloc + Write)
        $layout->add_section( '.data',    $data_size, 6 );    # RW (Alloc + Write + Unknown flag 4)
        $layout->add_section( '.got',     512,        6 );    # RW

        # Non-alloc symbol and string tables for static linking/debugging (nm)
        $layout->add_section( '.symtab',       4096, 0 );
        $layout->add_section( '.strtab',       4096, 0 );
        $layout->add_section( '.eh_frame',     4096, 0 );
        $layout->add_section( '.eh_frame_hdr', 4096, 0 );
        #
        if ( $dbg >= 1 ) { $layout->add_section( '.debug_line', 4096, 0 ); }
        if ( $dbg >= 2 ) {
            $layout->add_section( '.debug_info',   4096, 0 );
            $layout->add_section( '.debug_abbrev', 4096, 0 );
        }
        if ( $dbg >= 3 ) {
            $layout->add_section( '.debug_frame',   4096, 0 );
            $layout->add_section( '.debug_aranges', 4096, 0 );
        }
        if ( $dbg >= 4 ) {
            $layout->add_section( '.debug_names', 4096, 0 );
            $layout->add_section( '.debug_str',   4096, 0 );
        }
    }

    method _build_entry_stub( $platform, $func_offsets, $text_rva, $got_exit, $got_init_tls = undef, $got_rtld_call_init = undef ) {
        if ( $platform->is_arm64 ) {
            my $sub     = 0xD1000000 | ( 1 << 22 ) | ( 0x100 << 10 ) | ( 31 << 5 ) | 31;
            my $add     = add_imm( 0, 31, 0 );
            my $bl_main = bl( 20 + ( $func_offsets->{_BROCKEN_ENTRY} // 0 ) );
            my $adrp    = adrp( 8, $got_exit, $text_rva + 12 );
            my $ldr     = ldr_64( 8, 8, $got_exit & 0xFFF );
            my $blr     = blr(8);
            my $brk     = brk(0);
            return pack 'V7', $sub, $add, $bl_main, $adrp, $ldr, $blr, $brk;
        }
        if ( $platform->is_riscv64 ) {
            my $auipc_pc = $text_rva + 16;
            my $diff     = $got_exit - $auipc_pc;
            my $hi20     = ( $diff + 0x800 ) >> 12;
            my $lo12     = $diff & 0xFFF;
            my $lui      = ( 256 << 12 ) | ( 5 << 7 ) | 0x37;
            my $sub      = 0x40510133;
            my $mv       = ( 0 << 20 ) | ( 2 << 15 ) | ( 0 << 12 ) | ( 10 << 7 ) | 0x13;
            my $auipc    = ( ( $hi20 & 0xFFFFF ) << 12 ) | ( 5 << 7 ) | 0x17;
            my $ld       = ( ( $lo12 & 0xFFF ) << 20 ) | ( 5 << 15 ) | ( 3 << 12 ) | ( 5 << 7 ) | 0x03;
            my $jalr     = ( 0 << 20 ) | ( 5 << 15 ) | ( 0 << 12 ) | ( 0 << 7 ) | 0x67;
            my $jal_ofs  = 20 + ( $func_offsets->{_BROCKEN_ENTRY} // 0 );
            my $half     = $jal_ofs >> 1;
            my $jal_imm
                = ( ( $half >> 19 ) & 1 ) << 31 | ( ( $half & 0x3FF ) << 21 ) | ( ( $half >> 10 ) & 1 ) << 20 | ( ( $half >> 11 ) & 0xFF ) << 12;
            my $jal  = $jal_imm | ( 1 << 7 ) | 0x6F;
            my $ebrk = 0x00100073;
            return pack 'V8', $lui, $sub, $mv, $jal, $auipc, $ld, $jalr, $ebrk;
        }
        my $HEAP_SIZE = 1048576;
        my $stub      = pack( 'C4', 0x48, 0x83, 0xE4, 0xF0 );     # and rsp, -16
        $stub .= pack( 'C3 V', 0x48, 0x81, 0xEC, $HEAP_SIZE );    # sub rsp, HEAP_SIZE
        $stub .= pack( 'C3', 0x48, 0x89, 0xE7 );                  # mov rdi, rsp

        # DragonFly: call _init_tls and _rtld_call_init before main for TLS setup
        my $pre_main = '';
        if ( defined $got_init_tls ) {
            $pre_main .= pack( 'C', 0x57 );                                           # push rdi (save heap_base)
            my $rir1 = $text_rva + length($stub) + length($pre_main) + 6;
            $pre_main .= pack( 'C2 l<', 0xFF, 0x15, $got_init_tls - $rir1 );          # call [rip + init_tls]
            my $rir2 = $text_rva + length($stub) + length($pre_main) + 6;
            $pre_main .= pack( 'C2 l<', 0xFF, 0x15, $got_rtld_call_init - $rir2 );    # call [rip + rtld_call_init]
            $pre_main .= pack( 'C', 0x5F );                                           # pop rdi (restore heap_base)
        }
        $stub .= $pre_main;

        # Calculate dynamic call target offset (call main)
        my $tail_len       = length($pre_main) + 5 + 3 + 6 + 2;                                  # pre_main + call(5) + mov(3) + call exit(6) + ud2(2)
        my $final_len      = length($stub) + 5 + 3 + 6 + 2;
        my $main_target    = $text_rva + $final_len + ( $func_offsets->{_BROCKEN_ENTRY} // 0 );
        my $rip_after_call = $text_rva + length($stub) + 5;
        my $main_rel       = $main_target - $rip_after_call;
        $stub .= pack( 'C l<', 0xE8, $main_rel );                                                # call main
        $stub .= pack( 'C3', 0x48, 0x89, 0xC7 );                                                 # mov rdi, rax

        # Calculate dynamic exit call offset
        my $exit_rip = $text_rva + length($stub) + 6;
        my $exit_rel = $got_exit - $exit_rip;
        $stub .= pack( 'C2 l<', 0xFF, 0x15, $exit_rel );                                         # call [rip + exit]
        $stub .= pack( 'C2', 0x0F, 0x0B );                                                       # ud2
        return $stub;
    }

    method entry_stub_len($platform) {
        return 0 unless $self->type eq 'exe';
        my ( $got_init_tls, $got_rtld_call_init );
        if ( $platform->is_dragonflybsd ) {
            $got_init_tls       = 0;
            $got_rtld_call_init = 8;
        }
        return length( $self->_build_entry_stub( $platform, {}, 0, 0, $got_init_tls, $got_rtld_call_init ) );
    }

    method import_rva($name) {

        # GOT slot offsets for dynamic linker imports:
        #   dlopen               = +24  (offset 3,  index 3)
        #   dlsym                = +32  (offset 4,  index 4)
        #   pthread_create       = +40  (offset 5,  index 5)
        #   exit / _exit         = +48  (offset 6,  index 6)
        #   pthread_join         = +56  (offset 7,  index 7)
        #   sched_setaffinity    = +64  (offset 8,  index 8)
        #   pthread_mutex_lock   = +72  (offset 9,  index 9)
        #   pthread_mutex_unlock = +80  (offset 10, index 10)
        #   pthread_cond_wait    = +88  (offset 11, index 11)
        #   pthread_cond_signal  = +96  (offset 12, index 12)
        #   pthread_cond_broadcast = +104 (offset 13, index 13)
        #   _init_tls            = +112 (offset 14, index 14)
        #   _rtld_call_init      = +120 (offset 15, index 15)
        # Slot 0-2 reserved (0, DYNAMIC, LINK_MAP).
        # Dynamically registered extern functions get slots starting at +128.
        my $fixed_imports = {
            dlopen                 => 24,
            dlsym                  => 32,
            pthread_create         => 40,
            exit                   => 48,
            _exit                  => 48,
            pthread_join           => 56,
            sched_setaffinity      => 64,
            pthread_mutex_lock     => 72,
            pthread_mutex_unlock   => 80,
            pthread_cond_wait      => 88,
            pthread_cond_signal    => 96,
            pthread_cond_broadcast => 104,
            _init_tls              => 112,
            _rtld_call_init        => 120,
        };
        my $got_base = $self->layout->get('.got')->{rva};
        return $got_base + $fixed_imports->{$name}       if exists $fixed_imports->{$name};
        return $got_base + $_extern_got_offsets->{$name} if exists $_extern_got_offsets->{$name};
        die 'Unknown ELF import: ' . $name;
    }

    # Standard Linux x86_64 static image base; PIE/BSD use base 0 for ASLR.
    method image_base () { return $self->type eq 'shared' ? 0 : 0x400000; }

    # Given an ELF shared library path, returns its DT_SONAME (or undef).
    sub _elf_soname ($path) {
        open my $fh, '<:raw', $path or return undef;
        read( $fh, my $ehdr, 64 ) == 64 or do { close $fh; return undef };
        return undef unless substr( $ehdr, 0, 4 ) eq "\x7FELF";
        my $class  = ord substr $ehdr, 4, 1;    # 1=32, 2=64
        my $endian = ord( substr $ehdr, 5, 1 ) == 1 ? '<' : '>';
        my ( $e_phoff, $e_phentsize, $e_phnum );
        if ( $class == 2 ) {
            $e_phoff     = unpack "Q$endian", substr $ehdr, 32, 8;
            $e_phentsize = unpack 'v',        substr $ehdr, 54, 2;
            $e_phnum     = unpack 'v',        substr $ehdr, 56, 2;
        }
        else {
            $e_phoff     = unpack "L$endian", substr $ehdr, 28, 4;
            $e_phentsize = unpack 'v',        substr $ehdr, 42, 2;
            $e_phnum     = unpack 'v',        substr $ehdr, 44, 2;
        }
        my @loads;
        my ( $dyn_vaddr, $dyn_size );
        for my $i ( 0 .. $e_phnum - 1 ) {
            seek $fh, $e_phoff + $i * $e_phentsize, 0;
            read $fh, my $phdr, $e_phentsize or next;
            my $p_type = unpack "L$endian", substr $phdr, 0, 4;
            if ( $p_type == 2 ) {    # PT_DYNAMIC
                if ( $class == 2 ) {
                    $dyn_vaddr = unpack "Q$endian", substr $phdr, 16, 8;
                    $dyn_size  = unpack "Q$endian", substr $phdr, 32, 8;
                }
                else {
                    $dyn_vaddr = unpack "L$endian", substr $phdr, 8,  4;
                    $dyn_size  = unpack "L$endian", substr $phdr, 20, 4;
                }
            }
            elsif ( $p_type == 1 ) {    # PT_LOAD
                my ( $p_vaddr, $p_offset, $p_filesz );
                if ( $class == 2 ) {
                    $p_offset = unpack "Q$endian", substr $phdr, 8,  8;
                    $p_vaddr  = unpack "Q$endian", substr $phdr, 16, 8;
                    $p_filesz = unpack "Q$endian", substr $phdr, 32, 8;
                }
                else {
                    $p_offset = unpack "L$endian", substr $phdr, 4,  4;
                    $p_vaddr  = unpack "L$endian", substr $phdr, 8,  4;
                    $p_filesz = unpack "L$endian", substr $phdr, 16, 4;
                }
                push @loads, [ $p_vaddr, $p_offset, $p_filesz ];
            }
        }
        return undef unless defined $dyn_vaddr && @loads;
        my $dyn_foff;
        for my $l (@loads) {
            my ( $vaddr, $foff, $fsize ) = @$l;
            if ( $dyn_vaddr >= $vaddr && $dyn_vaddr < $vaddr + $fsize ) {
                $dyn_foff = $foff + ( $dyn_vaddr - $vaddr );
                last;
            }
        }
        return undef unless defined $dyn_foff;
        my ( $soname_off, $strtab_vaddr, $strtab_size );
        my $dyn_entsize = $class == 2 ? 16 : 8;
        for ( my $j = 0; $j * $dyn_entsize < $dyn_size; $j++ ) {
            seek $fh, $dyn_foff + $j * $dyn_entsize, 0;
            read $fh, my $dyn, $dyn_entsize or last;
            my $d_tag;
            my $d_val;
            if ( $class == 2 ) {
                $d_tag = unpack "q$endian", substr $dyn, 0, 8;
                $d_val = unpack "Q$endian", substr $dyn, 8, 8;
            }
            else {
                $d_tag = unpack "l$endian", substr $dyn, 0, 4;
                $d_val = unpack "L$endian", substr $dyn, 4, 4;
            }
            last if $d_tag == 0;                                 # DT_NULL
            if    ( $d_tag == 14 ) { $soname_off   = $d_val }    # DT_SONAME
            elsif ( $d_tag == 5 )  { $strtab_vaddr = $d_val }    # DT_STRTAB
            elsif ( $d_tag == 10 ) { $strtab_size  = $d_val }    # DT_STRSZ
        }
        return undef unless defined $soname_off && defined $strtab_vaddr;
        my $strtab_foff;
        for my $l (@loads) {
            my ( $vaddr, $foff, $fsize ) = @$l;
            if ( $strtab_vaddr >= $vaddr && $strtab_vaddr < $vaddr + $fsize ) {
                $strtab_foff = $foff + ( $strtab_vaddr - $vaddr );
                last;
            }
        }
        return undef unless defined $strtab_foff;
        seek $fh, $strtab_foff + $soname_off, 0;
        read $fh, my $soname, $strtab_size ? $strtab_size - $soname_off : 256;
        $soname =~ s/\0.*$//;
        return $soname;
    }

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
        my $entry_stub_len = $self->entry_stub_len($platform);
        if ( !defined $self->layout ) {
            my $extra_data = $platform->is_bsd ? 32 : ( $platform->is_haiku ? 8 : 0 );
            $self->pre_layout( length($code_bytes) + $entry_stub_len, $extra_data, $platform, $self->debug_level );
        }
        else {
            # Update text size and recalculate layout so all subsequent RVA
            # lookups (e.g. import_rva, got_rva) reflect the current code size.
            $self->layout->get('.text')->{size} = length($code_bytes) + $entry_stub_len;
            $self->layout->calculate( $self->layout->section_align );
        }
        my $l          = $self->layout;
        my $is_pie     = $platform->is_haiku && !$shared;
        my $base       = $is_pie ? 0 : $self->image_base;
        my $elf_type   = $shared ? 3 : ( $is_pie ? 3 : 2 );    # ET_DYN (3) for PIE, ET_EXEC (2) for static
        my $text_rva   = $self->layout->get('.text')->{rva};
        my $got_rva    = $self->layout->get('.got')->{rva};
        my $page_align = $self->layout->section_align;
        my $text       = $code_bytes;
        my $entry_stub = '';

        if ( $self->type eq 'exe' ) {
            my $got_exit = $self->import_rva('exit');
            my ( $got_init_tls, $got_rtld_call_init );
            if ( $platform->is_dragonflybsd ) {
                $got_init_tls       = $self->import_rva('_init_tls');
                $got_rtld_call_init = $self->import_rva('_rtld_call_init');
            }
            $entry_stub = $self->_build_entry_stub( $platform, \%func_offsets, $text_rva, $got_exit, $got_init_tls, $got_rtld_call_init );
            $text       = $entry_stub . $code_bytes;
            $self->layout->get('.text')->{size} = length($text);
        }

        # Pre-scan fixups to discover extern functions not defined in compiled code
        my %extern_seen;
        for my $ff (@func_fixups) {
            next if $ff->{type} eq 'lea_rodata_rel32' || $ff->{type} eq 'lea_rodata_adr';
            next if exists $func_offsets{ $ff->{target} };
            $extern_seen{ $ff->{target} } = 1;
        }

        # Allocate GOT slots for extern functions starting at +128 (slot 16+)
        my $next_got_offset = 128;
        for my $name ( sort keys %extern_seen ) {
            $_extern_got_offsets->{$name} = $next_got_offset;
            $next_got_offset += 8;
        }

        # Generate import stubs for undefined external functions
        my $entry_size = $self->type eq 'exe' ? length($entry_stub) : 0;
        for my $ff (@func_fixups) {
            next if exists $func_offsets{ $ff->{target} };
            my $got_rva;
            eval { $got_rva = $self->import_rva( $ff->{target} ) };
            next if $@;
            my $stub_ofs = length($text);
            my $stub_bytes;
            if ( $platform->is_x64 ) {
                my $disp32 = $got_rva - ( $text_rva + $stub_ofs + 6 );
                $stub_bytes = pack( 'CC l<', 0xFF, 0x25, $disp32 );
            }
            elsif ( $platform->is_arm64 ) {
                $stub_bytes = pack( 'V', adrp( 16, $got_rva, $text_rva + $stub_ofs ) );
                $stub_bytes .= pack( 'V', ldr_64( 16, 16, $got_rva & 0xFFF ) );
                $stub_bytes .= pack( 'V', 0xD61F0000 | ( 16 << 5 ) );
            }
            elsif ( $platform->is_riscv64 ) {
                my $diff  = $got_rva - ( $text_rva + $stub_ofs );
                my $hi20  = ( $diff + 0x800 ) >> 12;
                my $lo12  = $diff & 0xFFF;
                my $auipc = ( ( $hi20 & 0xFFFFF ) << 12 ) | ( 5 << 7 ) | 0x17;
                my $ld    = ( ( $lo12 & 0xFFF ) << 20 ) | ( 5 << 15 ) | ( 3 << 12 ) | ( 5 << 7 ) | 0x03;
                my $jalr  = ( 0 << 20 ) | ( 5 << 15 ) | ( 0 << 12 ) | ( 0 << 7 ) | 0x67;
                $stub_bytes = pack( 'V3', $auipc, $ld, $jalr );
            }
            next unless length($stub_bytes);
            $text .= $stub_bytes;
            $func_offsets{ $ff->{target} } = $stub_ofs - $entry_size;
        }
        $self->layout->get('.text')->{size} = length($text);

        # Resolve cross-function call fixups at link time
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
            elsif ( $ff->{type} eq 'lea_rodata_rel32' ) {
                my $rodata_sec = $self->layout->get('.rodata') or die "no .rodata section for lea_rodata_rel32";
                my $rodata_rva = $rodata_sec->{rva};
                my $label_off  = 0;
                for my $key ( sort keys $self->rodata->%* ) {
                    last if $key eq $ff->{target};
                    $label_off += length( $self->rodata->{$key} );
                }
                my $target_rva = $rodata_rva + $label_off;
                my $text_rva   = $self->layout->get('.text')->{rva};
                my $rel        = $target_rva - ( $text_rva + $src_pos + 4 );
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
            $osabi     = 0;
            $note_data = pack( 'L<3 a12 L<', 10, 4, 1, "DragonFly\0\0\0", 600401 );
            $note_data .= pack( 'L<3 a12 L<', 10, 4, 32, "DragonFly\0\0\0", 1 );    # DF_FEATURE_PTHREAD
        }
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
        if ( $self->type eq 'exe' ) {
            my $ipath = $platform->interpreter;
            if ( defined $ipath && length $ipath ) {
                $interp                               = $ipath . "\0";
                $self->layout->get('.interp')->{size} = length($interp);
                $has_interp                           = 1;
            }
        }
        my @exports = @{ $self->exported_funcs // [] };
        my @imports = (
            'dlopen',              'dlsym',              'pthread_create',       'pthread_join',
            $platform->exit_name,  'pthread_mutex_lock', 'pthread_mutex_unlock', 'pthread_cond_wait',
            'pthread_cond_signal', 'pthread_cond_broadcast'
        );
        if ( $platform->needs_sched_setaffinity ) {
            push @imports, 'sched_setaffinity';
        }
        if ( $platform->is_dragonflybsd ) {
            push @imports, '_init_tls', '_rtld_call_init';
        }

        # Merge dynamically discovered extern functions into @imports
        for my $name ( sort keys %$_extern_got_offsets ) {
            next if grep { $_ eq $name } @imports;
            push @imports, $name;
        }
        my $libc = $platform->libc_name;

        # Probe the exact dynamic libc.so name on the host filesystem when running natively
        if ( $platform->is_native ) {
            my @search_paths = (
                '/usr/lib', '/lib', '/lib64', '/usr/lib64',
                '/usr/lib/x86_64-linux-gnu', '/usr/lib/aarch64-linux-gnu', '/usr/lib/riscv64-linux-gnu',
            );
            my @found;
            for my $dir (@search_paths) {
                next unless -d $dir;
                if ( opendir my $dh, $dir ) {
                    push @found, map {"$dir/$_"} grep { /^libc\.so(?:\.\d+)*/ && !/_p\.so/ } readdir $dh;
                    closedir $dh;
                }
            }
            if (@found) {

                # Prefer files with actual SONAMEs
                my $best_soname;
                for my $f ( sort { length($a) <=> length($b) } @found ) {
                    my $soname = _elf_soname($f);
                    if ($soname) {
                        $best_soname = $soname;
                        last;
                    }
                }
                if ($best_soname) {
                    $libc = $best_soname;
                }
                else {
                    # Fallback to the most-versioned filename
                    my $best = (
                        sort {
                            my @av  = $a =~ /\.(\d+)/g;
                            my @bv  = $b =~ /\.(\d+)/g;
                            my $cmp = 0;
                            for ( my $i = 0; $i < @av || $i < @bv; $i++ ) {
                                $cmp = ( $av[$i] // 0 ) <=> ( $bv[$i] // 0 );
                                last if $cmp;
                            }
                            $cmp;
                        } @found
                    )[-1];
                    if ($best) {
                        require File::Basename;
                        $libc = File::Basename::basename($best);
                    }
                }
            }
        }
        my @libs;
        my $libpthread = $platform->libpthread_name;
        if ( defined $libpthread ) {

            # Try compiler query to find the actual pthread library.
            for my $cc (qw(clang gcc cc)) {
                my $out = `$cc -pthread -print-file-name=libpthread.so 2>/dev/null`;
                chomp $out if defined $out;
                if ( $out && $out ne 'libpthread.so' && -e $out ) {
                    my $soname = _elf_soname($out);
                    if ($soname) {
                        $libpthread = $soname;
                        last;
                    }
                }
                if ( $platform->is_dragonflybsd ) {
                    my $out_xu = `$cc -pthread -print-file-name=libthread_xu.so 2>/dev/null`;
                    chomp $out_xu if defined $out_xu;
                    if ( $out_xu && $out_xu ne 'libthread_xu.so' && -e $out_xu ) {
                        my $soname = _elf_soname($out_xu);
                        if ($soname) {
                            $libpthread = $soname;
                            last;
                        }
                    }
                }
            }

            # The threading library must be loaded before libc.so so it can properly intercept
            # weak internal symbols and initialize Thread Local Storage (TLS).
            push @libs, $libpthread;
        }
        push @libs, $libc;
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

        # Add function names to string table for .symtab entries
        for my $name ( sort keys %func_offsets ) {
            next if exists $str_off{$name};
            $str_off{$name} = length($dynstr);
            $dynstr .= $name . "\0";
        }
        $self->layout->get('.dynstr')->{size} = length($dynstr);
        my $dynsym  = pack( 'L< C C S< Q< Q<', 0, 0, 0, 0, 0, 0 );
        my $sym_idx = 1;

        # Add function symbols to .symtab (STB_GLOBAL | STT_FUNC = 0x12)
        for my $name ( sort keys %func_offsets ) {
            $sym_idx++;
            my $rva = $self->layout->get('.text')->{rva} + $entry_size + $func_offsets{$name};
            $dynsym .= pack( 'L< C C S< Q< Q<', $str_off{$name}, 0x12, 0, 1, $base + $rva, 0 );
        }
        my %sym_indices;
        for my $name (@imports) {
            $sym_indices{$name} = $sym_idx++;

            # STB_GLOBAL|STT_FUNC = 0x12; STB_WEAK|STT_FUNC = 0x22
            # sched_setaffinity is absent on DragonFly BSD (it uses pthread_setaffinity_np);
            # emit it as a weak symbol so RTLD doesn't abort if the symbol is missing.
            my $st_info = ( $name eq 'sched_setaffinity' && $platform->is_dragonflybsd ) ? 0x22 : 0x12;
            $dynsym .= pack( 'L< C C S< Q< Q<', $str_off{$name}, $st_info, 0, 0, 0, 0 );
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
        my $exit_sym_idx = $sym_indices{ $platform->exit_name };
        $rela_dyn .= pack( 'Q< Q< q<', $exit_slot, ( $exit_sym_idx << 32 ) | $rel_type, 0 );
        my $join_slot    = $base + $self->import_rva('pthread_join');
        my $join_sym_idx = $sym_indices{'pthread_join'};
        $rela_dyn .= pack( 'Q< Q< q<', $join_slot, ( $join_sym_idx << 32 ) | $rel_type, 0 );

        if ( $platform->is_linux || $platform->is_freebsd || $platform->is_dragonflybsd ) {
            my $sched_slot    = $base + $self->import_rva('sched_setaffinity');
            my $sched_sym_idx = $sym_indices{'sched_setaffinity'};
            $rela_dyn .= pack( 'Q< Q< q<', $sched_slot, ( $sched_sym_idx << 32 ) | $rel_type, 0 );
        }
        my $mutex_lock_slot    = $base + $self->import_rva('pthread_mutex_lock');
        my $mutex_lock_sym_idx = $sym_indices{'pthread_mutex_lock'};
        $rela_dyn .= pack( 'Q< Q< q<', $mutex_lock_slot, ( $mutex_lock_sym_idx << 32 ) | $rel_type, 0 );
        my $mutex_unlock_slot    = $base + $self->import_rva('pthread_mutex_unlock');
        my $mutex_unlock_sym_idx = $sym_indices{'pthread_mutex_unlock'};
        $rela_dyn .= pack( 'Q< Q< q<', $mutex_unlock_slot, ( $mutex_unlock_sym_idx << 32 ) | $rel_type, 0 );
        my $cond_wait_slot    = $base + $self->import_rva('pthread_cond_wait');
        my $cond_wait_sym_idx = $sym_indices{'pthread_cond_wait'};
        $rela_dyn .= pack( 'Q< Q< q<', $cond_wait_slot, ( $cond_wait_sym_idx << 32 ) | $rel_type, 0 );
        my $cond_signal_slot    = $base + $self->import_rva('pthread_cond_signal');
        my $cond_signal_sym_idx = $sym_indices{'pthread_cond_signal'};
        $rela_dyn .= pack( 'Q< Q< q<', $cond_signal_slot, ( $cond_signal_sym_idx << 32 ) | $rel_type, 0 );
        my $cond_broadcast_slot    = $base + $self->import_rva('pthread_cond_broadcast');
        my $cond_broadcast_sym_idx = $sym_indices{'pthread_cond_broadcast'};
        $rela_dyn .= pack( 'Q< Q< q<', $cond_broadcast_slot, ( $cond_broadcast_sym_idx << 32 ) | $rel_type, 0 );

        if ( $platform->is_dragonflybsd ) {
            my $init_tls_slot    = $base + $self->import_rva('_init_tls');
            my $init_tls_sym_idx = $sym_indices{'_init_tls'};
            $rela_dyn .= pack( 'Q< Q< q<', $init_tls_slot, ( $init_tls_sym_idx << 32 ) | $rel_type, 0 );
            my $rtld_call_slot    = $base + $self->import_rva('_rtld_call_init');
            my $rtld_call_sym_idx = $sym_indices{'_rtld_call_init'};
            $rela_dyn .= pack( 'Q< Q< q<', $rtld_call_slot, ( $rtld_call_sym_idx << 32 ) | $rel_type, 0 );
        }

        # Relocation entries for dynamically discovered extern functions
        for my $name ( sort keys %$_extern_got_offsets ) {
            if ( !exists $sym_indices{$name} ) {
                $sym_indices{$name} = $sym_idx++;
                $dynsym .= pack( 'L< C C S< Q< Q<', $str_off{$name}, 0x12, 0, 0, 0, 0 );
            }
            my $slot = $base + $self->import_rva($name);
            $rela_dyn .= pack( 'Q< Q< q<', $slot, ( $sym_indices{$name} << 32 ) | $rel_type, 0 );
        }
        $self->layout->get('.rela.dyn')->{size} = length($rela_dyn);

# GOT layout: [0]=reserved, [1]=DT_DEBUG, [2]=LINK_MAP, [3]=dlopen, [4]=dlsym, [5]=pthread_create, [6]=exit, [7]=pthread_join, [8]=sched_setaffinity, [9]=pthread_mutex_lock, [10]=pthread_mutex_unlock, [11]=pthread_cond_wait, [12]=pthread_cond_signal, [13]=pthread_cond_broadcast, [14]=_init_tls, [15]=_rtld_call_init, [16+]=dynamic extern functions
# Compute total GOT slots needed: 3 reserved + max slot index from all imports
        my $max_got_offset = 0;
        for my $name (@imports) {
            my $off = $self->import_rva($name);
            $max_got_offset = $off if $off > $max_got_offset;
        }
        my $got_slots = int( $max_got_offset / 8 ) + 1;
        $got_slots = 64 if $got_slots < 64;    # minimum 512 bytes
        my $got = pack( 'Q<*', (0) x $got_slots );
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
        $self->layout->get('.hash')->{size} = length($hash);
        my $gnu_hash_rva = 0;
        my $gnu_hash     = '';
        if ( $platform->is_dragonflybsd ) {

            # GNU hash table (DT_GNU_HASH / .gnu.hash) -- DragonFly ld-elf.so.2
            # requires it for TLS initialization (SYSV .hash alone is insufficient).
            my $dl_new_hash = sub {
                my $name = shift;
                my $h    = 5381;
                for my $c ( split //, $name ) {
                    $h = ( ( $h << 5 ) + $h ) + ord($c);
                    $h &= 0xffffffff;
                }
                return $h;
            };
            my $gnu_nbucket   = 3;
            my $gnu_symndx    = 1;
            my $gnu_maskwords = 1;
            my $gnu_shift2    = 3;
            my $bloom         = 0;
            my @gnu_buckets   = (0) x $gnu_nbucket;
            my @gnu_chains    = (0) x ( $sym_idx - $gnu_symndx );
            {
                my %by_bucket;
                for my $name ( keys %sym_indices ) {
                    my $idx = $sym_indices{$name};
                    next if $idx < $gnu_symndx;
                    my $h = $dl_new_hash->($name);
                    push @{ $by_bucket{ $h % $gnu_nbucket } }, { idx => $idx, hash => $h };
                }
                for my $bucket ( keys %by_bucket ) {
                    my @syms = sort { $a->{idx} <=> $b->{idx} } @{ $by_bucket{$bucket} };
                    $gnu_buckets[$bucket] = $syms[0]->{idx};
                    for my $i ( 0 .. $#syms ) {
                        my $sym = $syms[$i];
                        my $val = $sym->{hash} & ~1;
                        $val |= 1 if $i == $#syms;
                        $gnu_chains[ $sym->{idx} - $gnu_symndx ] = $val;
                        $bloom |= ( 1 << ( $sym->{hash} % 64 ) ) | ( 1 << ( ( $sym->{hash} >> $gnu_shift2 ) % 64 ) );
                    }
                }
            }
            my $gnu_hash = pack( 'L< L< L< L<', $gnu_nbucket, $gnu_symndx, $gnu_maskwords, $gnu_shift2 );
            $gnu_hash .= pack( 'Q<', $bloom );
            $gnu_hash .= pack( 'L<*', @gnu_buckets, @gnu_chains );
            $self->layout->get('.gnu.hash')->{size} = length($gnu_hash);
            $gnu_hash_rva = $self->layout->get('.gnu.hash')->{rva};
        }
        $self->layout->get('.symtab')->{size} = length($dynsym);
        $self->layout->get('.strtab')->{size} = length($dynstr);
        $self->layout->calculate($page_align);
        my $dyn_rva  = $self->layout->get('.dynamic')->{rva};
        my $str_rva  = $self->layout->get('.dynstr')->{rva};
        my $sym_rva  = $self->layout->get('.dynsym')->{rva};
        my $hash_rva = $self->layout->get('.hash')->{rva};
        $gnu_hash_rva = $platform->is_dragonflybsd ? $self->layout->get('.gnu.hash')->{rva} : 0;
        my $rela_rva       = $self->layout->get('.rela.dyn')->{rva};
        my $got_rva_actual = $self->layout->get('.got')->{rva};
        my $dynamic        = '';

        # Dynamic section entries (d_tag, d_val/d_ptr):
        #   DT_NEEDED=1, DT_PLTGOT=3, DT_HASH=4, DT_STRTAB=5, DT_SYMTAB=6,
        #   DT_RELA=7, DT_RELASZ=8, DT_RELAENT=9, DT_STRSZ=10, DT_SYMENT=11
        for my $lib (@libs) {
            $dynamic .= pack( 'Q< Q<', 1, $str_off{$lib} );    # DT_NEEDED
        }
        $dynamic .= pack( 'Q< Q<', 4,          $base + $hash_rva );                                     # DT_HASH
        $dynamic .= pack( 'Q< Q<', 0x6ffffef5, $base + $gnu_hash_rva ) if $platform->is_dragonflybsd;
        $dynamic .= pack( 'Q< Q<', 5,          $base + $str_rva );                                      # DT_STRTAB
        $dynamic .= pack( 'Q< Q<', 6,          $base + $sym_rva );                                      # DT_SYMTAB
        $dynamic .= pack( 'Q< Q<', 10,         length($dynstr) );                                       # DT_STRSZ
        $dynamic .= pack( 'Q< Q<', 11,         24 );                                                    # DT_SYMENT (sizeof(Elf64_Sym))
        $dynamic .= pack( 'Q< Q<', 7,          $base + $rela_rva );                                     # DT_RELA
        $dynamic .= pack( 'Q< Q<', 8,          length($rela_dyn) );                                     # DT_RELASZ
        $dynamic .= pack( 'Q< Q<', 9,          24 );                                                    # DT_RELAENT (sizeof(Elf64_Rela))
        $dynamic .= pack( 'Q< Q<', 3,          $base + $got_rva_actual );                               # DT_PLTGOT

        # DT_DEBUG=0x15: inform dynamic linker to maintain r_debug pointer.
        # Value 0 means the linker initializes it at a platform-default slot.
        if ( $platform->is_dragonflybsd ) {
            $dynamic .= pack( 'Q< Q<', 0x15, 0 );
            my $init_sec = $self->layout->get('.init');
            my $fini_sec = $self->layout->get('.fini');
            $dynamic .= pack( 'Q< Q<', 12, $base + $init_sec->{rva} ) if $init_sec;
            $dynamic .= pack( 'Q< Q<', 13, $base + $fini_sec->{rva} ) if $fini_sec;
        }
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
            elsif ( $s->{name} eq '.init' || $s->{name} eq '.fini' ) {
                $payload = "\xc3";
            }
            elsif ( $s->{name} eq '.rodata' ) {
                $payload = join( '', map { $self->rodata->{$_} } sort keys $self->rodata->%* );
                $s->{size} = length($payload);
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
            elsif ( $s->{name} eq '.gnu.hash' ) {
                $payload = $gnu_hash;
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
            my $actual_len = length($payload);
            $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
            seek( $fh, $s->{off}, 0 );
            print $fh $payload;
            $s->{size} = $actual_len if $s->{name} =~ /^\.(debug|eh_frame)/;
        }
        my $shstrtab_off = tell($fh);
        print $fh $shstrtab;
        my $shoff = tell($fh);
        if ( my $align = 64 - ( $shoff % 64 ) ) {
            print $fh "\0" x $align;
            $shoff += $align;
        }
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
            elsif ( $s->{name} eq '.init' || $s->{name} eq '.fini' ) {
                $flags = 6;
            }
            elsif ( $s->{name} eq '.rodata' ) {
                $type  = 1;
                $flags = 2;
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
            elsif ( $s->{name} eq '.gnu.hash' ) {
                $type       = 0x6ffffff6;                     # SHT_GNU_HASH
                $flags      = 2;
                $sh_link    = $sec_indices{'.dynsym'} // 0;
                $sh_entsize = 0;
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
        my $eh_frame_hdr_sec = $self->layout->get('.eh_frame_hdr');
        $num_ph++ if $eh_frame_hdr_sec;
        $num_ph++ if $platform->is_freebsd;
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
        my $dyn_sec   = $self->layout->get('.dynamic');
        my $got_sec   = $self->layout->get('.got');
        my $rx_p_off  = 0;
        my $rx_p_size = $dyn_sec->{off};

        # PT_LOAD=1, flags=RX(5): maps .text through .gnu.hash (all before .dynamic)
        push @phdrs, pack( 'L< L< Q< Q< Q< Q< Q< Q<', 1, 5, $rx_p_off, $base, $base, $rx_p_size, $rx_p_size, $page_align );
        my $rw_p_off = $dyn_sec->{off};
        my $rw_size  = ( $got_sec->{off} + $got_sec->{size} ) - $rw_p_off;

        # PT_LOAD=1, flags=RW(6): maps .dynamic through .got (GCC-style overlapping LOAD)
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
        if ($eh_frame_hdr_sec) {

            # PT_GNU_EH_FRAME=0x6474e550: points to .eh_frame_hdr index for binary FDE lookup
            push @phdrs,
                pack(
                'L< L< Q< Q< Q< Q< Q< Q<',
                0x6474e550, 4,
                $eh_frame_hdr_sec->{off},
                $base + $eh_frame_hdr_sec->{rva},
                $base + $eh_frame_hdr_sec->{rva},
                $eh_frame_hdr_sec->{size},
                $eh_frame_hdr_sec->{size}, 4
                );
        }
        if ( $platform->is_freebsd ) {

            # PT_TLS=7: Creates a minimal thread-local storage segment.
            # Required on FreeBSD to trigger rtld TLS initialization.
            # On DragonFly this actually HARM: the kernel sets FS.base to an
            # 8-byte zero-filled area from our PT_TLS, but libc's sigblockall
            # expects a full TCB there. Without PT_TLS the kernel leaves FS.base
            # alone and rtld manages it correctly (matching GCC's behavior).
            my $data_sec  = $self->layout->get('.data');
            my $tls_vaddr = $data_sec ? $base + $data_sec->{rva} : $base;
            my $tls_off   = $data_sec ? $data_sec->{off}         : 0;
            push @phdrs, pack( 'L< L< Q< Q< Q< Q< Q< Q<', 7, 6, $tls_off, $tls_vaddr, $tls_vaddr, 0, 8, 8 );
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
