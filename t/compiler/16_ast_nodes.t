use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::AST;

subtest 'Node base class' => sub {
    my $n = Brocken::AST::Node->new( line => 10, col => 5 );
    is $n->line, 10, 'node line';
    is $n->col,  5,  'node col';
};

subtest 'Node defaults' => sub {
    my $n = Brocken::AST::Node->new;
    is $n->line, 0, 'default line 0';
    is $n->col,  0, 'default col 0';
};

subtest 'Program' => sub {
    my $p = Brocken::AST::Program->new( stmts => [] );
    ok $p->isa('Brocken::AST::Program'), 'Program isa Program';
    is scalar( @{ $p->stmts } ), 0, 'empty stmts';
};

subtest 'Statement nodes' => sub {
    my $block = Brocken::AST::Block->new( stmts => [] );
    ok $block->isa('Brocken::AST::Block'), 'block isa Block';
    ok $block->stmts, 'block has statements';

    my $vd = Brocken::AST::MyDecl->new( name => '$x', type => 'Int' );
    is $vd->name, '$x',  'MyDecl name';
    is $vd->type, 'Int', 'MyDecl type';

    my $assign = Brocken::AST::Assign->new( name => '$x', expr => Brocken::AST::IntLiteral->new(value => 42) );
    is $assign->name, '$x', 'Assign name';

    my $if = Brocken::AST::If->new( cond => undef, then => $block );
    is $if->cond, undef,   'If cond';
    is $if->then, $block,  'If then';
    is $if->else, undef,   'If else default undef';

    my $while = Brocken::AST::While->new( cond => undef, body => $block );
    is $while->body, $block, 'While body';

    my $ret = Brocken::AST::Return->new;
    ok $ret->isa('Brocken::AST::Return'), 'Return isa Return';
};

subtest 'Expression nodes' => sub {
    my $int = Brocken::AST::IntLiteral->new( value => 42 );
    is $int->value, 42, 'IntLiteral value';

    my $var = Brocken::AST::Var->new( name => '$x' );
    is $var->name, '$x', 'Var name';

    my $binop = Brocken::AST::BinOp->new( op => '+', left => $int, right => $int );
    is $binop->op,   '+',    'BinOp op';
    is $binop->left, $int,   'BinOp left';

    my $unary = Brocken::AST::UnaryOp->new( op => '!', operand => $var );
    is $unary->op,      '!',  'UnaryOp op';
    is $unary->operand, $var, 'UnaryOp operand';

    my $ternary = Brocken::AST::Ternary->new( cond => $var, if_true => $int, if_false => $int );
    is $ternary->cond,     $var, 'Ternary cond';
    is $ternary->if_true,  $int, 'Ternary if_true';
    is $ternary->if_false, $int, 'Ternary if_false';

    my $call = Brocken::AST::Call->new( name => 'say', args => [$int] );
    is $call->name, 'say', 'Call name';
    ok scalar( @{ $call->args } ) == 1, 'Call args';

    ok $int->isa('Brocken::AST::Node'), 'Expr nodes inherit from Node';
};

subtest 'SubDecl node' => sub {
    my $body = Brocken::AST::Block->new( stmts => [] );
    my $sub = Brocken::AST::SubDecl->new( name => 'foo', params => [], body => $body );
    is $sub->name, 'foo', 'SubDecl name';
    is scalar( @{ $sub->params } ), 0, 'SubDecl params';
    is $sub->body, $body, 'SubDecl body';
};

done_testing;
