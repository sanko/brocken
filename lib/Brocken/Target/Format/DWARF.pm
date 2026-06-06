use v5.38;
use feature 'class';
no warnings 'experimental::class';
#
class Brocken::Target::Format::DWARF {

    # DWARF v4 Line Program Opcodes
    use constant DW_LNS_copy            => 1;
    use constant DW_LNS_advance_line    => 3;
    use constant DW_LNE_set_address     => 2;
    use constant DW_LNE_end_of_sequence => 1;

    # Encodes an unsigned integer into Little Endian Base 128 (compressed format)
    method encode_uleb128 ($val) {
        use integer;    # Enforce standard signed arithmetic shifts
        my $bin = "";
        while (1) {
            my $byte = $val & 0x7f;
            $val >>= 7;
            if ( $val == 0 ) {
                $bin .= pack 'C', $byte;
                last;
            }
            else {
                $bin .= pack 'C', $byte | 0x80;
            }
        }
        return $bin;
    }

    # Encodes a signed integer into Little Endian Base 128 (compressed format)
    method encode_sleb128 ($val) {
        use integer;    # Enforce standard signed arithmetic shifts
        my $bin  = '';
        my $more = 1;
        while ($more) {
            my $byte = $val & 0x7f;
            $val >>= 7;    # Arithmetic right shift preserving the sign bit
            my $sign_bit = $byte & 0x40;
            if ( ( $val == 0 && !$sign_bit ) || ( $val == -1 && $sign_bit ) ) {
                $more = 0;
            }
            else {
                $byte |= 0x80;
            }
            $bin .= pack 'C', $byte;
        }
        return $bin;
    }

    # Generates a valid, debuggable .debug_line section (DWARF v4)
    method generate_line_table ( $filename, $mappings ) {

        # Prepare Directory and File Name Tables
        # Index 1 is current directory '.', terminated by a final null byte
        my $directories_data = ".\x00\x00";

        # File Name: null-terminated name, dir index, mod time, size, terminated by a final null byte
        my $files_data = $filename . "\x00" . $self->encode_uleb128(1)    # Directory index 1
            . $self->encode_uleb128(0)                                    # Modification time 0
            . $self->encode_uleb128(0)                                    # Size 0
            . "\x00";

        # Compile the Line Number Program instructions
        my $program         = '';
        my $current_address = 0;
        my $current_line    = 1;
        for my $m (@$mappings) {
            my $addr = $m->{address};
            my $line = $m->{line};

            # Set Virtual Address (DW_LNE_set_address)
            # 0x00 (prefix), size (9 bytes), sub-opcode 2, 64-bit virtual address
            $program .= pack 'C', 0x00;
            $program .= $self->encode_uleb128(9);
            $program .= pack 'C', DW_LNE_set_address;
            $program .= pack 'Q', $addr;

            # Update Line Number (DW_LNS_advance_line)
            my $line_diff = $line - $current_line;
            $program .= pack 'C', DW_LNS_advance_line;
            $program .= $self->encode_sleb128($line_diff);

            # Append Row to Matrix (DW_LNS_copy)
            $program .= pack 'C', DW_LNS_copy;
            $current_address = $addr;
            $current_line    = $line;
        }

        # End of Sequence (Opcode 0, size 1, sub-opcode 1)
        $program .= pack 'C', 0x00;
        $program .= $self->encode_uleb128(1);
        $program .= pack 'C', DW_LNE_end_of_sequence;

        # Assemble the compilation unit header (DWARF v4)
        my $version = 4;

        # Calculate header size (starts after the 'header_length' field)
        # Size = minimum_instruction_length (1) + default_is_stmt (1) + line_base (1) +
        #        line_range (1) + opcode_base (1) + standard_opcode_lengths (12) +
        #        len(directories) + len(files) = 17 + directories + files
        my $header_length = 17 + length($directories_data) + length($files_data);

        # Standard Opcode Lengths for opcode_base = 13 (DWARF v4)
        my $std_opcode_lengths = pack 'C12',    0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1;
        my $header             = pack 'S L C5', $version, $header_length, 1,    # minimum_instruction_length
            1,                                                                  # default_is_stmt
            251,                                                                # line_base (signed -5 formatted safely)
            14,                                                                 # line_range
            13;                                                                 # opcode_base

        # Ensure signed char line_base -5 is written securely
        substr( $header, 8, 1, pack 'c', -5 );
        my $full_header = $header . $std_opcode_lengths . $directories_data . $files_data;

        # Total Unit Length (starts after this 4-byte field)
        my $unit_length = length($full_header) + length($program);

        # Return full .debug_line chunk
        return pack( 'L', $unit_length ) . $full_header . $program;
    }
}
#
1;
