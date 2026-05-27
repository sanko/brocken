use v5.40;
use Test2::V0;
use lib 'lib';
use Brocken::AST;
use Brocken::AST::Expr;
use Brocken::AST::Stmt;
use Brocken::AST::OOP;

# --- Program ---
my $p = Brocken::AST::Stmt::Program->new( statements => [] );
ok $p->isa('Brocken::AST::Node'), 'Program isa Node';
is scalar( @{ $p->statements } ), 0, 'Program has 0 statements';

# --- IntLiteral ---
my $int = Brocken::AST::Expr::IntLiteral->new( value => 42, type => 'Int' );
ok $int->isa('Brocken::AST::Node'), 'IntLiteral isa Node';
is $int->value, 42, 'IntLiteral value 42';

# --- FloatLiteral ---
my $flt = Brocken::AST::Expr::FloatLiteral->new( value => 3.14, type => 'Float' );
is $flt->value, 3.14, 'FloatLiteral value 3.14';

# --- StrLiteral ---
my $str = Brocken::AST::Expr::StrLiteral->new( value => 'hello', type => 'String' );
is $str->value, 'hello', 'StrLiteral value hello';

# --- NilLiteral ---
my $nil = Brocken::AST::Expr::NilLiteral->new( value => undef, type => 'Nil' );
ok $nil->isa('Brocken::AST::Node'), 'NilLiteral isa Node';

# --- Var ---
my $var = Brocken::AST::Expr::Var->new( name => 'x', sigil => '$' );
is $var->name,  'x', 'Var name x';
is $var->sigil, '$', 'Var sigil $';

# --- Ident ---
my $id = Brocken::AST::Expr::Var->new( name => 'foo', sigil => '' );
is $id->name, 'foo', 'Ident name foo';

# --- BinOp ---
my $bin = Brocken::AST::Expr::BinOp->new(
    left  => Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' ),
    op    => '+',
    right => Brocken::AST::Expr::IntLiteral->new( value => 2, type => 'Int' ),
);
is $bin->op,           '+', 'BinOp op +';
is $bin->left->value,  1,   'BinOp left 1';
is $bin->right->value, 2,   'BinOp right 2';

# --- UnaryOp ---
my $un = Brocken::AST::Expr::UnaryOp->new( op => '-', expr => Brocken::AST::Expr::IntLiteral->new( value => 5, type => 'Int' ), );
is $un->op,          '-', 'UnaryOp op -';
is $un->expr->value, 5,   'UnaryOp expr 5';

# --- Call ---
my $call = Brocken::AST::Expr::Call->new( name => 'print', args => [ Brocken::AST::Expr::StrLiteral->new( value => 'hi', type => 'String' ) ], );
is $call->name,                'print', 'Call name print';
is scalar( @{ $call->args } ), 1,       'Call 1 arg';
is $call->args->[0]->value,    'hi',    'Call arg hi';

# --- Assignment ---
my $assign = Brocken::AST::Stmt::Assignment->new( name => 'x', value => Brocken::AST::Expr::IntLiteral->new( value => 10, type => 'Int' ), );
is $assign->name,         'x', 'Assignment name x';
is $assign->value->value, 10,  'Assignment value 10';

# --- VarDecl ---
my $decl
    = Brocken::AST::Stmt::VarDecl->new( name => 'y', type => 'Int', value => Brocken::AST::Expr::IntLiteral->new( value => 20, type => 'Int' ), );
is $decl->name,         'y',   'VarDecl name y';
is $decl->type,         'Int', 'VarDecl type Int';
is $decl->value->value, 20,    'VarDecl value 20';

# VarDecl without type or value
my $decl2 = Brocken::AST::Stmt::VarDecl->new( name => 'z', type => undef, value => undef );
is $decl2->name, 'z', 'VarDecl name z';
ok !defined( $decl2->type ),  'VarDecl no type';
ok !defined( $decl2->value ), 'VarDecl no value';

# --- Block ---
my $block = Brocken::AST::Stmt::Block->new( statements => [ Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' ) ], );
is scalar( @{ $block->statements } ), 1, 'Block has 1 stmt';

# --- If ---
my $if = Brocken::AST::Stmt::If->new(
    condition  => Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' ),
    then_block => Brocken::AST::Stmt::Block->new( statements => [] ),
);
ok $if->condition->isa('Brocken::AST::Expr::IntLiteral'), 'If condition';
ok !defined( $if->else_block ),                           'If no else_block';

# If with else_block
my $if_else = Brocken::AST::Stmt::If->new(
    condition  => Brocken::AST::Expr::IntLiteral->new( value => 0, type => 'Int' ),
    then_block => Brocken::AST::Stmt::Block->new( statements => [] ),
    else_block => Brocken::AST::Stmt::Block->new( statements => [] ),
);
ok defined( $if_else->else_block ), 'If with else_block';

# --- While ---
my $while = Brocken::AST::Stmt::While->new(
    condition => Brocken::AST::Expr::IntLiteral->new( value => 1, type => 'Int' ),
    body      => Brocken::AST::Stmt::Block->new( statements => [] ),
);
ok $while->body->isa('Brocken::AST::Stmt::Block'), 'While body';

# --- Method (SubDecl) ---
my $sub = Brocken::AST::OOP::Method->new( name => 'foo', params => [ 'x', 'y' ], body => Brocken::AST::Stmt::Block->new( statements => [] ), );
is $sub->name,                  'foo', 'Method name foo';
is scalar( @{ $sub->params } ), 2,     'Method 2 params';
is $sub->params->[0],           'x',   'Method param x';

# --- Return ---
my $ret = Brocken::AST::Stmt::Return->new( expr => undef );
ok !defined( $ret->expr ), 'Return no expr';
my $ret_v = Brocken::AST::Stmt::Return->new( expr => Brocken::AST::Expr::IntLiteral->new( value => 99, type => 'Int' ), );
is $ret_v->expr->value, 99, 'Return value 99';

# --- FlowStmt (Last) ---
my $flow = Brocken::AST::Stmt::Last->new();
ok $flow->isa('Brocken::AST::Stmt::Last'), 'FlowStmt (Last)';

# --- Ternary ---
my $tern = Brocken::AST::Expr::Ternary->new(
    cond => Brocken::AST::Expr::IntLiteral->new( value => 1,  type => 'Int' ),
    then => Brocken::AST::Expr::IntLiteral->new( value => 10, type => 'Int' ),
    else => Brocken::AST::Expr::IntLiteral->new( value => 20, type => 'Int' ),
);
is $tern->cond->value, 1,  'Ternary cond';
is $tern->then->value, 10, 'Ternary then';
is $tern->else->value, 20, 'Ternary else';

# --- IndexExpr ---
my $idx = Brocken::AST::Expr::IndexExpr->new(
    source => Brocken::AST::Expr::Var->new( name => 'x' ),
    index  => Brocken::AST::Expr::IntLiteral->new( value => 0, type => 'Int' ),
);
ok $idx->source->isa('Brocken::AST::Expr::Var'), 'IndexExpr source is Var';
is $idx->index->value, 0, 'Index 0';

# --- For ---
my $for = Brocken::AST::Stmt::For->new( body => Brocken::AST::Stmt::Block->new( statements => [] ) );
ok !defined( $for->init ),      'For no init';
ok !defined( $for->condition ), 'For no condition';

# --- Foreach ---
my $fe = Brocken::AST::Stmt::ForEach->new(
    var    => 'item',
    source => Brocken::AST::Expr::Var->new( name => 'list' ),
    body   => Brocken::AST::Stmt::Block->new( statements => [] ),
);
is $fe->var, 'item', 'Foreach var item';
done_testing;
