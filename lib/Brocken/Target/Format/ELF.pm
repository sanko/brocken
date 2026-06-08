# lib/Brocken/Target/Format/ELF.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Format::ELF {
    use constant ELF_CLASS64    => 2;
    use constant ELF_DATA2LSB   => 1;    # Little-endian
    use constant ELF_EV_CURRENT => 1;
    use constant ELF_OSABI_SYSV => 0;

    method write_executable ( $output_file, $code_bytes, $triple, $passed_argument = undef, $debug_bytes = undef ) {
        my $code          = ref $code_bytes eq 'HASH' ? $code_bytes->{binary} : $code_bytes;
        my $start_wrapper = '';
        if ( $triple->is_arm64 ) {
            $start_wrapper .= pack( "V*", 0x94000003, 0xd2800ba8, 0xd4000001 );
        }
        elsif ( $triple->is_riscv64 ) {
            $start_wrapper .= pack( "V*", 0x00c000ef, 0x05d00893, 0x00000073 );
        }
        else {
            $start_wrapper .= pack 'C3 V', 0x48, 0xC7, 0xC7, $passed_argument if defined $passed_argument;
            $start_wrapper .= pack( "C*", 0xE8, 0x0C, 0x00, 0x00, 0x00, 0x48, 0x89, 0xC7, 0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00, 0x0F, 0x05 );
        }
        my $full_code       = $start_wrapper . $code;
        my $elf_hdr_size    = 64;
        my $prog_hdr_size   = 56;
        my $code_offset     = $elf_hdr_size + $prog_hdr_size;                                                                         # 120
        my $shstrtab        = "\x00.text\x00.debug_line\x00.shstrtab\x00";
        my $debug_offset    = $code_offset + length($full_code);
        my $shstrtab_offset = $debug_offset + ( defined $debug_bytes ? length($debug_bytes) : 0 );
        my $sh_table_offset = $shstrtab_offset + length($shstrtab);
        my $has_debug       = defined $debug_bytes ? 1 : 0;
        my $num_sections    = $has_debug           ? 4 : 3;
        my $shstrtab_idx    = $has_debug           ? 3 : 2;
        my $e_ident         = "\x7fELF" . pack( 'C*', ELF_CLASS64, ELF_DATA2LSB, ELF_EV_CURRENT, ELF_OSABI_SYSV ) . ( "\x00" x 8 );
        my $e_type          = 2;                                                                                                      # ET_EXEC
        my $e_machine       = $triple->is_arm64 ? 183 : ( $triple->is_riscv64 ? 243 : 62 );
        my $e_version       = 1;
        my $e_entry         = 0x401000;
        my $e_phoff         = $elf_hdr_size;
        my $e_shoff         = $sh_table_offset;
        my $e_flags         = 0;
        my $e_ehsize        = $elf_hdr_size;
        my $e_phentsize     = $prog_hdr_size;
        my $e_phnum         = 1;
        my $e_shentsize     = 64;
        my $e_shnum         = $num_sections;
        my $e_shstrndx      = $shstrtab_idx;
        my $elf_header      = pack 'a16 S S L Q Q Q L S S S S S S', $e_ident, $e_type, $e_machine, $e_version, $e_entry, $e_phoff, $e_shoff, $e_flags,
            $e_ehsize, $e_phentsize, $e_phnum, $e_shentsize, $e_shnum, $e_shstrndx;
        my $p_type         = 1;                                   # PT_LOAD
        my $p_flags        = 5;                                   # PF_R | PF_X
        my $p_offset       = 0;
        my $p_vaddr        = 0x400000;
        my $p_paddr        = 0x400000;
        my $p_filesz       = $code_offset + length($full_code);
        my $p_memsz        = $p_filesz;
        my $p_align        = 0x1000;
        my $program_header = pack 'L L Q Q Q Q Q Q', $p_type, $p_flags, $p_offset, $p_vaddr, $p_paddr, $p_filesz, $p_memsz, $p_align;
        substr $elf_header, 24, 8, pack 'Q', 0x400000 + length($elf_header) + length($program_header);
        my $section_table = "\x00" x 64;                          # Init with nulls

        # .text Section
        $section_table .= pack 'L L Q Q Q Q L L Q Q', 1, 1,       # sh_type
            6,                                                    # sh_flags
            0x400000 + $code_offset,                              # sh_addr
            $code_offset,                                         # sh_offset
            length($full_code),                                   # sh_size
            0, 0, 16, 0;

        # .debug_line Section
        if ($has_debug) {
            $section_table .= pack 'L L Q Q Q Q L L Q Q', 7, 1,    # sh_type
                0,                                                 # sh_flags
                0,                                                 # sh_addr
                $debug_offset,                                     # sh_offset
                length($debug_bytes),                              # sh_size
                0, 0, 1, 0;
        }

        # .shstrtab Section
        $section_table .= pack 'L L Q Q Q Q L L Q Q', 19, 3,    # sh_type
            0,                                                  # sh_flags
            0,                                                  # sh_addr
            $shstrtab_offset,                                   # sh_offset
            length($shstrtab),                                  # sh_size
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

    method write_shared_library ( $output_file, $code_bytes, $triple, $debug_bytes = undef ) {
        $self->write_executable( $output_file, $code_bytes, $triple, undef, $debug_bytes );
        open my $fh, '+<', $output_file or die $!;
        binmode $fh;
        seek $fh, 16, 0;
        print $fh pack 'S', 3;    # ET_DYN (Shared Object)
        close $fh;
    }
}
1;
