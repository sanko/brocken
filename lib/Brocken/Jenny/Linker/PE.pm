use v5.42;
use feature qw[class];
no warnings qw[portable];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;

class Brocken::Jenny::Linker::PE : isa(Brocken::Jenny::Linker) {
    use Brocken::Jenny::Codegen::ARM64::Inst;
    use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC O_RDWR);

=pod

=head1 NAME

Brocken::Jenny::Linker::PE - 64-bit Portable Executable (PE32+) Generator

=head1 DESCRIPTION

Generates PE32+ binaries for 64-bit Windows (x86_64 and ARM64). Produces standard PE headers (DOS header, COFF header,
optional header with subsystem/entry point), section table, and raw section data. Supports DWARF debug sections,
relocations, and import directories.

=head2 Sections Produced

=over

=item C<.text> - Executable code (RVA rounded to page alignment)

=item C<.rdata> - Read-only data (import directory, strings)

=item C<.pdata> - Exception handler data

=item DWARF v5 debug sections (controlled by C<debug_level>)

=back

=head2 Debug Levels

All debug features (DWARF sections, COFF symbols) are controlled by the C<debug_level> setter on the linker object
(inherited from L<Brocken::Jenny::Linker>):

    0  No debug output (no DWARF, no COFF)
    1  .debug_line only (line numbers)
    2  + .debug_info, .debug_abbrev (variable info)
    3  + .debug_frame, .debug_aranges (unwind tables)
    4  + .debug_names, .debug_str, struct DIEs (full DWARF)
    5  + COFF symbols, ASLR disabled (GDB breakpoint support)

=over

=item COFF Symbols (level >= 5)

A COFF symbol table including a C<.text> section-definition symbol (with one auxiliary record) and one
C<IMAGE_SYM_CLASS_EXTERNAL> symbol per function. Long section names and function names share a single combined string
table after the symbol table. This makes GDB's C<break E<lt>funcnameE<gt>> work on PE.

Without COFF symbols (level < 5), GDB can still enumerate functions via C<info functions> using DWARF C<.debug_names>
but cannot resolve breakpoints by name.

=item ASLR (level >= 5)

At level 5, the C<IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE> bit (0x0020) is cleared in the DLL characteristics, disabling
ASLR so breakpoints set from COFF symbols resolve to the correct address at runtime. At levels < 5, ASLR remains
enabled.

=back

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

                # Windows ARM64 Entry Stub with heap:
                # Layout (36 bytes total):
                #   0:  sub sp, sp, #0x100000   (1 MB heap allocation)
                #   4:  mov x0, sp               (heap base in x0, first param)
                #   8:  stp x29, x30, [sp, #-16]!
                #  12:  mov x29, sp
                #  16:  bl _BROCKEN_ENTRY
                #  20:  ldp x29, x30, [sp], #16  (restore frame)
                #  24:  add sp, sp, #0x100000    (deallocate heap)
                #  28:  uxtb w0, w0              (truncate exit code to 8 bits)
                #  32:  ret
                my $bl = bl( 20 + ( $func_offsets{_BROCKEN_ENTRY} // 0 ) );
                $entry_stub = pack( 'V', 0xD14403FF )             # sub sp, sp, #0x100000
                    . pack( 'V', 0x910003E0 )                     # mov x0, sp
                    . pack( 'V', stp_pre( 29, 30, 31, -16 ) ) .
                    pack( 'V', add_imm( 29, 31, 0 ) ) .
                    pack( 'V', $bl ) .
                    pack( 'V', ldp_post( 29, 30, 31, 16 ) ) .
                    pack( 'V', 0x914403FF )                       # add sp, sp, #0x100000
                    . pack( 'V', uxtb( 0, 0 ) ) . pack( 'V', ret() );
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
        my $text_size      = length($text);
        my $has_data       = length($data_bytes) > 0;
        my $has_rodata     = scalar( keys $self->rodata->%* ) > 0;
        my $rodata_bytes   = $has_rodata ? join( '', map { $self->rodata->{$_} } sort keys $self->rodata->%* ) : '';
        my $debug_sections = $self->debug_data;
        my $has_debug   = ( $self->debug_level >= 1 ) && ( ( defined $debug_bytes && length($debug_bytes) > 0 ) || ( keys $debug_sections->%* ) > 0 );
        my $has_reloc   = 1;
        my $has_exports = ( ref $self->exported_funcs eq 'ARRAY' && scalar( @{ $self->exported_funcs } ) > 0 ) ? 1 : 0;
        my $edata_bytes = '';
        my $edata_rva   = 0;
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

        # Pre-scan fixups to discover extern functions not defined in compiled code
        my @extern_funcs;
        for my $ff (@func_fixups) {
            next if $ff->{type} eq 'lea_rodata_rel32' || $ff->{type} eq 'lea_rodata_adr';
            next if exists $func_offsets{ $ff->{target} };
            push @extern_funcs, $ff->{target} unless grep { $_ eq $ff->{target} } @extern_funcs;
        }

        # Generate inline setjmp/longjmp stubs (skip libc import)
        my $entry_size = $self->type eq 'exe' ? length($entry_stub) : 0;
        my %sjlj_stubs;
        if ( $platform->is_x64 && grep { $_ eq 'setjmp' || $_ eq 'longjmp' } @extern_funcs ) {
            my $stub_base = length($text);
            if ( grep { $_ eq 'setjmp' } @extern_funcs ) {

                # setjmp(buf): save callee-saved regs, return 0
                # All [rcx+disp8] stores use mod=01 for correct encoding
                # 48 89 59 00       mov [rcx+0x00], rbx
                # 48 89 69 08       mov [rcx+0x08], rbp
                # 48 89 79 10       mov [rcx+0x10], rdi
                # 48 89 71 18       mov [rcx+0x18], rsi
                # 4C 89 61 20       mov [rcx+0x20], r12
                # 4C 89 69 28       mov [rcx+0x28], r13
                # 4C 89 71 30       mov [rcx+0x30], r14
                # 4C 89 79 38       mov [rcx+0x38], r15
                # 48 89 E0          mov rax, rsp
                # 48 89 41 40       mov [rcx+0x40], rax
                # 48 8B 04 24       mov rax, [rsp]
                # 48 89 41 48       mov [rcx+0x48], rax
                # 31 C0             xor eax, eax
                # C3                ret
                $text .= pack( 'C4', 0x48, 0x89, 0x59, 0x00 );
                $text .= pack( 'C4', 0x48, 0x89, 0x69, 0x08 );
                $text .= pack( 'C4', 0x48, 0x89, 0x79, 0x10 );
                $text .= pack( 'C4', 0x48, 0x89, 0x71, 0x18 );
                $text .= pack( 'C4', 0x4C, 0x89, 0x61, 0x20 );
                $text .= pack( 'C4', 0x4C, 0x89, 0x69, 0x28 );
                $text .= pack( 'C4', 0x4C, 0x89, 0x71, 0x30 );
                $text .= pack( 'C4', 0x4C, 0x89, 0x79, 0x38 );
                $text .= pack( 'C3', 0x48, 0x89, 0xE0 );
                $text .= pack( 'C4', 0x48, 0x89, 0x41, 0x40 );
                $text .= pack( 'C4', 0x48, 0x8B, 0x04, 0x24 );
                $text .= pack( 'C4', 0x48, 0x89, 0x41, 0x48 );
                $text .= pack( 'C2', 0x31, 0xC0 );
                $text .= pack( 'C',  0xC3 );
                $sjlj_stubs{setjmp} = $stub_base;
                $stub_base = length($text);
            }
            if ( grep { $_ eq 'longjmp' } @extern_funcs ) {

                # longjmp(buf, val): restore regs, jump to saved ret addr
                # 4C 8B 41 48       mov r8, [rcx+0x48]    (return addr)
                # 48 8B 19          mov rbx, [rcx+0x00]
                # 48 8B 69 08       mov rbp, [rcx+0x08]
                # 48 8B 79 10       mov rdi, [rcx+0x10]
                # 48 8B 71 18       mov rsi, [rcx+0x18]
                # 4C 8B 61 20       mov r12, [rcx+0x20]
                # 4C 8B 69 28       mov r13, [rcx+0x28]
                # 4C 8B 71 30       mov r14, [rcx+0x30]
                # 4C 8B 79 38       mov r15, [rcx+0x38]
                # 48 8B 41 40       mov rax, [rcx+0x40]   (saved rsp)
                # 48 89 C4          mov rsp, rax
                # 48 89 D0          mov rax, rdx           (return val)
                # 41 FF E0          jmp r8
                $text .= pack( 'C4', 0x4C, 0x8B, 0x41, 0x48 );
                $text .= pack( 'C3', 0x48, 0x8B, 0x19 );
                $text .= pack( 'C4', 0x48, 0x8B, 0x69, 0x08 );
                $text .= pack( 'C4', 0x48, 0x8B, 0x79, 0x10 );
                $text .= pack( 'C4', 0x48, 0x8B, 0x71, 0x18 );
                $text .= pack( 'C4', 0x4C, 0x8B, 0x61, 0x20 );
                $text .= pack( 'C4', 0x4C, 0x8B, 0x69, 0x28 );
                $text .= pack( 'C4', 0x4C, 0x8B, 0x71, 0x30 );
                $text .= pack( 'C4', 0x4C, 0x8B, 0x79, 0x38 );
                $text .= pack( 'C4', 0x48, 0x8B, 0x41, 0x40 );
                $text .= pack( 'C3', 0x48, 0x89, 0xC4 );
                $text .= pack( 'C3', 0x48, 0x89, 0xD0 );
                $text .= pack( 'C3', 0x41, 0xFF, 0xE0 );
                $sjlj_stubs{longjmp} = $stub_base;
            }

            # Register stub offsets (relative to code start, excluding entry stub)
            for my $name ( keys %sjlj_stubs ) {
                $func_offsets{$name} = $sjlj_stubs{$name} - $entry_size;
            }
            @extern_funcs = grep { $_ ne 'setjmp' && $_ ne 'longjmp' } @extern_funcs;
        }
        elsif ( $platform->is_arm64 && grep { $_ eq 'setjmp' || $_ eq 'longjmp' } @extern_funcs ) {
            use Brocken::Jenny::Codegen::ARM64::Inst;
            my $stub_base = length($text);
            if ( grep { $_ eq 'setjmp' } @extern_funcs ) {

                # setjmp(buf): save x19-x30 + SP, return 0
                # x0 = jmp_buf pointer (Windows ARM64 ABI: x0 = first arg)
                for my $i ( 0 .. 11 ) {
                    my $reg = $i < 10 ? 19 + $i : ( $i == 10 ? 29 : 30 );
                    $text .= pack( 'V', str_64( $reg, 0, $i * 8 ) );
                }
                $text .= pack( 'V', add_imm( 1, 31, 0 ) );    # mov x1, sp
                $text .= pack( 'V', str_64( 1, 0, 96 ) );     # str x1, [x0, #96]
                $text .= pack( 'V', movz_64( 0, 0 ) );        # mov x0, #0
                $text .= pack( 'V', ret() );                  # ret
                $sjlj_stubs{setjmp} = $stub_base;
                $stub_base = length($text);
            }
            if ( grep { $_ eq 'longjmp' } @extern_funcs ) {

                # longjmp(buf, val): restore x19-x30 + SP, jump to saved LR
                # x0 = buf, x1 = return value
                $text .= pack( 'V', ldr_64( 2, 0, 96 ) );     # ldr x2, [x0, #96]  (saved SP)
                $text .= pack( 'V', add_imm( 31, 2, 0 ) );    # mov sp, x2
                for my $i ( reverse( 0 .. 11 ) ) {
                    my $reg = $i < 10 ? 19 + $i : ( $i == 10 ? 29 : 30 );
                    $text .= pack( 'V', ldr_64( $reg, 0, $i * 8 ) );
                }
                $text .= pack( 'V', mov_64( 0, 1 ) );         # mov x0, x1  (return val)
                $text .= pack( 'V', ret() );                  # ret (jumps to saved LR)
                $sjlj_stubs{longjmp} = $stub_base;
            }

            # Register stub offsets (relative to code start, excluding entry stub)
            for my $name ( keys %sjlj_stubs ) {
                $func_offsets{$name} = $sjlj_stubs{$name} - $entry_size;
            }
            @extern_funcs = grep { $_ ne 'setjmp' && $_ ne 'longjmp' } @extern_funcs;
        }

        # Generate import stubs for undefined external functions
        my @kernel32_imports = qw(CreateThread WaitForSingleObject CloseHandle SetThreadAffinityMask GetExitCodeThread
            AcquireSRWLockExclusive ReleaseSRWLockExclusive InitializeConditionVariable
            SleepConditionVariableSRW WakeConditionVariable WakeAllConditionVariable);
        my %kernel32_imports = map { $_ => 1 } @kernel32_imports;
        my %import_names;
        my ( %kernel32_names, %msvcrt_names );
        for my $name (@extern_funcs) {
            if ( $kernel32_imports{$name} ) {
                $kernel32_names{$name} = 1;
            }
            else {
                $msvcrt_names{$name} = 1;
            }
            $import_names{$name} = 1;
        }
        my @import_list = sort keys %import_names;
        my @k32_list    = sort keys %kernel32_names;
        my @mscrt_list  = sort keys %msvcrt_names;
        my $has_idata   = scalar @import_list > 0;
        my $idata_bytes = '';
        my $idata_rva   = 0;

        # Pre-compute idata RVA (text + preceding sections, page-aligned)
        # Account for import stubs that will be appended to .text during fixup resolution
        my $import_stub_overhead = 0;
        if ( $platform->is_arm64 ) {
            $import_stub_overhead = scalar(@import_list) * 12;    # ADRP + LDR + BR (4 bytes each)
        }
        elsif ( $platform->is_x64 ) {
            $import_stub_overhead = scalar(@import_list) * 6;     # JMP [rip+disp32]
        }
        my $final_text_size = length($text) + $import_stub_overhead;
        my $rdata_rva_fixed = 0x1000 + ( ( $final_text_size + 4095 ) & ~4095 );
        $idata_rva = $rdata_rva_fixed;
        $idata_rva += ( length($rodata_bytes) + 4095 ) & ~4095 if $has_rodata;
        $idata_rva += ( $self->brk_sym_size() + 4095 ) & ~4095 if $self->brk_sym_size() > 0;
        $idata_rva += ( length($data_bytes) + 4095 ) & ~4095   if length($data_bytes) > 0;
        $idata_rva += ( length($edata_bytes) + 4095 ) & ~4095  if $has_exports;
        my %iat_base;    # name => IAT RVA entry (populated below if has_idata)

        if ($has_idata) {
            my $desc_size = 20;
            my $num_idlls = ( @k32_list ? 1 : 0 ) + ( @mscrt_list ? 1 : 0 );
            my $idir_size = $num_idlls * $desc_size + $desc_size;              # descriptors + null terminator
            my $idir      = '';
            my $dll_data  = '';
            my @iat_blobs;

            # Pass 1: build DLL payload (ILT + names + hint/name entries) and IAT blobs
            for my $dll ( [ kernel32 => \@k32_list, "kernel32.dll\0\0" ], [ msvcrt => \@mscrt_list, "msvcrt.dll\0\0" ] ) {
                my ( $tag, $list, $dll_name ) = @$dll;
                next unless @$list;
                my $ilt_off         = length($dll_data);
                my $dll_name_off    = $ilt_off + ( 8 * ( scalar( $list->@* ) + 1 ) );
                my $hnt_off         = $dll_name_off + length($dll_name);
                my $payload_base    = $idata_rva + $idir_size;
                my $current_hnt_rva = $payload_base + $hnt_off;
                my ( $ilt_bytes, $hnt_bytes, $iat_bytes ) = ( '', '', '' );

                for my $fn ( $list->@* ) {
                    my $entry = pack( 'v', 0 ) . $fn . "\0";
                    $entry     .= "\0" if length($entry) % 2;
                    $ilt_bytes .= pack( 'Q<', $current_hnt_rva );
                    $iat_bytes .= pack( 'Q<', $current_hnt_rva );
                    $hnt_bytes .= $entry;
                    $current_hnt_rva += length($entry);
                }
                $ilt_bytes .= pack( 'Q<', 0 );
                $iat_bytes .= pack( 'Q<', 0 );

                # Descriptor for this DLL (appended to idir)
                my $iat_off = 0;
                $iat_off += length($_) for @iat_blobs;
                my $iat_rva = $payload_base + length($dll_data) + $iat_off;
                my $desc    = pack( 'V', $payload_base + $ilt_off ) .         # OriginalFirstThunk (ILT)
                    pack( 'V', 0 ) .                                          # TimeDateStamp
                    pack( 'V', 0 ) .                                          # ForwarderChain
                    pack( 'V', $payload_base + $dll_name_off ) .              # Name
                    pack( 'V', $iat_rva );                                    # FirstThunk (IAT)
                $idir     .= $desc;
                $dll_data .= $ilt_bytes . $dll_name . $hnt_bytes;
                push @iat_blobs, $iat_bytes;

                # Record IAT base RVA for each function
                for my $i ( 0 .. $#{$list} ) {
                    $iat_base{ $list->[$i] } = $iat_rva + $i * 8;
                }
            }
            $idir .= "\x00" x $desc_size;    # null terminator
            $idata_bytes = $idir . $dll_data . join( '', @iat_blobs );
        }

        # Resolve cross-function call fixups at link time, with import stubs
        my $stubs_rva_start;
        for my $ff (@func_fixups) {
            my $src_pos = $entry_size + $ff->{base_offset} + $ff->{offset};
            die "fixup offset $src_pos out of bounds" if $src_pos + 4 > length($text);

            # rodata-relocated fixups are resolved first (no function target needed)
            if ( $ff->{type} eq 'lea_rodata_rel32' ) {
                my $label_off = 0;
                for my $key ( sort keys $self->rodata->%* ) {
                    last if $key eq $ff->{target};
                    $label_off += length( $self->rodata->{$key} );
                }
                my $target_rva = $rdata_rva_fixed + $label_off;
                my $src_rva    = 0x1000 + $src_pos;
                my $rel        = $target_rva - ( $src_rva + 4 );
                substr( $text, $src_pos, 4, pack( 'V', $rel & 0xFFFFFFFF ) );
                next;
            }
            if ( $ff->{type} eq 'lea_rodata_adr' ) {
                my $label_off = 0;
                for my $key ( sort keys $self->rodata->%* ) {
                    last if $key eq $ff->{target};
                    $label_off += length( $self->rodata->{$key} );
                }
                my $target_rva = $rdata_rva_fixed + $label_off;
                my $src_rva    = 0x1000 + $src_pos;
                my $rel        = $target_rva - $src_rva;
                my $word       = unpack( 'V', substr( $text, $src_pos, 4 ) );
                my $rd         = $word & 0x1F;
                my $lo         = $rel & 3;
                my $hi         = ( $rel >> 2 ) & 0x7FFFF;
                $word = 0x10000000 | ( $lo << 29 ) | ( $hi << 5 ) | $rd;
                substr( $text, $src_pos, 4, pack( 'V', $word ) );
                next;
            }
            my $target_off = $func_offsets{ $ff->{target} };
            if ( !defined $target_off && exists $iat_base{ $ff->{target} } ) {
                my $stub_ofs      = length($text);
                my $text_rva      = 0x1000;
                my $iat_entry_rva = $iat_base{ $ff->{target} };
                $stubs_rva_start //= $text_rva + $stub_ofs;
                if ( $platform->is_x64 ) {
                    my $disp32 = $iat_entry_rva - ( $text_rva + $stub_ofs + 6 );
                    $text .= pack( 'CC l<', 0xFF, 0x25, $disp32 );
                }
                elsif ( $platform->is_arm64 ) {
                    $text .= pack( 'V3', adrp( X16, $iat_entry_rva, $text_rva + $stub_ofs ), ldr_64( X16, X16, $iat_entry_rva & 0xFFF ), br(X16), );
                }
                $func_offsets{ $ff->{target} } = $stub_ofs - $entry_size;
                $target_off = $stub_ofs - $entry_size;
            }
            die "write_executable: undefined function '$ff->{target}'" unless defined $target_off;
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

        # .pdata section for ARM64 exception/unwind data (required on ARM64 Windows)
        my $pdata_bytes = '';
        my $has_pdata   = 0;
        if ( $platform->is_arm64 && !$ENV{BROCKEN_SKIP_PDATA} ) {
            my @pdata_entries;

            # Entry stub at RVA 0x1000 (stp x29,x30,[sp,#-16]! / mov x29,sp / bl / ldp / uxtb / ret)
            if ( $self->type eq 'exe' && length($entry_stub) > 0 ) {
                push @pdata_entries, { rva => 0x1000, size => length($entry_stub) };
            }
            if ( ref $code_data eq 'ARRAY' ) {
                for my $fd ( $code_data->@* ) {
                    my $rva = 0x1000 + $entry_size + ( $func_offsets{ $fd->{name} } // 0 );
                    my $uw  = $fd->{unwind} // {};
                    push @pdata_entries,
                        { rva => $rva, size => length( $fd->{bytes} ), frame_size => $uw->{frame_size}, num_saved_int => $uw->{num_saved_int} };
                }
            }
            elsif ( length($text_raw) > 0 ) {
                push @pdata_entries, { rva => 0x1000 + $entry_size, size => length($text_raw) };
            }
            if ( defined $stubs_rva_start ) {
                my $stubs_size = length($text_bytes) - ( $stubs_rva_start - 0x1000 );
                push @pdata_entries, { rva => $stubs_rva_start, size => $stubs_size };
            }
            for my $e (@pdata_entries) {
                my $func_len = int( $e->{size} / 4 ) - 1;
                my $is_entry = $e->{rva} == 0x1000;
                my ( $cr, $frame_sz, $regi );
                if ($is_entry) {
                    $cr       = 2;
                    $frame_sz = 1;
                    $regi     = 0;
                }
                else {
                    $cr       = 1;
                    $frame_sz = ( $e->{frame_size} // 0 ) / 16;
                    $regi     = $e->{num_saved_int} // 0;
                }

                # ARM64 packed unwind data format (Microsoft PE spec):
                #   Bits  0-17: FunctionLength  (size/4 - 1, 18 bits)
                #   Bit      18: Version (1 for packed format)
                #   Bit      19: Frag (0 for non-frag)
                #   Bits 20-21: CR (0=None, 1=LR, 2=LR+FP)
                #   Bits 22-26: FrameSize (in 16-byte units, 5 bits)
                #   Bits 27-29: RegI (number of x19-x28 saved, 3 bits)
                #   Bits 30-31: RegF (number of v8-v15 saved, 2 bits)
                my $packed = ( $func_len & 0x3FFFF )    # Bits 0-17
                    | ( 1 << 18 )                       # Bit 18: Version
                    | ( 0 << 19 )                       # Bit 19: Frag
                    | ( ( $cr & 3 ) << 20 )             # Bits 20-21: CR
                    | ( ( $frame_sz & 0x1F ) << 22 )    # Bits 22-26: FrameSize
                    | ( ( $regi & 7 ) << 27 )           # Bits 27-29: RegI
                    | ( 0 << 30 );                      # Bits 30-31: RegF = 0
                $pdata_bytes .= pack( 'V V', $e->{rva}, $packed );
            }
            $has_pdata = length($pdata_bytes) > 0;
        }

        # Layout sections
        my $brk_sym_size       = $self->brk_sym_size();
        my $has_brk_sym        = $brk_sym_size > 0;
        my $num_debug_sections = 0;
        my @debug_sec_names;
        my %debug_sec_data;
        if ($has_debug) {
            if ( keys $debug_sections->%* ) {
                @debug_sec_names    = sort keys $debug_sections->%*;
                $num_debug_sections = scalar @debug_sec_names;
                for my $name (@debug_sec_names) {
                    $debug_sec_data{$name} = $debug_sections->{$name};
                }
            }
            elsif ( defined $debug_bytes ) {
                $num_debug_sections         = 1;
                @debug_sec_names            = ('.debug_l');
                $debug_sec_data{'.debug_l'} = $debug_bytes;
            }
        }
        my $num_sections
            = 1 + ( $has_brk_sym ? 1 : 0 )
            + ( $has_rodata  ? 1 : 0 )
            + ( $has_data    ? 1 : 0 )
            + ( $has_exports ? 1 : 0 )
            + ( $has_idata   ? 1 : 0 )
            + $has_reloc
            + $has_pdata
            + $num_debug_sections;
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

        # .rdata section (Read-only data)
        my $sec_raw_rodata_size = 0;
        if ($has_rodata) {
            $sec_raw_rodata_size = ( length($rodata_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".rdata\x00\x00\x00", length($rodata_bytes), $sec_rva, $sec_raw_rodata_size, $sec_raw_ptr, 0, 0, 0, 0, 0x40000040 );
            $sec_rva     += ( length($rodata_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_rodata_size;
        }

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
        my $pdata_vaddr        = 0;
        my $sec_raw_pdata_size = 0;

        if ($has_pdata) {
            $pdata_vaddr        = $sec_rva;
            $sec_raw_pdata_size = ( length($pdata_bytes) + 511 ) & ~511;
            $section_table .= pack( 'a8 V2 V2 V2 v2 V',
                ".pdata\x00\x00", length($pdata_bytes), $sec_rva, $sec_raw_pdata_size, $sec_raw_ptr, 0, 0, 0, 0, 0x40000040 );
            $sec_rva     += ( length($pdata_bytes) + 4095 ) & ~4095;
            $sec_raw_ptr += $sec_raw_pdata_size;
        }

        # Collect function names from code_data for COFF symbols
        my @func_names;
        if ( ref $code_data eq 'ARRAY' ) {
            push @func_names, $_->{name} for $code_data->@*;
        }

        # Build combined string table: long section names + long function names
        my %strtab_offsets;
        my $strtab_data = '';
        for my $name ( @debug_sec_names, @func_names ) {
            next unless length($name) > 8;
            next if exists $strtab_offsets{$name};
            $strtab_offsets{$name} = 4 + length($strtab_data);
            $strtab_data .= $name . "\0";
        }
        my $has_strtab         = length($strtab_data) > 0;
        my $strtab_payload     = $has_strtab ? pack( 'V', 4 + length($strtab_data) ) . $strtab_data : '';
        my $has_long_sec_names = scalar( grep { length($_) > 8 } @debug_sec_names ) > 0;

        # Build section table with long-name support via string table offsets
        my %debug_raw_sizes;
        for my $name (@debug_sec_names) {
            my $data     = $debug_sec_data{$name};
            my $raw_size = ( length($data) + 511 ) & ~511;
            $debug_raw_sizes{$name} = $raw_size;
            my $name_field;
            if ( exists $strtab_offsets{$name} ) {
                $name_field = sprintf( "/%d\x00\x00\x00\x00\x00", $strtab_offsets{$name} );
                $name_field = substr( $name_field . ( "\x00" x 8 ), 0, 8 );
            }
            else {
                $name_field = pack( 'a8', $name );
            }
            $section_table .= pack( 'a8 V2 V2 V2 v2 V', $name_field, length($data), $sec_rva, $raw_size, $sec_raw_ptr, 0, 0, 0, 0, 0x42000040 );
            $sec_rva     += ( length($data) + 4095 ) & ~4095;
            $sec_raw_ptr += $raw_size;
        }

        # COFF symbol table (only at debug_level >= 5 for GDB breakpoint support)
        my $coff_symtab             = '';
        my $num_coff_symbols        = 0;
        my $pointer_to_symbol_table = 0;
        if ( $self->debug_level >= 5 && ( @func_names || $has_strtab ) ) {
            $pointer_to_symbol_table = $sec_raw_ptr;

            # .text section symbol (1 aux entry = 2 symbol-table entries)
            my $sec_name_field = pack( 'a8', '.text' );
            $coff_symtab .= pack( 'a8 V v v C2', $sec_name_field, 0, 1, 0, 0x68, 1 );
            $coff_symtab .= pack( 'V v v V v C C3', $sec_raw_code_size, 0, 0, 0, 1, 0, 0, 0, 0 );
            $num_coff_symbols += 2;

            # One symbol per function (no aux entries)
            for my $name (@func_names) {
                my $name_field;
                if ( length($name) <= 8 ) {
                    $name_field = pack( 'a8', $name );
                }
                else {
                    $name_field = pack( 'V V', 0, $strtab_offsets{$name} );
                }
                my $rva = 0x1000 + $entry_size + ( $func_offsets{$name} // 0 );
                $coff_symtab .= pack( 'a8 V v v C2', $name_field, $rva, 1, 0x20, 2, 0 );
                $num_coff_symbols++;
            }
        }

        # COFF characteristics: 0x0022 = IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE
        my $file_header = pack( 'v2 V3 v2', $machine, $num_sections, $timestamp, $pointer_to_symbol_table, $num_coff_symbols, 240, 0x0022 );

        # PE32+ Optional Header (Magic=0x020b): fields include entry, image base 0x140000000, section alignment 0x1000, file alignment 0x200,
        # subsystem=3 (CONSOLE), DLL characteristics=0x8160 (NX compatible + TSA aware + DYNAMIC_BASE),
        # stack reserve 0x400000 (4MB), stack commit 0x200000 (2MB covers 1MB entry-stub heap), heap reserve 0x100000, heap commit 0x1000
        my $init_debug_size = 0;
        $init_debug_size += $_ for values %debug_raw_sizes;
        my $size_of_image = $sec_rva;
        my $size_of_code  = $sec_raw_code_size;
        my $init_data_size
            = $sec_raw_data_size
            + $sec_raw_edata_size
            + $sec_raw_reloc_size
            + $init_debug_size
            + $sec_raw_brk_sym_size
            + $sec_raw_rodata_size
            + $sec_raw_idata_size
            + $sec_raw_pdata_size;
        my $os_ver     = 6;
        my $dll_chars  = $self->debug_level >= 5 ? 0x8140 : 0x8160;          # Clear DYNAMIC_BASE at debug >= 5
        my $opt_header = pack( 'v C2 V3 V2 Q< V2 v4 v2 V V V V v2 Q<4 V2',
            0x020b,         14, 10, $size_of_code, $init_data_size, 0, 0x1000, 0x1000, 0x140000000, 4096, 512, $os_ver, 0, 0, 0, $os_ver, 0, 0,
            $size_of_image, $size_of_headers, 0, 3, $dll_chars, 0x400000, 0x200000, 0x100000, 0x1000, 0, 16 );

        # Data directories (128 bytes = 16 entries x 8 bytes each):
        #   [0]=export, [1]=import, [3]=pdata, [5]=reloc
        my $data_dirs = "\x00" x 128;
        if ($has_idata) {
            substr $data_dirs, 8, 4, pack( 'V', $idata_rva );
            my $num_desc = ( @k32_list ? 1 : 0 ) + ( @mscrt_list ? 1 : 0 );
            substr $data_dirs, 12, 4, pack( 'V', $num_desc * 20 + 20 );    # descriptors + null terminator
            my $k32_iat_entries   = scalar(@k32_list) > 0   ? scalar(@k32_list) + 1   : 0;
            my $mscrt_iat_entries = scalar(@mscrt_list) > 0 ? scalar(@mscrt_list) + 1 : 0;
            my $total_iat_entries = $k32_iat_entries + $mscrt_iat_entries;
            my $iat_rva           = $idata_rva + length($idata_bytes) - ( 8 * $total_iat_entries );
            my $iat_size          = 8 * $total_iat_entries;
            substr $data_dirs, 96,  4, pack( 'V', $iat_rva );
            substr $data_dirs, 100, 4, pack( 'V', $iat_size );
        }
        if ($has_exports) {
            substr $data_dirs, 0, 4, pack( 'V', $edata_rva );
            substr $data_dirs, 4, 4, pack( 'V', length($edata_bytes) );
        }
        substr $data_dirs, 40, 4, pack( 'V', $reloc_rva );
        substr $data_dirs, 44, 4, pack( 'V', length($reloc_bytes) );
        if ($has_pdata) {
            substr $data_dirs, 24, 4, pack( 'V', $pdata_vaddr );
            substr $data_dirs, 28, 4, pack( 'V', length($pdata_bytes) );
        }
        $opt_header .= $data_dirs;
        print $fh $dos_header, $dos_stub, $pe_signature, $file_header, $opt_header, $section_table;
        my $headers_len
            = length($dos_header) + length($dos_stub) + length($pe_signature) + length($file_header) + length($opt_header) + length($section_table);
        print $fh ( "\x00" x ( $size_of_headers - $headers_len ) );

        # Write section payloads
        print $fh $text_bytes;
        print $fh ( "\x00" x ( $sec_raw_code_size - length($text_bytes) ) );
        if ($has_rodata) {
            print $fh $rodata_bytes;
            print $fh ( "\x00" x ( $sec_raw_rodata_size - length($rodata_bytes) ) );
        }
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
        if ($has_pdata) {
            print $fh $pdata_bytes;
            print $fh ( "\x00" x ( $sec_raw_pdata_size - length($pdata_bytes) ) );
        }
        if ($has_debug) {
            for my $name (@debug_sec_names) {
                my $data = $debug_sec_data{$name};
                print $fh $data;
                print $fh ( "\x00" x ( $debug_raw_sizes{$name} - length($data) ) );
            }
        }
        if ( $pointer_to_symbol_table > 0 ) {
            print $fh $coff_symtab;
            print $fh $strtab_payload;
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
