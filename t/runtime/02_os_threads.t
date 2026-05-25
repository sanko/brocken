use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::AST::Expr;

subtest 'spawn_thread Call node construction' => sub {
    my $sub_ref = Brocken::AST::Expr::Const->new( value => 0, type => 'Int' );
    my $call    = Brocken::AST::Expr::Call->new( name => 'spawn_thread', args => [$sub_ref] );
    ok $call->isa('Brocken::AST::Node'),           'Call isa Node';
    is $call->name, 'spawn_thread',               'call name is spawn_thread';
    is scalar( @{ $call->args } ), 1,             'one argument';
};

subtest 'spawn_thread with sub expression' => sub {
    my $sub_expr = Brocken::AST::Expr::BinOp->new(
        op    => '+',
        left  => Brocken::AST::Expr::Const->new( value => 1, type => 'Int' ),
        right => Brocken::AST::Expr::Const->new( value => 2, type => 'Int' ),
    );
    my $call = Brocken::AST::Expr::Call->new( name => 'spawn_thread', args => [$sub_expr] );
    is $call->name,                   'spawn_thread', 'call name';
    ok $call->args->[0]->isa('Brocken::AST::Expr::BinOp'), 'arg is BinOp';
    is $call->args->[0]->op,          '+',               'binop is +';
    is $call->args->[0]->left->value, 1, 'left is 1';
    is $call->args->[0]->right->value, 2, 'right is 2';
};

subtest 'Thread-related AST nodes inherit from Node' => sub {
    my $int = Brocken::AST::Expr::Const->new( value => 0, type => 'Int' );
    my $call = Brocken::AST::Expr::Call->new( name => 'spawn_thread', args => [$int] );
    ok $call->isa('Brocken::AST::Node'), 'spawn_thread Call isa Node';
    ok $call->args->[0]->isa('Brocken::AST::Node'), 'arg isa Node';
};

done_testing;
