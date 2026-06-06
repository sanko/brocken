use v5.38;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Core::IR;
#
class Brocken::Target::Architecture::ARM64 {
    field $stack_offset           = 8;     # Start at 16 (leaving 16 bytes for saved x29/x30)
    field $offsets                = {};    # Maps virtual registers & variables to positive x29 stack offsets
    field $line_mappings : reader = [];

    method get_offset($reg) {
        if ( !exists $offsets->{$reg} ) {
            $stack_offset += 8;
            $offsets->{$reg} = $stack_offset;
        }
        return $offsets->{$reg};
    }

    method record_line_mapping( $inst, $current_bin_length, $triple ) {
        if ( defined $inst->line ) {

            # Standard Entry Base for ARM64 Linux is 0x401000 + 12 bytes (for ARM64 ELF exit wrapper)
            my $wrapper_size = ( $triple->is_macos ) ? 16 : 12;
            my $v_addr       = 0x401000 + $wrapper_size + $current_bin_length;
            if ( !@$line_mappings || $line_mappings->[-1]->{line} != $inst->line ) {
                push @$line_mappings, { address => $v_addr, line => $inst->line, };
            }
        }
    }

    method assemble( $blocks, $triple ) {
        my $bin = '';
        my %block_addresses;
        my @relocations;

        # Function Prologue (Allocates 128 bytes of stack frame, saves x29 & x30)
        # stp x29, x30, [sp, #-128]! (pre-indexed decrementation)
        $bin .= pack 'V', 0xa9bf7bfd;

        # mov x29, sp (sets frame pointer to current sp)
        $bin .= pack 'V', 0x910003fd;

        # Pass 1: Emit instruction words
        for my $block (@$blocks) {
            $block_addresses{ $block->label } = length($bin);
            for my $inst ( @{ $block->instructions } ) {
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

                        # movz x0, #val
                        $bin .= pack 'V', 0xd2800000 | ( $val << 5 ) | 0;

                        # str x0, [x29, #slot_off]
                        $bin .= pack 'V', 0xf9000000 | ( ( $slot_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;
                    }
                    else {
                        # ldr x0, [x29, #val_off]
                        my $val_off = $self->get_offset($val);
                        $bin .= pack 'V', 0xf9400000 | ( ( $val_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;

                        # str x0, [x29, #slot_off]
                        $bin .= pack 'V', 0xf9000000 | ( ( $slot_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;
                    }
                }
                elsif ( $op eq 'LOAD' ) {
                    my $dest     = $inst->dest;
                    my $slot     = $inst->srcs->[0];
                    my $dest_off = $self->get_offset($dest);
                    my $slot_off = $self->get_offset($slot);

                    # ldr x0, [x29, #slot_off]
                    $bin .= pack 'V', 0xf9400000 | ( ( $slot_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;

                    # str x0, [x29, #dest_off]
                    $bin .= pack 'V', 0xf9000000 | ( ( $dest_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;
                }
                elsif ( $op eq 'LOAD_ARG' ) {
                    my $dest     = $inst->dest;
                    my $idx      = $inst->srcs->[0];
                    my $dest_off = $self->get_offset($dest);

                    # ARM64 standard register calling convention: x0-x7 holds first 8 parameters
                    if ( $idx >= 0 && $idx <= 7 ) {

                        # str x[idx], [x29, #dest_off]
                        $bin .= pack 'V', 0xf9000000 | ( ( $dest_off / 8 ) << 10 ) | ( 29 << 5 ) | $idx;
                    }
                    else {
                        die "ARM64 Assembling Error: Stack parameters (>8) not supported yet\n";
                    }
                }
                elsif ( $op eq 'ADD' || $op eq 'SUB' || $op eq 'MUL' ) {
                    my $dest     = $inst->dest;
                    my $left     = $inst->srcs->[0];
                    my $right    = $inst->srcs->[1];
                    my $dest_off = $self->get_offset($dest);

                    # Load left into x0
                    if ( $left =~ /^\d+$/ ) {
                        $bin .= pack 'V', 0xd2800000 | ( $left << 5 ) | 0;
                    }
                    else {
                        my $left_off = $self->get_offset($left);
                        $bin .= pack 'V', 0xf9400000 | ( ( $left_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;
                    }

                    # Load right into x1
                    if ( $right =~ /^\d+$/ ) {
                        $bin .= pack 'V', 0xd2800000 | ( $right << 5 ) | 1;
                    }
                    else {
                        my $right_off = $self->get_offset($right);
                        $bin .= pack 'V', 0xf9400000 | ( ( $right_off / 8 ) << 10 ) | ( 29 << 5 ) | 1;
                    }
                    if ( $op eq 'ADD' ) {

                        # add x0, x0, x1
                        $bin .= pack 'V', 0x8b010000;
                    }
                    elsif ( $op eq 'SUB' ) {

                        # sub x0, x0, x1
                        $bin .= pack 'V', 0xcb010000;
                    }
                    elsif ( $op eq 'MUL' ) {

                        # mul x0, x0, x1 (madd x0, x0, x1, xzr)
                        $bin .= pack 'V', 0x9b017c00;
                    }

                    # Store result x0 back to dest stack offset
                    $bin .= pack 'V', 0xf9000000 | ( ( $dest_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;
                }
                elsif ( $op eq 'JUMP' ) {
                    my $target_label = $inst->srcs->[0];
                    push @relocations, { patch_offset => length($bin), type => 'B', target_label => $target_label };
                    $bin .= pack( "V", 0x14000000 );    # b #0 placeholder
                }
                elsif ( $op eq 'JUMP_IF_FALSE' ) {
                    my $cond_reg     = $inst->srcs->[0];
                    my $target_label = $inst->srcs->[1];
                    my $cond_off     = $self->get_offset($cond_reg);

                    # ldr x0, [x29, #cond_off]
                    $bin .= pack 'V', 0xf9400000 | ( ( $cond_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;

                    # cbz x0, target placeholder
                    push @relocations, { patch_offset => length($bin), type => 'CBZ', target_label => $target_label };
                    $bin .= pack 'V', 0xb4000000;       # cbz x0, #0 placeholder
                }
                elsif ( $op eq 'JUMP_IF_TRUE' ) {
                    my $cond_reg     = $inst->srcs->[0];
                    my $target_label = $inst->srcs->[1];
                    my $cond_off     = $self->get_offset($cond_reg);

                    # ldr x0, [x29, #cond_off]
                    $bin .= pack 'V', 0xf9400000 | ( ( $cond_off / 8 ) << 10 ) | ( 29 << 5 ) | 0;

                    # cbnz x0, target placeholder
                    push @relocations, { patch_offset => length($bin), type => 'CBNZ', target_label => $target_label };
                    $bin .= pack 'V', 0xb5000000;
                }
            }
        }

        # Load final calculated temporary into x0 as return value
        if ( $stack_offset != 8 ) {
            $bin .= pack 'V', 0xf9400000 | ( ( $stack_offset / 8 ) << 10 ) | ( 29 << 5 ) | 0;
        }

        # Function Epilogue (Deallocates 128 bytes, restores x29 & x30)
        # ldp x29, x30, [sp], #128 (post-indexed incrementation)
        $bin .= pack 'V', 0xa8c87bfd;

        # ret
        $bin .= pack 'V', 0xd65f03c0;

        # Pass 2: Backpatch PC-relative offsets
        for my $reloc (@relocations) {
            my $target_addr = $block_addresses{ $reloc->{target_label} };
            if ( !defined $target_addr ) {
                die "ARM64 Assembling Error: JUMP target label '" . $reloc->{target_label} . "' is undefined\n";
            }

            # PC relative offset on ARM64: Target Offset - Jump Instruction Offset
            my $byte_dist = $target_addr - $reloc->{patch_offset};
            my $word_dist = $byte_dist / 4;                          # Convert to 32-bit instructions (always exact)

            # Read the placeholder instruction word
            my $inst_word = unpack 'V', substr( $bin, $reloc->{patch_offset}, 4 );

            # Inject the relative distance bits into the opcode
            if ( $reloc->{type} eq 'B' ) {
                $inst_word |= ( $word_dist & 0x03ffffff );    # 26-bit immediate offset
            }
            else {
                $inst_word |= ( ( $word_dist & 0x7ffff ) << 5 );    # 19-bit immediate offset (CBZ / CBNZ)
            }
            substr( $bin, $reloc->{patch_offset}, 4, pack 'V', $inst_word );
        }
        return $bin;
    }
}
#
1;
