# lib/Brocken/Target/Architecture/X64.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Architecture::X64 {
    use constant REG_RAX => 0;
    use constant REG_RCX => 1;
    use constant REG_RDX => 2;
    use constant REG_RBX => 3;
    use constant REG_RSP => 4;
    use constant REG_RBP => 5;
    use constant REG_RSI => 6;
    use constant REG_RDI => 7;
    use constant REG_R14 => 14;
    field $stack_offset : reader  = 0;
    field $offsets                = {};
    field $types                  = {};
    field $line_mappings : reader = [];

    method get_offset( $reg, $type = undef ) {
        if ( !exists $offsets->{$reg} ) {
            if ( !defined $type || !ref($type) ) {
                $type = Brocken::Core::Type->new( name => $type // 'Any' );
            }
            my $size  = $type->byte_size();
            my $align = $size;
            $align = 16 if $align > 16;
            use integer;
            my $next_off = $stack_offset - $size;
            if ( $align > 1 ) {
                my $rem = $next_off % $align;
                if ( $rem != 0 ) {
                    $next_off -= ( $align + $rem );
                }
            }
            $stack_offset    = $next_off;
            $offsets->{$reg} = $stack_offset;
            $types->{$reg}   = $type;
        }
        return $offsets->{$reg};
    }

    method emit_load_rax( $offset, $type ) {
        if ( !defined $type || !ref($type) ) {
            $type = Brocken::Core::Type->new( name => $type // 'Any' );
        }
        my $size     = $type->byte_size;
        my $off_byte = ( 256 + $offset ) % 256;
        if ( $size == 1 ) {
            return pack( "C5", 0x48, 0x0F, 0xBE, 0x45, $off_byte );
        }
        elsif ( $size == 2 ) {
            return pack( "C5", 0x48, 0x0F, 0xBF, 0x45, $off_byte );
        }
        elsif ( $size == 4 ) {
            return pack( "C4", 0x48, 0x63, 0x45, $off_byte );
        }
        else {
            return pack( "C4", 0x48, 0x8B, 0x45, $off_byte );
        }
    }

    method emit_store_rax( $offset, $type ) {
        if ( !defined $type || !ref($type) ) {
            $type = Brocken::Core::Type->new( name => $type // 'Any' );
        }
        my $size     = $type->byte_size;
        my $off_byte = ( 256 + $offset ) % 256;
        if ( $size == 1 ) {
            return pack( "C3", 0x88, 0x45, $off_byte );
        }
        elsif ( $size == 2 ) {
            return pack( "C4", 0x66, 0x89, 0x45, $off_byte );
        }
        elsif ( $size == 4 ) {
            return pack( "C3", 0x89, 0x45, $off_byte );
        }
        else {
            return pack( "C4", 0x48, 0x89, 0x45, $off_byte );
        }
    }

    method emit_store_arg_reg( $offset, $idx, $type ) {
        if ( !defined $type || !ref($type) ) {
            $type = Brocken::Core::Type->new( name => $type // 'Any' );
        }
        my $size     = $type->byte_size;
        my $off_byte = ( 256 + $offset ) % 256;
        if ( $idx == 0 ) {
            return pack( "C3 C", 0x40, 0x88, 0x7D, $off_byte ) if $size == 1;
            return pack( "C4",   0x66, 0x89, 0x7D, $off_byte ) if $size == 2;
            return pack( "C3", 0x89, 0x7D, $off_byte ) if $size == 4;
            return pack( "C4", 0x48, 0x89, 0x7D, $off_byte );
        }
        elsif ( $idx == 1 ) {
            return pack( "C3 C", 0x40, 0x88, 0x75, $off_byte ) if $size == 1;
            return pack( "C4",   0x66, 0x89, 0x75, $off_byte ) if $size == 2;
            return pack( "C3", 0x89, 0x75, $off_byte ) if $size == 4;
            return pack( "C4", 0x48, 0x89, 0x75, $off_byte );
        }
        elsif ( $idx == 2 ) {
            return pack( "C3", 0x88, 0x55, $off_byte )       if $size == 1;
            return pack( "C4", 0x66, 0x89, 0x55, $off_byte ) if $size == 2;
            return pack( "C3", 0x89, 0x55, $off_byte )       if $size == 4;
            return pack( "C4", 0x48, 0x89, 0x55, $off_byte );
        }
        elsif ( $idx == 3 ) {
            return pack( "C3", 0x88, 0x4D, $off_byte )       if $size == 1;
            return pack( "C4", 0x66, 0x89, 0x4D, $off_byte ) if $size == 2;
            return pack( "C3", 0x89, 0x4D, $off_byte )       if $size == 4;
            return pack( "C4", 0x48, 0x4D, 0x4D, $off_byte );
        }
        else {
            die "X64 Assembling Error: Sized register mapping for arg index $idx > 3 not fully mapped yet\n";
        }
    }

    method record_line_mapping( $inst, $current_bin_length ) {
        if ( defined $inst->line ) {
            my $v_addr = 0x401000 + 17 + $current_bin_length;
            if ( !@$line_mappings || $line_mappings->[-1]->{line} != $inst->line ) {
                push @$line_mappings, { address => $v_addr, line => $inst->line, };
            }
        }
    }

    # Assembles a whole program containing multiple distinct functions and methods
    method XXXassemble_program( $program_blocks, $triple ) {
        my $bin = "";
        my %block_addresses;       # Maps block labels to starting byte offsets
        my %function_addresses;    # Maps fully qualified function names to starting byte offsets
        my @relocations;           # Tracks relative jumps and calls needing backpatching

        # Compile each function and class method sequentially
        # Sort keys guarantees deterministic binary layout ordering
        for my $fq_name ( sort keys %$program_blocks ) {
            my $blocks = $program_blocks->{$fq_name};

            # Record the exact starting address of this function on disk!
            $function_addresses{$fq_name} = length($bin);

            # 1. Emit Function Prologue
            $bin .= pack( "C",  0x55 );                     # push rbp
            $bin .= pack( "C3", 0x48, 0x89, 0xE5 );         # mov rbp, rsp
            $bin .= pack( "C4", 0x48, 0x83, 0xEC, 128 );    # sub rsp, 128

            # Reset local stack offset offsets per-function compilation frame
            $stack_offset = 0;
            $offsets      = {};
            $types        = {};

            # 2. Lower Basic Blocks
            for my $block (@$blocks) {

                # Record the local block address relative to the program start
                $block_addresses{ $block->label } = length($bin);
                for my $inst ( @{ $block->instructions } ) {
                    $self->record_line_mapping( $inst, length($bin) );
                    my $op = $inst->op;
                    if ( $op eq 'ALLOCA' ) {
                        $self->get_offset( $inst->dest, $inst->type );
                    }
                    elsif ( $op eq 'STORE' ) {
                        my $slot      = $inst->srcs->[0];
                        my $val       = $inst->srcs->[1];
                        my $slot_off  = $self->get_offset($slot);
                        my $slot_type = $types->{$slot};
                        if ( $val =~ /^\d+$/ ) {
                            my $size     = $slot_type->byte_size;
                            my $off_byte = ( 256 + $slot_off ) % 256;
                            if ( $size == 1 ) {
                                $bin .= pack( "C3 C", 0xC6, 0x45, $off_byte, $val );
                            }
                            elsif ( $size == 2 ) {
                                $bin .= pack( "C4 S", 0x66, 0xC7, 0x45, $off_byte, $val );
                            }
                            elsif ( $size == 4 ) {
                                $bin .= pack( "C3 L", 0xC7, 0x45, $off_byte, $val );
                            }
                            else {
                                $bin .= pack( "C4 L", 0x48, 0xC7, 0x45, $off_byte, $val );
                            }
                        }
                        else {
                            my $val_off  = $self->get_offset($val);
                            my $val_type = $types->{$val};
                            $bin .= $self->emit_load_rax( $val_off, $val_type );
                            $bin .= $self->emit_store_rax( $slot_off, $slot_type );
                        }
                    }
                    elsif ( $op eq 'LOAD' ) {
                        my $dest      = $inst->dest;
                        my $slot      = $inst->srcs->[0];
                        my $dest_off  = $self->get_offset( $dest, $inst->type );
                        my $slot_off  = $self->get_offset($slot);
                        my $slot_type = $types->{$slot};
                        $bin .= $self->emit_load_rax( $slot_off, $slot_type );
                        $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                    }
                    elsif ( $op eq 'LOAD_ARG' ) {
                        my $dest     = $inst->dest;
                        my $idx      = $inst->srcs->[0];
                        my $dest_off = $self->get_offset( $dest, $inst->type );
                        $bin .= $self->emit_store_arg_reg( $dest_off, $idx, $inst->type );
                    }
                    elsif ( $op eq 'ADD' || $op eq 'SUB' || $op eq 'MUL' ) {
                        my $dest     = $inst->dest;
                        my $left     = $inst->srcs->[0];
                        my $right    = $inst->srcs->[1];
                        my $dest_off = $self->get_offset( $dest, $inst->type );
                        if ( $left =~ /^\d+$/ ) {
                            $bin .= pack "C3 L", 0x48, 0xC7, 0xC0, $left;
                        }
                        else {
                            my $left_off  = $self->get_offset($left);
                            my $left_type = $types->{$left};
                            $bin .= $self->emit_load_rax( $left_off, $left_type );
                        }
                        if ( $op eq 'ADD' ) {
                            if ( $right =~ /^\d+$/ ) {
                                $bin .= pack "C2 L", 0x48, 0x05, $right;
                            }
                            else {
                                my $right_off = $self->get_offset($right);
                                my $off_byte  = ( 256 + $right_off ) % 256;
                                $bin .= pack( "C4", 0x48, 0x8B, 0x4D, $off_byte );
                                $bin .= pack( "C3", 0x48, 0x01, 0xC8 );
                            }
                        }
                        elsif ( $op eq 'SUB' ) {
                            if ( $right =~ /^\d+$/ ) {
                                $bin .= pack "C2 L", 0x48, 0x2D, $right;
                            }
                            else {
                                my $right_off = $self->get_offset($right);
                                my $off_byte  = ( 256 + $right_off ) % 256;
                                $bin .= pack( "C4", 0x48, 0x8B, 0x4D, $off_byte );
                                $bin .= pack( "C3", 0x48, 0x29, 0xC8 );
                            }
                        }
                        elsif ( $op eq 'MUL' ) {
                            if ( $right =~ /^\d+$/ ) {
                                $bin .= pack "C3 L", 0x48, 0x69, 0xC0, $right;
                            }
                            else {
                                my $right_off = $self->get_offset($right);
                                my $off_byte  = ( 256 + $right_off ) % 256;
                                $bin .= pack( "C4", 0x48, 0x8B, 0x4D, $off_byte );
                                $bin .= pack( "C4", 0x48, 0x0F, 0xAF, 0xC1 );
                            }
                        }
                        $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                    }
                    elsif ( $op eq 'JUMP' ) {
                        my $target_label = $inst->srcs->[0];
                        $bin .= pack 'C', 0xE9;
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'BLOCK', target_label => $target_label };
                        $bin .= pack 'V', 0;
                    }
                    elsif ( $op eq 'JUMP_IF_FALSE' ) {
                        my $cond_reg     = $inst->srcs->[0];
                        my $target_label = $inst->srcs->[1];
                        my $cond_off     = $self->get_offset($cond_reg);
                        my $cond_type    = $types->{$cond_reg};
                        $bin .= $self->emit_load_rax( $cond_off, $cond_type );
                        $bin .= pack 'C3', 0x48, 0x85, 0xC0;
                        $bin .= pack 'C2', 0x0F, 0x84;
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'BLOCK', target_label => $target_label };
                        $bin .= pack 'V', 0;
                    }
                    elsif ( $op eq 'JUMP_IF_TRUE' ) {
                        my $cond_reg     = $inst->srcs->[0];
                        my $target_label = $inst->srcs->[1];
                        my $cond_off     = $self->get_offset($cond_reg);
                        my $cond_type    = $types->{$cond_reg};
                        $bin .= $self->emit_load_rax( $cond_off, $cond_type );
                        $bin .= pack 'C3', 0x48, 0x85, 0xC0;
                        $bin .= pack 'C2', 0x0F, 0x85;
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'BLOCK', target_label => $target_label };
                        $bin .= pack 'V', 0;
                    }
                    elsif ( $op eq 'ALLOC_OBJ' ) {
                        my $dest         = $inst->dest;
                        my $size         = $inst->srcs->[0];
                        my $dest_off     = $self->get_offset($dest);
                        my $payload_type = Brocken::Core::Type->new( name => 'Payload', size => $size );
                        my $payload_off  = $self->get_offset( "${dest}_payload", $payload_type );
                        $bin .= pack( "C4", 0x48, 0x8D, 0x45, ( 256 + $payload_off ) % 256 );
                        $bin .= $self->emit_store_rax( $dest_off, Brocken::Core::Type->new( name => 'Pointer' ) );
                    }
                    elsif ( $op eq 'GET_FIELD' ) {
                        my $dest     = $inst->dest;
                        my $obj      = $inst->srcs->[0];
                        my $offset   = $inst->srcs->[1];
                        my $dest_off = $self->get_offset($dest);
                        my $obj_off  = $self->get_offset($obj);
                        $bin .= pack( "C4", 0x48, 0x8B, 0x45, ( 256 + $obj_off ) % 256 );
                        $bin .= pack( "C4", 0x48, 0x8B, 0x48, $offset );
                        $bin .= pack( "C4", 0x48, 0x89, 0x4D, ( 256 + $dest_off ) % 256 );
                    }
                    elsif ( $op eq 'SET_FIELD' ) {
                        my $obj     = $inst->srcs->[0];
                        my $offset  = $inst->srcs->[1];
                        my $val     = $inst->srcs->[2];
                        my $obj_off = $self->get_offset($obj);
                        my $val_off = $self->get_offset($val);
                        $bin .= pack( "C4", 0x48, 0x8B, 0x45, ( 256 + $obj_off ) % 256 );
                        $bin .= pack( "C4", 0x48, 0x8B, 0x4D, ( 256 + $val_off ) % 256 );
                        $bin .= pack( "C4", 0x48, 0x89, 0x48, $offset );
                    }
                    elsif ( $op eq 'CALL_METHOD' ) {
                        my $dest        = $inst->dest;
                        my $method_name = $inst->srcs->[0];
                        my $obj_ptr     = $inst->srcs->[1];

                        # Set parameter 0 as $self object pointer (System V ABI rdi)
                        my $obj_off = $self->get_offset($obj_ptr);
                        $bin .= pack( "C4", 0x48, 0x8B, 0x7D, ( 256 + $obj_off ) % 256 );

                        # Emit AMD64 relative Call instruction (0xE8)
                        $bin .= pack( "C", 0xE8 );
                        push @relocations, {
                            patch_offset  => length($bin),
                            next_inst_off => length($bin) + 4,
                            type          => 'FUNCTION',
                            target_label  => $method_name,       # Statically dispatch via relocs
                        };
                        $bin .= pack( "V", 0 );                  # 4-byte dummy offset

                        # Store returned value (rax) to destination register
                        if ( defined $dest ) {
                            my $dest_off = $self->get_offset($dest);
                            $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                        }
                    }
                }
            }

            # Function Epilogue (shared across all blocks of this function)
            if ( $stack_offset != 0 ) {
                my $final_type = $types->{ ( keys %$offsets )[-1] } // Brocken::Core::Type->new( name => 'Any' );
                $bin .= $self->emit_load_rax( $stack_offset, $final_type );
            }
            $bin .= pack 'C', 0xC9;    # leave
            $bin .= pack 'C', 0xC3;    # ret
        }

        # 3. Pass 2: Backpatch both basic-block jumps and subroutine calls!
        for my $reloc (@relocations) {
            my $target_addr;
            if ( $reloc->{type} eq 'BLOCK' ) {
                $target_addr = $block_addresses{ $reloc->{target_label} };
            }
            else {
                # Look up external function/method start address!
                # Try fully qualified name, fallback to classless name
                $target_addr = $function_addresses{ $reloc->{target_label} } // $function_addresses{ "Point::" . $reloc->{target_label} }
                    // $function_addresses{ "main::" . $reloc->{target_label} };
            }
            if ( !defined $target_addr ) {
                die "Assembling Error: Target '" . $reloc->{target_label} . "' is undefined\n";
            }
            my $rel_dist = $target_addr - $reloc->{next_inst_off};
            substr $bin, $reloc->{patch_offset}, 4, pack 'V', $rel_dist;
        }
        return $bin;
    }

    method assemble ( $blocks, $triple ) {
        my $result = $self->assemble_program( { main => $blocks }, $triple );
        return ref $result eq 'HASH' ? $result->{binary} : $result;
    }

    method get_type($reg) {
        return $types->{$reg};
    }

    method last_type() {
        my @keys = keys %$offsets;
        return undef unless @keys;
        return $types->{ $keys[-1] };
    }

    method reset_assembly_state() {
        $stack_offset = 0;
        $offsets      = {};
        $types        = {};
    }

    # Helper for X64.pm - assemble_program defined outside class block
    # Workaround for Perl 5.42 class feature segfault in larger files
    use v5.38;
    no warnings 'redefine';

    package Brocken::Target::Architecture::X64;

    sub _process_escapes($str) {
        $str =~ s/\\(['"\\])/$1/g;
        $str =~ s/\\n/\n/g;
        $str =~ s/\\t/\t/g;
        $str =~ s/\\r/\r/g;
        return $str;
    }

    sub _detect_syscall_numbers() {
        my $ntdll = "C:\\Windows\\System32\\ntdll.dll";
        open my $fh, "<:raw", $ntdll or return {};
        my $data;
        read $fh, $data, 1024 * 1024 * 4;
        close $fh;
        my $pe_off = unpack( "V", substr( $data, 0x3C, 4 ) );
        return {} if $pe_off <= 0 || $pe_off > length($data);
        my $coff         = $pe_off + 4;
        my $num_sects    = unpack( "v", substr( $data, $coff + 2,  2 ) );
        my $opt_hdr_size = unpack( "v", substr( $data, $coff + 16, 2 ) );
        my $opt_off      = $coff + 20;
        my $sect_off     = $opt_off + $opt_hdr_size;

        # Parse section headers into array for RVA→file offset lookups
        my @sections;
        for my $i ( 0 .. $num_sects - 1 ) {
            my $s = substr( $data, $sect_off + $i * 40, 40 );
            my @v = unpack( "x8 V V V V", $s );
            push @sections, { vsize => $v[0], va => $v[1], rsize => $v[2], roff => $v[3] };
        }

        # Get export directory RVA from data directory index 0
        my $pe32_plus  = ( unpack( "v", substr( $data, $opt_off, 2 ) ) == 0x20b );
        my $export_rva = unpack( "V", substr( $data, $opt_off + ( $pe32_plus ? 112 : 96 ), 4 ) );

        # Find export table file offset
        my $export_off;
        for my $s (@sections) {
            if ( $export_rva >= $s->{va} && $export_rva < $s->{va} + $s->{rsize} ) {
                $export_off = $s->{roff} + ( $export_rva - $s->{va} );
                last;
            }
        }
        return {} unless defined $export_off;

        # Parse export directory
        my @exp = unpack( "V10", substr( $data, $export_off, 40 ) );
        my ( $num_fns, $num_names, $addr_of_fns, $addr_of_names, $addr_of_ords ) = @exp[ 5, 6, 7, 8, 9 ];
        my $rva2off = sub($rva) {
            for my $s (@sections) {
                if ( $rva >= $s->{va} && $rva < $s->{va} + $s->{vsize} ) {
                    return $s->{roff} + ( $rva - $s->{va} );
                }
            }
            return undef;
        };
        my $fns_off   = $rva2off->($addr_of_fns);
        my $names_off = $rva2off->($addr_of_names);
        my $ords_off  = $rva2off->($addr_of_ords);
        my $base      = $exp[4];
        my %ssn;
    TARGET: for my $target (qw(NtWriteFile NtTerminateProcess)) {
            for my $i ( 0 .. $num_names - 1 ) {
                my $name_rva = unpack( "V", substr( $data, $names_off + $i * 4, 4 ) );
                my $name_off = $rva2off->($name_rva);
                next unless defined $name_off;
                my $name = substr( $data, $name_off, 60 );
                $name =~ s/\x00.*//;
                if ( $name eq $target ) {
                    my $ord    = unpack( "v", substr( $data, $ords_off + $i * 2,              2 ) );
                    my $fn_rva = unpack( "V", substr( $data, $fns_off + ( $ord - $base ) * 4, 4 ) );
                    my $fn_off = $rva2off->($fn_rva);
                    next unless defined $fn_off;
                    my $stub = substr( $data, $fn_off, 14 );

                    # Find 0xB8 (mov eax, ...) in stub and extract SSN
                    for my $j ( 0 .. length($stub) - 5 ) {
                        if ( unpack( "C", substr( $stub, $j, 1 ) ) == 0xB8 ) {
                            $ssn{$target} = unpack( "V", substr( $stub, $j + 1, 4 ) );
                            next TARGET;
                        }
                    }
                }
            }
        }
        return \%ssn;
    }

    sub assemble_program ( $self, $program_blocks, $triple ) {
        my $bin = "";
        my %block_addresses;
        my %function_addresses;
        my @relocations;
        my $ssn   = _detect_syscall_numbers();
        my $is_pe = $triple && $triple->can('class_format') && $triple->class_format eq 'PE';
        for my $fq_name ( sort keys %$program_blocks ) {
            next if $fq_name eq '__string_constants';
            my $blocks = $program_blocks->{$fq_name};
            $function_addresses{$fq_name} = length($bin);
            $bin .= pack( "C",  0x55 );
            $bin .= pack( "C3", 0x48, 0x89, 0xE5 );
            $bin .= pack( "C4", 0x48, 0x83, 0xEC, 128 );
            $self->reset_assembly_state;
            for my $block (@$blocks) {
                $block_addresses{ $fq_name . '::' . $block->label } = length($bin);
                for my $inst ( @{ $block->instructions } ) {
                    $self->record_line_mapping( $inst, length($bin) );
                    my $op = $inst->op;
                    if ( $op eq 'ALLOCA' ) {
                        $self->get_offset( $inst->dest, $inst->type );
                    }
                    elsif ( $op eq 'STORE' ) {
                        my $slot      = $inst->srcs->[0];
                        my $val       = $inst->srcs->[1];
                        my $slot_off  = $self->get_offset($slot);
                        my $slot_type = $self->get_type($slot);
                        if ( $val =~ /^\d+$/ ) {
                            my $size     = $slot_type->byte_size;
                            my $off_byte = ( 256 + $slot_off ) % 256;
                            if ( $size == 1 ) {
                                $bin .= pack( "C3 C", 0xC6, 0x45, $off_byte, $val );
                            }
                            elsif ( $size == 2 ) {
                                $bin .= pack( "C4 S", 0x66, 0xC7, 0x45, $off_byte, $val );
                            }
                            elsif ( $size == 4 ) {
                                $bin .= pack( "C3 L", 0xC7, 0x45, $off_byte, $val );
                            }
                            else {
                                $bin .= pack( "C4 L", 0x48, 0xC7, 0x45, $off_byte, $val );
                            }
                        }
                        else {
                            my $val_off  = $self->get_offset($val);
                            my $val_type = $self->get_type($val);
                            $bin .= $self->emit_load_rax( $val_off, $val_type );
                            $bin .= $self->emit_store_rax( $slot_off, $slot_type );
                        }
                    }
                    elsif ( $op eq 'LOAD' ) {
                        my $dest      = $inst->dest;
                        my $slot      = $inst->srcs->[0];
                        my $dest_off  = $self->get_offset( $dest, $inst->type );
                        my $slot_off  = $self->get_offset($slot);
                        my $slot_type = $self->get_type($slot);
                        $bin .= $self->emit_load_rax( $slot_off, $slot_type );
                        $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                    }
                    elsif ( $op eq 'LOAD_ARG' ) {
                        my $dest     = $inst->dest;
                        my $idx      = $inst->srcs->[0];
                        my $dest_off = $self->get_offset( $dest, $inst->type );
                        $bin .= $self->emit_store_arg_reg( $dest_off, $idx, $inst->type );
                    }
                    elsif ( $op eq 'ADD' || $op eq 'SUB' || $op eq 'MUL' ) {
                        my $dest     = $inst->dest;
                        my $left     = $inst->srcs->[0];
                        my $right    = $inst->srcs->[1];
                        my $dest_off = $self->get_offset( $dest, $inst->type );
                        if ( $left =~ /^\d+$/ ) {
                            $bin .= pack "C3 L", 0x48, 0xC7, 0xC0, $left;
                        }
                        else {
                            my $left_off  = $self->get_offset($left);
                            my $left_type = $self->get_type($left);
                            $bin .= $self->emit_load_rax( $left_off, $left_type );
                        }
                        if ( $op eq 'ADD' ) {
                            if ( $right =~ /^\d+$/ ) {
                                $bin .= pack "C2 L", 0x48, 0x05, $right;
                            }
                            else {
                                my $right_off = $self->get_offset($right);
                                my $off_byte  = ( 256 + $right_off ) % 256;
                                $bin .= pack( "C4", 0x48, 0x8B, 0x4D, $off_byte );
                                $bin .= pack( "C3", 0x48, 0x01, 0xC8 );
                            }
                        }
                        elsif ( $op eq 'SUB' ) {
                            if ( $right =~ /^\d+$/ ) {
                                $bin .= pack "C2 L", 0x48, 0x2D, $right;
                            }
                            else {
                                my $right_off = $self->get_offset($right);
                                my $off_byte  = ( 256 + $right_off ) % 256;
                                $bin .= pack( "C4", 0x48, 0x8B, 0x4D, $off_byte );
                                $bin .= pack( "C3", 0x48, 0x29, 0xC8 );
                            }
                        }
                        elsif ( $op eq 'MUL' ) {
                            if ( $right =~ /^\d+$/ ) {
                                $bin .= pack "C3 L", 0x48, 0x69, 0xC0, $right;
                            }
                            else {
                                my $right_off = $self->get_offset($right);
                                my $off_byte  = ( 256 + $right_off ) % 256;
                                $bin .= pack( "C4", 0x48, 0x8B, 0x4D, $off_byte );
                                $bin .= pack( "C4", 0x48, 0x0F, 0xAF, 0xC1 );
                            }
                        }
                        $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                    }
                    elsif ( $op eq 'JUMP' ) {
                        my $target_label = $inst->srcs->[0];
                        $bin .= pack 'C', 0xE9;
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'BLOCK', target_label => $target_label };
                        $bin .= pack 'V', 0;
                    }
                    elsif ( $op eq 'JUMP_IF_FALSE' ) {
                        my $cond_reg     = $inst->srcs->[0];
                        my $target_label = $inst->srcs->[1];
                        my $cond_off     = $self->get_offset($cond_reg);
                        my $cond_type    = $self->get_type($cond_reg);
                        $bin .= $self->emit_load_rax( $cond_off, $cond_type );
                        $bin .= pack 'C3', 0x48, 0x85, 0xC0;
                        $bin .= pack 'C2', 0x0F, 0x84;
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'BLOCK', target_label => $target_label };
                        $bin .= pack 'V', 0;
                    }
                    elsif ( $op eq 'JUMP_IF_TRUE' ) {
                        my $cond_reg     = $inst->srcs->[0];
                        my $target_label = $inst->srcs->[1];
                        my $cond_off     = $self->get_offset($cond_reg);
                        my $cond_type    = $self->get_type($cond_reg);
                        $bin .= $self->emit_load_rax( $cond_off, $cond_type );
                        $bin .= pack 'C3', 0x48, 0x85, 0xC0;
                        $bin .= pack 'C2', 0x0F, 0x85;
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'BLOCK', target_label => $target_label };
                        $bin .= pack 'V', 0;
                    }
                    elsif ( $op eq 'ALLOC_OBJ' ) {
                        my $dest         = $inst->dest;
                        my $size         = $inst->srcs->[0];
                        my $dest_off     = $self->get_offset($dest);
                        my $payload_type = Brocken::Core::Type->new( name => 'Payload', size => $size );
                        my $payload_off  = $self->get_offset( "${dest}_payload", $payload_type );
                        $bin .= pack( "C4", 0x48, 0x8D, 0x45, ( 256 + $payload_off ) % 256 );
                        $bin .= $self->emit_store_rax( $dest_off, Brocken::Core::Type->new( name => 'Pointer' ) );
                    }
                    elsif ( $op eq 'GET_FIELD' ) {
                        my $dest     = $inst->dest;
                        my $obj      = $inst->srcs->[0];
                        my $offset   = $inst->srcs->[1];
                        my $dest_off = $self->get_offset($dest);
                        my $obj_off  = $self->get_offset($obj);
                        $bin .= pack( "C4", 0x48, 0x8B, 0x45, ( 256 + $obj_off ) % 256 );
                        $bin .= pack( "C4", 0x48, 0x8B, 0x48, $offset );
                        $bin .= pack( "C4", 0x48, 0x89, 0x4D, ( 256 + $dest_off ) % 256 );
                    }
                    elsif ( $op eq 'SET_FIELD' ) {
                        my $obj     = $inst->srcs->[0];
                        my $offset  = $inst->srcs->[1];
                        my $val     = $inst->srcs->[2];
                        my $obj_off = $self->get_offset($obj);
                        my $val_off = $self->get_offset($val);
                        $bin .= pack( "C4", 0x48, 0x8B, 0x45, ( 256 + $obj_off ) % 256 );
                        $bin .= pack( "C4", 0x48, 0x8B, 0x4D, ( 256 + $val_off ) % 256 );
                        $bin .= pack( "C4", 0x48, 0x89, 0x48, $offset );
                    }
                    elsif ( $op eq 'CALL' ) {
                        my $dest     = $inst->dest;
                        my $sub_name = $inst->srcs->[0];

                        # Load arguments into arg registers per System V AMD64 ABI
                        # arg0 → rdi(7), arg1 → rsi(6), arg2 → rdx(2), arg3 → rcx(1), arg4 → r8(8), arg5 → r9(9)
                        my @arg_regs = ( 7, 6, 2, 1, 8, 9 );
                        for my $i ( 1 .. $#{ $inst->srcs } ) {
                            my $arg = $inst->srcs->[$i];
                            my $rm  = $arg_regs[ $i - 1 ];
                            last unless defined $rm;
                            if ( $arg =~ /^\d+$/ ) {
                                my $rex = $rm >= 8 ? 0x49 : 0x48;
                                $bin .= pack "C3 V", $rex, 0xC7, 0xC0 | ( $rm & 7 ), $arg;
                            }
                            else {
                                my $arg_off  = $self->get_offset($arg);
                                my $arg_type = $self->get_type($arg);
                                $bin .= $self->emit_load_rax( $arg_off, $arg_type );
                                my $rex = $rm >= 8 ? 0x49 : 0x48;
                                $bin .= pack "C3", $rex, 0x89, 0xC0 | ( $rm & 7 );
                            }
                        }
                        $bin .= pack( "C", 0xE8 );
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'FUNCTION', target_label => $sub_name, };
                        $bin .= pack( "V", 0 );
                        if ( defined $dest ) {
                            my $dest_off = $self->get_offset($dest);
                            $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                        }
                    }
                    elsif ( $op eq 'CALL_METHOD' ) {
                        my $dest        = $inst->dest;
                        my $method_name = $inst->srcs->[0];
                        my $obj_ptr     = $inst->srcs->[1];
                        my $obj_off     = $self->get_offset($obj_ptr);
                        $bin .= pack( "C4", 0x48, 0x8B, 0x7D, ( 256 + $obj_off ) % 256 );
                        $bin .= pack( "C", 0xE8 );
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'FUNCTION', target_label => $method_name, };
                        $bin .= pack( "V", 0 );

                        if ( defined $dest ) {
                            my $dest_off = $self->get_offset($dest);
                            $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                        }
                    }
                    elsif ( $op eq 'SPAWN_FIBER' || $op eq 'ISOLATE_CREATE' ) {
                        my $body_func = $inst->srcs->[0];
                        $bin .= pack( "C3", 0x48, 0x8D, 0x05 );
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'FUNCTION', target_label => $body_func, };
                        $bin .= pack 'V', 0;
                        if ( defined $inst->dest ) {
                            my $dest_off = $self->get_offset( $inst->dest, $inst->type );
                            $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                        }
                    }
                    elsif ( $op eq 'YIELD' ) {

                        # YIELD is a no-op in sequential simulation
                    }
                    elsif ( $op eq 'TRANSFER' ) {
                        my $target      = $inst->srcs->[0];
                        my $target_off  = $self->get_offset($target);
                        my $target_type = $self->get_type($target);
                        $bin .= $self->emit_load_rax( $target_off, $target_type );
                        $bin .= pack( "C2", 0xFF, 0xD0 );
                    }
                    elsif ( $op eq 'SEND' ) {
                        my $target      = $inst->srcs->[0];
                        my $val         = $inst->srcs->[1];
                        my $target_off  = $self->get_offset($target);
                        my $target_type = $self->get_type($target);
                        if ( $val =~ /^\d+$/ ) {
                            $bin .= pack( "C3 L", 0x48, 0xC7, 0xC2, $val );
                        }
                        else {
                            my $val_off  = $self->get_offset($val);
                            my $val_type = $self->get_type($val);
                            $bin .= $self->emit_load_rax( $val_off, $val_type );
                            $bin .= pack( "C3", 0x48, 0x89, 0xC2 );
                        }
                        $bin .= pack( "C3", 0x48, 0x8D, 0x05 );
                        push @relocations,
                            {
                            patch_offset  => length($bin),
                            next_inst_off => length($bin) + 4,
                            type          => 'RIP_DATA',
                            target_label  => '__brocken_channel_data',
                            };
                        $bin .= pack 'V', 0;
                        $bin .= pack( "C3", 0x48, 0x89, 0x10 );
                        $bin .= pack( "C4", 0x48, 0x8B, 0x48, 0x08 );
                        $bin .= pack( "C3", 0x48, 0x85, 0xC9 );
                        $bin .= pack( "C2", 0x0F, 0x85 );
                        my $skip_call_patch = length($bin);
                        $bin .= pack 'V', 0;
                        $bin .= pack( "C4", 0x48, 0xC7, 0x40, 0x08 );
                        $bin .= pack( "C",  0x01 );
                        $bin .= $self->emit_load_rax( $target_off, $target_type );
                        $bin .= pack( "C2", 0xFF, 0xD0 );
                        $bin .= pack( "C3", 0x48, 0x8D, 0x05 );
                        push @relocations,
                            {
                            patch_offset  => length($bin),
                            next_inst_off => length($bin) + 4,
                            type          => 'RIP_DATA',
                            target_label  => '__brocken_channel_data',
                            };
                        $bin .= pack 'V', 0;
                        $bin .= pack( "C4", 0x48, 0x83, 0x68, 0x08 );
                        my $after_skip = length($bin);
                        my $skip_off   = $after_skip - ( $skip_call_patch + 4 );
                        substr $bin, $skip_call_patch, 4, pack 'V', $skip_off;
                    }
                    elsif ( $op eq 'RECEIVE' ) {
                        $bin .= pack( "C3", 0x48, 0x8D, 0x05 );
                        push @relocations,
                            {
                            patch_offset  => length($bin),
                            next_inst_off => length($bin) + 4,
                            type          => 'RIP_DATA',
                            target_label  => '__brocken_channel_data',
                            };
                        $bin .= pack 'V', 0;
                        $bin .= pack( "C4", 0x48, 0x8B, 0x00 );
                        if ( defined $inst->dest ) {
                            my $dest_off = $self->get_offset( $inst->dest, $inst->type );
                            $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                        }
                    }
                    elsif ( $op eq 'STRING_CONST' ) {
                        my $dest      = $inst->dest;
                        my $str_label = $inst->srcs->[0];
                        my $dest_off  = $self->get_offset( $dest, $inst->type );
                        $bin .= pack( "C3", 0x48, 0x8D, 0x05 );    # lea rax, [rip + label]
                        push @relocations,
                            { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'RIP_DATA', target_label => $str_label, };
                        $bin .= pack 'V', 0;
                        $bin .= $self->emit_store_rax( $dest_off, $inst->type );
                    }
                    elsif ( $op eq 'INIT_STDIO' ) {
                        if ($is_pe) {

                            # Get stdout/stderr handles from PEB and store in runtime data
                            # mov rax, gs:[0x60]        — PEB
                            $bin .= pack( "C9", 0x65, 0x48, 0x8B, 0x04, 0x25, 0x60, 0x00, 0x00, 0x00 );

                            # mov rax, [rax+0x20]       — ProcessParameters
                            $bin .= pack( "C4", 0x48, 0x8B, 0x40, 0x20 );

                            # mov rcx, [rax+0x28]       — StdOutput handle
                            $bin .= pack( "C4", 0x48, 0x8B, 0x48, 0x28 );

                            # mov rdx, [rax+0x30]       — StdError handle
                            $bin .= pack( "C4", 0x48, 0x8B, 0x50, 0x30 );

                            # lea rax, [rip + __brocken_runtime_data]
                            $bin .= pack( "C3", 0x48, 0x8D, 0x05 );
                            push @relocations,
                                {
                                patch_offset  => length($bin),
                                next_inst_off => length($bin) + 4,
                                type          => 'RIP_DATA',
                                target_label  => '__brocken_runtime_data',
                                };
                            $bin .= pack 'V', 0;

                            # mov [rax], rcx            — store stdout
                            $bin .= pack( "C3", 0x48, 0x89, 0x08 );

                            # mov [rax+8], rdx           — store stderr
                            $bin .= pack( "C4", 0x48, 0x89, 0x50, 0x08 );
                        }
                    }
                    elsif ( $op eq 'SAY' ) {
                        my $val = $inst->srcs->[0];
                        if ($is_pe) {
                            my $val_off  = $self->get_offset($val);
                            my $val_type = $self->get_type($val);
                            $bin .= $self->emit_load_rax( $val_off, $val_type );
                            my $length    = 0;
                            my $str_label = $inst->srcs->[1];
                            if ( defined $str_label ) {
                                my $string_constants = $program_blocks->{__string_constants} // {};
                                if ( exists $string_constants->{$str_label} ) {
                                    my $str_val = _process_escapes( $string_constants->{$str_label} );
                                    $length = length($str_val);
                                }
                            }

                            # mov rbx, rax   — save string addr in RBX
                            $bin .= pack( "C3", 0x48, 0x89, 0xC3 );

                            # sub rsp, 0x48  — allocate stack for NtWriteFile args (standard convention)
                            $bin .= pack( "C4", 0x48, 0x83, 0xEC, 0x48 );

                            # lea rax, [rip + __brocken_runtime_data]
                            $bin .= pack( "C3", 0x48, 0x8D, 0x05 );
                            push @relocations,
                                {
                                patch_offset  => length($bin),
                                next_inst_off => length($bin) + 4,
                                type          => 'RIP_DATA',
                                target_label  => '__brocken_runtime_data',
                                };
                            $bin .= pack 'V', 0;

                            # mov rdi, [rax]  — stdout handle from runtime data
                            $bin .= pack( "C3", 0x48, 0x8B, 0x38 );

                            # mov rcx, rdi   — FileHandle (1st arg)
                            $bin .= pack( "C3", 0x48, 0x89, 0xF9 );

                            # xor edx, edx   — Event = NULL (2nd arg)
                            $bin .= pack( "C2", 0x31, 0xD2 );

                            # xor r8d, r8d   — ApcRoutine = NULL (3rd arg)
                            $bin .= pack( "C3", 0x45, 0x31, 0xC0 );

                            # xor r9d, r9d   — ApcContext = NULL (4th arg)
                            $bin .= pack( "C3", 0x45, 0x31, 0xC9 );

                            # lea rax, [rsp+0x00]  — &IoStatusBlock (in shadow space)
                            $bin .= pack( "C5", 0x48, 0x8D, 0x44, 0x24, 0x00 );

                            # mov [rsp+0x20], rax  — 5th param (standard convention: [RSP+0x20])
                            $bin .= pack( "C5", 0x48, 0x89, 0x44, 0x24, 0x20 );

                            # mov [rsp+0x28], rbx  — 6th: Buffer (string addr)
                            $bin .= pack( "C5", 0x48, 0x89, 0x5C, 0x24, 0x28 );

                            # mov [rsp+0x30], length  — 7th: Length
                            $bin .= pack( "C5 L", 0x48, 0xC7, 0x44, 0x24, 0x30, $length );

                            # xor eax, eax
                            $bin .= pack( "C2", 0x31, 0xC0 );

                            # mov [rsp+0x38], rax  — 8th: ByteOffset = NULL
                            $bin .= pack( "C5", 0x48, 0x89, 0x44, 0x24, 0x38 );

                            # mov [rsp+0x40], rax  — 9th: Key = NULL
                            $bin .= pack( "C5", 0x48, 0x89, 0x44, 0x24, 0x40 );

                            # call [rip + disp] — through IAT to ntdll stub (avoids direct syscall)
                            $bin .= pack( "C2", 0xFF, 0x15 );
                            push @relocations, { patch_offset => length($bin), next_inst_off => length($bin) + 4, type => 'IAT_CALL', };
                            $bin .= pack 'V', 0;

                            # add rsp, 0x48  — restore stack
                            $bin .= pack( "C4", 0x48, 0x83, 0xC4, 0x48 );
                        }
                    }
                }
            }
            if ( $self->stack_offset != 0 ) {
                my $final_type = $self->last_type // Brocken::Core::Type->new( name => 'Any' );
                $bin .= $self->emit_load_rax( $self->stack_offset, $final_type );
            }
            if ($is_pe) {

                # Return from entry point — loader terminates process with RAX as exit code
                # leave restores RSP from RBP; then ret returns to loader
                $bin .= pack( "C", 0xC9 );    # leave
                $bin .= pack( "C", 0xC3 );    # ret
            }
            else {
                $bin .= pack 'C', 0xC9;
                $bin .= pack 'C', 0xC3;
            }
        }

        # ── Data sections (read-only: .text) ───────────────────────
        my %data_addresses;
        my $iat_entry_bin_off      = 0;
        my $import_descriptor_rva  = 0;
        my $import_descriptor_size = 0;
        my $writable_data_offset   = 0;
        my $desc_off               = 0;

        # 1. String constants (read-only)
        my $string_constants = $program_blocks->{__string_constants} // {};
        for my $label ( sort keys %$string_constants ) {
            $data_addresses{$label} = length($bin);
            my $str = _process_escapes( $string_constants->{$label} );
            $bin .= $str . "\x00";
        }

        # 2. Import table read-only parts (PE only)
        if ($is_pe) {
            my $ilt_entry_off = length($bin);
            $bin .= pack( "Q", 0 );                           # ILT entry (patched below to hint/name RVA)
            $bin .= pack( "Q", 0 );                           # ILT zero terminator
            my $hint_name_off = length($bin);
            $bin .= pack( "v", 0 );                           # hint (ordinal hint, 0)
            $bin .= "NtWriteFile\x00";
            my $hint_name_rva = 0x1000 + $hint_name_off;
            substr( $bin, $ilt_entry_off, 8, pack( "Q", $hint_name_rva ) );
            my $dll_name_off = length($bin);
            $bin .= "ntdll.dll\x00";
            $desc_off = length($bin);
            $bin .= pack( "V",  0x1000 + $ilt_entry_off );    # OriginalFirstThunk
            $bin .= pack( "V",  0 );                          # TimeDateStamp
            $bin .= pack( "V",  0 );                          # ForwarderChain
            $bin .= pack( "V",  0x1000 + $dll_name_off );     # Name
            $bin .= pack( "V",  0 );                          # FirstThunk placeholder (patched below)
            $bin .= pack( "V5", 0, 0, 0, 0, 0 );              # zero terminator descriptor
            $import_descriptor_rva  = 0x1000 + $desc_off;
            $import_descriptor_size = 40;
        }

        # ── Data sections (writable: .data) ─────────────────────────
        $writable_data_offset = length($bin);

        # 3. IAT (writable — patched by loader)
        if ($is_pe) {
            $iat_entry_bin_off = length($bin);

            # hint/name is at a known offset in .text, compute its RVA
            my $ilt_entry_off = unpack( "V", substr( $bin, $desc_off, 4 ) ) - 0x1000;
            my $hint_name_rva = 0x1000 + $ilt_entry_off + 16;
            $bin .= pack( "Q", $hint_name_rva );    # IAT entry (initial = hint/name RVA)
            $bin .= pack( "Q", 0 );                 # IAT zero terminator

            # Patch import descriptor FirstThunk with .data section RVA
            my $iat_rva = 0x2000 + ( $iat_entry_bin_off - $writable_data_offset );
            substr( $bin, $desc_off + 16, 4, pack( 'V', $iat_rva ) );
        }

        # 4. Runtime data (stdout/stderr handles for PE format)
        if ($is_pe) {
            $data_addresses{'__brocken_runtime_data'} = length($bin);
            $bin .= pack( "Q2", 0, 0 );
        }

        # 5. Channel data (for SEND/RECEIVE)
        my $has_rip_data = grep { $_->{type} eq 'RIP_DATA' } @relocations;
        if ($has_rip_data) {
            $data_addresses{'__brocken_channel_data'} = length($bin);
            $bin .= pack( "Q2", 0, 0 );
        }

        # ── Relocation resolution ───────────────────────────────────
        my $section_gap = $writable_data_offset ? ( 0x1000 - $writable_data_offset ) : 0;
        for my $reloc (@relocations) {
            my $target_addr;
            if ( $reloc->{type} eq 'BLOCK' ) {
                $target_addr = $block_addresses{ $reloc->{target_label} };
                if ( !defined $target_addr ) {
                    for my $fn ( keys %$program_blocks ) {
                        next if $fn eq '__string_constants';
                        $target_addr = $block_addresses{ $fn . '::' . $reloc->{target_label} };
                        last if defined $target_addr;
                    }
                }
            }
            elsif ( $reloc->{type} eq 'RIP_DATA' ) {
                $target_addr = $data_addresses{ $reloc->{target_label} };
                if ( !defined $target_addr ) {
                    die "Assembling Error: Data target '" . $reloc->{target_label} . "' is undefined\n";
                }
            }
            elsif ( $reloc->{type} eq 'IAT_CALL' ) {
                $target_addr = $iat_entry_bin_off;
                if ( !$target_addr ) {
                    die "Assembling Error: IAT not generated for IAT_CALL relocation\n";
                }
            }
            else {
                $target_addr = $function_addresses{ $reloc->{target_label} } // $function_addresses{ "Point::" . $reloc->{target_label} }
                    // $function_addresses{ "main::" . $reloc->{target_label} };
            }
            if ( !defined $target_addr ) {
                die "Assembling Error: Target '" . $reloc->{target_label} . "' is undefined\n";
            }
            my $rel_dist = $target_addr - $reloc->{next_inst_off};
            if ( $section_gap && $target_addr >= $writable_data_offset ) {
                $rel_dist += $section_gap;
            }
            substr $bin, $reloc->{patch_offset}, 4, pack 'V', $rel_dist;
        }
        return {
            binary                 => $bin,
            writable_data_offset   => $writable_data_offset,
            import_descriptor_rva  => $import_descriptor_rva,
            import_descriptor_size => $import_descriptor_size,
        };
    }
}
1;
