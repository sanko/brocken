use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
use Brocken::Compiler::Lowerer;
use Brocken::AST;

sub lower_source {
    my ($source) = @_;
    my $lowerer  = Brocken::Compiler::Lowerer->new();
    my $lexer    = Brocken::Lexer->new( source => $source );
    my $parser   = Brocken::Parser->new( lexer => $lexer );
    my $ast      = $parser->parse();
    return $lowerer->lower($ast);
}

sub last_instr_str {
    my ($cfg) = @_;
    my @instr = $cfg->entry_block->instructions;
    return $instr[-1]->to_string;
}

sub first_instr_str {
    my ($cfg) = @_;
    my @instr = $cfg->entry_block->instructions;
    return $instr[0]->to_string;
}

# ===== OurDecl =====
subtest 'our $x = 42' => sub {
    my $cfg   = lower_source('our $x = 42;');
    my @instr = $cfg->entry_block->instructions;
    is( scalar @instr,        2,               'two instructions' );
    is( $instr[0]->to_string, 'v0 = 42',       'literal assigned to vreg' );
    is( $instr[1]->to_string, 'store $x = v0', 'store to our var' );
    like( $cfg->entry_block->terminator->to_string, qr/ret/, 'terminator is return' );
};
subtest 'our $x without value' => sub {
    my $cfg   = lower_source('our $x;');
    my @instr = $cfg->entry_block->instructions;
    is( scalar @instr, 0, 'no instructions without value' );
};

# ===== StateDecl =====
subtest 'state $x = 99' => sub {
    my $cfg   = lower_source('state $x = 99;');
    my @instr = $cfg->entry_block->instructions;
    is( scalar @instr,        2,               'two instructions' );
    is( $instr[0]->to_string, 'v0 = 99',       'literal assigned to vreg' );
    is( $instr[1]->to_string, 'store $x = v0', 'store to state var' );
};

# ===== MethodCall =====
subtest '$o->method(42)' => sub {
    my $cfg   = lower_source('$o->method(42);');
    my @instr = $cfg->entry_block->instructions;
    cmp_ok( scalar @instr, '>=', 3, 'has instructions' );
    my $call = $instr[-1];
    like( $call->to_string, qr/v\d+ = call method_call\(/, 'last instruction is method_call' );
    like( $call->to_string, qr/v0/,                        'uses object vreg' );
    like( $call->to_string, qr/v1/,                        'uses arg vreg' );
};
subtest 'method_call in expression' => sub {
    my $cfg   = lower_source('my $x = $o->method(42);');
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call method_call\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'method_call found in instructions' );
};

# ===== IndexExpr =====
subtest '$a[0] index access' => sub {
    my $cfg   = lower_source('$a[0];');
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call index_get\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'index_get call found' );
};

# ===== Exit =====
subtest 'exit(42)' => sub {
    my $cfg   = lower_source('exit(42);');
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call exit\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'exit call found' );
    like( $call, qr/v0/, 'arg is v0 (literal 42)' );
};
subtest 'exit without arg' => sub {
    my $cfg   = lower_source('exit();');
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call exit\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'exit call found with no args' );
};

# ===== Die =====
subtest 'die("msg")' => sub {
    my $cfg   = lower_source('die("msg");');
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call die\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'die call found' );
};
subtest 'die without arg' => sub {
    my $cfg   = lower_source('die();');
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call die\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'die call found with no args' );
};

# Helper: wrap an Expr node as a VarDecl so lower_stmt can handle it
sub wrap_as_stmt {
    my ($expr) = @_;
    return Brocken::AST::Stmt::VarDecl->new( name => '_', type => 'Any', value => $expr );
}

# ===== Direct AST construction tests =====
subtest 'Expr::NilLiteral' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower( [ wrap_as_stmt( Brocken::AST::Expr::NilLiteral->new( value => 'undef', type => 'Undef' ) ) ] );
    my @instr   = $cfg->entry_block->instructions;
    is( scalar @instr,        2,            'two instructions (assign + store)' );
    is( $instr[0]->to_string, 'v0 = undef', 'nil literal is undef' );
};
subtest 'Expr::AnonCall' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   wrap_as_stmt(
                Brocken::AST::Expr::AnonCall->new(
                    invocant => Brocken::AST::Expr::Var->new( name => 'f' ),
                    args     => [ Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' ) ]
                )
            )
        ]
    );
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call anon_call\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'anon_call found' );
    like( $call, qr/v0, v1/, 'invocant and arg referenced' );
};
subtest 'Expr::ArrayLiteral' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   wrap_as_stmt(
                Brocken::AST::Expr::ArrayLiteral->new(
                    elements => [
                        Brocken::AST::Expr::IntLiteral->new( value => 10, type => 'Int' ),
                        Brocken::AST::Expr::IntLiteral->new( value => 20, type => 'Int' )
                    ]
                )
            )
        ]
    );
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call array_literal\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'array_literal found' );
    like( $call, qr/2, /, 'count arg is 2' );
};
subtest 'Expr::HashLiteral' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   wrap_as_stmt(
                Brocken::AST::Expr::HashLiteral->new(
                    pairs => [
                        {   key   => Brocken::AST::Expr::StrLiteral->new( value => 'a', type => 'String' ),
                            value => Brocken::AST::Expr::IntLiteral->new( value => 1,   type => 'Int' )
                        }
                    ]
                )
            )
        ]
    );
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call hash_literal\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'hash_literal found' );
};
subtest 'Expr::TupleLiteral' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   wrap_as_stmt(
                Brocken::AST::Expr::TupleLiteral->new(
                    elements => [
                        Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' ),
                        Brocken::AST::Expr::IntLiteral->new( value => 2, type => 'Int' ),
                        Brocken::AST::Expr::IntLiteral->new( value => 3, type => 'Int' )
                    ]
                )
            )
        ]
    );
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call tuple_literal\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'tuple_literal found' );
    like( $call, qr/3, v\d+, v\d+, v\d+/, '3 elements in tuple' );
};
subtest 'Expr::Exists' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower( [ wrap_as_stmt( Brocken::AST::Expr::Exists->new( expr => Brocken::AST::Expr::Var->new( name => 'h' ) ) ) ] );
    my @instr   = $cfg->entry_block->instructions;
    my $call    = ( grep {/call exists\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'exists call found' );
};
subtest 'Expr::Delete' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower( [ wrap_as_stmt( Brocken::AST::Expr::Delete->new( expr => Brocken::AST::Expr::Var->new( name => 'h' ) ) ) ] );
    my @instr   = $cfg->entry_block->instructions;
    my $call    = ( grep {/call delete\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'delete call found' );
};

# ===== Stmt::Map (direct AST) =====
subtest 'Expr::Stmt::Map' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   Brocken::AST::Stmt::Map->new(
                expr   => Brocken::AST::Expr::Var->new( name => 'f' ),
                source => Brocken::AST::Expr::Var->new( name => 'a' )
            )
        ]
    );
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call map\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'map call found' );
};

# ===== Stmt::Exit (direct AST) =====
subtest 'Stmt::Exit (direct)' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower( [ Brocken::AST::Stmt::Exit->new( expr => Brocken::AST::Expr::IntLiteral->new( value => 0, type => 'Int' ) ) ] );
    my @instr   = $cfg->entry_block->instructions;
    my $call    = ( grep {/call exit\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'exit call found via Stmt::Exit' );
};

# ===== Stmt::Yada (direct AST) =====
subtest 'Stmt::Yada' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower( [ Brocken::AST::Stmt::Yada->new() ] );
    my @instr   = $cfg->entry_block->instructions;
    cmp_ok( scalar @instr, '>', 0, 'has instructions (die with msg)' );
    my $call = ( grep {/call die\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'die call emitted for yada' );
};

# ===== Stmt::Eval throws =====
subtest 'Stmt::Eval throws' => sub {
    my $lowerer   = Brocken::Compiler::Lowerer->new();
    my $eval_node = Brocken::AST::Stmt::Eval->new( code => Brocken::AST::Stmt::Block->new( statements => [] ) );
    eval { $lowerer->lower( [$eval_node] ) };
    like( $@, qr/disabled/i, 'Eval throws "disabled"' );
};

# ===== Stmt::Use (direct AST) =====
subtest 'Stmt::Use' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower( [ Brocken::AST::Stmt::Use->new( package => 'Foo' ) ] );
    my @instr   = $cfg->entry_block->instructions;
    cmp_ok( scalar @instr,                                       '>', 0, 'has instructions (no-op assign)' );
    cmp_ok( scalar( grep {/= 1/} map { $_->to_string } @instr ), '>', 0, 'assigns 1 as no-op' );
};
subtest 'Stmt::Require' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower( [ Brocken::AST::Stmt::Require->new( package => 'Bar' ) ] );
    my @instr   = $cfg->entry_block->instructions;
    cmp_ok( scalar @instr,                                       '>', 0, 'has instructions (no-op assign)' );
    cmp_ok( scalar( grep {/= 1/} map { $_->to_string } @instr ), '>', 0, 'assigns 1 as no-op' );
};

# ===== Exception::Die (direct AST) =====
subtest 'Exception::Die' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   wrap_as_stmt(
                Brocken::AST::Exception::Die->new( exception => Brocken::AST::Expr::StrLiteral->new( value => 'oops', type => 'String' ) )
            )
        ]
    );
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call die\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'die call found from Exception::Die' );
};
subtest 'Exception::Die without arg' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower( [ Brocken::AST::Exception::Die->new( exception => undef ) ] );
    my @instr   = $cfg->entry_block->instructions;
    my $call    = ( grep {/call die\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'die call found from Exception::Die with no args' );
};

# ===== Exception::TryCatch (direct AST) =====
subtest 'Exception::TryCatch' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   Brocken::AST::Exception::TryCatch->new(
                try_block   => Brocken::AST::Stmt::Block->new( statements => [ Brocken::AST::Expr::Call->new( name => 'print', args => [] ) ] ),
                catch_var   => 'err',
                catch_block => Brocken::AST::Stmt::Block->new( statements => [ Brocken::AST::Expr::Call->new( name => 'die', args => [] ) ] ),
            )
        ]
    );
    my @instr      = $cfg->entry_block->instructions;
    my $print_call = ( grep {/call print\(/} map { $_->to_string } @instr )[0];
    my $die_call   = ( grep {/call die\(/} map { $_->to_string } @instr )[0];
    ok( defined $print_call, 'try block lowered (print call found)' );
    ok( defined $die_call,   'catch block lowered (die call found)' );
};

# ===== OOP::ClassDecl (direct AST) =====
subtest 'OOP::ClassDecl' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   Brocken::AST::OOP::ClassDecl->new(
                name    => 'MyClass',
                fields  => [],
                methods => [
                    Brocken::AST::OOP::Method->new(
                        name   => 'greet',
                        params => [],
                        body   => Brocken::AST::Stmt::Block->new(
                            statements => [
                                Brocken::AST::Expr::Call->new(
                                    name => 'print',
                                    args => [ Brocken::AST::Expr::StrLiteral->new( value => 'hi', type => 'String' ) ]
                                )
                            ]
                        ),
                    )
                ],
            )
        ]
    );
    my @instr      = $cfg->entry_block->instructions;
    my $class_call = ( grep {/call class_register\(/} map { $_->to_string } @instr )[0];
    ok( defined $class_call, 'class_register call found' );
};

# ===== NativeDecl throws =====
subtest 'NativeDecl throws' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    eval { $lowerer->lower( [ Brocken::AST::NativeDecl->new( library => 'c', name => 'strlen', signature => {} ) ] ) };
    like( $@, qr/not supported/i, 'NativeDecl throws not supported' );
};

# ===== Stmt::Defer (direct AST) =====
subtest 'Stmt::Defer (inline execution)' => sub {
    my $lowerer = Brocken::Compiler::Lowerer->new();
    my $cfg     = $lowerer->lower(
        [   Brocken::AST::Stmt::Defer->new(
                block => Brocken::AST::Stmt::Block->new(
                    statements => [
                        Brocken::AST::Expr::Call->new(
                            name => 'print',
                            args => [ Brocken::AST::Expr::StrLiteral->new( value => 'deferred', type => 'String' ) ]
                        )
                    ]
                )
            )
        ]
    );
    my @instr = $cfg->entry_block->instructions;
    my $call  = ( grep {/call print\(/} map { $_->to_string } @instr )[0];
    ok( defined $call, 'defer block lowered inline (defer body executed)' );
};
done_testing;
