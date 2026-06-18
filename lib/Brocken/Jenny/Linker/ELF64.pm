use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;

class Brocken::Jenny::Linker::ELF64 : isa(Brocken::Jenny::Linker) {

=pod

=head1 NAME

Brocken::Jenny::Linker::ELF64 - 64-bit Executable and Linkable Format Generator

=head1 DESCRIPTION

Generates ELF64 binaries for Linux, BSDs, Haiku, and Solaris.

=head2 Binary Structure

=over 4

=item * B<Elf64_Ehdr>: Main header (64 bytes).

=item * B<Elf64_Phdr>: Program Headers defining memory segments (PT_LOAD, PT_DYNAMIC, etc.).

=item * B<Elf64_Shdr>: Section Headers describing the file's logical sections.

=back

=head2 Platform-Specific Workarounds

=over 4

=item * B<Haiku>: Requires C<_gSharedObjectHaikuABI> and C<_gSharedObjectHaikuVersion>
symbols in C<.dynsym> to enable modern POSIX APIs.

=item * B<BSDs>: FreeBSD, NetBSD, and DragonFly require C<environ> and
C<__progname> symbols to be mapped to writable memory to avoid early
crashes in C<libc> initialization.

=item * B<NetBSD>: Requires a C<PT_NOTE> containing C<NT_NETBSD_IDENT>
to be recognized as a native binary, plus PaX relaxation notes.

=item * B<OpenBSD>: Requires a C<PT_OPENBSD_PINTABLE> segment listing
allowed syscall entry points for its "syscall pinning" security feature.

=item * B<DragonFly BSD>: Requires a smaller C<PT_GNU_RELRO> segment
that doesn't overlap the GOT, or the dynamic linker will crash.

=back

=cut

    # Structurally compliant segment layout grouping all read-only sections
    # in the RX segment, and keeping only writable sections in the RW segment.
    method _setup_layout( $layout, $text_size, $data_size, $arch, $os, $dbg = 0 ) {

        #method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
        $layout->add_section( '.text', $text_size, 5 );    # RX (Read + Execute)

        # Read-only metadata sections (strictly mapped to RX segment)
        $layout->add_section( '.interp',   512,  2 ) if $self->type eq 'exe';
        $layout->add_section( '.dynstr',   4096, 2 );
        $layout->add_section( '.dynsym',   4096, 2 );
        $layout->add_section( '.rela.dyn', 4096, 2 );
        $layout->add_section( '.hash',     4096, 2 );

        # Writable data and dynamic linking tables (mapped to RW segment)
        $layout->add_section( '.dynamic', 4096,       3 );    # RW (Read + Write)
        $layout->add_section( '.data',    $data_size, 6 );    # RW
        $layout->add_section( '.got',     512,        6 );    # RW

        # Non-alloc symbol and string tables for static linking/debugging (nm)
        $layout->add_section( '.symtab', 4096, 0 );
        $layout->add_section( '.strtab', 4096, 0 );
        #
        if ( $dbg >= 1 ) {
            $layout->add_section( '.debug_line',     4096, 0 );
            $layout->add_section( '.debug_info',     4096, 0 );
            $layout->add_section( '.debug_abbrev',   4096, 0 );
            $layout->add_section( '.debug_frame',    4096, 0 );
            $layout->add_section( '.debug_aranges',  4096, 0 );
            $layout->add_section( '.debug_pubnames', 4096, 0 );
            $layout->add_section( '.eh_frame',       4096, 0 );
        }
    }

    method import_rva($name) {

        #my $imports = { dlopen => 16, dlsym => 24, pthread_create => 32, exit => 40, _exit => 40 };
        my $imports = { dlopen => 24, dlsym => 32, pthread_create => 40, exit => 48, _exit => 48 };
        return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die 'Unknown ELF import: ' . $name );
    }
    method image_base () { return $self->type eq 'shared' ? 0 : 0x400000; }

    method write_executable ( $output_file, $code_data, $platform, $shared = false, $debug_bytes = undef ) {

        # Ensure $platform is normalized into a platform object if a raw string is passed
        $platform = Brocken::Katsuro::Platform::parse($platform) unless ref $platform;

        # Multi-function support: if $code_data is an arrayref of {name, bytes, fixups},
        # concatenate all blobs, compute function offsets, and track external fixups.
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

        # Automatically calculate layout if it wasn't called beforehand
        if ( !defined $self->layout ) {

            # Allocate extra data space for platform-specific control variables
            my $extra_data = $platform->is_bsd ? 32 : ( $platform->is_haiku ? 8 : 0 );
            $self->pre_layout( length($code_bytes) + 32, $extra_data, $platform );
        }
        my $l = $self->layout;

        #my $is_pie     = ($platform->is_bsd || $platform->is_haiku) && !($shared && $platform->is_freebsd);
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

                # ARM64 Dynamic Exit Stub:
                # - bl main
                # - adrp x8, :got:exit
                # - ldr x8, [x8, :got_lo12:exit]
                # - blr x8
                # - brk #0
                my $got_exit  = $self->import_rva('exit');
                my $adrp_pc   = $text_rva + 4;
                my $page_diff = ( $got_exit >> 12 ) - ( $adrp_pc >> 12 );
                $page_diff &= 0x1FFFFF;
                my $immlo   = $page_diff & 3;
                my $immhi   = ( $page_diff >> 2 ) & 0x7FFFF;
                my $adrp    = 0x90000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | 8;
                my $pimm    = ( $got_exit & 0xFFF ) >> 3;
                my $ldr     = 0xF9400000 | ( $pimm << 10 ) | ( 8 << 5 ) | 8;
                my $blr     = 0xD63F0100;
                my $bl_main = 0x94000000 | ( ( ( 20 + ( $func_offsets{main} // 0 ) ) >> 2 ) & 0x3FFFFFF );
                my $brk     = 0xD4200000;
                $entry_stub = pack( 'V5', $bl_main, $adrp, $ldr, $blr, $brk );
            }
            elsif ( $platform->is_riscv64 ) {

                # RISC-V 64-bit Entry Stub:
                # - jal ra, main
                # - auipc t0, %pcrel_hi(exit)
                # - ld t0, %pcrel_lo(auipc)(t0)
                # - jalr ra, t0
                # - ebreak
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
                    | ( $halfword & 0xFF000 );
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
                $entry_stub .= pack( 'C V',   0xE8, $main_rel );       # call main (rel)
                $entry_stub .= pack( 'C3',    0x48, 0x89, 0xC7 );      # mov rdi, rax
                $entry_stub .= pack( 'C2 l<', 0xFF, 0x15, $rel32 );    # call [rip + got_exit]
                $entry_stub .= pack( 'C2',    0x0F, 0x0B );            # ud2 (Invalid instruction safety)
            }
            $text = $entry_stub . $code_bytes;
        }

        # Resolve cross-function call fixups at link time
        my $entry_size = $self->type eq 'exe' ? length($entry_stub) : 0;
        for my $ff (@func_fixups) {
            my $target_off = $func_offsets{ $ff->{target} };
            die "write_executable: undefined function '$ff->{target}'" unless defined $target_off;
            my $src_pos = $entry_size + $ff->{base_offset} + $ff->{offset};
            if ( $ff->{type} eq 'call_rel32' ) {
                my $rel = ( $entry_size + $target_off ) - ( $src_pos + 5 );
                substr( $text, $src_pos + 1, 4, pack( 'V', $rel & 0xFFFFFFFF ) );
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
        }

        # Deterministic OSABI and ABI notes explicitly defined per platform.
        my $osabi        = 0;
        my $note_data    = '';
        my $has_pintable = 0;
        if ( $platform->is_freebsd ) {
            $osabi     = 9;                                                    # ELFOSABI_FREEBSD
            $note_data = pack( 'L<3 a8 L<', 8, 4, 1, "FreeBSD\0", 1400097 );
        }
        elsif ( $platform->is_midnightbsd ) {
            $osabi     = 9;
            $note_data = pack( 'L<3 a12 L<', 12, 4, 1, "MidnightBSD\0", 300000 );
        }
        elsif ( $platform->is_netbsd ) {
            $osabi     = 2;                                                        # ELFOSABI_NETBSD
            $note_data = pack( 'L<3 a8 L<', 7, 4, 1, "NetBSD\0\0", 1099000000 );
            $note_data .= pack( 'L<3 a4 L<', 4, 4, 3, "PaX\0", 0x0a );             # Flag 0x0a relaxes PaX W^X
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

        # Per-OS interpreter path for dynamic executables
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

        # Per-OS libc name fallback for DT_NEEDED
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

        # Generate pintable data for OpenBSD (syscall allowlisting)
        my $pintable_data = '';
        if ( $has_pintable && $platform->is_openbsd ) {
            my $pos             = 0;
            my $text_rva_actual = $self->layout->get('.text')->{rva};
            my $exit_sys        = $platform->syscall('exit') // 1;
            if ( $platform->is_x64 ) {
                while ( ( my $idx = index( $text, "\x0F\x05", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_rva_actual + $idx;

                    # OpenBSD ELF64 pintable entries are 16 bytes: uint64_t addr, uint32_t syscall, uint32_t pad
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

        # Setup Interp path for executable
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

        # Setup Dynamic Strings Table
        my @exports   = @{ $self->exported_funcs // [] };
        my $exit_name = $platform->is_haiku ? 'exit' : '_exit';                # Reference: eg/ABI.md Section 2.3
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
                my @matches = glob("$dir/libc.so.[0-9]*");
                for my $m (@matches) {
                    next if $m =~ /_p\.so/;    # skip profiled
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

        # Dynamic libraries loaded by DT_NEEDED
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
                    my @matches = glob("$dir/$prefix.so.[0-9]*");
                    for my $m (@matches) {
                        next if $m =~ /_p\.so/;    # skip profiled
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
        # Reference: eg/ABI.md Section 2.2
        if ( $platform->is_bsd && $self->type eq 'exe' ) {
            $str_off{'__progname'} = length($dynstr);
            $dynstr .= '__progname' . "\0";
            $str_off{'environ'} = length($dynstr);
            $dynstr .= 'environ' . "\0";
        }

        # Map Haiku ABI version symbols
        # Reference: eg/ABI.md Section 2.1
        if ( $platform->is_haiku ) {
            $str_off{'_gSharedObjectHaikuABI'} = length($dynstr);
            $dynstr .= "_gSharedObjectHaikuABI\0";
            $str_off{'_gSharedObjectHaikuVersion'} = length($dynstr);
            $dynstr .= "_gSharedObjectHaikuVersion\0";
        }
        $self->layout->get('.dynstr')->{size} = length($dynstr);

        # Setup Dynamic Symbol Table
        # Elf64_Sym (24 bytes): Null symbol
        my $dynsym = pack(
            'L< C C S< Q< Q<', 0,    # st_name (String table offset)
            0,                       # st_info (Bind/Type)
            0,                       # st_other (Visibility)
            0,                       # st_shndx (Section index)
            0,                       # st_value (Value/Address)
            0                        # st_size (Symbol size)
        );
        my $sym_idx = 1;
        my %sym_indices;

        # Undefined dynamic imports
        for my $name (@imports) {
            $sym_indices{$name} = $sym_idx++;

            # Elf64_Sym (24 bytes) for undefined global functions
            $dynsym .= pack(
                'L< C C S< Q< Q<', $str_off{$name},    # st_name
                0x12,                                  # st_info (STB_GLOBAL | STT_FUNC)
                0,                                     # st_other (STV_DEFAULT)
                0,                                     # st_shndx (SHN_UNDEF)
                0,                                     # st_value
                0                                      # st_size
            );
        }

        # Exports if shared library
        if ( $self->type eq 'shared' ) {
            for my $name (@exports) {
                my $rva = $self->layout->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
                $sym_indices{$name} = $sym_idx++;

                # Elf64_Sym (24 bytes) for defined exported functions
                $dynsym .= pack(
                    'L< C C S< Q< Q<', $str_off{$name},    # st_name
                    0x12,                                  # st_info (STB_GLOBAL | STT_FUNC)
                    0,                                     # st_other (STV_DEFAULT)
                    1,                                     # st_shndx (.text section index)
                    $base + $rva,                          # st_value
                    0                                      # st_size
                );
            }
        }

        # Define __progname for BSD to satisfy libc's internal reference (e.g. DragonFly)
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
                $dynsym .= pack(
                    'L< C C S< Q< Q<', $progname_off,    # st_name
                    0x11,                                # st_info (STB_GLOBAL | STT_OBJECT)
                    0,                                   # st_other (STV_DEFAULT)
                    $data_sec_idx // 0,                  # st_shndx
                    $base + $data_sec->{rva} + 16,       # st_value (points to Offset 16 in .data)
                    8                                    # st_size (pointer size)
                );
            }
        }

        # Define environ for BSD to satisfy libc's dynamic reference (e.g. DragonFly)
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
                $dynsym .= pack(
                    'L< C C S< Q< Q<', $environ_off,    # st_name
                    0x11,                               # st_info (STB_GLOBAL | STT_OBJECT)
                    0,                                  # st_other (STV_DEFAULT)
                    $data_sec_idx // 0,                 # st_shndx
                    $base + $data_sec->{rva} + 8,       # st_value (points to Offset 8 in .data)
                    8                                   # st_size (pointer size)
                );
            }
        }

        # Define Haiku ABI variables
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
            $sym_indices{'_gSharedObjectHaikuABI'} = $sym_idx++;
            $dynsym .= pack( 'L< C C S< Q< Q<', $abi_off, 0x11, 0, $data_sec_idx // 0, $base + $data_sec->{rva}, 4 );
            $sym_indices{'_gSharedObjectHaikuVersion'} = $sym_idx++;
            $dynsym .= pack( 'L< C C S< Q< Q<', $ver_off, 0x11, 0, $data_sec_idx // 0, $base + $data_sec->{rva} + 4, 4 );
        }
        $self->layout->get('.dynsym')->{size} = length($dynsym);

        # Setup Relocations (.rela.dyn)
        my $rel_type
            = $platform->is_arm64 ? 1025 : ( $platform->is_riscv64 ? 2 : 6 );   # R_RISCV_64 (2) or R_AARCH64_GLOB_DAT (1025) or R_X86_64_GLOB_DAT (6)
        my $rela_dyn = '';

        # Elf64_Rela (24 bytes) for dlopen
        my $dlopen_slot    = $base + $self->import_rva('dlopen');
        my $dlopen_sym_idx = $sym_indices{'dlopen'};
        $rela_dyn .= pack(
            'Q< Q< q<', $dlopen_slot,                 # r_offset
            ( $dlopen_sym_idx << 32 ) | $rel_type,    # r_info
            0                                         # r_addend
        );

        # Elf64_Rela (24 bytes) for dlsym
        my $dlsym_slot    = $base + $self->import_rva('dlsym');
        my $dlsym_sym_idx = $sym_indices{'dlsym'};
        $rela_dyn .= pack(
            'Q< Q< q<', $dlsym_slot,                  # r_offset
            ( $dlsym_sym_idx << 32 ) | $rel_type,     # r_info
            0                                         # r_addend
        );

        # Elf64_Rela (24 bytes) for pthread_create
        my $pthread_slot    = $base + $self->import_rva('pthread_create');
        my $pthread_sym_idx = $sym_indices{'pthread_create'};
        $rela_dyn .= pack(
            'Q< Q< q<', $pthread_slot,                 # r_offset
            ( $pthread_sym_idx << 32 ) | $rel_type,    # r_info
            0                                          # r_addend
        );

        # Elf64_Rela (24 bytes) for exit mapping
        my $exit_slot    = $base + $self->import_rva('exit');
        my $exit_sym_idx = $sym_indices{$exit_name};
        $rela_dyn .= pack(
            'Q< Q< q<', $exit_slot,                    # r_offset
            ( $exit_sym_idx << 32 ) | $rel_type,       # r_info
            0                                          # r_addend
        );
        $self->layout->get('.rela.dyn')->{size} = length($rela_dyn);

        # Setup GOT section payload (3 reserved + 4 import slots: dlopen, dlsym, pthread_create, exit)
        # First 3 QWORDs reserved for BSD rtld (DYNAMIC, link_map, resolver); imports start at offset 24.
        my $got = pack( 'Q< Q< Q< Q< Q< Q< Q<', 0, 0, 0, 0, 0, 0, 0 );
        $self->layout->get('.got')->{size} = length($got);

        # Setup Hash Table (Standard System V Hash)
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

        # Size the static .symtab and .strtab sections before final layout calculations
        $self->layout->get('.symtab')->{size} = length($dynsym);
        $self->layout->get('.strtab')->{size} = length($dynstr);

        # Calculate to stabilize RVAs before building .dynamic
        $self->layout->calculate($page_align);

        # Setup .dynamic payload
        my $dyn_rva        = $self->layout->get('.dynamic')->{rva};
        my $str_rva        = $self->layout->get('.dynstr')->{rva};
        my $sym_rva        = $self->layout->get('.dynsym')->{rva};
        my $hash_rva       = $self->layout->get('.hash')->{rva};
        my $rela_rva       = $self->layout->get('.rela.dyn')->{rva};
        my $got_rva_actual = $self->layout->get('.got')->{rva};
        my $dynamic        = '';

        # Elf64_Dyn (16 bytes each) entries
        for my $lib (@libs) {
            $dynamic .= pack( 'Q< Q<', 1, $str_off{$lib} );    # DT_NEEDED (string offset)
        }
        $dynamic .= pack( 'Q< Q<', 4,  $base + $hash_rva );          # DT_HASH
        $dynamic .= pack( 'Q< Q<', 5,  $base + $str_rva );           # DT_STRTAB
        $dynamic .= pack( 'Q< Q<', 6,  $base + $sym_rva );           # DT_SYMTAB
        $dynamic .= pack( 'Q< Q<', 10, length($dynstr) );            # DT_STRSZ
        $dynamic .= pack( 'Q< Q<', 11, 24 );                         # DT_SYMENT (sizeof Elf64_Sym)
        $dynamic .= pack( 'Q< Q<', 7,  $base + $rela_rva );          # DT_RELA
        $dynamic .= pack( 'Q< Q<', 8,  length($rela_dyn) );          # DT_RELASZ
        $dynamic .= pack( 'Q< Q<', 9,  24 );                         # DT_RELAENT (sizeof Elf64_Rela)
        $dynamic .= pack( 'Q< Q<', 3,  $base + $got_rva_actual );    # DT_PLTGOT

        if ($is_pie) {
            $dynamic .= pack( 'Q< Q<', 0x6ffffffb, 0x08000000 );     # DT_FLAGS_1 with DF_1_PIE
        }
        $dynamic .= pack( 'Q< Q<', 0, 0 );                           # DT_NULL
        $self->layout->get('.dynamic')->{size} = length($dynamic);

        # Final layout calculation
        $self->layout->calculate($page_align);

        # Build Section Names String Table (.shstrtab)
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

        # Open file and write payloads based on layout
        open my $fh, '>', $output_file or die $!;
        binmode $fh;
        for my $s ( $self->layout->sections ) {
            my $payload = "\0" x $s->{size};
            if ( $s->{name} eq '.text' ) {
                $payload = $text;
            }
            elsif ( $s->{name} eq '.interp' ) {
                $payload = $interp;
            }
            elsif ( $s->{name} eq '.dynstr' ) {
                $payload = $dynstr;
            }
            elsif ( $s->{name} eq '.dynsym' ) {
                $payload = $dynsym;
            }
            elsif ( $s->{name} eq '.symtab' ) {
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

                    # Satisfy __progname and environ expectations
                    my $empty_env_addr = $base + $s->{rva};
                    my $empty_str_addr = $base + $s->{rva} + 24;
                    $payload = pack( 'Q< Q< Q<', 0, $empty_env_addr, $empty_str_addr );
                }
                elsif ( $platform->is_haiku && $s->{size} >= 8 ) {
                    $payload = pack( 'L< L<', 4, 0 );    # Haiku ABI Version 4
                }
                else {
                    $payload = "\0" x $s->{size};
                }
            }
            elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                $payload = $self->debug_section( $s->{name} ) || "\0";
            }
            $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
            seek( $fh, $s->{off}, 0 );
            print $fh $payload;
        }

        # Write Section Header String Table and Section Headers at the end
        my $shstrtab_off = tell($fh);
        print $fh $shstrtab;
        my $shoff = tell($fh);
        my @shdrs = ();

        # NULL Section (index 0) -- Elf64_Shdr (64 bytes)
        push @shdrs, pack(
            'L< L< Q< Q< Q< Q< L< L< Q< Q<', 0,    # sh_name
            0,                                     # sh_type
            0,                                     # sh_flags
            0,                                     # sh_addr
            0,                                     # sh_offset
            0,                                     # sh_size
            0,                                     # sh_link
            0,                                     # sh_info
            0,                                     # sh_addralign
            0                                      # sh_entsize
        );

        # Real sections from layout -- Elf64_Shdr (64 bytes each)
        for my $s ( $self->layout->sections ) {
            my $type       = 1;                    # SHT_PROGBITS
            my $flags      = 0;
            my $sh_link    = 0;
            my $sh_info    = 0;
            my $sh_entsize = 0;
            if ( $s->{name} eq '.text' ) {
                $flags = 6;                        # SHF_ALLOC | SHF_EXECINSTR
            }
            elsif ( $s->{name} eq '.data' ) {
                $flags = 3;                        # SHF_ALLOC | SHF_WRITE
            }
            elsif ( $s->{name} eq '.interp' ) {
                $type  = 1;                        # SHT_PROGBITS
                $flags = 2;                        # SHF_ALLOC
            }
            elsif ( $s->{name} eq '.dynstr' ) {
                $type  = 3;                        # SHT_STRTAB
                $flags = 2;                        # SHF_ALLOC
            }
            elsif ( $s->{name} eq '.dynsym' ) {
                $type       = 11;                             # SHT_DYNSYM
                $flags      = 2;                              # SHF_ALLOC
                $sh_link    = $sec_indices{'.dynstr'} // 0;
                $sh_info    = 1;                              # One local symbol (the null symbol)
                $sh_entsize = 24;
            }
            elsif ( $s->{name} eq '.symtab' ) {
                $type       = 2;                              # SHT_SYMTAB
                $flags      = 0;                              # Not SHF_ALLOC
                $sh_link    = $sec_indices{'.strtab'} // 0;
                $sh_info    = 1;
                $sh_entsize = 24;
            }
            elsif ( $s->{name} eq '.strtab' ) {
                $type  = 3;                                   # SHT_STRTAB
                $flags = 0;                                   # Not SHF_ALLOC
            }
            elsif ( $s->{name} eq '.rela.dyn' ) {
                $type       = 4;                              # SHT_RELA
                $flags      = 2;                              # SHF_ALLOC
                $sh_link    = $sec_indices{'.dynsym'} // 0;
                $sh_entsize = 24;
            }
            elsif ( $s->{name} eq '.hash' ) {
                $type       = 5;                              # SHT_HASH
                $flags      = 2;                              # SHF_ALLOC
                $sh_link    = $sec_indices{'.dynsym'} // 0;
                $sh_entsize = 4;
            }
            elsif ( $s->{name} eq '.dynamic' ) {
                $type       = 6;                                         # SHT_DYNAMIC
                $flags      = ( $platform->is_dragonflybsd ) ? 2 : 3;    # Read-only on DFly to avoid RELRO crash
                $sh_link    = $sec_indices{'.dynstr'} // 0;
                $sh_entsize = 16;
            }
            elsif ( $s->{name} eq '.got' ) {
                $type       = 1;                                         # SHT_PROGBITS
                $flags      = 3;                                         # SHF_ALLOC | SHF_WRITE
                $sh_entsize = 8;
            }
            elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                $flags = 0;                                              # Debug sections are not loaded
            }
            push @shdrs, pack(
                'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{ $s->{name} },    # sh_name
                $type,                                                          # sh_type
                $flags,                                                         # sh_flags
                ( $flags & 2 ? $base + $s->{rva} : 0 ),                         # sh_addr
                $s->{off},                                                      # sh_offset
                $s->{size},                                                     # sh_size
                $sh_link,                                                       # sh_link
                $sh_info,                                                       # sh_info
                1,                                                              # sh_addralign
                $sh_entsize                                                     # sh_entsize
            );
        }
        my $shstrtab_idx = scalar(@shdrs);

        # .shstrtab section header -- Elf64_Shdr (64 bytes)
        push @shdrs, pack(
            'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{'.shstrtab'},    # sh_name
            3,                                                             # sh_type (SHT_STRTAB)
            0,                                                             # sh_flags
            0,                                                             # sh_addr
            $shstrtab_off,                                                 # sh_offset
            length($shstrtab),                                             # sh_size
            0, 0, 1, 0                                                     # sh_link, sh_info, sh_addralign, sh_entsize
        );

        # .note.GNU-stack section header -- Elf64_Shdr (64 bytes)
        push @shdrs, pack(
            'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{'.note.GNU-stack'},    # sh_name
            1,                                                                   # sh_type (SHT_PROGBITS)
            0,                                                                   # sh_flags
            0, 0, 0, 0, 0, 1, 0                                                  # sh_addr, sh_offset, sh_size, l, i, a, e
        );
        seek( $fh, $shoff, 0 );
        print $fh $_ for @shdrs;

        # Program Headers -- Elf64_Phdr (56 bytes each)
        my $num_ph = 5;                       # PT_PHDR, PT_LOAD (RX), PT_LOAD (RW), PT_DYNAMIC, PT_GNU_STACK
        if ($has_interp)    { $num_ph++; }    # PT_INTERP
        if ($note_data)     { $num_ph++; }    # PT_NOTE
        if ($pintable_data) { $num_ph++; }    # PT_OPENBSD_PINTABLE
        if ($is_pie)        { $num_ph++; }    # PT_GNU_RELRO
        my @phdrs     = ();
        my $extra_off = 64 + ( $num_ph * 56 );

        # PT_PHDR (type 6) -- Elf64_Phdr (56 bytes)
        push @phdrs, pack(
            'L< L< Q< Q< Q< Q< Q< Q<', 6,    # p_type (PT_PHDR)
            4,                               # p_flags (PF_R)
            64,                              # p_offset (offset immediately following ELF header)
            $base + 64,                      # p_vaddr
            $base + 64,                      # p_paddr
            $num_ph * 56,                    # p_filesz
            $num_ph * 56,                    # p_memsz
            8                                # p_align
        );

        # PT_INTERP (type 3) -- Elf64_Phdr (56 bytes)
        if ($has_interp) {
            my $interp_sec = $self->layout->get('.interp');
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 3,    # p_type (PT_INTERP)
                4,                               # p_flags (PF_R)
                $interp_sec->{off},              # p_offset
                $base + $interp_sec->{rva},      # p_vaddr
                $base + $interp_sec->{rva},      # p_paddr
                $interp_sec->{size},             # p_filesz
                $interp_sec->{size},             # p_memsz
                1                                # p_align
            );
        }

        # PT_LOAD RX segment (Headers + .text through .hash) -- Elf64_Phdr (56 bytes)
        my $hash_sec  = $self->layout->get('.hash');
        my $rx_p_off  = 0;
        my $rx_p_size = $hash_sec->{off} + $hash_sec->{size};
        push @phdrs, pack(
            'L< L< Q< Q< Q< Q< Q< Q<', 1,    # p_type (PT_LOAD)
            5,                               # p_flags (PF_R | PF_X)
            $rx_p_off,                       # p_offset
            $base,                           # p_vaddr
            $base,                           # p_paddr
            $rx_p_size,                      # p_filesz
            $rx_p_size,                      # p_memsz
            $page_align                      # p_align
        );

        # PT_LOAD RW segment (Covers .dynamic through .got) -- Elf64_Phdr (56 bytes)
        my $dyn_sec  = $self->layout->get('.dynamic');
        my $got_sec  = $self->layout->get('.got');
        my $rw_p_off = $dyn_sec->{off} & ~( $page_align - 1 );
        my $rw_size  = ( $got_sec->{off} + $got_sec->{size} ) - $rw_p_off;
        push @phdrs, pack(
            'L< L< Q< Q< Q< Q< Q< Q<', 1,    # p_type (PT_LOAD)
            6,                               # p_flags (PF_R | PF_W)
            $rw_p_off,                       # p_offset (page-aligned down)
            $base + $dyn_sec->{rva},         # p_vaddr
            $base + $dyn_sec->{rva},         # p_paddr
            $rw_size,                        # p_filesz
            $rw_size,                        # p_memsz
            $page_align                      # p_align
        );

        # PT_DYNAMIC (type 2) -- Elf64_Phdr (56 bytes)
        push @phdrs, pack(
            'L< L< Q< Q< Q< Q< Q< Q<', 2,    # p_type (PT_DYNAMIC)
            6,                               # p_flags (PF_R | PF_W)
            $dyn_sec->{off},                 # p_offset
            $base + $dyn_sec->{rva},         # p_vaddr
            $base + $dyn_sec->{rva},         # p_paddr
            $dyn_sec->{size},                # p_filesz
            $dyn_sec->{size},                # p_memsz
            8                                # p_align
        );

        # PT_GNU_RELRO (type 0x6474e552) -- Elf64_Phdr (56 bytes)
        # Covers ONLY .dynamic to ensure .data and .got remain fully writable.
        # Reference: eg/ABI.md Section 2.4
        if ($is_pie) {
            my $relro_start = $dyn_sec->{off} & ~( $page_align - 1 );
            my $relro_size  = ( $dyn_sec->{off} + $dyn_sec->{size} - $relro_start + $page_align - 1 ) & ~( $page_align - 1 );
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 0x6474e552,                 # p_type (PT_GNU_RELRO)
                4,                                                     # p_flags (PF_R)
                $relro_start,                                          # p_offset
                $base + ( $dyn_sec->{rva} & ~( $page_align - 1 ) ),    # p_vaddr
                $base + ( $dyn_sec->{rva} & ~( $page_align - 1 ) ),    # p_paddr
                $relro_size,                                           # p_filesz
                $relro_size,                                           # p_memsz
                1                                                      # p_align
            );
        }

        # PT_NOTE -- Elf64_Phdr (56 bytes)
        if ($note_data) {
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 4,                          # p_type (PT_NOTE)
                4,                                                     # p_flags (PF_R)
                $extra_off,                                            # p_offset
                $base + $extra_off,                                    # p_vaddr
                $base + $extra_off,                                    # p_paddr
                length($note_data),                                    # p_filesz
                length($note_data),                                    # p_memsz
                4                                                      # p_align
            );
            $extra_off += length($note_data);
        }

        # PT_OPENBSD_PINTABLE -- Elf64_Phdr (56 bytes)
        if ($pintable_data) {
            push @phdrs, pack(
                'L< L< Q< Q< Q< Q< Q< Q<', 0x65a3dbe9,                 # p_type (PT_OPENBSD_PINTABLE)
                4,                                                     # p_flags (PF_R)
                $extra_off,                                            # p_offset
                $base + $extra_off,                                    # p_vaddr
                $base + $extra_off,                                    # p_paddr
                length($pintable_data),                                # p_filesz
                length($pintable_data),                                # p_memsz
                4                                                      # p_align
            );
            $extra_off += length($pintable_data);
        }

        # PT_GNU_STACK (type 0x6474e551) -- Elf64_Phdr (56 bytes)
        # p_flags = 6 (PF_R|PF_W) for non-executable stack. Some BSD kernels
        # reject binaries with p_flags=0 on PT_GNU_STACK.
        push @phdrs, pack(
            'L< L< Q< Q< Q< Q< Q< Q<', 0x6474e551,    # p_type (PT_GNU_STACK)
            6, 0, 0, 0, 0, 0, 0x10                    # p_flags=6(PF_R|PF_W), p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align
        );
        my $entry_point = $self->type eq 'shared' ? 0 : $base + $self->layout->get('.text')->{rva};

        # Finalize ELF Header (Elf64_Ehdr - Exactly 64 bytes) and write program headers/extra data
        # Reference: https://refspecs.linuxbase.org/elf/gabi4+/ch4.eheader.html
        my $ehdr = pack(
            'A4 C C C C C x7 S< S< L< Q< Q< Q< L< S< S< S< S< S< S<', "\x7fELF",    # e_ident[0..3] (Magic)
            2,                                                                      # e_ident[4] (Class: 64-bit)
            1,                                                                      # e_ident[5] (Data: Little Endian)
            1,                                                                      # e_ident[6] (Version: 1)
            $osabi,                                                                 # e_ident[7] (OS/ABI)
            0,                                                                      # e_ident[8] (ABI Version)

            # e_ident[9..15] (Padding, implicitly added by x7)
            $elf_type,                                                               # e_type (ET_EXEC = 2 or ET_DYN = 3)
            ( $platform->is_arm64 ? 183 : ( $platform->is_riscv64 ? 243 : 62 ) ),    # e_machine (EM_AARCH64 = 183 or EM_X86_64 = 62)
            1,                                                                       # e_version
            $entry_point,                                                            # e_entry (Starting Virtual Address)
            64,                                                                      # e_phoff (Program Header Table offset)
            $shoff,                                                                  # e_shoff (Section Header Table offset)
            ( $platform->is_riscv64 ? 0x0004 : 0 ),                                  # e_flags (EF_RISCV_FLOAT_ABI_DOUBLE for RISC-V lp64d)
            64,                                                                      # e_ehsize (ELF Header Size)
            56,                                                                      # e_phentsize (Program Header Entry Size)
            $num_ph,                                                                 # e_phnum (Number of Program Header Entries)
            64,                                                                      # e_shentsize (Section Header Entry Size)
            scalar(@shdrs),                                                          # e_shnum (Number of Section Header Entries)
            $shstrtab_idx                                                            # e_shstrndx (Section index of .shstrtab)
        );
        seek( $fh, 0, 0 );
        print $fh $ehdr, @phdrs, $note_data, $pintable_data;
        close $fh;
        chmod 0755, $output_file;
        return $output_file;
    }
}
1;
