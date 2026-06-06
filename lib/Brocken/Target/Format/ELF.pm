use v5.38;
use feature 'class';
no warnings 'experimental::class';
#
class Brocken::Target::Format::ELF {
    use constant ELF_CLASS64    => 2;
    use constant ELF_DATA2LSB   => 1;    # Little-endian
    use constant ELF_EV_CURRENT => 1;
    use constant ELF_OSABI_SYSV => 0;

    # Machine flags
    use constant EM_AARCH64 => 183;
    use constant EM_RISCV   => 243;
    use constant EM_X86_64  => 62;

    method write_executable ( $output_file, $code_bytes, $triple, $passed_argument = undef, $debug_bytes = undef ) {
        my $start_wrapper = '';
        if ( $triple->is_arm64 ) {

            # Linux AArch64 Static Binary Entry Wrapper:
            #   0x94000003         ; bl main (computes PC-relative jump offset to locate main)
            #   0xd2800ba8         ; mov x8, #93 (exit syscall on ARM64)
            #   0xd4000001         ; svc #0 (invokes kernel)
            $start_wrapper .= pack 'V*', 0x94000003, 0xd2800ba8, 0xd4000001;
        }
        elsif ( $triple->is_riscv64 ) {

            # Linux RISC-V 64-bit Static Binary Entry Wrapper:
            #   0x00c000ef         ; jal ra, main (offset 12)
            #   0x05d00893         ; li a7, 93 (exit syscall on RISC-V)
            #   0x00000073         ; ecall
            $start_wrapper .= pack 'V*', 0x00c000ef, 0x05d00893, 0x00000073;
        }
        else {
            # Prepend Argument Initialization: mov rdi, passed_argument
            # Bytes: 48 C7 C7 <32-bit imm>
            $start_wrapper .= pack 'C3 V', 0x48, 0xC7, 0xC7, $passed_argument if defined $passed_argument;

            # Prepend standard static binary execution wrapper
            # Bytes:
            #   E8 0C 00 00 00         ; call main
            #   48 89 C7               ; mov rdi, rax
            #   48 C7 C0 3C 00 00 00   ; mov rax, 60 (syscall: exit)
            #   0F 05                  ; syscall
            $start_wrapper .= pack 'C*', 0xE8, 0x0C, 0x00, 0x00, 0x00, 0x48, 0x89, 0xC7, 0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00, 0x0F, 0x05;
        }
        #
        my $full_code = $start_wrapper . $code_bytes;

        # Calculate section offsets
        my $elf_hdr_size  = 64;
        my $prog_hdr_size = 56;
        my $code_offset   = $elf_hdr_size + $prog_hdr_size;    # 120

        # Build Section Name String Table
        # Indices: 0 -> "", 1 -> ".text", 7 -> ".debug_line", 19 -> ".shstrtab"
        my $shstrtab        = "\x00.text\x00.debug_line\x00.shstrtab\x00";
        my $debug_offset    = $code_offset + length($full_code);
        my $shstrtab_offset = $debug_offset + ( defined $debug_bytes ? length($debug_bytes) : 0 );
        my $sh_table_offset = $shstrtab_offset + length($shstrtab);

        # Header counts depending on if DWARF is present
        my $has_debug    = defined $debug_bytes ? 1 : 0;
        my $num_sections = $has_debug           ? 4 : 3;
        my $shstrtab_idx = $has_debug           ? 3 : 2;
        #
        my $e_ident     = "\x7fELF" . pack( 'C*', ELF_CLASS64, ELF_DATA2LSB, ELF_EV_CURRENT, ELF_OSABI_SYSV ) . ( "\x00" x 8 );
        my $e_type      = 2;                                                                                                      # ET_EXEC
        my $e_machine   = $triple->is_arm64 ? EM_AARCH64 : $triple->is_riscv64 ? EM_RISCV : EM_X86_64;
        my $e_version   = 1;
        my $e_entry     = 0x401000;            # Entry point virtual address (common starting address)
        my $e_phoff     = $elf_hdr_size;       # Program headers immediately follow ELF header
        my $e_shoff     = $sh_table_offset;    # Section Header Table starts here on disk
        my $e_flags     = 0;
        my $e_ehsize    = $elf_hdr_size;
        my $e_phentsize = $prog_hdr_size;
        my $e_phnum     = 1;                   # Just one segment load for now (RX for both code and static data)
        my $e_shentsize = 64;                  # ELF64 Section Header Entry is 64 bytes
        my $e_shnum     = $num_sections;
        my $e_shstrndx  = $shstrtab_idx;
        #
        my $elf_header = pack 'a16 S S L Q Q Q L S S S S S S', $e_ident, $e_type, $e_machine, $e_version, $e_entry, $e_phoff, $e_shoff, $e_flags,
            $e_ehsize, $e_phentsize, $e_phnum, $e_shentsize, $e_shnum, $e_shstrndx;

        # Program Header (PT_LOAD segment mapping headers + text to virtual 0x400000)
        my $p_type   = 1;                                   # PT_LOAD
        my $p_flags  = 5;                                   # PF_R | PF_X
        my $p_offset = 0;
        my $p_vaddr  = 0x400000;
        my $p_paddr  = 0x400000;
        my $p_filesz = $code_offset + length($full_code);
        my $p_memsz  = $p_filesz;
        my $p_align  = 0x1000;
        #
        my $program_header = pack 'L L Q Q Q Q Q Q', $p_type, $p_flags, $p_offset, $p_vaddr, $p_paddr, $p_filesz, $p_memsz, $p_align;

        # Patch entry point address: 0x400000 + ELF Header size + Program Header size = 0x400078
        # The entry point offset inside the binary is the start of the code bytes
        # ELF Header (64 bytes) + Program Header (56 bytes) = 120 bytes (0x78)
        # We must adjust $e_entry to point to 0x400000 + 120 bytes = 0x400078
        # Let's patch the entry point in our elf_header string:
        substr $elf_header, 24, 8, pack 'Q', 0x400000 + length($elf_header) + length($program_header);

        # Section header table
        my $section_table = "\x00" x 64;    # Init with nulls

        # .text Section (64 bytes)
        $section_table .= pack 'L L Q Q Q Q L L Q Q', 1,    # sh_name (offset 1 -> ".text")
            1,                                              # sh_type (SHT_PROGBITS)
            6,                                              # sh_flags (SHF_ALLOC | SHF_EXECINSTR)
            0x400000 + $code_offset,                        # sh_addr (virtual address)
            $code_offset,                                   # sh_offset (file offset)
            length($full_code),                             # sh_size
            0, 0,                                           # sh_link, sh_info
            16,                                             # sh_addralign
            0                                               # sh_entsize
            ;

        # .debug_line Section (only if debug is present)
        if ($has_debug) {
            $section_table .= pack 'L L Q Q Q Q L L Q Q', 7,    # sh_name (offset 7 -> ".debug_line")
                1,                                              # sh_type (SHT_PROGBITS)
                0,                                              # sh_flags (none)
                0,                                              # sh_addr
                $debug_offset,                                  # sh_offset
                length($debug_bytes),                           # sh_size
                0, 0, 1, 0;
        }

        # .shstrtab Section
        $section_table .= pack 'L L Q Q Q Q L L Q Q', 19,    # sh_name (offset 19 -> ".shstrtab")
            3,                                               # sh_type (SHT_STRTAB)
            0,                                               # sh_flags (none)
            0,                                               # sh_addr
            $shstrtab_offset,                                # sh_offset
            length($shstrtab),                               # sh_size
            0, 0, 1, 0;

        # Write out executable
        open my $fh, '>', $output_file or die "Cannot open $output_file for writing: $!";
        binmode $fh;
        print $fh $elf_header;
        print $fh $program_header;
        print $fh $full_code;
        print $fh $debug_bytes if $has_debug;
        print $fh $shstrtab;
        print $fh $section_table;
        close $fh;
        chmod 0755, $output_file;
    }

    # Compiles an ELF Shared Library (.so) instead of an executable
    method write_shared_library ( $output_file, $code_bytes, $triple, $debug_bytes = undef ) {

        # Redirect to write_executable but patch the e_type header field to ET_DYN (3) on disk
        $self->write_executable( $output_file, $code_bytes, $triple, undef, $debug_bytes );
        open my $fh, '+<', $output_file or die $!;
        binmode $fh;

        # ELF e_type is at byte offset 16 (size 2)
        seek $fh, 16, 0;
        print $fh pack 'S', 3;    # ET_DYN (Shared Object)
        close $fh;
    }
}
#
1;
