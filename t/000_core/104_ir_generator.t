use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::IR;
use Brocken::Core::IRGenerator;

# Helper 1: Returns raw basic blocks
sub compile_to_blocks($code) {
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $tokens = $lexer->tokenize();
    my $parser = Brocken::Core::Parser->new( tokens => $tokens );
    my @statements;
    while ( $parser->peek->type ne 'EOF' ) {
        push @statements, $parser->parse_statement();
    }
    my $generator = Brocken::Core::IRGenerator->new();
    for my $stmt (@statements) {
        $generator->lower_statement($stmt);
    }
    return $generator->blocks;
}

# Helper 2: Flattens all instructions across all blocks for sequence checks
sub compile_to_instructions($code) {
    my $blocks = compile_to_blocks($code);
    return [ map { @{ $_->instructions } } @$blocks ];
}
subtest 'Lexical Declaration & Initialization' => sub {
    my $code  = 'my $x = 42;';
    my $insts = compile_to_instructions($code);
    is( @$insts,         3,            'emitted exactly 3 instructions for declaration and assignment' );
    is( $insts->[0]->op, 'INIT_STDIO', 'first instruction is INIT_STDIO' );

    # v0 = ALLOCA
    is( $insts->[1]->op, 'ALLOCA', 'second instruction is ALLOCA' );
    ok( defined $insts->[1]->dest, 'ALLOCA has a destination register' );

    # STORE v0, 42
    is( $insts->[2]->op,        'STORE',           'third instruction is STORE' );
    is( $insts->[2]->srcs->[0], $insts->[1]->dest, 'STORE destination targets the ALLOCA register' );
    is( $insts->[2]->srcs->[1], 42,                'STORE source value is the literal 42' );
};
subtest 'Variable Reads & Binary Arithmetic' => sub {
    my $code = q{
        my $x = 10;
        my $y = $x + 5;
    };
    my $insts = compile_to_instructions($code);

    # Expected Sequence:
    # 0: INIT_STDIO
    # 1: v0 = ALLOCA
    # 2: STORE v0, 10
    # 3: v1 = ALLOCA
    # 4: v2 = LOAD v0
    # 5: v3 = ADD v2, 5
    # 6: STORE v1, v3
    is( @$insts,         7,            'emitted exactly 7 instructions' );
    is( $insts->[0]->op, 'INIT_STDIO', 'instruction 0 is INIT_STDIO' );
    my $x_slot = $insts->[1]->dest;
    my $y_slot = $insts->[3]->dest;
    is( $insts->[4]->op,        'LOAD',  'instruction 4 is LOAD' );
    is( $insts->[4]->srcs->[0], $x_slot, 'LOAD reads from $x slot' );
    my $loaded_val_reg = $insts->[4]->dest;
    is( $insts->[5]->op,        'ADD',           'instruction 5 is ADD' );
    is( $insts->[5]->srcs->[0], $loaded_val_reg, 'ADD reads the loaded value of $x' );
    is( $insts->[5]->srcs->[1], 5,               'ADD adds literal 5' );
    my $add_result_reg = $insts->[5]->dest;
    is( $insts->[6]->op,        'STORE',         'instruction 6 is STORE' );
    is( $insts->[6]->srcs->[0], $y_slot,         'STORE targets the $y slot' );
    is( $insts->[6]->srcs->[1], $add_result_reg, 'STORE writes the output of the ADD calculation' );
};
subtest 'Compile-Time Variable Scope Violations' => sub {

    # Test 1: Assignment to undeclared variable
    like(
        dies { compile_to_instructions('$z = 100;') },
        qr/Compilation Error: Variable '\$z' must be declared before assignment/,
        'fails to assign to an undeclared variable'
    );

    # Test 2: Reading an undeclared variable
    like(
        dies { compile_to_instructions('my $a = $b;') },
        qr/Compilation Error: Use of undeclared variable '\$b'/,
        'fails to read from an undeclared variable'
    );
};
subtest 'Defined-OR Parameter Defaulting (//=)' => sub {
    my $code   = 'my $id //= 999;';
    my $blocks = compile_to_blocks($code);
    is( @$blocks, 3, 'generates exactly 3 blocks: entry, default, and merge' );
    my ( $entry, $default, $merge ) = @$blocks;
    like( $entry->label,   qr/^entry_\d+$/,   'entry block labeled correctly' );
    like( $default->label, qr/^default_\d+$/, 'default block labeled correctly' );
    like( $merge->label,   qr/^merge_\d+$/,   'merge block labeled correctly' );

    # Entry Block Analysis
    my $e_insts = $entry->instructions;
    is( $e_insts->[0]->op,        'INIT_STDIO',    'initializes stdio' );
    is( $e_insts->[1]->op,        'ALLOCA',        'allocates variable space' );
    is( $e_insts->[2]->op,        'LOAD',          'loads slot value to check definedness' );
    is( $e_insts->[3]->op,        'IS_DEF',        'applies IS_DEF check' );
    is( $e_insts->[4]->op,        'JUMP_IF_TRUE',  'conditional jump setup' );
    is( $e_insts->[4]->srcs->[1], $merge->label,   'JUMP_IF_TRUE targets the merge block' );
    is( $e_insts->[5]->op,        'JUMP',          'unconditional fall-through jump' );
    is( $e_insts->[5]->srcs->[0], $default->label, 'unconditional JUMP targets the default block' );

    # Default Block Analysis
    my $d_insts = $default->instructions;
    is( $d_insts->[0]->op,        'STORE',       'default block assigns default value' );
    is( $d_insts->[0]->srcs->[1], 999,           'default value assigned is 999' );
    is( $d_insts->[1]->op,        'JUMP',        'jumps out of default block' );
    is( $d_insts->[1]->srcs->[0], $merge->label, 'jump targets the merge block' );
};
subtest 'Logical-OR Parameter Defaulting (||=)' => sub {
    my $code    = 'my $flag ||= 1;';
    my $blocks  = compile_to_blocks($code);
    my $entry   = $blocks->[0];
    my $e_insts = $entry->instructions;
    is( $e_insts->[3]->op, 'IS_TRUE', 'applies IS_TRUE check for ||= operator' );
};
subtest 'Conditional Flow Routing (if / elsif / else)' => sub {
    my $code = q{
        my $x = 1;
        my $y = 0;
        if ($x) {
            $y = 10;
        }
        elsif ($y) {
            $y = 20;
        }
        else {
            $y = 30;
        }
    };
    my $blocks = compile_to_blocks($code);

    # We expect our structure to compile into nested basic blocks:
    # 0: entry
    # 1: if_then (for $x)
    # 2: if_else (which hosts the inner if evaluation block)
    # 3: if_merge (for the outer if block)
    # 4: if_then (for inner $y)
    # 5: if_else (for final else fallback block)
    # 6: if_merge (for inner elsif block)
    ok( @$blocks >= 5, 'generates multi-tier nested conditional routing blocks' );

    # Validate that block naming schemes align correctly
    my @labels = map { $_->label } @$blocks;
    ok( ( grep {/^if_then_\d+$/} @labels ),  'emitted if_then blocks' );
    ok( ( grep {/^if_else_\d+$/} @labels ),  'emitted if_else blocks' );
    ok( ( grep {/^if_merge_\d+$/} @labels ), 'emitted if_merge blocks' );

    # Ensure termination jumps redirect to correct exit merge targets
    my $outer_merge      = $blocks->[3]->label;
    my $inner_then_insts = $blocks->[4]->instructions;
    is( $inner_then_insts->[-1]->op, 'JUMP', 'inner then statement block successfully terminates with an unconditional jump' );
};
subtest 'Cyclic Control Flow (while loop backward jumps)' => sub {
    my $code = q{
        my $x = 5;
        while ($x) {
            $x = $x - 1;
        }
    };
    my $blocks = compile_to_blocks($code);

    # We expect 4 blocks: entry, while_cond, while_body, and while_exit
    is( @$blocks, 4, 'emitted exactly 4 blocks for loop compilation' );
    my ( $entry, $cond, $body, $exit ) = @$blocks;
    like( $entry->label, qr/^entry_\d+$/,      'entry block generated' );
    like( $cond->label,  qr/^while_cond_\d+$/, 'loop condition block generated' );
    like( $body->label,  qr/^while_body_\d+$/, 'loop body block generated' );
    like( $exit->label,  qr/^while_exit_\d+$/, 'loop exit block generated' );

    # Validate backward loop edge in body block
    my $b_insts = $body->instructions;
    is( $b_insts->[-1]->op,        'JUMP',       'last instruction of loop body is a JUMP' );
    is( $b_insts->[-1]->srcs->[0], $cond->label, 'unconditional JUMP links backward to condition block' );

    # Validate condition exit path
    my $c_insts = $cond->instructions;
    is( $c_insts->[-2]->op,        'JUMP_IF_FALSE', 'conditional branch exits loop if false' );
    is( $c_insts->[-2]->srcs->[1], $exit->label,    'JUMP_IF_FALSE targets exit block' );
};
#
done_testing;
