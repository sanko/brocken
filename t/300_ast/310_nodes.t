use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::AST;
use Brocken::AST::Node;
use Brocken::AST::Expr;
use Brocken::AST::Stmt;
use Brocken::AST::OOP;

subtest 'Node base class' => sub {
    my $n = Brocken::AST::Node->new( line => 10, col => 5 );
    is $n->line, 10, 'node line';
    is $n->col,  5,  'node col';
};

subtest 'Program' => sub {
    my $p = Brocken::AST::Stmt::Program->new( statements => [] );
    ok $p->isa('Brocken::AST::Node'), 'Program isa Node';
    ok $p->isa('Brocken::AST::Stmt::Program'), 'Program isa Program';
    is scalar( @{ $p->statements } ), 0, 'empty statements';
};

subtest 'Literal expressions' => sub {
    my $int = Brocken::AST::Expr::IntLiteral->new( value => 42, type => 'Int' );
    ok $int->isa('Brocken::AST::Node'), 'IntLiteral isa Node';
    is $int->value, 42, 'IntLiteral value 42';

    my $flt = Brocken::AST::Expr::FloatLiteral->new( value => 3.14, type => 'Float' );
    is $flt->value, 3.14, 'FloatLiteral value 3.14';

    my $str = Brocken::AST::Expr::StrLiteral->new( value => 'hello', type => 'String' );
    is $str->value, 'hello', 'StrLiteral value hello';

    my $nil = Brocken::AST::Expr::NilLiteral->new( value => undef, type => 'Nil' );
    ok $nil->isa('Brocken::AST::Node'), 'NilLiteral isa Node';
};

subtest 'Variable and identifier expressions' => sub {
    my $var = Brocken::AST::Expr::Var->new( name => 'x', sigil => '$' );
    is $var->name,  'x', 'Var name x';
    is $var->sigil, '$', 'Var sigil $';

    my $id = Brocken::AST::Expr::Var->new( name => 'foo', sigil => '' );
    is $id->name, 'foo', 'Ident name foo';
};

subtest 'Binary and unary operations' => sub {
    my $int1 = Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' );
    my $int2 = Brocken::AST::Expr::IntLiteral->new( value => 2, type => 'Int' );

    my $bin = Brocken::AST::Expr::BinOp->new(
        left  => $int1,
        op    => '+',
        right => $int2,
    );
    is $bin->op,           '+', 'BinOp op +';
    is $bin->left->value,  1,   'BinOp left 1';
    is $bin->right->value, 2,   'BinOp right 2';
    is $bin->left, $int1, 'BinOp left obj';
    is $bin->right, $int2, 'BinOp right obj';

    my $un = Brocken::AST::Expr::UnaryOp->new( op => '-', expr => $int1 );
    is $un->op,          '-', 'UnaryOp op -';
    is $un->expr->value, 1,   'UnaryOp expr 1';
    is $un->expr, $int1, 'UnaryOp expr obj';
};

subtest 'Call expressions' => sub {
    my $arg = Brocken::AST::Expr::StrLiteral->new( value => 'hi', type => 'String' );
    my $call = Brocken::AST::Expr::Call->new( name => 'print', args => [$arg] );
    is $call->name,                'print', 'Call name print';
    is scalar( @{ $call->args } ), 1,       'Call 1 arg';
    is $call->args->[0]->value,    'hi',    'Call arg hi';
    ok $call->args->[0]->isa('Brocken::AST::Node'), 'arg isa Node';
};

subtest 'Ternary expression' => sub {
    my $t = Brocken::AST::Expr::Ternary->new(
        cond => Brocken::AST::Expr::IntLiteral->new( value => 1,  type => 'Int' ),
        then => Brocken::AST::Expr::IntLiteral->new( value => 10, type => 'Int' ),
        else => Brocken::AST::Expr::IntLiteral->new( value => 20, type => 'Int' ),
    );
    is $t->cond->value, 1,  'Ternary cond';
    is $t->then->value, 10, 'Ternary then';
    is $t->else->value, 20, 'Ternary else';
};

subtest 'Index expression' => sub {
    my $idx = Brocken::AST::Expr::IndexExpr->new(
        source => Brocken::AST::Expr::Var->new( name => 'x' ),
        index  => Brocken::AST::Expr::IntLiteral->new( value => 0, type => 'Int' ),
    );
    ok $idx->source->isa('Brocken::AST::Expr::Var'), 'IndexExpr source is Var';
    is $idx->index->value, 0, 'Index 0';
};

subtest 'Block' => sub {
    my $block = Brocken::AST::Stmt::Block->new( statements => [ Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' ) ] );
    is scalar( @{ $block->statements } ), 1, 'Block has 1 stmt';
    ok $block->statements, 'block has statements';
};

subtest 'Variable declaration' => sub {
    my $decl = Brocken::AST::Stmt::VarDecl->new(
        name  => 'y',
        type  => 'Int',
        value => Brocken::AST::Expr::IntLiteral->new( value => 20, type => 'Int' ),
    );
    is $decl->name,         'y',   'VarDecl name y';
    is $decl->type,         'Int', 'VarDecl type Int';
    is $decl->value->value, 20,    'VarDecl value 20';

    my $decl2 = Brocken::AST::Stmt::VarDecl->new( name => 'z', type => undef, value => undef );
    is $decl2->name, 'z', 'VarDecl name z';
    ok !defined( $decl2->type ),  'VarDecl no type';
    ok !defined( $decl2->value ), 'VarDecl no value';
};

subtest 'Assignment' => sub {
    my $assign = Brocken::AST::Stmt::Assignment->new(
        name  => 'x',
        value => Brocken::AST::Expr::IntLiteral->new( value => 10, type => 'Int' ),
    );
    is $assign->name,         'x', 'Assignment name x';
    is $assign->value->value, 10,  'Assignment value 10';
};

subtest 'If statement' => sub {
    my $cond = Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' );
    my $block = Brocken::AST::Stmt::Block->new( statements => [] );

    my $if = Brocken::AST::Stmt::If->new(
        condition  => $cond,
        then_block => $block,
    );
    ok $if->condition->isa('Brocken::AST::Expr::IntLiteral'), 'If condition';
    ok !defined( $if->else_block ), 'If no else_block';
    is $if->condition,  $cond,  'If condition obj';
    is $if->then_block, $block, 'If then obj';

    my $if_else = Brocken::AST::Stmt::If->new(
        condition  => $cond,
        then_block => $block,
        else_block => $block,
    );
    ok defined( $if_else->else_block ), 'If with else_block';
};

subtest 'While statement' => sub {
    my $body = Brocken::AST::Stmt::Block->new( statements => [] );
    my $while = Brocken::AST::Stmt::While->new(
        condition => Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' ),
        body      => $body,
    );
    ok $while->body->isa('Brocken::AST::Stmt::Block'), 'While body';
    is $while->body, $body, 'While body obj';
};

subtest 'For statement' => sub {
    my $for = Brocken::AST::Stmt::For->new( body => Brocken::AST::Stmt::Block->new( statements => [] ) );
    ok !defined( $for->init ),      'For no init';
    ok !defined( $for->condition ), 'For no condition';

    my $fe = Brocken::AST::Stmt::ForEach->new(
        var    => 'item',
        source => Brocken::AST::Expr::Var->new( name => 'list' ),
        body   => Brocken::AST::Stmt::Block->new( statements => [] ),
    );
    is $fe->var, 'item', 'Foreach var item';
};

subtest 'Flow statements (Return, Last, Next)' => sub {
    my $ret = Brocken::AST::Stmt::Return->new( expr => undef );
    ok !defined( $ret->expr ), 'Return no expr';

    my $ret_v = Brocken::AST::Stmt::Return->new(
        expr => Brocken::AST::Expr::IntLiteral->new( value => 99, type => 'Int' ),
    );
    is $ret_v->expr->value, 99, 'Return value 99';

    my $last = Brocken::AST::Stmt::Last->new();
    ok $last->isa('Brocken::AST::Stmt::Last'), 'Last node';

    my $next = Brocken::AST::Stmt::Next->new();
    ok $next->isa('Brocken::AST::Stmt::Next'), 'Next node';

    my $redo = Brocken::AST::Stmt::Redo->new();
    ok $redo->isa('Brocken::AST::Stmt::Redo'), 'Redo node';
};

subtest 'Method (subroutine declaration)' => sub {
    my $sub = Brocken::AST::OOP::Method->new(
        name   => 'foo',
        params => [ 'x', 'y' ],
        body   => Brocken::AST::Stmt::Block->new( statements => [] ),
    );
    is $sub->name,                  'foo', 'Method name foo';
    is scalar( @{ $sub->params } ), 2,     'Method 2 params';
    is $sub->params->[0],           'x',   'Method param x';
    is $sub->params->[1],           'y',   'Method param y';
};

done_testing;
