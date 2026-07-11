use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
use Brocken::Katsuro::AST;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'hash literal parses as Expr::Hash' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('sub foo() -> ptr { return (a => 1, b => 2); }');
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
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('sub foo() -> ptr { return (name => "hello"); }');
    my $ret  = $prog->statements->[0]->body->statements->[0];
    my $hash = $ret->expr;
    isa_ok( $hash, ['Brocken::Katsuro::AST::Expr::Hash'] );
    my $pair = $hash->pairs->[0];
    isa_ok( $pair->{key}, ['Brocken::Katsuro::AST::Expr::Const'] );
    is( $pair->{key}->value, 'name', 'key is string "name"' );
};
subtest 'bare paren without => is not hash' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('sub foo() -> ptr { return (42); }');
    my $ret  = $prog->statements->[0]->body->statements->[0];
    my $expr = $ret->expr;
    isa_ok( $expr, ['Brocken::Katsuro::AST::Expr::List'] );
};
subtest 'comma paren without => is list' => sub {
    my $c    = Brocken::Compiler->new;
    my $prog = $c->parse_only('sub foo() -> ptr { return (1, 2, 3); }');
    my $ret  = $prog->statements->[0]->body->statements->[0];
    my $expr = $ret->expr;
    isa_ok( $expr, ['Brocken::Katsuro::AST::Expr::List'] );
};
subtest 'hash literal produces ptr type' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
sub make_hash() -> ptr {
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
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
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
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
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
done_testing;
