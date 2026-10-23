use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::AST;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'hash literal parses as Expr::Hash' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(ptr) { return (a => 1, b => 2); }');
    my $func = $prog->statements->[0];
    my $ret  = $func->body->statements->[0];
    isa_ok( $ret, ['Brocken::Katsuro::AST::Stmt::Return'] );
    my $expr = $ret->expr;
    isa_ok( $expr, ['Brocken::Katsuro::AST::Expr::Hash'] );
    is( $expr->pairs->@*, 2, 'two pairs' );
    isa_ok( $expr->pairs->[0]->{key}, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $expr->pairs->[0]->{key}->value,   'a', 'first key is "a"' );
    is( $expr->pairs->[0]->{value}->value, 1,   'first value is 1' );
    isa_ok( $expr->pairs->[1]->{key}, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $expr->pairs->[1]->{key}->value,   'b', 'second key is "b"' );
    is( $expr->pairs->[1]->{value}->value, 2,   'second value is 2' );
};
subtest 'fat comma auto-quotes bareword key' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(ptr) { return (name => "hello"); }');
    my $ret  = $prog->statements->[0]->body->statements->[0];
    my $hash = $ret->expr;
    isa_ok( $hash, ['Brocken::Katsuro::AST::Expr::Hash'] );
    my $pair = $hash->pairs->[0];
    isa_ok( $pair->{key}, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $pair->{key}->value, 'name', 'key is string "name"' );
};
subtest 'bare paren without => is not hash' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(ptr) { return (42); }');
    my $ret  = $prog->statements->[0]->body->statements->[0];
    my $expr = $ret->expr;
    isa_ok( $expr, ['Brocken::Katsuro::AST::Expr::List'] );
};
subtest 'comma paren without => is list' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(ptr) { return (1, 2, 3); }');
    my $ret  = $prog->statements->[0]->body->statements->[0];
    my $expr = $ret->expr;
    isa_ok( $expr, ['Brocken::Katsuro::AST::Expr::List'] );
};
subtest 'mixed positional and named call arguments keep the positional prefix' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(i64) { return bar(1, x => 2); }');
    my $ret  = $prog->statements->[0]->body->statements->[0];
    my $call = $ret->expr;
    isa_ok( $call, ['Brocken::Katsuro::AST::Expr::Call'] );
    is( scalar( $call->args->@* ), 2, 'two arguments: positional then hash' );
    isa_ok( $call->args->[0], ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $call->args->[0]->value, 1, 'positional value preserved' );
    isa_ok( $call->args->[1], ['Brocken::Katsuro::AST::Expr::Hash'] );
    is( $call->args->[1]->pairs->@*, 1, 'one named pair' );
};
subtest 'hash literal produces ptr type' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
sub make_hash() :returns(ptr) {
    return (x => 10, y => 20);
}
BROCKEN
    my $f;
    for ( $mod->functions->@* ) { $f = $_ if $_->name eq 'make_hash' }
    ok( $f, 'found make_hash' );
    is( $f->return_type->as_string, 'ptr', 'returns ptr' );
};
subtest 'named constructor with hash args' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Point {
    field i64 $x;
    field i64 $y;
}
my ptr $p = Point->new(x => 3, y => 4);
return $p->x + $p->y;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/hash_named_ctor' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 7, 'Point->new(x=>3, y=>4) -> x+y=7' );
        unlink $file;
    }
};
subtest 'named constructor with :param fields' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
    field i64 $y :param;
}
my ptr $p = Point->new(x => 5, y => 6);
return $p->x + $p->y;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/hash_named_param_ctor' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 11, 'Point->new(x=>5, y=>6) with :param -> x+y=11' );
        unlink $file;
    }
};
subtest 'positional constructor arguments for :param fields' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
    field i64 $y :param;
}
my ptr $p = Point->new(4, 9);
return $p->x + $p->y;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/pos_param_ctor' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 13, 'Point->new(4, 9) with :param -> 4+9=13' );
        unlink $file;
    }
};
subtest 'mixed positional and named constructor arguments' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
    field i64 $y :param;
}
my ptr $p = Point->new(4, y => 9);
return $p->x + $p->y;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/mixed_param_ctor' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 13, 'Point->new(4, y=>9) -> 4+9=13' );
        unlink $file;
    }
};
subtest 'hash element access parses as Expr::HashIndex' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(i64) { my %h; %h{"a"} = 1; return %h{"a"}; }');
    my $body = $prog->statements->[0]->body->statements;

    # `%h{"a"} = 1;` lowers to a Stmt::Assign whose target is an Expr::HashIndex.
    my $store = $body->[1];
    isa_ok( $store,               ['Brocken::Katsuro::AST::Stmt::Assign'] );
    isa_ok( $store->target,       ['Brocken::Katsuro::AST::Expr::HashIndex'] );
    isa_ok( $store->target->hash, ['Brocken::Katsuro::AST::Expr::Var'] );
    is( $store->target->hash->sigil, '%', 'subscript base keeps the % sigil' );
    isa_ok( $store->target->key, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $store->target->key->value, 'a', 'key is the string "a"' );

    # `return %h{"a"};` reads back through the same node kind.
    my $ret = $body->[2];
    isa_ok( $ret,       ['Brocken::Katsuro::AST::Stmt::Return'] );
    isa_ok( $ret->expr, ['Brocken::Katsuro::AST::Expr::HashIndex'] );
};
subtest 'exists %h{key} parses as Expr::Exists over an Expr::HashIndex' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(i64) { my %h; if (exists %h{"a"}) { return 1; } return 0; }');
    my $body = $prog->statements->[0]->body->statements;
    my $if   = $body->[1];
    isa_ok( $if, ['Brocken::Katsuro::AST::Stmt::If'] );
    my $cond = $if->cond;
    isa_ok( $cond,             ['Brocken::Katsuro::AST::Expr::Exists'] );
    isa_ok( $cond->expr,       ['Brocken::Katsuro::AST::Expr::HashIndex'], 'the argument is a hash element' );
    isa_ok( $cond->expr->hash, ['Brocken::Katsuro::AST::Expr::Var'] );
    is( $cond->expr->hash->sigil, '%', 'subscript base keeps the % sigil' );
};
done_testing;
