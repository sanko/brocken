use v5.38;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Core::IR;

class Brocken::Target::Architecture::RISC64 {
    field $stack_offset           = 16;    # Start after saved ra/s0 space (16 bytes)
    field $offsets                = {};    # Maps variables to positive s0 offsets
    field $line_mappings : reader = [];

    method get_offset($reg) {
        if ( !exists $offsets->{$reg} ) {
            $stack_offset += 8;
            $offsets->{$reg} = $stack_offset;
        }
        return $offsets->{$reg};
    }

    method record_line_mapping( $inst, $current_bin_length, $os ) {
        if ( defined $inst->line ) {

            # Standard Entry Base for RISC-V Linux is 0x401000 + 12 bytes
            my $v_addr = 0x401000 + 12 + $current_bin_length;
            if ( !@$line_mappings || $line_mappings->[-1]->{line} != $inst->line ) {
                push @$line_mappings, { address => $v_addr, line => $inst->line, };
            }
        }
    }

    # RISC-V I-Type (Immediate) Instruction Packer
    method encode_i_type ( $opcode, $funct3, $rd, $rs1, $imm ) {
        use integer;
        my $imm12 = $imm & 0xFFF;
        return ( $imm12 << 20 ) | ( $rs1 << 15 ) | ( $funct3 << 12 ) | ( $rd << 7 ) | $opcode;
    }

    # RISC-V S-Type (Store) Instruction Packer
    method encode_s_type ( $opcode, $funct3, $rs1, $rs2, $offset ) {
        use integer;
        my $imm      = $offset & 0xFFF;
        my $imm_11_5 = ( $imm >> 5 ) & 0x7F;
        my $imm_4_0  = $imm & 0x1F;
        return ( $imm_11_5 << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( $funct3 << 12 ) | ( $imm_4_0 << 7 ) | $opcode;
    }

    # RISC-V R-Type (Register) Instruction Packer
    method encode_r_type ( $opcode, $funct3, $funct7, $rd, $rs1, $rs2 ) {
        return ( $funct7 << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( $funct3 << 12 ) | ( $rd << 7 ) | $opcode;
    }

    # RISC-V B-Type (Branch) Instruction Packer
    method encode_b_type ( $opcode, $funct3, $rs1, $rs2, $offset ) {
        use integer;
        my $imm      = ( $offset / 2 ) & 0xFFF;    # Target offsets are divided by 2
        my $imm_12   = ( $imm >> 11 ) & 1;
        my $imm_10_5 = ( $imm >> 4 ) & 0x3F;
        my $imm_4_1  = ( $imm >> 0 ) & 0xF;
        my $imm_11   = ( $imm >> 10 ) & 1;
        return ( $imm_12 << 31 ) | ( $imm_10_5 << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( $funct3 << 12 ) | ( $imm_4_1 << 8 ) | ( $imm_11 << 7 )
            | $opcode;
    }

    # RISC-V J-Type (Jump) Instruction Packer
    method encode_j_type ( $opcode, $rd, $offset ) {
        use integer;
        my $imm       = ( $offset / 2 ) & 0xFFFFF;    # Target offsets are divided by 2
        my $imm_20    = ( $imm >> 19 ) & 1;
        my $imm_10_1  = ( $imm >> 0 ) & 0x3FF;
        my $imm_11    = ( $imm >> 10 ) & 1;
        my $imm_19_12 = ( $imm >> 11 ) & 0xFF;
        return ( $imm_20 << 31 ) | ( $imm_10_1 << 21 ) | ( $imm_11 << 20 ) | ( $imm_19_12 << 12 ) | ( $rd << 7 ) | $opcode;
    }

    method assemble( $blocks, $triple ) {
        my $bin = '';
        my %block_addresses;
        my @relocations;

        # Function Prologue (Allocates 128 bytes, saves s0 & ra)
        # addi sp, sp, -128
        $bin .= pack 'V', $self->encode_i_type( 19, 0, 2, 2, -128 );

        # sd ra, 120(sp)
        $bin .= pack 'V', $self->encode_s_type( 35, 3, 2, 1, 120 );

        # sd s0, 112(sp)
        $bin .= pack 'V', $self->encode_s_type( 35, 3, 2, 8, 112 );

        # addi s0, sp, 128
        $bin .= pack 'V', $self->encode_i_type( 19, 0, 8, 2, 128 );

        # Pass 1: Emit instructions
        for my $block (@$blocks) {
            $block_addresses{ $block->label } = length($bin);
            for my $inst ( @{ $block->instructions } ) {
                $self->record_line_mapping( $inst, length($bin), $triple->os );
                my $op = $inst->op;
                if ( $op eq 'ALLOCA' ) {
                    $self->get_offset( $inst->dest );
                }
                elsif ( $op eq 'STORE' ) {
                    my $slot     = $inst->srcs->[0];
                    my $val      = $inst->srcs->[1];
                    my $slot_off = $self->get_offset($slot);
                    if ( $val =~ /^\d+$/ ) {

                        # li a0, val (addi a0, x0, val)
                        $bin .= pack 'V', $self->encode_i_type( 19, 0, 10, 0, $val );

                        # sd a0, -slot_off(s0)
                        $bin .= pack 'V', $self->encode_s_type( 35, 3, 8, 10, -$slot_off );
                    }
                    else {
                        # ld a0, -val_off(s0)
                        my $val_off = $self->get_offset($val);
                        $bin .= pack 'V', $self->encode_i_type( 3, 3, 10, 8, -$val_off );

                        # sd a0, -slot_off(s0)
                        $bin .= pack 'V', $self->encode_s_type( 35, 3, 8, 10, -$slot_off );
                    }
                }
                elsif ( $op eq 'LOAD' ) {
                    my $dest     = $inst->dest;
                    my $slot     = $inst->srcs->[0];
                    my $dest_off = $self->get_offset($dest);
                    my $slot_off = $self->get_offset($slot);

                    # ld a0, -slot_off(s0)
                    $bin .= pack 'V', $self->encode_i_type( 3, 3, 10, 8, -$slot_off );

                    # sd a0, -dest_off(s0)
                    $bin .= pack 'V', $self->encode_s_type( 35, 3, 8, 10, -$dest_off );
                }
                elsif ( $op eq 'LOAD_ARG' ) {
                    my $dest     = $inst->dest;
                    my $idx      = $inst->srcs->[0];
                    my $dest_off = $self->get_offset($dest);

                    # standard LP64D calling convention: a0-a7 (x10-x17) holds first 8 parameters
                    if ( $idx >= 0 && $idx <= 7 ) {

                        # sd a[idx], -dest_off(s0)
                        $bin .= pack 'V', $self->encode_s_type( 35, 3, 8, 10 + $idx, -$dest_off );
                    }
                    else {
                        die "RISC64 Assembling Error: Stack parameters (>8) not supported yet\n";
                    }
                }
                elsif ( $op eq 'ADD' || $op eq 'SUB' || $op eq 'MUL' ) {
                    my $dest     = $inst->dest;
                    my $left     = $inst->srcs->[0];
                    my $right    = $inst->srcs->[1];
                    my $dest_off = $self->get_offset($dest);

                    # Load left into a0
                    if ( $left =~ /^\d+$/ ) {
                        $bin .= pack 'V', $self->encode_i_type( 19, 0, 10, 0, $left );
                    }
                    else {
                        my $left_off = $self->get_offset($left);
                        $bin .= pack 'V', $self->encode_i_type( 3, 3, 10, 8, -$left_off );
                    }

                    # Load right into a1
                    if ( $right =~ /^\d+$/ ) {
                        $bin .= pack 'V', $self->encode_i_type( 19, 0, 11, 0, $right );
                    }
                    else {
                        my $right_off = $self->get_offset($right);
                        $bin .= pack 'V', $self->encode_i_type( 3, 3, 11, 8, -$right_off );
                    }
                    if ( $op eq 'ADD' ) {

                        # add a0, a0, a1
                        $bin .= pack 'V', $self->encode_r_type( 51, 0, 0, 10, 10, 11 );
                    }
                    elsif ( $op eq 'SUB' ) {

                        # sub a0, a0, a1
                        $bin .= pack 'V', $self->encode_r_type( 51, 0, 32, 10, 10, 11 );
                    }
                    elsif ( $op eq 'MUL' ) {

                        # mul a0, a0, a1
                        $bin .= pack 'V', $self->encode_r_type( 51, 0, 1, 10, 10, 11 );
                    }

                    # Store result a0 back to dest stack offset
                    $bin .= pack 'V', $self->encode_s_type( 35, 3, 8, 10, -$dest_off );
                }
                elsif ( $op eq 'JUMP' ) {
                    my $target_label = $inst->srcs->[0];
                    push @relocations, { patch_offset => length($bin), type => 'JAL', target_label => $target_label };
                    $bin .= pack 'V', 0x0000006f;    # jal x0, #0 placeholder
                }
                elsif ( $op eq 'JUMP_IF_FALSE' ) {
                    my $cond_reg     = $inst->srcs->[0];
                    my $target_label = $inst->srcs->[1];
                    my $cond_off     = $self->get_offset($cond_reg);

                    # ld a0, -cond_off(s0)
                    $bin .= pack 'V', $self->encode_i_type( 3, 3, 10, 8, -$cond_off );

                    # beq a0, x0, target placeholder
                    push @relocations, { patch_offset => length($bin), type => 'BEQ', target_label => $target_label };
                    $bin .= pack 'V', 0x00050063;    # beq a0, x0, #0 placeholder
                }
                elsif ( $op eq 'JUMP_IF_TRUE' ) {
                    my $cond_reg     = $inst->srcs->[0];
                    my $target_label = $inst->srcs->[1];
                    my $cond_off     = $self->get_offset($cond_reg);

                    # ld a0, -cond_off(s0)
                    $bin .= pack 'V', $self->encode_i_type( 3, 3, 10, 8, -$cond_off );

                    # bne a0, x0, target placeholder
                    push @relocations, { patch_offset => length($bin), type => 'B', target_label => $target_label };
                    $bin .= pack 'V', 0x00051063;    # bne a0, x0, #0 placeholder
                }
            }
        }

        # Load final calculated temporary into a0 as return value
        if ( $stack_offset != 16 ) {
            $bin .= pack 'V', $self->encode_i_type( 3, 3, 10, 8, -$stack_offset );
        }

        # Function Epilogue
        # ld ra, 120(sp)
        $bin .= pack 'V', $self->encode_i_type( 3, 3, 1, 2, 120 );

        # ld s0, 112(sp)
        $bin .= pack 'V', $self->encode_i_type( 3, 3, 8, 2, 112 );

        # addi sp, sp, 128
        $bin .= pack 'V', $self->encode_i_type( 19, 0, 2, 2, 128 );

        # ret (jalr x0, ra, 0)
        $bin .= pack 'V', $self->encode_i_type( 103, 0, 0, 1, 0 );

        # Pass 2: Backpatch PC-relative offsets
        for my $reloc (@relocations) {
            my $target_addr = $block_addresses{ $reloc->{target_label} };
            if ( !defined $target_addr ) {
                die "RISC64 Assembling Error: JUMP target label '" . $reloc->{target_label} . "' is undefined\n";
            }
            my $byte_dist = $target_addr - $reloc->{patch_offset};

            # Inject the relative distance bits into the opcode word
            my $inst_word = 0;
            if ( $reloc->{type} eq 'JAL' ) {
                $inst_word = $self->encode_j_type( 0x6f, 0, $byte_dist );
            }
            else {
                # B-Type branch (beq / bne)
                my $funct3 = ( $reloc->{type} eq 'BEQ' ) ? 0 : 1;
                $inst_word = $self->encode_b_type( 0x63, $funct3, 10, 0, $byte_dist );
            }
            substr( $bin, $reloc->{patch_offset}, 4, pack( 'V', $inst_word ) );
        }
        return $bin;
    }
}
1;
