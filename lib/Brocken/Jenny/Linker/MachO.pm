use v5.42;
use feature qw[class];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;
class Brocken::Jenny::Linker::MachO : isa(Brocken::Jenny::Linker) {

=pod

=head1 NAME

Brocken::Jenny::Linker::MachO - 64-bit Mach-O Executable Generator

=head1 DESCRIPTION

Generates Mach-O binaries compliant with macOS (Darwin) kernels.

=head2 Load Commands

Mach-O files use "Load Commands" to guide the dynamic linker (dyld).

=over 4

=item * B<LC_SEGMENT_64>: Maps file regions into virtual memory.

=item * B<LC_LOAD_DYLINKER>: Points to C</usr/lib/dyld>.

=item * B<LC_LOAD_DYLIB>: Links against C<libSystem.B.dylib>.

=item * B<LC_MAIN>: Specifies the C<_start> entry point offset.

=item * B<LC_DYLD_INFO_ONLY>: Describes exports and binding opcodes.

=back

=head2 Apple Silicon (ARM64) Quirks

=over 4

=item * B<Page Size>: Must be 16KB (0x4000).

=item * B<Code Signing>: ARM64 macOS strictly forbids execution of
unsigned binaries. We apply an ad-hoc signature using C<codesign -s ->.

=back

=cut

    field $has_ffi : reader = false;
    method set_has_ffi($v) { $has_ffi = $v; }

    method _setup_layout( $layout, $text_size, $data_size, $arch, $os, $dbg = 0 ) {
        $layout->add_section( '.text',     $text_size,           5 );                      # Read + Execute
        $layout->add_section( '.data',     $data_size,           3 ) if $data_size > 0;    # Read + Write
        $layout->add_section( '.got',      512,                  3 ) if $has_ffi;          # Global Offset Table
        $layout->add_section( '.linkedit', $has_ffi ? 4096 : 64, 1 );                      # Symbols, Strings, Dynamic linking info
        if ( $dbg >= 1 ) {
            $layout->add_section( '.debug_line',     4096, 0 );
            $layout->add_section( '.debug_info',     8192, 0 );
            $layout->add_section( '.debug_abbrev',   4096, 0 );
            $layout->add_section( '.debug_frame',    8192, 0 );
            $layout->add_section( '.debug_aranges',  4096, 0 );
            $layout->add_section( '.debug_pubnames', 4096, 0 );
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
                my $movz = 0xD2800000 | ( ( $exit_sys & 0xffff ) << 5 ) | 16;
                my $movk = 0xF2A00000 | ( ( ( $exit_sys >> 16 ) & 0xffff ) << 5 ) | 16;
                my $bl   = 0x94000000 | ( ( ( 20 + ( $func_offsets{main} // 0 ) ) >> 2 ) & 0x3FFFFFF );
                $entry_stub = pack( 'V5', $bl, $movz, $movk, 0xD4001001, 0xD4200000 );
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
                my $enc  = ( ( $half >> 19 ) & 1 ) << 31 | ( ( $half & 0x3FF ) << 21 ) | ( ( $half >> 10 ) & 1 ) << 20
                    | ( ( $half >> 11 ) & 0xFF ) << 12;
                my $word = unpack( 'V', substr( $text, $src_pos, 4 ) );
                $word = ( $word & 0x00000FFF ) | $enc;
                substr( $text, $src_pos, 4, pack( 'V', $word ) );
            }
        }

        # Automatically calculate layout if it wasn't called beforehand
        if ( !defined $self->layout ) {
            $self->pre_layout( length($text), length($data_bytes), $platform );
        }
        my $base           = $self->image_base;
        my $page_size      = $platform->page_size;                                       # 16KB for Apple Silicon, 4KB for Intel
        my $cputype        = ( $arch =~ /aarch64|arm64/i ) ? 0x0100000c : 0x01000007;    # CPU_TYPE_ARM64 or CPU_TYPE_X86_64
        my $cpusubtype     = ( $arch =~ /aarch64|arm64/i ) ? 0          : 3;             # CPU_SUBTYPE_ARM64_ALL or CPU_SUBTYPE_I386_ALL
        my $filetype       = ( $self->type eq 'shared' ) ? 6 : 2;                        # MH_DYLIB or MH_EXECUTE
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
            $bind_info .= pack( 'C', 0x70 | $data_seg ) . $_uleb->($got_off);
            for my $name ( '_dlopen', '_dlsym', '_pthread_create' ) {
                $bind_info .= pack( 'C', 0x11 );
                $bind_info .= pack( 'C', 0x51 );
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
                my $mangled = "_$name";
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
                my $offset = length($root);
                for my $n (@nodes) {
                    $node_offsets{ $n->{sym} } = $offset;
                    $offset += length( $n->{bytes} );
                }
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
        my %seg_names = ( '.text' => '__TEXT', '.data' => '__DATA', '.got' => '__DATA' );
        my %sec_names = ( '.text' => '__text', '.data' => '__data', '.got' => '__got' );
        for my $s ( $self->layout->sections ) {
            if ( $s->{name} =~ /^\.debug_/ ) {
                $seg_names{ $s->{name} } = '__DWARF';
                ( my $macho_name = $s->{name} ) =~ s/^\./__/;
                $sec_names{ $s->{name} } = $macho_name;
            }
        }
        my @text_sections = grep { $_->{name} eq '.text' } $self->layout->sections;
        my $t_sec         = $text_sections[0];
        my @data_sections = grep { $_->{name} eq '.data' || $_->{name} eq '.got' } $self->layout->sections;
        my $t_vmsize      = $t_sec->{off} + $t_sec->{size};
        my $t_seg_size    = ( $t_vmsize + $page_size - 1 ) & ~( $page_size - 1 );
        my ( $d_start_rva, $d_start_off, $d_size, $d_seg_size );
        if (@data_sections) {
            $d_start_rva = $data_sections[0]->{rva};
            $d_start_off = $data_sections[0]->{off};
            $d_size      = 0;
            for (@data_sections) { $d_size += $_->{size}; }
            $d_seg_size = ( $d_size + $page_size - 1 ) & ~( $page_size - 1 );
        }
        my @cmds = ();

        # PageZero Segment Header
        # Reference: https://opensource.apple.com/source/xnu/xnu-4570.1.46/EXTERNAL_HEADERS/mach-o/loader.h
        if ( $self->type ne 'shared' ) {
            push @cmds, pack(
                'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
                72,                         # cmdsize
                '__PAGEZERO',               # segname
                0,                          # vmaddr
                $base,                      # vmsize
                0,                          # fileoff
                0,                          # filesize
                0,                          # maxprot (none)
                0,                          # initprot (none)
                0,                          # nsects
                0                           # flags
            );
        }

        # TEXT Segment Header
        my $t_cmd_size = 72 + 80 * scalar(@text_sections);
        my $t_cmd      = pack(
            'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
            $t_cmd_size,                # cmdsize
            '__TEXT',                   # segname
            $base,                      # vmaddr
            $t_seg_size,                # vmsize
            0,                          # fileoff
            $t_seg_size,                # filesize
            5,                          # maxprot (VM_PROT_READ | VM_PROT_EXECUTE)
            5,                          # initprot (VM_PROT_READ | VM_PROT_EXECUTE)
            scalar(@text_sections),     # nsects
            0                           # flags
        );
        for my $s (@text_sections) {

            # TEXT Sections (80 bytes each)
            $t_cmd .= pack(
                'a16 a16 Q<2 L<2 L<3 L<2 L<',
                $sec_names{ $s->{name} },
                '__TEXT',   $base + $s->{rva},
                $s->{size}, $s->{off}, 4, 0, 0, 0x80000400, 0, 0, 0
            );
        }
        push @cmds, $t_cmd;

        # DATA Segment Header (only if we have data or GOT sections)
        if (@data_sections) {
            my $d_cmd_size = 72 + 80 * scalar(@data_sections);
            my $d_cmd      = pack(
                'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
                $d_cmd_size,                # cmdsize
                '__DATA',                   # segname
                $base + $d_start_rva,       # vmaddr
                $d_seg_size,                # vmsize
                $d_start_off,               # fileoff
                $d_size,                    # filesize
                3,                          # maxprot (VM_PROT_READ | VM_PROT_WRITE)
                3,                          # initprot (VM_PROT_READ | VM_PROT_WRITE)
                scalar(@data_sections),     # nsects
                0                           # flags
            );
            for my $s (@data_sections) {

                # DATA Sections (80 bytes each)
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

        # LINKEDIT Segment Header
        my $le_sec      = $self->layout->get('.linkedit');
        my $le_seg_size = ( $le_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
        push @cmds, pack(
            'L<2 a16 Q<4 L<4', 0x19,    # cmd (LC_SEGMENT_64)
            72,                         # cmdsize
            '__LINKEDIT',               # segname
            $base + $le_sec->{rva},     # vmaddr
            $le_seg_size,               # vmsize
            $le_sec->{off},             # fileoff
            $le_sec->{size},            # filesize
            1,                          # maxprot (VM_PROT_READ)
            1,                          # initprot (VM_PROT_READ)
            0,                          # nsects
            0                           # flags
        );
        push @cmds, $lc_id_dylib if $self->type eq 'shared';

        # LC_BUILD_VERSION (24 bytes - required by codesign on macOS 11+)
        push @cmds, pack( 'L<6', 0x32, 24, 1, 0x000B0000, 0x000B0000, 0 );

        # LC_LOAD_DYLINKER (Loads dynamic linker `/usr/lib/dyld`)
        push @cmds, pack( 'L<3', 0xE, 32, 12 ) . "/usr/lib/dyld\0\0\0\0\0\0\0";
        push @cmds, $lc_load_libsystem;

        # LC_DYLD_INFO_ONLY (48 bytes)
        my $export_off = ( $self->type eq 'shared' && $nextdefsym > 0 ) ? $le_off + length($bind_info) : 0;
        my $export_sz  = ( $self->type eq 'shared' && $nextdefsym > 0 ) ? $trie_size                   : 0;
        push @cmds, pack(
            'L<12', 0x80000022,    # cmd
            48,                    # cmdsize
            0, 0,                  # rebase_off, rebase_size
            $le_off,               # bind_off
            $bind_info_size,       # bind_size
            0, 0,                  # weak_bind_off, weak_bind_size
            0, 0,                  # lazy_bind_off, lazy_bind_size
            $export_off,           # export_off
            $export_sz             # export_size
        );

        # LC_SYMTAB (24 bytes)
        my $symtab_off = $le_off + length($bind_info) + $trie_size;
        push @cmds, pack(
            'L<6', 0x2,                    # cmd
            24,                            # cmdsize
            $symtab_off,                   # symoff
            $num_syms,                     # nsyms
            $symtab_off + $symtab_size,    # stroff
            $strtab_size                   # strsize
        );

        # LC_DYSYMTAB (80 bytes)
        my $iextdefsym = 0;
        my $iundefsym  = $nextdefsym;
        push @cmds, pack(
            'L<20', 0xB,                   # cmd
            80,                            # cmdsize
            0,           0,                # ilocalsym, nlocalsym
            $iextdefsym, $nextdefsym,      # iextdefsym, nextdefsym
            $iundefsym,  $nundefsym,       # iundefsym, nundefsym
            (0) x 14                       # reserved / empty
        );

        # LC_MAIN (24 bytes - Points directly to our TEXT segment start off)
        push @cmds, pack(
            'L<2 Q<2', 0x80000028,         # cmd (LC_MAIN)
            24,                            # cmdsize
            $t_sec->{off},                 # entryoff (physical offset of _start)
            0                              # stacksize
        ) if $self->type eq 'exe';
        if (@debug_sections) {
            my $cmdsize      = 72 + 80 * scalar(@debug_sections);
            my $dw_start_rva = $debug_sections[0]->{rva};
            my $dw_start_off = $debug_sections[0]->{off};
            my $dw_size      = 0;
            for (@debug_sections) { $dw_size += $_->{size}; }
            my $dw_size_aligned = ( $dw_size + $page_size - 1 ) & ~( $page_size - 1 );
            my $dw_cmd          = pack( 'L<2 a16 Q<4 L<4',
                0x19, $cmdsize, '__DWARF', $base + $dw_start_rva,
                $dw_size_aligned, $dw_start_off, $dw_size_aligned, 0, 0, scalar(@debug_sections), 0 );
            for my $s (@debug_sections) {
                $dw_cmd .= pack(
                    'a16 a16 Q<2 L<2 L<3 L<2 L<',
                    $sec_names{ $s->{name} },
                    '__DWARF',  $base + $s->{rva},
                    $s->{size}, $s->{off}, 0, 0, 0, 0, 0, 0, 0
                );
            }
            push @cmds, $dw_cmd;
        }
        my $ncmds      = scalar(@cmds);
        my $sizeofcmds = 0;
        for (@cmds) { $sizeofcmds += length($_); }
        open my $fh, '>', $output_file or die $!;
        binmode $fh;

        # mach_header_64 (Exactly 32 bytes)
        my $flags = 0x200085 | 0x00200000;
        $flags = 0x100085 if $self->type eq 'shared';
        print $fh pack(
            'L<7 L<', 0xfeedfacf,    # magic (MH_MAGIC_64)
            $cputype,                # cputype
            $cpusubtype,             # cpusubtype
            $filetype,               # filetype
            $ncmds,                  # ncmds
            $sizeofcmds,             # sizeofcmds
            $flags,                  # flags
            0                        # reserved
        );
        print $fh $_ for @cmds;

        # Write __TEXT,__text segment (padded to layout size)
        seek( $fh, $t_sec->{off}, 0 );
        my $text_payload = $text;
        $text_payload .= ( "\0" x ( $t_sec->{size} - length($text_payload) ) ) if length($text_payload) < $t_sec->{size};
        print $fh $text_payload;

        # Write __DATA,__data segment (padded to layout size) if section exists
        my $d_sec_actual = $self->layout->get('.data');
        if ($d_sec_actual) {
            seek( $fh, $d_sec_actual->{off}, 0 );
            my $data_payload = $data_bytes // '';
            $data_payload .= ( "\0" x ( $d_sec_actual->{size} - length($data_payload) ) ) if length($data_payload) < $d_sec_actual->{size};
            print $fh $data_payload;
        }

        # Write __DATA,__got segment (padded to layout size) if section exists
        if ($got_sec) {
            seek( $fh, $got_sec->{off}, 0 );
            my $got_payload = pack( 'Q< Q< Q<', 0, 0, 0 );
            $got_payload .= ( "\0" x ( $got_sec->{size} - length($got_payload) ) ) if length($got_payload) < $got_sec->{size};
            print $fh $got_payload;
        }

        # Write LINKEDIT segment (padded to layout size)
        seek( $fh, $le_sec->{off}, 0 );
        my $le_payload = $bind_info . $trie . $symtab . $strtab;
        $le_payload .= ( "\0" x ( $le_sec->{size} - length($le_payload) ) ) if length($le_payload) < $le_sec->{size};
        print $fh $le_payload;
        if (@debug_sections) {
            for my $s (@debug_sections) {
                seek( $fh, $s->{off}, 0 );
                my $dw_payload = $self->debug_section( $s->{name} ) || '';
                $dw_payload .= ( "\0" x ( $s->{size} - length($dw_payload) ) ) if length($dw_payload) < $s->{size};
                print $fh $dw_payload;
            }
        }
        close $fh;
        chmod 0755, $output_file;

        # ARM64 macOS mandatory ad-hoc signature
        if ( $os =~ /^(macos|darwin)/i ) {
            my $cs_out = `codesign -f -s - "$output_file" 2>&1`;
            warn 'codesign output: ' . $cs_out if length $cs_out;
            warn 'codesign exit: ' . ( $? >> 8 ) . "\n";
        }
        return $output_file;
    }
}
1;