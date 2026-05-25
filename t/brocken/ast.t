use v5.40;
use Test2::V0;
use lib 'lib';
use Brocken::AST;

# --- Program ---
my $p = Brocken::AST::Program->new(stmts => []);
ok $p->isa('Brocken::AST::Node'), 'Program isa Node';
is scalar(@{ $p->stmts }), 0, 'Program has 0 stmts';

# --- IntLiteral ---
my $int = Brocken::AST::IntLiteral->new(value => 42);
ok $int->isa('Brocken::AST::Node'), 'IntLiteral isa Node';
is $int->value, 42, 'IntLiteral value 42';

# --- FloatLiteral ---
my $flt = Brocken::AST::FloatLiteral->new(value => 3.14);
is $flt->value, 3.14, 'FloatLiteral value 3.14';

# --- StrLiteral ---
my $str = Brocken::AST::StrLiteral->new(value => 'hello');
is $str->value, 'hello', 'StrLiteral value hello';

# --- NilLiteral ---
my $nil = Brocken::AST::NilLiteral->new();
ok $nil->isa('Brocken::AST::Node'), 'NilLiteral isa Node';

# --- Var ---
my $var = Brocken::AST::Var->new(name => 'x', sigil => '$');
is $var->name, 'x', 'Var name x';
is $var->sigil, '$', 'Var sigil $';

# --- Ident ---
my $id = Brocken::AST::Ident->new(name => 'foo');
is $id->name, 'foo', 'Ident name foo';

# --- BinOp ---
my $bin = Brocken::AST::BinOp->new(
    left  => Brocken::AST::IntLiteral->new(value => 1),
    op    => '+',
    right => Brocken::AST::IntLiteral->new(value => 2),
);
is $bin->op, '+', 'BinOp op +';
is $bin->left->value, 1, 'BinOp left 1';
is $bin->right->value, 2, 'BinOp right 2';

# --- UnaryOp ---
my $un = Brocken::AST::UnaryOp->new(
    op      => '-',
    operand => Brocken::AST::IntLiteral->new(value => 5),
);
is $un->op, '-', 'UnaryOp op -';
is $un->operand->value, 5, 'UnaryOp operand 5';

# --- Call ---
my $call = Brocken::AST::Call->new(
    name => 'print',
    args => [Brocken::AST::StrLiteral->new(value => 'hi')],
);
is $call->name, 'print', 'Call name print';
is scalar(@{ $call->args }), 1, 'Call 1 arg';
is $call->args->[0]->value, 'hi', 'Call arg hi';

# --- Assign ---
my $assign = Brocken::AST::Assign->new(
    name => 'x',
    expr => Brocken::AST::IntLiteral->new(value => 10),
);
is $assign->name, 'x', 'Assign name x';
is $assign->expr->value, 10, 'Assign value 10';

# --- MyDecl ---
my $decl = Brocken::AST::MyDecl->new(
    name => 'y',
    type => 'Int',
    expr => Brocken::AST::IntLiteral->new(value => 20),
);
is $decl->name, 'y', 'MyDecl name y';
is $decl->type, 'Int', 'MyDecl type Int';
is $decl->expr->value, 20, 'MyDecl value 20';

# MyDecl without type or expr
my $decl2 = Brocken::AST::MyDecl->new(name => 'z');
is $decl2->name, 'z', 'MyDecl name z';
ok !defined($decl2->type), 'MyDecl no type';
ok !defined($decl2->expr), 'MyDecl no expr';

# --- Block ---
my $block = Brocken::AST::Block->new(
    stmts => [Brocken::AST::IntLiteral->new(value => 1)],
);
is scalar(@{ $block->stmts }), 1, 'Block has 1 stmt';

# --- If ---
my $if = Brocken::AST::If->new(
    cond => Brocken::AST::IntLiteral->new(value => 1),
    then => Brocken::AST::Block->new(stmts => []),
);
ok $if->cond->isa('Brocken::AST::IntLiteral'), 'If cond';
ok !defined($if->else), 'If no else';

# If with else
my $if_else = Brocken::AST::If->new(
    cond => Brocken::AST::IntLiteral->new(value => 0),
    then => Brocken::AST::Block->new(stmts => []),
    else => Brocken::AST::Block->new(stmts => []),
);
ok defined($if_else->else), 'If with else';

# --- While ---
my $while = Brocken::AST::While->new(
    cond => Brocken::AST::IntLiteral->new(value => 1),
    body => Brocken::AST::Block->new(stmts => []),
);
ok $while->body->isa('Brocken::AST::Block'), 'While body';

# --- SubDecl ---
my $sub = Brocken::AST::SubDecl->new(
    name   => 'foo',
    params => ['x', 'y'],
    body   => Brocken::AST::Block->new(stmts => []),
);
is $sub->name, 'foo', 'SubDecl name foo';
is scalar(@{ $sub->params }), 2, 'SubDecl 2 params';
is $sub->params->[0], 'x', 'SubDecl param x';

# --- Return ---
my $ret = Brocken::AST::Return->new();
ok !defined($ret->expr), 'Return no expr';

my $ret_v = Brocken::AST::Return->new(
    expr => Brocken::AST::IntLiteral->new(value => 99),
);
is $ret_v->expr->value, 99, 'Return value 99';

# --- FlowStmt ---
my $flow = Brocken::AST::FlowStmt->new(type => 'last');
is $flow->type, 'last', 'FlowStmt type last';

# --- Ternary ---
my $tern = Brocken::AST::Ternary->new(
    cond     => Brocken::AST::IntLiteral->new(value => 1),
    if_true  => Brocken::AST::IntLiteral->new(value => 10),
    if_false => Brocken::AST::IntLiteral->new(value => 20),
);
is $tern->cond->value, 1, 'Ternary cond';
is $tern->if_true->value, 10, 'Ternary if_true';
is $tern->if_false->value, 20, 'Ternary if_false';

# --- Index ---
my $idx = Brocken::AST::Index->new(
    target => Brocken::AST::Var->new(name => 'x'),
    index  => Brocken::AST::IntLiteral->new(value => 0),
);
ok $idx->target->isa('Brocken::AST::Var'), 'Index target is Var';
is $idx->index->value, 0, 'Index 0';

# --- For ---
my $for = Brocken::AST::For->new(body => Brocken::AST::Block->new(stmts => []));
ok !defined($for->init), 'For no init';
ok !defined($for->cond), 'For no cond';

# --- Foreach ---
my $fe = Brocken::AST::Foreach->new(
    var  => 'item',
    expr => Brocken::AST::Var->new(name => 'list'),
    body => Brocken::AST::Block->new(stmts => []),
);
is $fe->var, 'item', 'Foreach var item';

done_testing;
