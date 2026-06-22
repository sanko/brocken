use v5.42;
use feature qw[class];
no warnings qw[experimental::class portable];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;
use Symbol 'gensym';

class Brocken::Jenny::Linker::MachO : isa(Brocken::Jenny::Linker) {
    use Brocken::Jenny::Codegen::ARM64::Inst;
    use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC O_RDWR);
    field $has_ffi : reader = false;
    method set_has_ffi($v) { $has_ffi = $v; }

    method _setup_layout( $layout, $text_size, $data_size, $arch, $os, $dbg = 0 ) {
        $layout->add_section( '.text', $text_size, 5 );                                      # Read + Execute
        my $brk_sym_size = $self->brk_sym_size();
        $layout->add_section( '.brk_sym',  $brk_sym_size,        5 ) if $brk_sym_size > 0;
        $layout->add_section( '.data',     $data_size,           3 ) if $data_size > 0;      # Read + Write
        $layout->add_section( '.got',      512,                  3 ) if $has_ffi;            # Global Offset Table
        $layout->add_section( '.linkedit', $has_ffi ? 4096 : 64, 1 );                        # Symbols, Strings, Dynamic linking info
        if ( $dbg >= 1 ) {
            $layout->add_section( '.debug_line',     4096, 0 );
            $layout->add_section( '.debug_info',     8192, 0 );
            $layout->add_section( '.debug_abbrev',   4096, 0 );
            $layout->add_section( '.debug_frame',    8192, 0 );
            $layout->add_section( '.debug_aranges',  4096, 0 );
            $layout->add_section( '.debug_pubnames', 4096, 0 );
            $layout->add_section( '.debug_names',    4096, 0 );
            $layout->add_section( '.debug_str',      4096, 0 );
        }
    }

    method import_rva($name) {
        my $imports = { dlopen => 0, dlsym => 8, pthread_create => 16 };
        return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die 'Unknown Mach-O import: ' . $name );
    }
    method image_base () { return hex('100000000'); }    # 64-bit macOS default image base (4GB)

    method write_executable ( $output_file, $code_data, $platform, $shared = false, $debug_bytes = undef ) {

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
        my $full_code    = ref $code_bytes eq 'HASH' ? $code_bytes->{binary}                        : $code_bytes;
        my $writable_off = ref $code_bytes eq 'HASH' ? ( $code_bytes->{writable_data_offset} // 0 ) : 0;
        my $text_raw     = $writable_off             ? substr( $full_code, 0, $writable_off )       : $full_code;
        my $data_bytes   = $writable_off             ? substr( $full_code, $writable_off )          : '';
        my $text         = $text_raw;
        my $entry_stub   = '';
        my $arch         = $platform->arch;
        my $os           = $platform->os;

        # Prepend platform-specific Mach-O _start stubs if compiling an executable
        if ( $self->type eq 'exe' ) {
            my $exit_sys = $platform->syscall('exit') // 0x2000001;
            if ( $platform->is_arm64 ) {

                # ARM64 (Apple Silicon) native exit stub:
                # - bl main (relative call offset +20 bytes -> 5 instructions)
                # - movz x16, #sys_low
                # - movk x16, #sys_high, lsl #16
                # - svc #0x80
                # - brk #0 (Safety crash)
                my $bl   = bl( 20 + ( $func_offsets{main} // 0 ) );
                my $movz = movz_64( 16, $exit_sys & 0xFFFF );
                my $movk = movk_64( 16, ( $exit_sys >> 16 ) & 0xFFFF, 1 );
                $entry_stub = pack( 'V5', $bl, $movz, $movk, svc(0x80), brk(0) );
            }
            else {
                # x86_64 (Intel Mac) native exit stub with 16-byte stack alignment:
                # - and rsp, -16:   48 83 e4 f0    (Align stack for System V ABI)
                # - call main:      e8 0c 00 00 00 (Relative call 12 bytes ahead to start at byte 21)
                # - mov rdi, rax:   48 89 c7       (Copy main's return code to first argument)
                # - mov eax, sys:   b8 ...         (0x2000001 is exit syscall with macOS offset)
                # - syscall:        0f 05
                # - ud2:            0f 0b
                $entry_stub = pack( 'C4', 0x48, 0x83, 0xE4, 0xF0 );
                $entry_stub .= pack( 'C V', 0xE8, 12 + ( $func_offsets{main} // 0 ) );
                $entry_stub .= pack( 'C3',  0x48, 0x89, 0xC7 );
                $entry_stub .= pack( 'C V', 0xB8, $exit_sys );
                $entry_stub .= pack( 'C2',  0x0F, 0x05 );
                $entry_stub .= pack( 'C2',  0x0F, 0x0B );
            }
            $text = $entry_stub . $text_raw;
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

        # Automatically calculate layout if it wasn't called beforehand
        if ( !defined $self->layout ) {
            $self->pre_layout( length($text), length($data_bytes), $platform );
        }
        my $base      = $self->image_base;
        my $page_size = $platform->page_size;    # 16KB for Apple Silicon, 4KB for Intel

        # Mach-O CPU types: CPU_TYPE_X86_64=0x01000007, CPU_TYPE_ARM64=0x0100000c
        my $cputype        = ( $arch =~ /aarch64|arm64/i ) ? 0x0100000c : 0x01000007;
        my $cpusubtype     = ( $arch =~ /aarch64|arm64/i ) ? 0          : 3;            # CPU_SUBTYPE_ARM64_ALL / CPU_SUBTYPE_I386_ALL
        my $filetype       = ( $self->type eq 'shared' ) ? 6 : 2;                       # MH_DYLIB or MH_EXECUTE
        my @debug_sections = grep { $_->{name} =~ /^\.debug/ } $self->layout->sections;
        my $_uleb          = sub {
            my $v   = shift;
            my $out = '';
            do {
                my $byte = $v & 0x7F;
                $v >>= 7;
                $byte |= 0x80 if $v;
                $out .= pack( 'C', $byte );
            } while ($v);
            return $out;
        };
        my $lib_name = "/usr/lib/libSystem.B.dylib\0";
        while ( length($lib_name) % 8 != 0 ) { $lib_name .= "\0"; }

        # LC_LOAD_DYLIB load command (Loads macOS system library)
        my $lc_load_libsystem = pack( 'L<6', 0xC, 24 + length($lib_name), 24, 2, 0x010000, 0x010000 ) . $lib_name;

        # Setup dynamic binding info for resolving FFI imports
        my $bind_info      = '';
        my $bind_info_size = 0;
        my $got_sec        = $self->layout->get('.got');
        if ($got_sec) {
            my $data_sec    = $self->layout->get('.data');
            my $d_start_rva = $data_sec ? $data_sec->{rva} : $got_sec->{rva};
            my $got_off     = $got_sec->{rva} - $d_start_rva;
            my $data_seg    = 0;
            {
                my %saw;
                my @segseq;
                push @segseq, '__PAGEZERO' if $self->type ne 'shared';
                for ( $self->layout->sections ) {
                    my $sn
                        = ( $_->{name} =~ /^\.text/ )                     ? '__TEXT' :
                        ( $_->{name} eq '.data' || $_->{name} eq '.got' ) ? '__DATA' :
                        ( $_->{name} eq '.linkedit' )                     ? '__LINKEDIT' :
                        ( $_->{name} =~ /^\.debug/ )                      ? '__DWARF' :
                        undef;
                    push( @segseq, $sn ), $saw{$sn} = 1 if defined $sn && !$saw{$sn};
                }
                for ( 0 .. $#segseq ) { $data_seg = $_ if $segseq[$_] eq '__DATA'; }
            }

            # LC_DYLD_INFO_ONLY bind opcodes:
            #   0x70 | seg = BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB
            #   0x10 | ord = BIND_OPCODE_SET_DYLIB_ORDINAL_IMM (ordinal 1 = libSystem)
            #   0x50 | type = BIND_OPCODE_SET_TYPE_IMM (type 0 = TEXT_ABSOLUTE_32, 1 = POINTER)
            #   0x40 | trailing = BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM
            #   0x90 = BIND_OPCODE_DO_BIND
            $bind_info .= pack( 'C', 0x70 | $data_seg ) . $_uleb->($got_off);
            for my $name ( '_dlopen', '_dlsym', '_pthread_create' ) {
                $bind_info .= pack( 'C', 0x11 );
                $bind_info .= pack( 'C', 0x51 );                 # BIND_TYPE_POINTER
                $bind_info .= pack( 'C', 0x40 ) . "${name}\0";
                $bind_info .= pack( 'C', 0x90 );
            }
            $bind_info .= pack( 'C', 0x00 );
            $bind_info_size = length($bind_info);
            while ( length($bind_info) % 8 != 0 ) { $bind_info .= "\0"; }
        }

        # Hand-assemble both defined exports and undefined external imports
        # to make sure dyld dynamic linking validations are strictly met.
        my ( $trie, $symtab, $strtab, $lc_id_dylib ) = ( '', '', '', '' );
        my ( $num_syms, $le_off, $trie_size, $symtab_size, $strtab_size ) = ( 0, 0, 0, 0, 0 );
        my @syms;
        my %sym_types;
        my %sym_rvas;

        # Undefined dynamic external imports
        if ($got_sec) {
            for my $name ( '_dlopen', '_dlsym', '_pthread_create' ) {
                push @syms, $name;
                $sym_types{$name} = 0x01;    # N_UNDF | N_EXT
                $sym_rvas{$name}  = 0;
            }
        }

        # Defined exports if shared library
        if ( $self->type eq 'shared' ) {
            require File::Basename;
            my $dylib_name     = File::Basename::basename($output_file);
            my $dylib_name_pad = $dylib_name . "\0";
            while ( length($dylib_name_pad) % 8 != 0 ) { $dylib_name_pad .= "\0"; }

            # LC_ID_DYLIB (Identifies the output dylib name)
            $lc_id_dylib = pack( 'L<6', 0xD, 24 + length($dylib_name_pad), 24, 1, 1, 1 ) . $dylib_name_pad;
            my @exports = @{ $self->exported_funcs // [] };
            for my $name (@exports) {
                my $mangled = '_' . $name;    # Prepended with an underscore to comply with Mach-O standards
                push @syms, $mangled;
                $sym_types{$mangled} = 0x0f;                                                                       # N_SECT | N_EXT
                $sym_rvas{$mangled}  = $self->layout->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
            }
        }

        # Sort symbol definitions for LC_DYSYMTAB layout rules (defined first, then undefined)
        my @defined_ext   = grep { $sym_types{$_} == 0x0f } @syms;
        my @undefined_ext = grep { $sym_types{$_} == 0x01 } @syms;
        my @sorted_syms   = ( @defined_ext, @undefined_ext );
        $num_syms = scalar @sorted_syms;

        # Build string table
        $strtab = "\0";
        my %strx;
        for my $sym (@sorted_syms) {
            $strx{$sym} = length($strtab);
            $strtab .= $sym . "\0";
        }
        while ( length($strtab) % 8 != 0 ) { $strtab .= "\0"; }

        # Build symbol table entries (nlist_64 structures)
        for my $sym (@sorted_syms) {
            my $type = $sym_types{$sym};
            my $sect = ( $type == 0x0f ) ? 1                           : 0;
            my $val  = ( $type == 0x0f ) ? ( $base + $sym_rvas{$sym} ) : 0;
            $symtab .= pack( 'L< C C S< Q<', $strx{$sym}, $type, $sect, 0, $val );
        }

        # Build the Export Trie if compiling a shared dylib containing exports
        my $nextdefsym = scalar(@defined_ext);
        my $nundefsym  = scalar(@undefined_ext);
        if ( $self->type eq 'shared' && $nextdefsym > 0 ) {
            my @nodes;
            for my $sym (@defined_ext) {
                my $rva        = $sym_rvas{$sym};
                my $flags_u    = $_uleb->(0);
                my $rva_u      = $_uleb->($rva);
                my $term_data  = $flags_u . $rva_u;
                my $node_bytes = $_uleb->( length($term_data) ) . $term_data . pack( 'C', 0 );
                push @nodes, { sym => $sym, bytes => $node_bytes };
            }
            my %node_offsets;
            for ( 1 .. 3 ) {
                my $root = pack( 'C', 0 ) . pack( 'C', $nextdefsym );
                for my $n (@nodes) { $root .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } // 1024 ); }
                my $offset    = length($root);
                my $converged = 0;
                for my $n (@nodes) {
                    my $new_off = $offset;
                    ++$converged if exists $node_offsets{ $n->{sym} } && $node_offsets{ $n->{sym} } == $new_off;
                    $node_offsets{ $n->{sym} } = $new_off;
                    $offset += length( $n->{bytes} );
                }
                last if $converged == @nodes;
            }
            $trie = pack( 'C', 0 ) . pack( 'C', $nextdefsym );
            for my $n (@nodes) { $trie .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } ); }
            for my $n (@nodes) { $trie .= $n->{bytes}; }
            while ( length($trie) % 8 != 0 ) { $trie .= "\0"; }
        }
        $trie_size   = length($trie);
        $symtab_size = length($symtab);
        $strtab_size = length($strtab);

        # Enforce Minimum Linkedit size to prevent sparse file truncation issues
        my $le_payload_size = length($bind_info) + $trie_size + $symtab_size + $strtab_size;
        $self->layout->get('.linkedit')->{size} = $le_payload_size > 64 ? $le_payload_size : 64;
        $self->layout->calculate($page_size);
        $le_off = $self->layout->get('.linkedit')->{off};
        my %seg_names = ( '.text' => '__TEXT', '.data' => '__DATA', '.got' => '__DATA', '.brk_sym' => '__TEXT' );
        my %sec_names = ( '.text' => '__text', '.data' => '__data', '.got' => '__got',  '.brk_sym' => '__brk_sym' );
        for my $s ( $self->layout->sections ) {
            if ( $s->{name} =~ /^\.debug_/ ) {
                $seg_names{ $s->{name} } = '__DWARF';
                ( my $macho_name = $s->{name} ) =~ s/^\./__/;
                $sec_names{ $s->{name} } = $macho_name;
            }
        }
        my @text_sections = grep { $_->{name} eq '.text' || $_->{name} eq '.brk_sym' } $self->layout->sections;
        my $t_sec         = $self->layout->get('.text');
        my @data_sections = grep { $_->{name} eq '.data' || $_->{name} eq '.got' } $self->layout->sections;
        my $t_vmsize      = 0;
        for my $s (@text_sections) { my $end = $s->{off} + $s->{size}; $t_vmsize = $end if $end > $t_vmsize; }
        my $t_seg_size = ( $t_vmsize + $page_size - 1 ) & ~( $page_size - 1 );
        my ( $d_start_rva, $d_start_off, $d_size, $d_seg_size );

        if (@data_sections) {
            $d_start_rva = $data_sections[0]->{rva};
            $d_start_off = $data_sections[0]->{off};
            $d_size      = ( $data_sections[-1]->{off} + $data_sections[-1]->{size} ) - $d_start_off;
            $d_seg_size  = ( $d_size + $page_size - 1 ) & ~( $page_size - 1 );
        }

        # Load command constants:
        #   0x19            = LC_SEGMENT_64
        #   0x32            = LC_BUILD_VERSION
        #   0xE             = LC_LOAD_DYLINKER
        #   0xC             = LC_LOAD_DYLIB
        #   0x80000022      = LC_DYLD_INFO_ONLY
        #   0x2             = LC_SYMTAB
        #   0xB             = LC_DYSYMTAB
        #   0x80000028      = LC_MAIN
        # Section flags: 0x80000400 = S_ATTR_SOME_INSTRUCTIONS | S_REGULAR
        my @cmds = ();

        # LC_SEGMENT_64: PageZero Segment (covers [0, base) to trap NULL deref)
        if ( $self->type ne 'shared' ) {
            push @cmds, pack( 'L<2 a16 Q<4 L<4', 0x19, 72, '__PAGEZERO', 0, $base, 0, 0, 0, 0, 0, 0 );
        }

        # LC_SEGMENT_64: TEXT Segment
        my $t_cmd_size = 72 + 80 * scalar(@text_sections);
        my $t_cmd      = pack( 'L<2 a16 Q<4 L<4', 0x19, $t_cmd_size, '__TEXT', $base, $t_seg_size, 0, $t_seg_size, 5, 5, scalar(@text_sections), 0 );
        for my $s (@text_sections) {
            $t_cmd .= pack(
                'a16 a16 Q<2 L<2 L<3 L<2 L<',
                $sec_names{ $s->{name} },
                '__TEXT',   $base + $s->{rva},
                $s->{size}, $s->{off}, 4, 0, 0, 0x80000400, 0, 0, 0
            );
        }
        push @cmds, $t_cmd;
        if (@data_sections) {
            my $d_cmd_size = 72 + 80 * scalar(@data_sections);
            my $d_cmd      = pack( 'L<2 a16 Q<4 L<4',
                0x19, $d_cmd_size, '__DATA', $base + $d_start_rva,
                $d_seg_size, $d_start_off, $d_size, 3, 3, scalar(@data_sections), 0 );
            for my $s (@data_sections) {
                my $sec_flags = $s->{name} eq '.got' ? 0x00000000 : 0;
                $d_cmd .= pack(
                    'a16 a16 Q<2 L<2 L<3 L<2 L<',
                    $sec_names{ $s->{name} },
                    '__DATA',   $base + $s->{rva},
                    $s->{size}, $s->{off}, 3, 0, 0, $sec_flags, 0, 0, 0
                );
            }
            push @cmds, $d_cmd;
        }

        # LC_SEGMENT_64: LINKEDIT Segment (symbols, strings, bind info)
        my $le_sec      = $self->layout->get('.linkedit');
        my $le_seg_size = ( $le_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
        push @cmds,
            pack( 'L<2 a16 Q<4 L<4', 0x19, 72, '__LINKEDIT', $base + $le_sec->{rva}, $le_seg_size, $le_sec->{off}, $le_sec->{size}, 1, 1, 0, 0 );
        push @cmds, $lc_id_dylib if $self->type eq 'shared';

        # LC_BUILD_VERSION (required by codesign on macOS 11+):
        #   platform=1 (macOS), minos=11.0, sdk=11.0
        push @cmds, pack( 'L<6', 0x32, 24, 1, 0x000B0000, 0x000B0000, 0 );

        # LC_LOAD_DYLINKER: points to `/usr/lib/dyld`
        push @cmds, pack( 'L<3', 0xE, 32, 12 ) . "/usr/lib/dyld\0\0\0\0\0\0\0";
        push @cmds, $lc_load_libsystem;

        # LC_DYLD_INFO_ONLY: rebase/bind/lazy/export offsets (48 bytes)
        my $export_off = ( $self->type eq 'shared' && $nextdefsym > 0 ) ? $le_off + length($bind_info) : 0;
        my $export_sz  = ( $self->type eq 'shared' && $nextdefsym > 0 ) ? $trie_size                   : 0;
        push @cmds, pack( 'L<12', 0x80000022, 48, 0, 0, $le_off, $bind_info_size, 0, 0, 0, 0, $export_off, $export_sz );

        # LC_SYMTAB: symbol table offset, count, string table offset, size
        my $symtab_off = $le_off + length($bind_info) + $trie_size;
        push @cmds, pack( 'L<6', 0x2, 24, $symtab_off, $num_syms, $symtab_off + $symtab_size, $strtab_size );

        # LC_DYSYMTAB: local/extdef/undefsym indices (80 bytes)
        #   iextdefsym=0, nextdefsym, iundefsym, nundefsym
        my $iextdefsym = 0;
        my $iundefsym  = $nextdefsym;
        push @cmds, pack( 'L<20', 0xB, 80, 0, 0, $iextdefsym, $nextdefsym, $iundefsym, $nundefsym, (0) x 14 );

        # LC_MAIN: entry point file offset, stack size=0 (use default)
        push @cmds, pack( 'L<2 Q<2', 0x80000028, 24, $t_sec->{off}, 0 ) if $self->type eq 'exe';
        if (@debug_sections) {
            my $cmdsize         = 72 + 80 * scalar(@debug_sections);
            my $dw_start_rva    = $debug_sections[0]->{rva};
            my $dw_start_off    = $debug_sections[0]->{off};
            my $dw_size         = ( $debug_sections[-1]->{off} + $debug_sections[-1]->{size} ) - $dw_start_off;
            my $dw_size_aligned = ( $dw_size + $page_size - 1 ) & ~( $page_size - 1 );
            my $dw_seg          = pack(
                'L< L< a16 Q<4 L< L< L< L<',
                0x19, $cmdsize, '__DWARF', $base + $dw_start_rva,
                $dw_size_aligned, $dw_start_off, $dw_size_aligned, 0, 0, scalar(@debug_sections), 0
            );
            for my $s (@debug_sections) {
                $dw_seg .= pack(
                    'a16 a16 Q<2 L<2 L<3 L<2 L<',
                    $sec_names{ $s->{name} },
                    '__DWARF',  $base + $s->{rva},
                    $s->{size}, $s->{off}, 0, 0, 0, 0, 0, 0, 0
                );
            }
            push @cmds, $dw_seg;
        }
        my $ncmds      = scalar(@cmds);
        my $sizeofcmds = 0;
        for (@cmds) { $sizeofcmds += length($_); }
        sysopen my $fh, $output_file, O_WRONLY | O_CREAT | O_TRUNC or die $!;
        binmode $fh;

        # mach_header_64 (Exactly 32 bytes)
        # Flags: 0x200085 = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE
        #        0x00200000 = MH_HAS_LOAD_DYLIB | MH_NO_HEAP_EXECUTION
        # For dylib: 0x100085 = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_NO_REEXPORTED_DYLIBS
        my $flags = 0x200085 | 0x00200000;
        $flags = 0x100085 if $self->type eq 'shared';
        print $fh pack( 'L<7 L<', 0xfeedfacf, $cputype, $cpusubtype, $filetype, $ncmds, $sizeofcmds, $flags, 0 );
        print $fh $_ for @cmds;
        for my $s ( $self->layout->sections ) {
            my $payload = '';
            if ( $s->{name} eq '.text' ) {
                $payload = $text;
            }
            elsif ( $s->{name} eq '.brk_sym' ) {
                $payload = $self->build_brk_sym();
            }
            elsif ( $s->{name} eq '.data' ) {
                $payload = $data_bytes // '';
            }
            elsif ( $s->{name} eq '.got' ) {
                $payload = pack( 'Q< Q< Q<', 0, 0, 0 );
            }
            elsif ( $s->{name} eq '.linkedit' ) {
                $payload = $bind_info . $trie . $symtab . $strtab;
            }
            elsif ( $s->{name} =~ /^\.debug_/ ) {
                $payload = $self->debug_section( $s->{name} ) || '';
            }
            next unless length($payload) > 0 || $s->{size} > 0;
            seek( $fh, $s->{off}, 0 );
            if ( length($payload) > $s->{size} ) {
                die sprintf "Internal error: %s payload (%d B) exceeds section size (%d B)", $s->{name}, length($payload), $s->{size};
            }
            $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
            print $fh $payload;
        }
        close $fh;
        chmod 0755, $output_file;

        # ARM64 macOS mandatory ad-hoc signature (skip dylibs -- codesign corrupts link edit offsets)
        if ( $os =~ /^(macos|darwin)/i && $self->type ne 'shared' ) {
            my $cs_out = '';
            if ( open my $cs_fh, '-|', 'codesign', '-f', '-s', '-', $output_file ) {
                $cs_out = do { local $/; <$cs_fh> };
                close $cs_fh;
            }
            chomp $cs_out;
            warn 'codesign output: ' . $cs_out if length $cs_out;
            warn 'codesign exit: ' . ( $? >> 8 ) . "\n";
        }
        return $output_file;
    }
}

=encoding utf-8

=head1 NAME

Brocken::Jenny::Linker::MachO - macOS Mach-O Binary Generator

=head1 DESCRIPTION

Generates macOS Mach-O executables for x86_64 and ARM64 architectures. Produces a minimal Mach-O with header, load
commands (segment __TEXT, segment __DATA, entry point, optionally debug sections), and section data.

On ARM64 macOS, automatically runs C<codesign> for ad-hoc signing after writing the binary.

=head2 Structure

=over 4

=item B<Header> - Magic (MH_MAGIC_64), CPU type/subtype, file type (EXECUTE)

=item B<Load Commands> - LC_SEGMENT_64 for __TEXT and __DATA, LC_MAIN for entry point, LC_SYMTAB/Symtab, LC_DYSYMTAB, LC_BUILD_VERSION

=item B<Sections> - __TEXT,__text (code), __DATA,__data (data), optional debug sections

=back

=head1 METHODS

=head2 write_executable

    $linker->write_executable($output_file, $code_bytes, $platform, $type?, $debug_bytes?)

Writes a Mach-O executable with proper section alignment and page size (16KB for ARM64, 4KB for x86_64).

=head2 write_shared_library

    $linker->write_shared_library($output_file, $code_bytes, $platform, $debug_bytes?)

Not yet implemented for Mach-O.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
