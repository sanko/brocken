use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Architecture::X64 {

    # Physical X64 Registers
    # Note: r14 is reserved for the Brocken Execution Context (State)
    use constant REG_RAX => 0;
    use constant REG_RCX => 1;
    use constant REG_RDX => 2;
    use constant REG_RBX => 3;
    use constant REG_RSP => 4;
    use constant REG_RBP => 5;
    use constant REG_RSI => 6;
    use constant REG_RDI => 7;
    use constant REG_R14 => 14;    # Thread / Fiber state

    #
    field $stack_offset           = 0;
    field $offsets                = {};    # Maps virtual registers & variables to rbp stack offsets
    field $line_mappings : reader = [];    # Collects [{ address => $v_addr, line => $source_line }]

    method get_offset($reg) {
        if ( !exists $offsets->{$reg} ) {
            $stack_offset -= 8;
            $offsets->{$reg} = $stack_offset;
        }
        return $offsets->{$reg};
    }

    # Helper inside assemble() to record line changes dynamically
    method record_line_mapping( $inst, $current_bin_length, $triple ) {
        if ( defined $inst->line ) {

            # Linux ELF standard entry base: 0x401000 + 17 bytes (for ELF exit wrapper)
            my $v_addr = 0x401000 + 17 + $current_bin_length;

            # Avoid duplicate mappings for the same line/instruction boundary
            if ( !@$line_mappings || $line_mappings->[-1]->{line} != $inst->line ) {
                push @$line_mappings, { address => $v_addr, line => $inst->line };
            }
        }
    }

    # Lowers flat IR instructions of a block into raw x86-64 machine code bytes
    # Lowers a complete collection of Basic Blocks into raw x86-64 machine code
    method assemble( $blocks, $triple ) {
        my $bin = '';
        my %block_addresses;    # Maps block labels to starting byte offsets
        my @relocations;        # Tracks jumps that need relative target backpatching

        # Function Prologue (shared across all blocks)
        $bin .= pack 'C',  0x55;                     # push rbp
        $bin .= pack 'C3', 0x48, 0x89, 0xE5;         # mov rbp, rsp
        $bin .= pack 'C4', 0x48, 0x83, 0xEC, 128;    # sub rsp, 128

        # Pass 1: Assemble each block sequentially
        for my $block (@$blocks) {

            # Record the starting byte offset of this block in our binary buffer
            $block_addresses{ $block->label } = length($bin);
            for my $inst ( @{ $block->instructions } ) {

                # Record the line matching position
                $self->record_line_mapping( $inst, length($bin), $triple );
                my $op = $inst->op;
                if ( $op eq 'ALLOCA' ) {
                    $self->get_offset( $inst->dest );
                }
                elsif ( $op eq 'STORE' ) {
                    my $slot     = $inst->srcs->[0];
                    my $val      = $inst->srcs->[1];
                    my $slot_off = $self->get_offset($slot);
                    if ( $val =~ /^\d+$/ ) {
                        $bin .= pack 'C4 V', 0x48, 0xC7, 0x45, ( 256 + $slot_off ) % 256, $val;
                    }
                    else {
                        my $val_off = $self->get_offset($val);
                        $bin .= pack 'C4', 0x48, 0x8B, 0x45, ( 256 + $val_off ) % 256;
                        $bin .= pack 'C4', 0x48, 0x89, 0x45, ( 256 + $slot_off ) % 256;
                    }
                }
                elsif ( $op eq 'LOAD' ) {
                    my $dest     = $inst->dest;
                    my $slot     = $inst->srcs->[0];
                    my $dest_off = $self->get_offset($dest);
                    my $slot_off = $self->get_offset($slot);
                    $bin .= pack 'C4', 0x48, 0x8B, 0x45, ( 256 + $slot_off ) % 256;
                    $bin .= pack 'C4', 0x48, 0x89, 0x45, ( 256 + $dest_off ) % 256;
                }
                elsif ( $op eq 'ADD' || $op eq 'SUB' || $op eq 'MUL' ) {
                    my $dest     = $inst->dest;
                    my $left     = $inst->srcs->[0];
                    my $right    = $inst->srcs->[1];
                    my $dest_off = $self->get_offset($dest);
                    if ( $left =~ /^\d+$/ ) {
                        $bin .= pack 'C3 V', 0x48, 0xC7, 0xC0, $left;
                    }
                    else {
                        my $left_off = $self->get_offset($left);
                        $bin .= pack 'C4', 0x48, 0x8B, 0x45, ( 256 + $left_off ) % 256;
                    }
                    if ( $op eq 'ADD' ) {
                        if ( $right =~ /^\d+$/ ) {
                            $bin .= pack 'C2 V', 0x48, 0x05, $right;
                        }
                        else {
                            my $right_off = $self->get_offset($right);
                            $bin .= pack 'C4', 0x48, 0x03, 0x45, ( 256 + $right_off ) % 256;
                        }
                    }
                    elsif ( $op eq 'SUB' ) {
                        if ( $right =~ /^\d+$/ ) {
                            $bin .= pack 'C2 V', 0x48, 0x2D, $right;
                        }
                        else {
                            my $right_off = $self->get_offset($right);
                            $bin .= pack 'C4', 0x48, 0x2B, 0x45, ( 256 + $right_off ) % 256;
                        }
                    }
                    elsif ( $op eq 'MUL' ) {
                        if ( $right =~ /^\d+$/ ) {
                            $bin .= pack 'C3 V', 0x48, 0x69, 0xC0, $right;
                        }
                        else {
                            my $right_off = $self->get_offset($right);
                            $bin .= pack 'C5', 0x48, 0x0F, 0xAF, 0x45, ( 256 + $right_off ) % 256;
                        }
                    }
                    $bin .= pack 'C4', 0x48, 0x89, 0x45, ( 256 + $dest_off ) % 256;
                }
                elsif ( $op eq 'JUMP' ) {
                    my $target_label = $inst->srcs->[0];

                    # Emit JMP rel32 opcode (0xE9)
                    $bin .= pack 'C', 0xE9;

                    # Record the location of the 4 placeholder bytes
                    push @relocations, { patch_offset => length($bin), next_inst_off => length($bin) + 4, target_label => $target_label };
                    $bin .= pack 'V', 0;    # 4-byte dummy offset
                }
                elsif ( $op eq 'JUMP_IF_FALSE' ) {
                    my $cond_reg     = $inst->srcs->[0];
                    my $target_label = $inst->srcs->[1];
                    my $cond_off     = $self->get_offset($cond_reg);

                    # mov rax, [rbp + cond_off]
                    $bin .= pack 'C4', 0x48, 0x8B, 0x45, ( 256 + $cond_off ) % 256;

                    # test rax, rax
                    $bin .= pack 'C3', 0x48, 0x85, 0xC0;

                    # Emit JZ rel32 opcode (0x0F 0x84)
                    $bin .= pack 'C2', 0x0F, 0x84;

                    # Record the location of the 4 placeholder bytes
                    push @relocations, { patch_offset => length($bin), next_inst_off => length($bin) + 4, target_label => $target_label };
                    $bin .= pack 'V', 0;    # 4-byte dummy offset
                }
                elsif ( $op eq 'JUMP_IF_TRUE' ) {
                    my $cond_reg     = $inst->srcs->[0];
                    my $target_label = $inst->srcs->[1];
                    my $cond_off     = $self->get_offset($cond_reg);

                    # mov rax, [rbp + cond_off]
                    $bin .= pack 'C4', 0x48, 0x8B, 0x45, ( 256 + $cond_off ) % 256;

                    # test rax, rax
                    $bin .= pack 'C3', 0x48, 0x85, 0xC0;

                    # Emit JNZ rel32 opcode (0x0F 0x85)
                    $bin .= pack 'C2', 0x0F, 0x85;

                    # Record the location of the 4 placeholder bytes
                    push @relocations, { patch_offset => length($bin), next_inst_off => length($bin) + 4, target_label => $target_label };
                    $bin .= pack 'V', 0;    # 4-byte dummy offset
                }
                elsif ( $op eq 'LOAD' ) {
                    my $dest     = $inst->dest;
                    my $slot     = $inst->srcs->[0];
                    my $dest_off = $self->get_offset($dest);
                    my $slot_off = $self->get_offset($slot);
                    $bin .= pack 'C4', 0x48, 0x8B, 0x45, ( 256 + $slot_off ) % 256;
                    $bin .= pack 'C4', 0x48, 0x89, 0x45, ( 256 + $dest_off ) % 256;
                }
                elsif ( $op eq 'LOAD_ARG' ) {
                    my $dest     = $inst->dest;
                    my $idx      = $inst->srcs->[0];
                    my $dest_off = $self->get_offset($dest);

                    # System V AMD64 ABI Register-to-Stack Mapping
                    if ( $idx == 0 ) {

                        # mov [rbp + dest_off], rdi
                        $bin .= pack 'C4', 0x48, 0x89, 0x7D, ( 256 + $dest_off ) % 256;
                    }
                    elsif ( $idx == 1 ) {

                        # mov [rbp + dest_off], rsi
                        $bin .= pack 'C4', 0x48, 0x89, 0x75, ( 256 + $dest_off ) % 256;
                    }
                    elsif ( $idx == 2 ) {

                        # mov [rbp + dest_off], rdx
                        $bin .= pack 'C4', 0x48, 0x89, 0x55, ( 256 + $dest_off ) % 256;
                    }
                    elsif ( $idx == 3 ) {

                        # mov [rbp + dest_off], rcx
                        $bin .= pack 'C4', 0x48, 0x89, 0x4D, ( 256 + $dest_off ) % 256;
                    }
                    elsif ( $idx == 4 ) {

                        # mov [rbp + dest_off], r8
                        $bin .= pack 'C4', 0x4C, 0x89, 0x45, ( 256 + $dest_off ) % 256;
                    }
                    elsif ( $idx == 5 ) {

                        # mov [rbp + dest_off], r9
                        $bin .= pack 'C4', 0x4C, 0x89, 0x4D, ( 256 + $dest_off ) % 256;
                    }
                    else {
                        die "X64 Assembling Error: Stack-based parameters (>6) not supported yet\n";
                    }
                }
            }
        }

        # Load the final calculated value (the last stack offset) into rax as the returned value
        $bin .= pack 'C4', 0x48, 0x8B, 0x45, ( 256 + $stack_offset ) % 256 if $stack_offset != 0;

        # Function Epilogue (shared across all blocks)
        $bin .= pack 'C', 0xC9;    # leave
        $bin .= pack 'C', 0xC3;    # ret

        # Pass 2: Backpatch all relative jump offsets
        for my $reloc (@relocations) {
            my $target_addr = $block_addresses{ $reloc->{target_label} };
            if ( !defined $target_addr ) {
                die "Assembling Error: JUMP target label '" . $reloc->{target_label} . "' is undefined\n";
            }

            # Calculate relative distance: Target Address - Address immediately following the jump
            my $rel_dist = $target_addr - $reloc->{next_inst_off};

            # Write the 4-byte signed relative distance over the dummy placeholder
            substr $bin, $reloc->{patch_offset}, 4, pack 'V', $rel_dist;
        }
        return $bin;
    }
}
#
1;
