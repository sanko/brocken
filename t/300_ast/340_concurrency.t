use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::AST;
use Brocken::AST::Async;
use Brocken::AST::Expr;
use Brocken::AST::Stmt;
subtest 'FiberBlock node construction' => sub {
    my $body = Brocken::AST::Stmt::Block->new( statements => [] );
    my $fb   = Brocken::AST::Async::FiberBlock->new( body => $body );
    ok $fb->isa('Brocken::AST::Node'),              'FiberBlock isa Node';
    ok $fb->isa('Brocken::AST::Async::FiberBlock'), 'FiberBlock isa FiberBlock';
    is $fb->body,   $body, 'body accessor';
    is $fb->params, [],    'default params is empty array';
};
subtest 'FiberBlock with params' => sub {
    my $body   = Brocken::AST::Stmt::Block->new( statements => [] );
    my $params = [ { name => '$x', type => 'Int' } ];
    my $fb     = Brocken::AST::Async::FiberBlock->new( params => $params, body => $body );
    is scalar( @{ $fb->params } ), 1,    'one param';
    is $fb->params->[0]{name},     '$x', 'param name';
};
subtest 'Yield node construction' => sub {
    my $expr  = Brocken::AST::Expr::IntLiteral->new( value => 42, type => 'Int' );
    my $yield = Brocken::AST::Async::Yield->new( expr => $expr );
    ok $yield->isa('Brocken::AST::Node'),         'Yield isa Node';
    ok $yield->isa('Brocken::AST::Async::Yield'), 'Yield isa Yield';
    is $yield->expr->value, 42, 'yield expression value';
};
subtest 'spawn_thread Call node construction' => sub {
    my $sub_ref = Brocken::AST::Expr::Const->new( value => 0, type => 'Int' );
    my $call    = Brocken::AST::Expr::Call->new( name => 'spawn_thread', args => [$sub_ref] );
    ok $call->isa('Brocken::AST::Node'), 'Call isa Node';
    is $call->name,                'spawn_thread', 'call name is spawn_thread';
    is scalar( @{ $call->args } ), 1,              'one argument';
};
subtest 'spawn_thread with sub expression' => sub {
    my $sub_expr = Brocken::AST::Expr::BinOp->new(
        op    => '+',
        left  => Brocken::AST::Expr::Const->new( value => 1, type => 'Int' ),
        right => Brocken::AST::Expr::Const->new( value => 2, type => 'Int' ),
    );
    my $call = Brocken::AST::Expr::Call->new( name => 'spawn_thread', args => [$sub_expr] );
    is $call->name, 'spawn_thread', 'call name';
    ok $call->args->[0]->isa('Brocken::AST::Expr::BinOp'), 'arg is BinOp';
    is $call->args->[0]->op,           '+', 'binop is +';
    is $call->args->[0]->left->value,  1,   'left is 1';
    is $call->args->[0]->right->value, 2,   'right is 2';
};
subtest 'Thread-related AST nodes inherit from Node' => sub {
    my $int  = Brocken::AST::Expr::Const->new( value => 0, type => 'Int' );
    my $call = Brocken::AST::Expr::Call->new( name => 'spawn_thread', args => [$int] );
    ok $call->isa('Brocken::AST::Node'),            'spawn_thread Call isa Node';
    ok $call->args->[0]->isa('Brocken::AST::Node'), 'arg isa Node';
};
subtest 'join_thread Call node construction' => sub {
    my $arg  = Brocken::AST::Expr::Var->new( name => 't', sigil => '$' );
    my $call = Brocken::AST::Expr::Call->new( name => 'join_thread', args => [$arg] );
    is $call->name,                'join_thread', 'join_thread call name';
    is scalar( @{ $call->args } ), 1,             'one argument';
    is $call->args->[0]->name,     't',           'argument is variable t';
};
done_testing;
