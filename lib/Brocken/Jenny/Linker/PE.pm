use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;

class Brocken::Jenny::Linker::PE : isa(Brocken::Jenny::Linker) {
    use Brocken::Jenny::Codegen::ARM64::Inst;
    use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC O_RDWR);
    field $ENABLE_COFF = 0;

=pod

=head1 NAME

Brocken::Jenny::Linker::PE - 64-bit Portable Executable (PE32+) Generator

=head1 DESCRIPTION

Generates PE binaries for modern 64-bit Windows (x86_64 and ARM64).

=cut

    method write_executable ( $output_file, $code_data, $platform, $passed_argument = undef, $debug_bytes = undef ) {

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
        my $full_code    = ref $code_bytes eq 'HASH' ? $code_bytes->{binary}                        : $code_bytes;
        my $writable_off = ref $code_bytes eq 'HASH' ? ( $code_bytes->{writable_data_offset} // 0 ) : 0;
        my $text_raw     = $writable_off             ? substr( $full_code, 0, $writable_off )       : $full_code;
        my $data_bytes   = $writable_off             ? substr( $full_code, $writable_off )          : '';
        my $text         = $text_raw;
        my $entry_stub   = '';
        if ( $self->type eq 'exe' ) {
            if ( $platform->is_arm64 ) {

                # Windows ARM64 Entry Stub:
                # - stp x29, x30, [sp, #-16]!
                # - mov x29, sp
                # - bl main (relative call offset +16 bytes -> 4 instructions)
                # - ldp x29, x30, [sp], #16
                # - uxtb w0, w0  (truncate exit code to 8 bits)
                # - ret
                my $bl = bl( 16 + ( $func_offsets{_BROCKEN_ENTRY} // 0 ) );
                $entry_stub = pack( 'V6', stp_pre( 29, 30, 31, -16 ), add_imm( 29, 31, 0 ), $bl, ldp_post( 29, 30, 31, 16 ), uxtb( 0, 0 ), ret(), );
            }
            else {
                # Windows x86_64 Entry Stub with heap:
                # Layout (34 bytes total):
                #   0:  sub rsp, HEAP_SIZE    (1 MB heap allocation)
                #   7:  mov rcx, rsp           (heap base in rcx, harmless if main takes no args)
                #  10:  sub rsp, 40            (shadow space for main)
                #  14:  call main
                #  19:  add rsp, 40            (remove shadow space)
                #  23:  add rsp, HEAP_SIZE
                #  30:  movzx eax, al
                #  33:  ret
                my $HEAP_SIZE = 1048576;
                $entry_stub = pack( 'C3 V', 0x48, 0x81, 0xEC, $HEAP_SIZE );                          # sub rsp, HEAP_SIZE
                $entry_stub .= pack( 'C3',   0x48, 0x89, 0xE1 );                                     # mov rcx, rsp
                $entry_stub .= pack( 'C4',   0x48, 0x83, 0xEC, 0x28 );                               # sub rsp, 40
                $entry_stub .= pack( 'C V',  0xE8, 15 + ( $func_offsets{_BROCKEN_ENTRY} // 0 ) );    # call main
                $entry_stub .= pack( 'C4',   0x48, 0x83, 0xC4, 0x28 );                               # add rsp, 40
                $entry_stub .= pack( 'C3 V', 0x48, 0x81, 0xC4, $HEAP_SIZE );                         # add rsp, HEAP_SIZE
                $entry_stub .= pack( 'C3',   0x0F, 0xB6, 0xC0 );                                     # movzx eax, al
                $entry_stub .= pack( 'C',    0xC3 );                                                 # ret
            }
            $text = $entry_stub . $text_raw;
        }

        # Snapshot text before stubs for exports (edata RVA), then compute exports
        my $text_bytes     = $text;
        my $has_data       = length($data_bytes) > 0;
        my $has_debug      = defined $debug_bytes ? 1 : 0;
        my $has_reloc      = 1;
        my $has_exports    = ( ref $self->exported_funcs eq 'ARRAY' && scalar( @{ $self->exported_funcs } ) > 0 ) ? 1 : 0;
        my $edata_bytes    = '';
        my $edata_rva      = 0;
        my @sorted_exports = ();

        if ($has_exports) {
            my $text_rva = 0x1000;
            my $data_rva = 0x1000 + ( ( length($text_bytes) + 4095 ) & ~4095 );
            $data_rva += ( $self->brk_sym_size() + 4095 ) & ~4095 if $self->brk_sym_size() > 0;
            $edata_rva = $data_rva;
            $edata_rva += ( ( length($data_bytes) + 4095 ) & ~4095 ) if $has_data;
            $edata_bytes = "\x00" x 40;
            require File::Basename;
            my $dll_name     = File::Basename::basename($output_file);
            my $dll_name_off = length($edata_bytes);
            $edata_bytes .= $dll_name . "\0";
            @sorted_exports = sort @{ $self->exported_funcs };
            my %name_offsets;

            for my $name (@sorted_exports) {
                $name_offsets{$name} = length($edata_bytes);
                $edata_bytes .= $name . "\0";
            }
            my $eat_off = length($edata_bytes);
            for my $name (@sorted_exports) {
                my $label_val = $self->labels->{"E_$name"} // $self->labels->{$name} // 0;
                my $func_rva  = $text_rva + $label_val;
                $edata_bytes .= pack( 'V', $func_rva );
            }
            my $enpt_off = length($edata_bytes);
            for my $name (@sorted_exports) {
                my $name_rva = $edata_rva + $name_offsets{$name};
                $edata_bytes .= pack( 'V', $name_rva );
            }
            my $eot_off = length($edata_bytes);
            my $idx     = 0;
            for my $name (@sorted_exports) {
                $edata_bytes .= pack( 'v', $idx++ );
            }
            $edata_bytes .= "\x00" x 4;
            my $timestamp        = $ENV{SOURCE_DATE_EPOCH} || time();
            my $export_dir_table = pack( 'V2 v2 V7',
                0, $timestamp, 0, 0, $edata_rva + $dll_name_off,
                1, scalar(@sorted_exports), scalar(@sorted_exports),
                $edata_rva + $eat_off,
                $edata_rva + $enpt_off,
                $edata_rva + $eot_off );
            substr( $edata_bytes, 0, 40, $export_dir_table );
        }

        # Generate import stubs for undefined external functions
        my $entry_size    = $self->type eq 'exe' ? length($entry_stub) : 0;
        my @known_imports = qw(CreateThread WaitForSingleObject CloseHandle SetThreadAffinityMask GetExitCodeThread
            AcquireSRWLockExclusive ReleaseSRWLockExclusive InitializeConditionVariable
            SleepConditionVariableSRW WakeConditionVariable WakeAllConditionVariable);
        my %import_names;
        for my $ff (@func_fixups) {
            next if exists $func_offsets{ $ff->{target} };
            next unless grep { $ff->{target} eq $_ } @known_imports;
            $import_names{ $ff->{target} } = 1;
        }
        my @import_list = sort keys %import_names;
        my $has_idata   = scalar @import_list > 0;
        my $idata_bytes = '';
        my $idata_rva   = 0;
        my @iat_offsets;

        # Pre-compute idata RVA (text + preceding sections, page-aligned)
        $idata_rva = 0x1000 + ( ( length($text) + 4095 ) & ~4095 );
        $idata_rva += ( $self->brk_sym_size() + 4095 ) & ~4095 if $self->brk_sym_size() > 0;
        $idata_rva += ( length($data_bytes) + 4095 ) & ~4095   if length($data_bytes) > 0;
        $idata_rva += ( length($edata_bytes) + 4095 ) & ~4095  if $has_exports;
        if ($has_idata) {
            my $ilt_bytes       = '';
            my $hnt_bytes       = '';
            my $iat_bytes       = '';
            my $dll_name        = "kernel32.dll\0\0";
            my $desc_size       = 20;
            my $ilt_off         = $desc_size * 2;
            my $dll_name_off    = $ilt_off + ( 8 * ( scalar(@import_list) + 1 ) );
            my $hnt_off         = $dll_name_off + length($dll_name);
            my $current_hnt_rva = $idata_rva + $hnt_off;

            for my $i ( 0 .. $#import_list ) {
                my $fn    = $import_list[$i];
                my $entry = pack( 'v', 0 ) . $fn . "\0";
                if ( length($entry) % 2 != 0 ) { $entry .= "\0"; }
                $ilt_bytes .= pack( 'Q<', $current_hnt_rva );
                $iat_bytes .= pack( 'Q<', $current_hnt_rva );
                $hnt_bytes .= $entry;
                $current_hnt_rva += length($entry);
            }

            # Null terminators for ILT and IAT arrays
            $ilt_bytes .= pack( 'Q<', 0 );
            $iat_bytes .= pack( 'Q<', 0 );
            my $term         = "\x00" x $desc_size;
            my $desc_payload = pack( 'V5', 0, 0, 0, 0, 0 ) . $term . $ilt_bytes . $dll_name . $hnt_bytes;
            my $hnt_pad      = ( 8 - ( length($desc_payload) % 8 ) ) % 8;
            my $iat_off      = length($desc_payload) + $hnt_pad;
            my $desc
                = pack( 'V', $idata_rva + $ilt_off ) .
                pack( 'V', 0 ) .
                pack( 'V', 0 ) .
                pack( 'V', $idata_rva + $dll_name_off ) .
                pack( 'V', $idata_rva + $iat_off );
            $idata_bytes = $desc . $term . $ilt_bytes . $dll_name . $hnt_bytes . ( "\x00" x $hnt_pad ) . $iat_bytes;
        }

        # Resolve cross-function call fixups at link time, with import stubs
        for my $ff (@func_fixups) {
            my $target_off = $func_offsets{ $ff->{target} };
            if ( !defined $target_off && $has_idata && exists $import_names{ $ff->{target} } ) {
                my $stub_ofs = length($text);
                my $text_rva = 0x1000;
                my $iat_rva  = $idata_rva + length($idata_bytes) - ( 8 * ( scalar(@import_list) + 1 ) );
                my $idx      = 0;
                for my $fn (@import_list) {
                    last if $fn eq $ff->{target};
                    $idx++;
                }
                my $iat_entry_rva = $iat_rva + $idx * 8;
                warn sprintf "STUB: target=%s idx=%d idata_rva=0x%X idata_len=%d iat_rva=0x%X iat_entry=0x%X\n", $ff->{target}, $idx, $idata_rva,
                    length($idata_bytes), $iat_rva, $iat_entry_rva;
                if ( $platform->is_x64 ) {
                    my $disp32 = $iat_entry_rva - ( $text_rva + $stub_ofs + 6 );
                    $text .= pack( 'CC l<', 0xFF, 0x25, $disp32 );
                }
                elsif ( $platform->is_arm64 ) {
                    my $page = ( $iat_entry_rva >> 12 ) - ( ( $text_rva + $stub_ofs ) >> 12 );
                    my $adrp = 0x90000000 | ( ( $page & 3 ) << 29 ) | ( ( ( $page >> 2 ) & 0x7FFFF ) << 5 ) | 16;
                    my $ldr  = 0xF9400200 | ( ( ( $iat_entry_rva & 0xFF8 ) >> 3 ) << 10 ) | ( 16 << 5 ) | 16;
                    my $br   = 0xD61F0000 | ( 16 << 5 );
                    $text .= pack( 'V3', $adrp, $ldr, $br );
                }
                $func_offsets{ $ff->{target} } = $stub_ofs - $entry_size;
                $target_off = $stub_ofs - $entry_size;
            }
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
        $text_bytes = $text;

        # Layout sections
        my $brk_sym_size = $self->brk_sym_size();
        my $has_brk_sym  = $brk_sym_size > 0;
        my $num_sections
            = 1 + ( $has_brk_sym ? 1 : 0 )
            + ( $has_data    ? 1 : 0 )
            + ( $has_exports ? 1 : 0 )
            + ( $has_idata   ? 1 : 0 )
            + $has_reloc
            + ( $has_debug ? 1 : 0 );
        sysopen my $fh, $output_file, O_WRONLY | O_CREAT | O_TRUNC or die "Cannot open $output_file for writing: $!";
        binmode $fh;

        # DOS MZ Header (Exactly 64 bytes: a2=magic, v29=29 WORDS, V=e_lfanew)
        # We explicitly use v29 and count-matched repetition to avoid pack argument shifts.
        my $dos_header = pack( 'a2 v29 V',
            'MZ',   0x0090, 0x0003, 0x0000,          0x0004, 0x0000,      0xffff, 0x0000, 0x0100, 0x0000,
            0x0000, 0x0000, 0x0040, 0x0000, (0) x 4, 0,      0, (0) x 10, 0x00000080 );
        my $dos_stub     = ( "\x00" x 64 );
        my $pe_signature = "PE\x00\x00";

        # COFF File Header (Exactly 20 bytes)
        # Machine types: IMAGE_FILE_MACHINE_AMD64=0x8664, IMAGE_FILE_MACHINE_ARM64=0xAA64
        my $machine         = $platform->is_arm64 ? 0xAA64 : 0x8664;
        my $timestamp       = $ENV{SOURCE_DATE_EPOCH} || time();
        my $section_table   = '';
        my $size_of_headers = ( 392 + ( $num_sections * 40 ) + 511 ) & ~511;
        my $sec_raw_ptr     = $size_of_headers;
        my $sec_rva         = 0x1000;

        # Section characteristics flags:
        #   0x60000020 = IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ
        #   0x40000040 = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ
        #   0xC0000040 = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE
        #   0x42000040 = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_DISCARDABLE | IMAGE_SCN_MEM_READ
        # .text section (Code)
        my $sec_raw_code_size = ( length($text_bytes) + 511 ) & ~511;
        $section_table .= pack( 'a8 V2 V2 V2 v2 V', ".text\x00\x00\x00", length($text_bytes), $sec_rva, $sec_raw_code_size, $sec_raw_ptr, 0, 0, 0, 0,
            0x60000020 );
        $sec_rva     += ( length($text_bytes) + 4095 ) & ~4095;
        $sec_raw_ptr += $sec_raw_code_size;

        # .brk_sym section (Native Backtrace Info)
        my $sec_raw_brk_sym_size = 0;
        if ($has_brk_sym) {
            $sec_raw_brk_sym_size = ( $brk_sym_size + 511 ) & ~511;
            $section_table
                .= pack( 'a8 V2 V2 V2 v2 V', ".brk_sym", $brk_sym_size, $sec_rva, $sec_raw_brk_sym_size, $sec_raw_ptr, 0, 0, 0, 0, 0x40000040 );
            $sec_rva     += ( $brk_sym_size + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_brk_sym_size;
        }

        # .data section (Initialized Data)
        my $sec_raw_data_size = 0;
        if ($has_data) {
            $sec_raw_data_size = ( length($data_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".data\x00\x00\x00", length($data_bytes), $sec_rva, $sec_raw_data_size, $sec_raw_ptr, 0, 0, 0, 0, 0xC0000040 );
            $sec_rva     += ( length($data_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_data_size;
        }

        # .edata section
        my $sec_raw_edata_size = 0;
        if ($has_exports) {
            $sec_raw_edata_size = ( length($edata_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".edata\x00\x00", length($edata_bytes), $sec_rva, $sec_raw_edata_size, $sec_raw_ptr, 0, 0, 0, 0, 0x40000040 );
            $sec_rva     += ( length($edata_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_edata_size;
        }

        # .idata section (Import Directory Table)
        my $idata_rva_final    = $sec_rva;
        my $sec_raw_idata_size = 0;
        if ($has_idata) {
            $sec_raw_idata_size = ( length($idata_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".idata\x00\x00", length($idata_bytes), $sec_rva, $sec_raw_idata_size, $sec_raw_ptr, 0, 0, 0, 0, 0xC0000040 );
            $sec_rva     += ( length($idata_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_idata_size;
        }

        # .reloc section (Base Relocations, required for ASLR)
        my $reloc_bytes        = pack( 'V V v v', 0x1000, 12, 0, 0 );
        my $reloc_rva          = $sec_rva;
        my $sec_raw_reloc_size = ( length($reloc_bytes) + 511 ) & ~511;
        $section_table .= pack( 'a8 V2 V2 V2 v2 V', ".reloc\x00\x00", length($reloc_bytes), $sec_rva, $sec_raw_reloc_size, $sec_raw_ptr, 0, 0, 0, 0,
            0x42000040 );
        $sec_rva     += ( length($reloc_bytes) + 4095 ) & ~4095;
        $sec_raw_ptr += $sec_raw_reloc_size;

        # .debug_l (Simplified debug section for Windows)
        my $sec_raw_debug_size = 0;
        if ($has_debug) {
            $sec_raw_debug_size = ( length($debug_bytes) + 511 ) & ~511;
            $section_table
                .= pack( 'a8 V2 V2 V2 v2 V', '.debug_l', length($debug_bytes), $sec_rva, $sec_raw_debug_size, $sec_raw_ptr, 0, 0, 0, 0, 0x42000040 );
            $sec_rva     += ( length($debug_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_debug_size;
        }
        my $coff_symtab             = '';
        my $coff_strtab             = '';
        my $num_coff_symbols        = 0;
        my $pointer_to_symbol_table = 0;
        if ( $ENABLE_COFF && $has_exports && scalar(@sorted_exports) > 0 ) {
            my $str_payload = '';
            my %coff_str_offsets;
            for my $name (@sorted_exports) {
                $coff_str_offsets{$name} = 4 + length($str_payload);
                $str_payload .= $name . "\0";
            }
            for my $name (@sorted_exports) {
                my $label_val = $self->labels->{"E_$name"} // $self->labels->{$name} // 0;
                my $func_rva  = 0x1000 + $label_val;
                my $entry_name_field;
                if ( length($name) <= 8 ) {
                    $entry_name_field = pack( 'a8', $name );
                }
                else {
                    $entry_name_field = pack( 'V2', 0, $coff_str_offsets{$name} );
                }
                $coff_symtab .= pack( 'a8 V v v C2', $entry_name_field, $func_rva, 1, 0x20, 2, 0 );
                $num_coff_symbols++;
            }
            if ( length($str_payload) > 0 ) {
                $coff_strtab = pack( 'V', 4 + length($str_payload) ) . $str_payload;
            }
            $pointer_to_symbol_table = $sec_raw_ptr;
        }

        # COFF characteristics: 0x0022 = IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE
        my $file_header = pack( 'v2 V3 v2', $machine, $num_sections, $timestamp, $pointer_to_symbol_table, $num_coff_symbols, 240, 0x0022 );

        # PE32+ Optional Header (Magic=0x020b): fields include entry, image base 0x140000000, section alignment 0x1000, file alignment 0x200,
        # subsystem=3 (CONSOLE), DLL characteristics=0x8160 (NX compatible + TSA aware + DYNAMIC_BASE),
        # stack reserve 0x400000 (4MB), stack commit 0x200000 (2MB covers 1MB entry-stub heap), heap reserve 0x100000, heap commit 0x1000
        my $size_of_image = $sec_rva;
        my $size_of_code  = $sec_raw_code_size;
        my $init_data_size
            = $sec_raw_data_size + $sec_raw_edata_size + $sec_raw_reloc_size + $sec_raw_debug_size + $sec_raw_brk_sym_size + $sec_raw_idata_size;
        my $os_ver     = 6;
        my $opt_header = pack( 'v C2 V3 V2 Q< V2 v4 v2 V V V V v2 Q<4 V2',
            0x020b,         14, 10, $size_of_code, $init_data_size, 0, 0x1000, 0x1000, 0x140000000, 4096, 512, $os_ver, 0, 0, 0, $os_ver, 0, 0,
            $size_of_image, $size_of_headers, 0, 3, 0x8160, 0x400000, 0x200000, 0x100000, 0x1000, 0, 16 );

        # Data directories (128 bytes = 16 entries x 8 bytes each):
        #   [0]=export, [1]=import, [5]=reloc
        my $data_dirs = "\x00" x 128;
        if ($has_idata) {
            substr $data_dirs, 8,  4, pack( 'V', $idata_rva );
            substr $data_dirs, 12, 4, pack( 'V', 20 + 20 );      # IMAGE_IMPORT_DESCRIPTOR + zero terminator
            my $iat_rva  = $idata_rva + length($idata_bytes) - ( 8 * ( scalar(@import_list) + 1 ) );
            my $iat_size = 8 * ( scalar(@import_list) + 1 );
            substr $data_dirs, 96,  4, pack( 'V', $iat_rva );
            substr $data_dirs, 100, 4, pack( 'V', $iat_size );
        }
        if ($has_exports) {
            substr $data_dirs, 0, 4, pack( 'V', $edata_rva );
            substr $data_dirs, 4, 4, pack( 'V', length($edata_bytes) );
        }
        substr $data_dirs, 40, 4, pack( 'V', $reloc_rva );
        substr $data_dirs, 44, 4, pack( 'V', length($reloc_bytes) );
        $opt_header .= $data_dirs;
        print $fh $dos_header, $dos_stub, $pe_signature, $file_header, $opt_header, $section_table;
        my $headers_len
            = length($dos_header) + length($dos_stub) + length($pe_signature) + length($file_header) + length($opt_header) + length($section_table);
        print $fh ( "\x00" x ( $size_of_headers - $headers_len ) );

        # Write section payloads
        print $fh $text_bytes;
        print $fh ( "\x00" x ( $sec_raw_code_size - length($text_bytes) ) );
        if ($has_brk_sym) {
            my $brk_sym_bytes = $self->build_brk_sym();
            print $fh $brk_sym_bytes;
            print $fh ( "\x00" x ( $sec_raw_brk_sym_size - length($brk_sym_bytes) ) );
        }
        if ($has_data) {
            print $fh $data_bytes;
            print $fh ( "\x00" x ( $sec_raw_data_size - length($data_bytes) ) );
        }
        if ($has_exports) {
            print $fh $edata_bytes;
            print $fh ( "\x00" x ( $sec_raw_edata_size - length($edata_bytes) ) );
        }
        if ($has_idata) {
            print $fh $idata_bytes;
            print $fh ( "\x00" x ( $sec_raw_idata_size - length($idata_bytes) ) );
        }
        if ($has_reloc) {
            print $fh $reloc_bytes;
            print $fh ( "\x00" x ( $sec_raw_reloc_size - length($reloc_bytes) ) );
        }
        if ($has_debug) {
            print $fh $debug_bytes;
            print $fh ( "\x00" x ( $sec_raw_debug_size - length($debug_bytes) ) );
        }
        if ( $pointer_to_symbol_table > 0 ) {
            print $fh $coff_symtab;
            print $fh $coff_strtab;
        }
        close $fh;
        chmod 0755, $output_file;
    }

    method write_shared_library ( $output_file, $code_bytes, $platform, $debug_bytes = undef ) {
        my $p = ref($platform) ? $platform : Brocken::Katsuro::Platform::parse($platform);
        $self->write_executable( $output_file, $code_bytes, $p, undef, $debug_bytes );
        sysopen my $fh, $output_file, O_RDWR or die $!;
        binmode $fh;
        seek $fh, 0x96, 0;                # Offset to COFF Characteristics
        print $fh pack( 'v', 0x2022 );    # EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL
        close $fh;
    }
}
1;
