use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::AST::Node;
use Brocken::AST::Stmt;
use Brocken::AST::Expr;

# Since all classes are defined within Brocken::AST::Stmt package, they are reachable
# through that package or just by loading it.
# Actually, if they are defined inside the package, they might be fully qualified as
# Brocken::AST::Stmt::Block, but 'use' might not load them if it is not in a separate file.
# Let's check how they are loaded.
subtest 'Node base class' => sub {
    my $n = Brocken::AST::Node->new( line => 10, col => 5 );
    is $n->line, 10, 'node line';
    is $n->col,  5,  'node col';
};
subtest 'Program' => sub {
    my $p = Brocken::AST::Stmt::Program->new( statements => [] );
    ok $p->isa('Brocken::AST::Stmt::Program'), 'Program isa Program';
    is scalar( @{ $p->statements } ), 0, 'empty statements';
};
subtest 'Statement nodes' => sub {
    my $block = Brocken::AST::Stmt::Block->new( statements => [] );
    ok $block->isa('Brocken::AST::Stmt::Block'), 'block isa Block';
    ok $block->statements,                       'block has statements';
    my $vd = Brocken::AST::Stmt::VarDecl->new( name => '$x', type => 'Int', value => undef );
    is $vd->name, '$x',  'VarDecl name';
    is $vd->type, 'Int', 'VarDecl type';
    my $assign = Brocken::AST::Stmt::Assignment->new( name => '$x', value => Brocken::AST::Expr::IntLiteral->new( value => 42, type => 'Int' ) );
    is $assign->name, '$x', 'Assignment name';
    my $if = Brocken::AST::Stmt::If->new( condition => undef, then_block => $block );
    is $if->condition,  undef,  'If condition';
    is $if->then_block, $block, 'If then';
    is $if->else_block, undef,  'If else default undef';
    my $while = Brocken::AST::Stmt::While->new( condition => undef, body => $block );
    is $while->body, $block, 'While body';
    my $ret = Brocken::AST::Stmt::Return->new( expr => undef );
    ok $ret->isa('Brocken::AST::Stmt::Return'), 'Return isa Return';
};
subtest 'Expression nodes' => sub {
    my $int = Brocken::AST::Expr::IntLiteral->new( value => 42, type => 'Int' );
    is $int->value, 42, 'IntLiteral value';
    my $var = Brocken::AST::Expr::Var->new( name => '$x', sigil => '$' );
    is $var->name, '$x', 'Var name';
    my $binop = Brocken::AST::Expr::BinOp->new( op => '+', left => $int, right => $int );
    is $binop->op,   '+',  'BinOp op';
    is $binop->left, $int, 'BinOp left';
    my $unary = Brocken::AST::Expr::UnaryOp->new( op => '!', expr => $var );
    is $unary->op,   '!',  'UnaryOp op';
    is $unary->expr, $var, 'UnaryOp expr';
    my $ternary = Brocken::AST::Expr::Ternary->new( cond => $var, then => $int, else => $int );
    is $ternary->cond, $var, 'Ternary cond';
    is $ternary->then, $int, 'Ternary then';
    is $ternary->else, $int, 'Ternary else';
    my $call = Brocken::AST::Expr::Call->new( name => 'say', args => [$int] );
    is $call->name, 'say', 'Call name';
    ok scalar( @{ $call->args } ) == 1, 'Call args';
    ok $int->isa('Brocken::AST::Node'), 'Expr nodes inherit from Node';
};
done_testing;
