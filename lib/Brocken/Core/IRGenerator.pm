# lib/Brocken/Core/IRGenerator.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';
use Brocken::Core::IR;
use Brocken::Core::Scope;

class Brocken::Core::IRGenerator {
    field $temp_counter  = 0;
    field $block_counter = 0;
    field $current_scope = undef;
    field $blocks : reader = [];
    field $current_block : writer : reader = undef;

    # Active class metadata scope
    field $current_class = undef;

    # --- String constants: label => raw_value for string literals ---
    field $string_const_counter      = 0;
    field $string_constants : reader = {};
    field $temp_to_string            = {};    # temp_name => str_label mapping

    # --- Concurrency: separate program blocks ---
    # A hash of fq_name => [block_array] for fiber/isolate body functions.
    # The main function blocks are in $blocks (accessed via ->blocks).
    field $program_blocks : reader = {};
    ADJUST {
        $current_scope = Brocken::Core::Scope->new();
        $self->create_block('entry');

        # Prep INIT_STDIO at start of main to populate stdout/stderr handles from PEB
        $current_block->add_instruction( Brocken::Core::IR::Instruction->new( op => 'INIT_STDIO', dest => undef, srcs => [], type => 'Void' ) );
    }

    method create_block($label) {
        my $new_lbl = $label . "_" . $block_counter++;
        my $block   = Brocken::Core::IR::Block->new( label => $new_lbl );
        push @$blocks, $block;
        $current_block = $block;
        return $block;
    }

    method lower_body_blocks( $fq_name, $body_stmts ) {
        my $saved_blocks   = $blocks;
        my $saved_block    = $current_block;
        my $saved_scope    = $current_scope;
        my $saved_tcounter = $temp_counter;
        my $saved_bcounter = $block_counter;
        $blocks        = $program_blocks->{$fq_name};
        $current_scope = Brocken::Core::Scope->new();
        $temp_counter  = 0;
        $block_counter = 0;
        $self->create_block('entry');

        for my $stmt (@$body_stmts) {
            $self->lower_statement($stmt);
        }
        $program_blocks->{$fq_name} = $blocks;
        $blocks                     = $saved_blocks;
        $current_block              = $saved_block;
        $current_scope              = $saved_scope;
        $temp_counter               = $saved_tcounter;
        $block_counter              = $saved_bcounter;
    }

    method next_temp() {
        return "v" . $temp_counter++;
    }

    method lower_statement($node) {
        if ( $node->isa('Brocken::Core::AST::MyDecl') ) {
            my $slot_reg = $self->next_temp();

            # Forward the parsed Type object to the ALLOCA instruction instead of hardcoding 'Any'
            my $alloc_inst = Brocken::Core::IR::Instruction->new( op => 'ALLOCA', dest => $slot_reg, srcs => [], type => $node->type, );
            $current_block->add_instruction($alloc_inst);
            $current_scope->define( $node->name, $slot_reg );
            if ( defined $node->value ) {
                my $op = $node->default_op;
                if ( $op eq '=' ) {
                    my $init_val = $self->lower_expr( $node->value );
                    my $store_inst
                        = Brocken::Core::IR::Instruction->new( op => 'STORE', dest => undef, srcs => [ $slot_reg, $init_val ], type => $node->type, );
                    $current_block->add_instruction($store_inst);
                }
                else {
                    # Handle conditional parameters (//= or ||=)
                    my $default_block = $self->create_block('default');
                    my $merge_block   = $self->create_block('merge');

                    # Reference original block before allocations
                    my $orig_block = $blocks->[-3];
                    my $val_reg    = $self->next_temp();
                    $orig_block->add_instruction(
                        Brocken::Core::IR::Instruction->new( op => 'LOAD', dest => $val_reg, srcs => [$slot_reg], type => 'Any', ) );
                    my $check_reg = $self->next_temp();
                    my $check_op  = ( $op eq '//=' ) ? 'IS_DEF' : 'IS_TRUE';
                    $orig_block->add_instruction(
                        Brocken::Core::IR::Instruction->new( op => $check_op, dest => $check_reg, srcs => [$val_reg], type => 'Any', ) );
                    $orig_block->add_instruction(
                        Brocken::Core::IR::Instruction->new(
                            op   => 'JUMP_IF_TRUE',
                            dest => undef,
                            srcs => [ $check_reg, $merge_block->label ],
                            type => 'Any',
                        )
                    );
                    $orig_block->add_instruction(
                        Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $default_block->label ], type => 'Any', ) );

                    # Default Block
                    $current_block = $default_block;
                    my $init_val = $self->lower_expr( $node->value );
                    $current_block->add_instruction(
                        Brocken::Core::IR::Instruction->new( op => 'STORE', dest => undef, srcs => [ $slot_reg, $init_val ], type => 'Any', ) );
                    $current_block->add_instruction(
                        Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $merge_block->label ], type => 'Any', ) );

                    # Set Merge Block Active
                    $current_block = $merge_block;
                }
            }
            return;
        }
        if ( $node->isa('Brocken::Core::AST::If') ) {
            my $then_block  = $self->create_block('if_then');
            my $else_block  = defined $node->else_branch ? $self->create_block('if_else') : undef;
            my $merge_block = $self->create_block('if_merge');
            my $num_created = 2 + ( defined $else_block ? 1 : 0 );
            my $orig_block  = $blocks->[ -$num_created - 1 ];
            $current_block = $orig_block;
            my $cond_val     = $self->lower_expr( $node->condition );
            my $false_target = defined $else_block ? $else_block->label : $merge_block->label;
            $orig_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP_IF_FALSE', dest => undef, srcs => [ $cond_val, $false_target ], type => 'Any', ) );
            $orig_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $then_block->label ], type => 'Any', ) );

            # Lower Then branch
            $current_block = $then_block;
            for my $stmt ( @{ $node->then_branch } ) {
                $self->lower_statement($stmt);
            }
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $merge_block->label ], type => 'Any', ) );

            # Lower Else branch (or nested Elsif If node)
            if ( defined $else_block ) {
                $current_block = $else_block;
                if ( ref( $node->else_branch ) eq 'ARRAY' ) {
                    for my $stmt ( @{ $node->else_branch } ) {
                        $self->lower_statement($stmt);
                    }
                }
                else {
                    $self->lower_statement( $node->else_branch );
                }
                $current_block->add_instruction(
                    Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $merge_block->label ], type => 'Any', ) );
            }

            # Set Merge Block Active
            $current_block = $merge_block;
            return;
        }
        if ( $node->isa('Brocken::Core::AST::While') ) {
            my $cond_block = $self->create_block('while_cond');
            my $body_block = $self->create_block('while_body');
            my $exit_block = $self->create_block('while_exit');
            my $orig_block = $blocks->[-4];
            $current_block = $orig_block;
            $orig_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $cond_block->label ], type => 'Any', ) );
            $current_block = $cond_block;
            my $cond_val = $self->lower_expr( $node->condition );
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'JUMP_IF_FALSE',
                    dest => undef,
                    srcs => [ $cond_val, $exit_block->label ],
                    type => 'Any',
                )
            );
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $body_block->label ], type => 'Any', ) );
            $current_block = $body_block;

            for my $stmt ( @{ $node->body } ) {
                $self->lower_statement($stmt);
            }
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $cond_block->label ], type => 'Any', ) );
            $current_block = $exit_block;
            return;
        }
        if ( $node->isa('Brocken::Core::AST::Return') ) {
            if ( defined $node->value ) {
                my $val = $self->lower_expr( $node->value );
                $current_block->add_instruction(
                    Brocken::Core::IR::Instruction->new(
                        op   => 'RETURN',
                        dest => undef,
                        srcs => [$val],
                        type => 'Any',
                        line => $node->line,
                        col  => $node->col
                    )
                );
            }
            else {
                $current_block->add_instruction(
                    Brocken::Core::IR::Instruction->new(
                        op   => 'RETURN',
                        dest => undef,
                        srcs => [],
                        type => 'Void',
                        line => $node->line,
                        col  => $node->col
                    )
                );
            }
            return;
        }
        if ( $node->isa('Brocken::Core::AST::YieldStmt') ) {
            my @srcs;
            if ( defined $node->value ) {
                push @srcs, $self->lower_expr( $node->value );
            }
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'YIELD',
                    dest => undef,
                    srcs => \@srcs,
                    type => 'Void',
                    line => $node->line,
                    col  => $node->col
                )
            );
            return;
        }
        if ( $node->isa('Brocken::Core::AST::TransferStmt') ) {
            my $target = $self->lower_expr( $node->target );
            my @srcs   = ($target);
            if ( defined $node->value ) {
                push @srcs, $self->lower_expr( $node->value );
            }
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'TRANSFER',
                    dest => undef,
                    srcs => \@srcs,
                    type => 'Void',
                    line => $node->line,
                    col  => $node->col
                )
            );
            return;
        }
        if ( $node->isa('Brocken::Core::AST::SayStmt') ) {
            my $val  = $self->lower_expr( $node->value );
            my @srcs = ($val);
            if ( exists $temp_to_string->{$val} ) {
                push @srcs, $temp_to_string->{$val};
            }
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'SAY',
                    dest => undef,
                    srcs => \@srcs,
                    type => 'Void',
                    line => $node->line,
                    col  => $node->col
                )
            );
            return;
        }
        if ( $node->isa('Brocken::Core::AST::SendStmt') ) {
            my $target = $self->lower_expr( $node->target );
            my $val    = $self->lower_expr( $node->value );
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'SEND',
                    dest => undef,
                    srcs => [ $target, $val ],
                    type => 'Void',
                    line => $node->line,
                    col  => $node->col
                )
            );
            return;
        }
        my $expr_val = $self->lower_expr($node);
        if ( defined $expr_val ) {
            my $ret_reg = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'ALLOCA',
                    dest => $ret_reg,
                    srcs => [],
                    type => Brocken::Core::Type->new( name => 'Int' ),
                )
            );
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'STORE',
                    dest => undef,
                    srcs => [ $ret_reg, $expr_val ],
                    type => Brocken::Core::Type->new( name => 'Int' ),
                )
            );
        }
    }

    method lower_expr($node) {
        if ( $node->isa('Brocken::Core::AST::StringLiteral') ) {
            my $label = '__str_const_' . $string_const_counter++;
            $string_constants->{$label} = $node->value;
            my $dest = $self->next_temp();
            $temp_to_string->{$dest} = $label;
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'STRING_CONST', dest => $dest, srcs => [$label], type => 'String' ) );
            return $dest;
        }
        if ( $node->isa('Brocken::Core::AST::Literal') ) {
            return $node->value;
        }
        if ( $node->isa('Brocken::Core::AST::Variable') ) {
            my $slot_reg = $current_scope->lookup( $node->name );

            # If variable not declared in local scope, check if it is an active Class member field!
            if ( !defined $slot_reg && defined $current_class && exists $current_class->resolved_fields->{ $node->name } ) {

                # Load the field value dynamically relative to $self (register v0 / LOAD_ARG 0)
                my $self_ptr     = $current_scope->lookup('$self') or die "Compilation Error: Cannot access fields outside of method context\n";
                my $field_offset = $current_class->resolved_fields->{ $node->name }->memory_offset;
                my $field_type   = $current_class->resolved_fields->{ $node->name }->type;
                my $dest_reg     = $self->next_temp();
                $current_block->add_instruction(
                    Brocken::Core::IR::Instruction->new(
                        op   => 'GET_FIELD',
                        dest => $dest_reg,
                        srcs => [ $self_ptr, $field_offset ],
                        type => $field_type,
                    )
                );
                return $dest_reg;
            }
            if ( !defined $slot_reg ) {
                die "Compilation Error: Use of undeclared variable '" . $node->name . "' at line " . $node->line . "\n";
            }
            my $val_reg   = $self->next_temp();
            my $load_inst = Brocken::Core::IR::Instruction->new(
                op   => 'LOAD',
                dest => $val_reg,
                srcs => [$slot_reg],
                type => 'Any',
                line => $node->line,
                col  => $node->col
            );
            $current_block->add_instruction($load_inst);
            return $val_reg;
        }
        if ( $node->isa('Brocken::Core::AST::BinaryOp') ) {
            my $left_val  = $self->lower_expr( $node->left );
            my $right_val = $self->lower_expr( $node->right );
            my $dest      = $self->next_temp();
            my $opcode    = 'ADD';
            $opcode = 'SUB' if $node->op eq '-';
            $opcode = 'MUL' if $node->op eq '*';
            $opcode = 'DIV' if $node->op eq '/';
            my $inst = Brocken::Core::IR::Instruction->new(
                op   => $opcode,
                dest => $dest,
                srcs => [ $left_val, $right_val ],
                type => 'Int',
                line => $node->line,
                col  => $node->col
            );
            $current_block->add_instruction($inst);
            return $dest;
        }
        if ( $node->isa('Brocken::Core::AST::Assign') ) {
            my $var_name = $node->left->name;
            my $slot_reg = $current_scope->lookup($var_name);

            # Check for Class member field write access
            if ( !defined $slot_reg && defined $current_class && exists $current_class->resolved_fields->{$var_name} ) {
                my $self_ptr     = $current_scope->lookup('$self') or die "Compilation Error: Cannot access fields outside of method context\n";
                my $field_offset = $current_class->resolved_fields->{$var_name}->memory_offset;
                my $rhs_val      = $self->lower_expr( $node->right );
                $current_block->add_instruction(
                    Brocken::Core::IR::Instruction->new(
                        op   => 'SET_FIELD',
                        dest => undef,
                        srcs => [ $self_ptr, $field_offset, $rhs_val ],
                        type => 'Any',
                    )
                );
                return $rhs_val;
            }
            if ( !defined $slot_reg ) {
                die "Compilation Error: Variable '$var_name' must be declared before assignment at line " . $node->line . "\n";
            }
            my $rhs_val = $self->lower_expr( $node->right );
            my $inst    = Brocken::Core::IR::Instruction->new(
                op   => 'STORE',
                dest => undef,
                srcs => [ $slot_reg, $rhs_val ],
                type => 'Any',
                line => $node->line,
                col  => $node->col
            );
            $current_block->add_instruction($inst);
            return $rhs_val;
        }

        # Handle Subroutine Calls e.g. sum(15, 25)
        if ( $node->isa('Brocken::Core::AST::SubCall') ) {
            my @lowered_args = map { $self->lower_expr($_) } @{ $node->args };
            my $dest_reg     = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'CALL', dest => $dest_reg, srcs => [ $node->name, @lowered_args ], type => 'Any', ) );
            return $dest_reg;
        }

        # Handle Object-Oriented Infix Arrow Calls (new / method calls)
        if ( $node->isa('Brocken::Core::AST::MethodCall') ) {
            if ( $node->method_name eq 'new' ) {
                my $class_name = $node->invocand->name;

                # Fetch class metadata to resolve layout allocation size
                my $class_meta = Brocken::Core::Parser->new( tokens => [] )->classes->{$class_name};
                my $class_size = 32;
                if ( defined $class_meta ) {
                    require Brocken::Core::OOP::Resolver;
                    my $resolver = Brocken::Core::OOP::Resolver->new( class_registry => { $class_name => $class_meta } );
                    $class_size = $resolver->resolve_layout($class_name);
                }
                my $dest_reg = $self->next_temp();
                $current_block->add_instruction(
                    Brocken::Core::IR::Instruction->new(
                        op   => 'ALLOC_OBJ',
                        dest => $dest_reg,
                        srcs => [ $class_size, $class_name ],
                        type => 'Pointer',
                    )
                );
                return $dest_reg;
            }
            else {
                # Standard Method Dispatch
                my $obj_ptr      = $self->lower_expr( $node->invocand );
                my @lowered_args = map { $self->lower_expr($_) } @{ $node->args };
                my $dest_reg     = $self->next_temp();
                $current_block->add_instruction(
                    Brocken::Core::IR::Instruction->new(
                        op   => 'CALL_METHOD',
                        dest => $dest_reg,
                        srcs => [ $node->method_name, $obj_ptr, @lowered_args ],
                        type => 'Any',
                    )
                );
                return $dest_reg;
            }
        }
        if ( $node->isa('Brocken::Core::AST::FiberBlock') ) {
            my $fq_name = 'fiber_body_' . $block_counter++;
            $self->lower_body_blocks( $fq_name, $node->body );
            my $dest_reg = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'SPAWN_FIBER',
                    dest => $dest_reg,
                    srcs => [$fq_name],
                    type => 'Pointer',
                    line => $node->line,
                    col  => $node->col
                )
            );
            return $dest_reg;
        }
        if ( $node->isa('Brocken::Core::AST::IsolateBlock') ) {
            my $fq_name = 'isolate_body_' . $block_counter++;
            $self->lower_body_blocks( $fq_name, $node->body );
            my $dest_reg = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'ISOLATE_CREATE',
                    dest => $dest_reg,
                    srcs => [$fq_name],
                    type => 'Pointer',
                    line => $node->line,
                    col  => $node->col
                )
            );
            return $dest_reg;
        }
        if ( $node->isa('Brocken::Core::AST::ReceiveExpr') ) {
            my $dest_reg = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'RECEIVE',
                    dest => $dest_reg,
                    srcs => [],
                    type => 'Any',
                    line => $node->line,
                    col  => $node->col
                )
            );
            return $dest_reg;
        }
        die "Lowering Error: Unknown AST Node: " . ref($node);
    }

    # Compiles an entire Method and returns its collection of basic blocks
    method lower_method( $node, $enclosing_class = undef ) {
        $current_class = $enclosing_class;

        # 1. Reset compiling context for a fresh function compilation
        $temp_counter  = 0;
        $block_counter = 0;
        $blocks        = [];
        $current_scope = Brocken::Core::Scope->new();
        $self->create_block('entry');

        # Inside a class method, Parameter 0 is always the implicit $self pointer
        if ( defined $current_class ) {
            my $self_slot = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'ALLOCA', dest => $self_slot, srcs => [], type => 'Pointer', ) );
            $current_scope->define( '$self', $self_slot );
            my $arg_reg = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'LOAD_ARG', dest => $arg_reg, srcs => [0], type => 'Pointer', ) );
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'STORE', dest => undef, srcs => [ $self_slot, $arg_reg ], type => 'Pointer', ) );
        }

        # 2. Process method signature and bind parameters (start at argument index 1 if $self is present)
        my $arg_idx = defined $current_class ? 1 : 0;
        for my $param ( @{ $node->signature->params } ) {

            # Map each parameter to an ALLOCA stack slot
            my $slot_reg = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'ALLOCA', dest => $slot_reg, srcs => [], type => $param->type, ) );
            $current_scope->define( $param->name, $slot_reg );

            # Load the parameter value from the execution context (arg index)
            my $arg_reg = $self->next_temp();
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'LOAD_ARG', dest => $arg_reg, srcs => [$arg_idx], type => $param->type, ) );

            # Store argument register into parameter stack slot
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'STORE', dest => undef, srcs => [ $slot_reg, $arg_reg ], type => $param->type, ) );

            # 3. If parameter contains default handlers (//= or ||=), lower them
            if ( defined $param->default_expr ) {
                my $decl_ast = Brocken::Core::AST::MyDecl->new(
                    name       => $param->name,
                    value      => $param->default_expr,
                    default_op => $param->default_op,
                    line       => $param->line,
                    col        => $param->col
                );
                delete $current_scope->symbols->{ $param->name };
                $self->lower_statement($decl_ast);
            }
            $arg_idx++;
        }

        # 4. Compile the method body
        for my $stmt ( @{ $node->body } ) {
            $self->lower_statement($stmt);
        }
        return $blocks;
    }
}
1;
