use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Compiler;
use Brocken::Katsuro::AST;
subtest 'Empty program' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('');
    isa_ok( $prog, ['Brocken::Katsuro::AST::Program'] );
    is( $prog->statements->@*, 0, 'empty program has no statements' );
};
subtest 'Variable declarations' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('my i64 $x = 42; my ptr $p; my $z;');
    is( $prog->statements->@*, 3, 'three statements' );
    my $s0 = $prog->statements->[0];
    isa_ok( $s0, ['Brocken::Katsuro::AST::Stmt::VarDecl'] );
    is( $s0->sigil, '$',   'sigil' );
    is( $s0->name,  'x',   'name' );
    is( $s0->type,  'i64', 'type i64' );
    isa_ok( $s0->init, ['Brocken::Katsuro::AST::Expr::Const'] );
    my $s1 = $prog->statements->[1];
    isa_ok( $s1, ['Brocken::Katsuro::AST::Stmt::VarDecl'] );
    is( $s1->name, 'p',   'name p' );
    is( $s1->type, 'ptr', 'type ptr' );
    is( $s1->init, undef, 'no initializer' );
    my $s2 = $prog->statements->[2];
    isa_ok( $s2, ['Brocken::Katsuro::AST::Stmt::VarDecl'] );
    is( $s2->name, 'z',   'name z' );
    is( $s2->type, 'Any', 'default type Any' );
};
subtest 'Assignment statement' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('my i64 $x; $x = 99;');
    is( $prog->statements->@*, 2, 'two statements' );
    my $s1 = $prog->statements->[1];
    isa_ok( $s1,         ['Brocken::Katsuro::AST::Stmt::Assign'] );
    isa_ok( $s1->target, ['Brocken::Katsuro::AST::Expr::Var'] );
    is( $s1->target->name, 'x', 'assign to x' );
    isa_ok( $s1->expr, ['Brocken::Katsuro::AST::Expr::Const'] );
};
subtest 'If/elsif/else' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
if (1) { my i64 $a; } elsif (2) { my i64 $b; } else { my i64 $c; }
BROCKEN
    is( $prog->statements->@*, 1, 'one statement' );
    my $s = $prog->statements->[0];
    isa_ok( $s,       ['Brocken::Katsuro::AST::Stmt::If'] );
    isa_ok( $s->cond, ['Brocken::Katsuro::AST::Expr::Const'] );
    isa_ok( $s->then, ['Brocken::Katsuro::AST::Stmt::Block'] );
    is( $s->elsif->@*, 1, 'one elsif branch' );
    isa_ok( $s->elsif->[0]->[0], ['Brocken::Katsuro::AST::Expr::Const'] );
    isa_ok( $s->elsif->[0]->[1], ['Brocken::Katsuro::AST::Stmt::Block'] );
    isa_ok( $s->else,            ['Brocken::Katsuro::AST::Stmt::Block'] );
};
subtest 'While loop' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('while (true) { my i64 $x; }');
    is( $prog->statements->@*, 1, 'one statement' );
    my $s = $prog->statements->[0];
    isa_ok( $s,       ['Brocken::Katsuro::AST::Stmt::While'] );
    isa_ok( $s->cond, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $s->cond->value, 1, 'true is 1' );
    isa_ok( $s->body, ['Brocken::Katsuro::AST::Stmt::Block'] );
};
subtest 'Return statement' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('return 42; return;');
    is( $prog->statements->@*, 2, 'two statements' );
    isa_ok( $prog->statements->[0],       ['Brocken::Katsuro::AST::Stmt::Return'] );
    isa_ok( $prog->statements->[0]->expr, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $prog->statements->[0]->expr->value, 42 );
    ok( !defined $prog->statements->[1]->expr, 'void return' );
};
subtest 'Subroutine declaration' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
sub add(i64 $a, i64 $b) -> i64 {
    return 0;
}
sub empty() -> ptr;
BROCKEN
    is( $prog->statements->@*, 2, 'two declarations' );
    my $s0 = $prog->statements->[0];
    isa_ok( $s0, ['Brocken::Katsuro::AST::Stmt::SubDecl'] );
    is( $s0->name,              'add' );
    is( $s0->params->@*,        2, 'two params' );
    is( $s0->params->[0]{type}, 'i64' );
    is( $s0->params->[0]{name}, 'a' );
    is( $s0->params->[1]{type}, 'i64' );
    is( $s0->params->[1]{name}, 'b' );
    is( $s0->return_type,       'i64' );
    isa_ok( $s0->body, ['Brocken::Katsuro::AST::Stmt::Block'] );
    is( $s0->body->statements->@*, 1, 'one stmt in body' );
    my $s1 = $prog->statements->[1];
    isa_ok( $s1, ['Brocken::Katsuro::AST::Stmt::SubDecl'] );
    is( $s1->name,        'empty' );
    is( $s1->return_type, 'ptr' );
    is( $s1->body->statements->@*, 0, 'forward decl has empty body' );
};
subtest 'Class declaration' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
class Channel {
    field i32 $capacity;
    field ptr $buffer;
}
BROCKEN
    is( $prog->statements->@*, 1, 'one declaration' );
    my $s = $prog->statements->[0];
    isa_ok( $s, ['Brocken::Katsuro::AST::Stmt::ClassDecl'] );
    is( $s->name,              'Channel' );
    is( $s->fields->@*,        2, 'two fields' );
    is( $s->fields->[0]->type, 'i32' );
    is( $s->fields->[0]->name, 'capacity' );
    is( $s->fields->[1]->type, 'ptr' );
    is( $s->fields->[1]->name, 'buffer' );
};
subtest 'Binary expressions (precedence)' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('my i64 $r = 1 + 2 * 3;');
    my $init = $prog->statements->[0]->init;
    isa_ok( $init, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->op,         '+', 'top op is +' );
    is( $init->lhs->value, 1,   'lhs is 1' );
    isa_ok( $init->rhs, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->rhs->op,         '*', 'inner op is *' );
    is( $init->rhs->lhs->value, 2,   'inner lhs is 2' );
    is( $init->rhs->rhs->value, 3,   'inner rhs is 3' );
};
subtest 'Comparison operators' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('my i64 $r = $a == $b && $c < $d || $e != $f;');
    my $init = $prog->statements->[0]->init;
    isa_ok( $init, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->op, '||', 'top op is ||' );
    isa_ok( $init->lhs, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->lhs->op, '&&', 'inner op is &&' );
    isa_ok( $init->lhs->lhs, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->lhs->lhs->op, '==' );
    isa_ok( $init->lhs->rhs, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->lhs->rhs->op, '<' );
    isa_ok( $init->rhs, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->rhs->op, '!=' );
};
subtest 'Function calls' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('foo(1, 2); bar();');
    is( $prog->statements->@*, 2, 'two statements' );
    isa_ok( $prog->statements->[0], ['Brocken::Katsuro::AST::Expr::Call'] );
    is( $prog->statements->[0]->func_name, 'foo' );
    is( $prog->statements->[0]->args->@*,  2 );
    isa_ok( $prog->statements->[1], ['Brocken::Katsuro::AST::Expr::Call'] );
    is( $prog->statements->[1]->func_name, 'bar' );
    is( $prog->statements->[1]->args->@*,  0 );
};
subtest 'Intrinsic calls (Brocken::)' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('my ptr $p = Brocken::ptr_add($base, 16);');
    my $init = $prog->statements->[0]->init;
    isa_ok( $init, ['Brocken::Katsuro::AST::Expr::IntrinsicCall'] );
    is( $init->name,     'ptr_add' );
    is( $init->args->@*, 2 );
    isa_ok( $init->args->[0], ['Brocken::Katsuro::AST::Expr::Var'] );
    is( $init->args->[0]->name,  'base' );
    is( $init->args->[1]->value, 16 );
};
subtest 'Built-in say/print' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('say(42); print("hello");');
    is( $prog->statements->@*, 2, 'two statements' );
    isa_ok( $prog->statements->[0], ['Brocken::Katsuro::AST::Expr::Call'] );
    is( $prog->statements->[0]->func_name,        'say' );
    is( $prog->statements->[0]->args->[0]->value, 42 );
    is( $prog->statements->[1]->func_name,        'print' );
    is( $prog->statements->[1]->args->[0]->value, 'hello' );
};
subtest 'Parenthesized expressions' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('my i64 $r = (1 + 2) * 3;');
    my $init = $prog->statements->[0]->init;
    isa_ok( $init, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->op, '*', 'top op is *' );
    isa_ok( $init->lhs,       ['Brocken::Katsuro::AST::Expr::Paren'] );
    isa_ok( $init->lhs->expr, ['Brocken::Katsuro::AST::Expr::BinOp'] );
    is( $init->lhs->expr->op, '+' );
    is( $init->rhs->value,    3 );
};
subtest 'Unary operators' => sub {
    my $c       = Brocken::Compiler->new;
    my $prog    = $c->parse_only('my i64 $r = -42; my i64 $b = !true;');
    my $s0_init = $prog->statements->[0]->init;
    isa_ok( $s0_init, ['Brocken::Katsuro::AST::Expr::UnOp'] );
    is( $s0_init->op, '-', 'negation' );
    is( $s0_init->expr->value, 42 );
    my $s1_init = $prog->statements->[1]->init;
    isa_ok( $s1_init, ['Brocken::Katsuro::AST::Expr::UnOp'] );
    is( $s1_init->op, '!', 'not' );
    is( $s1_init->expr->value, 1 );
};
subtest 'Class with field attributes and defaults' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
class Point {
    field i64 $x :reader :param = 0;
    field i64 $y :reader :writer :param;
    field i64 $z :reader //= 0;
}
BROCKEN
    is( $prog->statements->@*, 1, 'one declaration' );
    my $s = $prog->statements->[0];
    isa_ok( $s, ['Brocken::Katsuro::AST::Stmt::ClassDecl'] );
    is( $s->name, 'Point' );
    is( $s->fields->@*, 3, 'three fields' );
    my $f0 = $s->fields->[0];
    is( $f0->type,                'i64' );
    is( $f0->name,                'x' );
    is( scalar( $f0->attrs->@* ), 2, 'attrs count' );
    is( $f0->attrs->[0],          'reader' );
    is( $f0->attrs->[1],          'param' );
    isa_ok( $f0->default, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $f0->default->value, 0 );
    is( $f0->default_op,     '=' );
    my $f1 = $s->fields->[1];
    is( $f1->type,                'i64' );
    is( $f1->name,                'y' );
    is( scalar( $f1->attrs->@* ), 3, 'attrs count' );
    is( $f1->attrs->[0],          'reader' );
    is( $f1->attrs->[1],          'writer' );
    is( $f1->attrs->[2],          'param' );
    ok( !defined $f1->default, 'no default' );
    my $f2 = $s->fields->[2];
    is( $f2->type,                'i64' );
    is( $f2->name,                'z' );
    is( scalar( $f2->attrs->@* ), 1, 'attrs count' );
    is( $f2->attrs->[0],          'reader' );
    isa_ok( $f2->default, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $f2->default->value, 0 );
    is( $f2->default_op,     '//=' );
};
subtest 'Method declaration inside class' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
class Counter {
    field i64 $count :reader;
    method increment() { $count = $count + 1; }
    method get_value() -> i64 { return $count; }
    method add(i64 $n) -> i64 { $count = $count + $n; return $count; }
}
BROCKEN
    is( $prog->statements->@*, 1, 'one declaration' );
    my $s = $prog->statements->[0];
    isa_ok( $s, ['Brocken::Katsuro::AST::Stmt::ClassDecl'] );
    is( $s->methods->@*, 3, 'three methods' );
    my $m0 = $s->methods->[0];
    is( $m0->name,        'increment' );
    is( $m0->params->@*,  0 );
    is( $m0->return_type, 'void' );
    isa_ok( $m0->body, ['Brocken::Katsuro::AST::Stmt::Block'] );
    my $m1 = $s->methods->[1];
    is( $m1->name,        'get_value' );
    is( $m1->params->@*,  0 );
    is( $m1->return_type, 'i64' );
    isa_ok( $m1->body, ['Brocken::Katsuro::AST::Stmt::Block'] );
    my $m2 = $s->methods->[2];
    is( $m2->name,              'add' );
    is( $m2->params->@*,        1 );
    is( $m2->params->[0]{type}, 'i64' );
    is( $m2->params->[0]{name}, 'n' );
    is( $m2->return_type,       'i64' );
};
subtest 'ADJUST block inside class' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
class Channel {
    field i32 $capacity :param;
    ADJUST {
        if ($capacity < 1) { $capacity = 1; }
    }
}
BROCKEN
    is( $prog->statements->@*, 1, 'one declaration' );
    my $s = $prog->statements->[0];
    isa_ok( $s, ['Brocken::Katsuro::AST::Stmt::ClassDecl'] );
    ok( defined $s->adjust, 'has ADJUST block' );
    isa_ok( $s->adjust,       ['Brocken::Katsuro::AST::Stmt::Adjust'] );
    isa_ok( $s->adjust->body, ['Brocken::Katsuro::AST::Stmt::Block'] );
};
subtest 'Field access and method call syntax' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
sub test() -> i64 {
    my ptr $p;
    $p->count;
    $p->increment();
    return $p->get_value();
}
BROCKEN
    my $sub   = $prog->statements->[0];
    my $stmts = $sub->body->statements;
    isa_ok( $stmts->[1], ['Brocken::Katsuro::AST::Expr::FieldAccess'], 'field access' );
    is( $stmts->[1]->field, 'count' );
    isa_ok( $stmts->[1]->obj, ['Brocken::Katsuro::AST::Expr::Var'] );
    is( $stmts->[1]->obj->name, 'p' );
    isa_ok( $stmts->[2], ['Brocken::Katsuro::AST::Expr::MethodCall'], 'method call' );
    is( $stmts->[2]->method,   'increment' );
    is( $stmts->[2]->args->@*, 0 );
    my $ret = $stmts->[3];
    isa_ok( $ret,       ['Brocken::Katsuro::AST::Stmt::Return'] );
    isa_ok( $ret->expr, ['Brocken::Katsuro::AST::Expr::MethodCall'] );
    is( $ret->expr->method,   'get_value' );
    is( $ret->expr->args->@*, 0 );
};
subtest '__CLASS__ expression' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
sub test() {
    say(__CLASS__);
}
BROCKEN
    my $sub  = $prog->statements->[0];
    my $stmt = $sub->body->statements->[0];
    isa_ok( $stmt,            ['Brocken::Katsuro::AST::Expr::Call'] );
    isa_ok( $stmt->args->[0], ['Brocken::Katsuro::AST::Expr::ClassConst'] );
};
subtest 'Full program: sub + class + vars + calls' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
class Channel {
    field i32 $capacity;
    field i32 $count;
    field i32 $closed;
}

sub channel_send(ptr $chan, i64 $val) -> i64 {
    my i64 $result = 0;
    if ($closed) {
        return 0;
    }
    while ($count >= $capacity) {
        # spin
    }
    return $result;
}
BROCKEN
    is( $prog->statements->@*, 2, 'two top-level declarations' );
    isa_ok( $prog->statements->[0], ['Brocken::Katsuro::AST::Stmt::ClassDecl'] );
    isa_ok( $prog->statements->[1], ['Brocken::Katsuro::AST::Stmt::SubDecl'] );
    my $sub = $prog->statements->[1];
    is( $sub->name,                 'channel_send' );
    is( $sub->params->@*,           2 );
    is( $sub->params->[0]{type},    'ptr' );
    is( $sub->params->[0]{name},    'chan' );
    is( $sub->params->[1]{type},    'i64' );
    is( $sub->params->[1]{name},    'val' );
    is( $sub->return_type,          'i64' );
    is( $sub->body->statements->@*, 4, '4 stmts in body' );
    isa_ok( $sub->body->statements->[0], ['Brocken::Katsuro::AST::Stmt::VarDecl'] );
    isa_ok( $sub->body->statements->[1], ['Brocken::Katsuro::AST::Stmt::If'] );
    isa_ok( $sub->body->statements->[2], ['Brocken::Katsuro::AST::Stmt::While'] );
    isa_ok( $sub->body->statements->[3], ['Brocken::Katsuro::AST::Stmt::Return'] );
};

# Subtest: Array declaration
subtest 'Array declaration' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
my [i64; 10] @arr;
BROCKEN
    is( $prog->statements->@*, 1, 'one statement' );
    isa_ok( $prog->statements->[0], ['Brocken::Katsuro::AST::Stmt::ArrayDecl'] );
    my $ad = $prog->statements->[0];
    is( $ad->name,      'arr', 'array name' );
    is( $ad->elem_type, 'i64', 'element type' );
    isa_ok( $ad->size_expr, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $ad->size_expr->value, 10, 'size' );
};

# Subtest: Array element access (read)
subtest 'Array element access' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
my [i64; 10] @arr;
my i64 $x = @arr[3];
BROCKEN
    is( $prog->statements->@*, 2, 'two statements' );
    isa_ok( $prog->statements->[0],       ['Brocken::Katsuro::AST::Stmt::ArrayDecl'] );
    isa_ok( $prog->statements->[1],       ['Brocken::Katsuro::AST::Stmt::VarDecl'] );
    isa_ok( $prog->statements->[1]->init, ['Brocken::Katsuro::AST::Expr::ArrayIndex'] );
    my $ai = $prog->statements->[1]->init;
    isa_ok( $ai->array, ['Brocken::Katsuro::AST::Expr::Var'] );
    is( $ai->array->sigil, '@',   'array sigil' );
    is( $ai->array->name,  'arr', 'array name' );
    isa_ok( $ai->index, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $ai->index->value, 3, 'index value' );
};

# Subtest: Array element write
subtest 'Array element write' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
my [i64; 10] @arr;
@arr[3] = 42;
BROCKEN
    is( $prog->statements->@*, 2, 'two statements' );
    isa_ok( $prog->statements->[1], ['Brocken::Katsuro::AST::Stmt::Assign'] );
    my $assign = $prog->statements->[1];
    isa_ok( $assign->target, ['Brocken::Katsuro::AST::Expr::ArrayIndex'] );
    is( $assign->target->array->name,  'arr' );
    is( $assign->target->index->value, 3 );
    is( $assign->expr->value,          42 );
};

# Subtest: use feature brocken_native_types
subtest 'use feature brocken_native_types' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only(<<'BROCKEN');
use feature 'brocken_native_types';
my i128 $x = 0;
BROCKEN
    is( $prog->statements->@*, 1, 'one statement (use feature filtered out)' );
    isa_ok( $prog->statements->[0], ['Brocken::Katsuro::AST::Stmt::VarDecl'] );
    is( $prog->statements->[0]->type, 'i128', 'i128 type enabled by feature' );
};

# === Source position tests ===
subtest 'Source positions on expressions and statements' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only( <<'BROCKEN', 'test.br' );
my i64 $x = 42;
return $x;
if (1) { return 1; }
sub foo(i64 $n) -> i64 { return $n; }
class Point { field i64 $x; }
BROCKEN

    # VarDecl position comes from $var_token (e.g. '$x'), not 'my' keyword
    my $vd = $prog->statements->[0];
    is( $vd->file, 'test.br', 'VarDecl file' );
    is( $vd->line, 1,         'VarDecl line' );
    is( $vd->col,  8,         'VarDecl col ($x)' );

    # Const position comes from the NUM token '42'
    my $init = $vd->init;
    is( $init->line, 1,  'Const line' );
    is( $init->col,  13, 'Const col (42)' );

    # 'return' keyword at col 1, line 2
    my $ret = $prog->statements->[1];
    is( $ret->line,      2, 'Return line' );
    is( $ret->col,       1, 'Return col' );
    is( $ret->expr->col, 8, 'Var col ($x)' );

    # 'if' keyword at col 1, line 3
    my $if = $prog->statements->[2];
    is( $if->line, 3, 'If line' );
    is( $if->col,  1, 'If col' );

    # 'sub' keyword at col 1, line 4
    my $sub = $prog->statements->[3];
    is( $sub->line, 4, 'Sub line' );
    is( $sub->col,  1, 'Sub col' );

    # 'class' keyword at col 1, line 5
    my $class = $prog->statements->[4];
    is( $class->line, 5, 'Class line' );
    is( $class->col,  1, 'Class col' );
};
subtest 'Source positions on expressions (in call)' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only( <<'BROCKEN', 'test.br' );
my i64 $r = foo(1 + 2 * 3);
BROCKEN

    # Call position comes from '(' token (opening paren of arg list)
    # 'm'=1, 'y'=2, ' '=3, 'i'=4, '6'=5, '4'=6, ' '=7, '$'=8, 'r'=9, ' '=10, '='=11, ' '=12,
    # 'f'=13, 'o'=14, 'o'=15, '('=16
    my $call = $prog->statements->[0]->init;
    is( $call->line, 1,  'Call line' );
    is( $call->col,  16, 'Call col (opening paren)' );

    # BinOp position comes from the OP token (the operator itself)
    # ... '('=16, '1'=17, ' '=18, '+'=19
    my $inner = $call->args->[0];
    is( $inner->line, 1,  'BinOp line' );
    is( $inner->col,  19, 'BinOp col (+)' );
};
subtest 'Parser error includes position' => sub {
    my $c = Brocken::Compiler->new;
    eval { $c->parse_only( 'my i64 $x = ;', 'test.br' ) };
    ok( $@, 'parse error thrown' );
    like( $@, qr/test\.br/, 'error mentions filename' );
    like( $@, qr/line 1/,   'error mentions line' );
};
subtest 'Default filename is (eval)' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('my i64 $x = 42;');
    is( $prog->statements->[0]->file, '(eval)', 'default file is (eval)' );
};
done_testing;
