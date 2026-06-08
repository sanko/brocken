# lib/Brocken/Target/Format/Webassembly.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Format::Webassembly {

    # DWARF & Wasm LEB128 Compression helpers
    method encode_uleb128 ($val) {
        use integer;
        my $bin = "";
        while (1) {
            my $byte = $val & 0x7f;
            $val >>= 7;
            if ( $val == 0 ) {
                $bin .= pack( "C", $byte );
                last;
            }
            else {
                $bin .= pack( "C", $byte | 0x80 );
            }
        }
        return $bin;
    }

    method encode_sleb128 ($val) {
        use integer;
        my $bin  = "";
        my $more = 1;
        while ($more) {
            my $byte = $val & 0x7f;
            $val >>= 7;
            my $sign_bit = $byte & 0x40;
            if ( ( $val == 0 && !$sign_bit ) || ( $val == -1 && $sign_bit ) ) {
                $more = 0;
            }
            else {
                $byte |= 0x80;
            }
            $bin .= pack( "C", $byte );
        }
        return $bin;
    }

    method encode_section ( $section_id, $payload ) {
        return pack( "C", $section_id ) . $self->encode_uleb128( length($payload) ) . $payload;
    }

    # Lowers abstract IR basic blocks directly into a valid executable binary .wasm module
    method write_executable ( $output_file, $blocks, $passed_argument = undef, $debug_bytes = undef, $arch_name = undef ) {

        # 1. WASM Header (8 bytes)
        my $wasm_binary = pack( "C4 C4", 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 );

        # 2. Analyze parameter counts and allocate local variables
        my $param_count = 0;
        my %local_map;
        for my $block (@$blocks) {
            for my $inst ( @{ $block->instructions } ) {
                if ( $inst->op eq 'LOAD_ARG' ) {
                    my $idx = $inst->srcs->[0];
                    $param_count = $idx + 1 if $idx + 1 > $param_count;
                }
            }
        }

        # Locals start after parameters on the stack
        my $local_idx = $param_count;
        for my $block (@$blocks) {
            for my $inst ( @{ $block->instructions } ) {
                my $op = $inst->op;
                if ( $op eq 'ALLOCA' ) {
                    $local_map{ $inst->dest } = $local_idx++;
                }
            }
        }
        my $local_count = $local_idx - $param_count;

        # 3. Type Section (ID 1)
        my $type_payload = $self->encode_uleb128(1);
        $type_payload .= pack( "C", 0x60 );
        $type_payload .= $self->encode_uleb128($param_count);
        $type_payload .= pack( "C*", (0x7e) x $param_count ) if $param_count > 0;
        $type_payload .= $self->encode_uleb128(1);
        $type_payload .= pack( "C", 0x7e );
        $wasm_binary  .= $self->encode_section( 1, $type_payload );

        # 4. Function Section (ID 3)
        my $func_payload = $self->encode_uleb128(1) . $self->encode_uleb128(0);
        $wasm_binary .= $self->encode_section( 3, $func_payload );

        # 5. Export Section (ID 7)
        my $export_payload = $self->encode_uleb128(1);
        $export_payload .= pack( "C", 4 ) . "main";
        $export_payload .= pack( "C", 0x00 );
        $export_payload .= $self->encode_uleb128(0);
        $wasm_binary    .= $self->encode_section( 7, $export_payload );

        # 6. Code Section (ID 10)
        my $code_bytes = "";
        if ( $local_count > 0 ) {
            $code_bytes .= $self->encode_uleb128(1);
            $code_bytes .= $self->encode_uleb128($local_count) . pack( "C", 0x7e );
        }
        else {
            $code_bytes .= $self->encode_uleb128(0);
        }

        # Emit bytecode instructions
        for my $block (@$blocks) {
            for my $inst ( @{ $block->instructions } ) {
                my $op = $inst->op;
                if ( $op eq 'STORE' ) {
                    my $slot     = $inst->srcs->[0];
                    my $val      = $inst->srcs->[1];
                    my $slot_idx = $local_map{$slot};
                    if ( $val =~ /^\d+$/ ) {
                        $code_bytes .= pack( "C", 0x42 ) . $self->encode_sleb128($val);
                    }
                    else {
                        my $val_idx = $local_map{$val};
                        $code_bytes .= pack( "C", 0x20 ) . $self->encode_uleb128($val_idx);
                    }
                    $code_bytes .= pack( "C", 0x21 ) . $self->encode_uleb128($slot_idx);
                }
                elsif ( $op eq 'LOAD' ) {
                    my $dest     = $inst->dest;
                    my $slot     = $inst->srcs->[0];
                    my $dest_idx = $local_map{$dest};
                    my $slot_idx = $local_map{$slot};
                    $code_bytes .= pack( "C", 0x20 ) . $self->encode_uleb128($slot_idx);
                    $code_bytes .= pack( "C", 0x21 ) . $self->encode_uleb128($dest_idx);
                }
                elsif ( $op eq 'LOAD_ARG' ) {
                    my $dest     = $inst->dest;
                    my $idx      = $inst->srcs->[0];
                    my $dest_idx = $local_map{$dest};
                    $code_bytes .= pack( "C", 0x20 ) . $self->encode_uleb128($idx);
                    $code_bytes .= pack( "C", 0x21 ) . $self->encode_uleb128($dest_idx);
                }
                elsif ( $op eq 'ADD' || $op eq 'SUB' || $op eq 'MUL' ) {
                    my $dest     = $inst->dest;
                    my $left     = $inst->srcs->[0];
                    my $right    = $inst->srcs->[1];
                    my $dest_idx = $local_map{$dest};
                    if ( $left =~ /^\d+$/ ) {
                        $code_bytes .= pack( "C", 0x42 ) . $self->encode_sleb128($left);
                    }
                    else {
                        my $left_idx = $local_map{$left};
                        $code_bytes .= pack( "C", 0x20 ) . $self->encode_uleb128($left_idx);
                    }
                    if ( $right =~ /^\d+$/ ) {
                        $code_bytes .= pack( "C", 0x42 ) . $self->encode_sleb128($right);
                    }
                    else {
                        my $right_idx = $local_map{$right};
                        $code_bytes .= pack( "C", 0x20 ) . $self->encode_uleb128($right_idx);
                    }
                    my $wasm_bin_op = 0x7C;
                    $wasm_bin_op = 0x7D if $op eq 'SUB';
                    $wasm_bin_op = 0x7E if $op eq 'MUL';
                    $code_bytes .= pack( "C", $wasm_bin_op );
                    $code_bytes .= pack( "C", 0x21 ) . $self->encode_uleb128($dest_idx);
                }
                elsif ( $op eq 'RET' ) {
                    my $val = $inst->srcs->[0];
                    if ( defined $val ) {
                        if ( $val =~ /^\d+$/ ) {
                            $code_bytes .= pack( "C", 0x42 ) . $self->encode_sleb128($val);
                        }
                        else {
                            my $val_idx = $local_map{$val};
                            $code_bytes .= pack( "C", 0x20 ) . $self->encode_uleb128($val_idx);
                        }
                    }
                    else {
                        $code_bytes .= pack( "C", 0x42 ) . $self->encode_sleb128(0);
                    }
                    $code_bytes .= pack( "C", 0x0F );
                }
            }
        }

        # If no explicit return occurred, push last local onto the stack
        if ( $local_idx > $param_count ) {
            $code_bytes .= pack( "C", 0x20 ) . $self->encode_uleb128( $local_idx - 1 );
        }
        else {
            $code_bytes .= pack( "C", 0x42 ) . $self->encode_sleb128(0);
        }

        # End of function body (0x0B)
        $code_bytes .= pack( "C", 0x0B );
        my $body_payload         = $self->encode_uleb128( length($code_bytes) ) . $code_bytes;
        my $code_section_payload = $self->encode_uleb128(1) . $body_payload;
        $wasm_binary .= $self->encode_section( 10, $code_section_payload );
        open my $fh, '>', $output_file or die "Cannot open $output_file: $!";
        print $fh $wasm_binary;
        close $fh;
    }
}
1;
