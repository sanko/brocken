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
    ADJUST {
        $current_scope = Brocken::Core::Scope->new();
        $self->create_block('entry');
    }

    method create_block($label) {
        my $new_lbl = $label . "_" . $block_counter++;
        my $block   = Brocken::Core::IR::Block->new( label => $new_lbl );
        push @$blocks, $block;
        $current_block = $block;
        return $block;
    }

    method next_temp() {
        return "v" . $temp_counter++;
    }

    method lower_statement($node) {
        if ( $node->isa('Brocken::Core::AST::MyDecl') ) {
            my $slot_reg   = $self->next_temp();
            my $alloc_inst = Brocken::Core::IR::Instruction->new( op => 'ALLOCA', dest => $slot_reg, srcs => [], type => 'Any', );
            $current_block->add_instruction($alloc_inst);
            $current_scope->define( $node->name, $slot_reg );
            if ( defined $node->value ) {
                my $op = $node->default_op;
                if ( $op eq '=' ) {
                    my $init_val = $self->lower_expr( $node->value );
                    my $store_inst
                        = Brocken::Core::IR::Instruction->new( op => 'STORE', dest => undef, srcs => [ $slot_reg, $init_val ], type => 'Any', );
                    $current_block->add_instruction($store_inst);
                }
                else {
                    # Handle conditional parameters (//= or ||=)
                    my $default_block = $self->create_block('default');
                    my $merge_block   = $self->create_block('merge');

                    # Reference the original entry block before new creations
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

            # Allocate structural basic blocks
            my $cond_block = $self->create_block('while_cond');
            my $body_block = $self->create_block('while_body');
            my $exit_block = $self->create_block('while_exit');

            # Locate original block before our allocations (3 blocks created)
            my $orig_block = $blocks->[-4];

            # In the original block, jump unconditionally into the loop condition evaluator
            $current_block = $orig_block;
            $orig_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $cond_block->label ], type => 'Any', ) );

            # Compile the loop condition evaluator
            $current_block = $cond_block;
            my $cond_val = $self->lower_expr( $node->condition );

            # If false, break out to the exit block
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new(
                    op   => 'JUMP_IF_FALSE',
                    dest => undef,
                    srcs => [ $cond_val, $exit_block->label ],
                    type => 'Any',
                )
            );

            # If true, continue into the loop body
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $body_block->label ], type => 'Any', ) );

            # Compile the loop body
            $current_block = $body_block;
            for my $stmt ( @{ $node->body } ) {
                $self->lower_statement($stmt);
            }

            # Unconditional backward jump back to re-evaluate condition
            $current_block->add_instruction(
                Brocken::Core::IR::Instruction->new( op => 'JUMP', dest => undef, srcs => [ $cond_block->label ], type => 'Any', ) );

            # Set loop exit block active for any trailing code
            $current_block = $exit_block;
            return;
        }
        $self->lower_expr($node);
    }

    method lower_expr($node) {
        if ( $node->isa('Brocken::Core::AST::Literal') ) {
            return $node->value;
        }
        if ( $node->isa('Brocken::Core::AST::Variable') ) {
            my $slot_reg = $current_scope->lookup( $node->name );
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
        die "Lowering Error: Unknown AST Node: " . ref($node);
    }

    # Compiles an entire Method and returns its collection of basic blocks
    method lower_method($node) {

        # Reset compiling context for a fresh function compilation
        $temp_counter  = 0;
        $block_counter = 0;
        $blocks        = [];
        $current_scope = Brocken::Core::Scope->new();
        $self->create_block('entry');

        # Process method signature and bind parameters
        my $arg_idx = 0;
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

            # If parameter contains default handlers (//= or ||=), lower them
            if ( defined $param->default_expr ) {

                # We can reuse our robust lexical-defaulting AST structures!
                my $decl_ast = Brocken::Core::AST::MyDecl->new(
                    name       => $param->name,
                    value      => $param->default_expr,
                    default_op => $param->default_op,
                    line       => $param->line,
                    col        => $param->col
                );

                # Temporarily remove parameter name from scope so our declaration
                # re-entry does not trigger an "already defined" scope collision
                delete $current_scope->symbols->{ $param->name };
                $self->lower_statement($decl_ast);
            }
            $arg_idx++;
        }

        # Compile the method body
        for my $stmt ( @{ $node->body } ) {
            $self->lower_statement($stmt);
        }
        return $blocks;
    }
}
