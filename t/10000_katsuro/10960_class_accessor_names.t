use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# Perl strips exactly one leading underscore when deriving a default accessor or constructor-parameter name from a
# field: `field $_x :param :reader` is addressed by the caller as `new(x => ...)` and read back as `$obj->x`.
# Each attribute also accepts an explicit name in parentheses, `:param(name)` / `:reader(name)` / `:writer(name)`,
# and `:accessor(name)` names its reader (the writer is `set_` + that name).
subtest 'leading underscore is stripped from default names' => sub {
    answers( 'class P { field i64 $_x :param :reader; } my ptr $p = P->new(x => 42); return $p->x();',
        42, 'new(x => ...) sets $_x and x() reads it' );
    answers( 'class C { field i64 $_count :param :writer; } my ptr $c = C->new(count => 1); $c->set_count(9); return $c->_count;',
        9, 'set_count() is the default writer for $_count' );
    answers( 'class D { field i64 $__bar :param; } my ptr $d = D->new(_bar => 5); return $d->__bar;',
        5, 'only one underscore is stripped: $__bar -> param _bar' );
};

subtest 'custom accessor names via payloads' => sub {
    answers( 'class P { field i64 $x :param :reader(get_x); } my ptr $p = P->new(x => 7); return $p->get_x();',
        7, ':reader(get_x) generates get_x()' );
    answers( 'class P { field i64 $x :param :writer(write_x); } my ptr $p = P->new(x => 1); $p->write_x(5)->write_x(6); return $p->x;',
        6, ':writer(write_x) generates write_x and chains' );
    answers( 'class V { field i64 $v :param :accessor(get_v); } my ptr $x = V->new(v => 3); $x->set_get_v(4); return $x->get_v();',
        4, ':accessor(get_v) reads as get_v and writes as set_get_v' );
};

subtest 'custom constructor parameter names' => sub {
    answers( 'class B { field i64 $size :param(amount); } my ptr $b = B->new(amount => 11); return $b->size;',
        11, ':param(amount) is set through new(amount => ...)' );
    answers( 'class T { field i64 $_total :param(grand_total); } my ptr $t = T->new(grand_total => 13); return $t->_total;',
        13, 'an explicit :param name beats underscore stripping' );
    answers( 'class A { field i64 $a :param(first); field i64 $b :param(second); } my ptr $p = A->new(7, 8); return $p->a + $p->b;',
        15, 'positional construction still follows declaration order' );
};

subtest 'custom param names combine with defaults' => sub {
    answers( 'class Cnt { field i64 $_count :param(total) ||= 3; } my ptr $c = Cnt->new(); return $c->_count;',
        3, 'a default applies when the custom-named param is absent' );
    answers( 'class Cnt { field i64 $_count :param(total) ||= 3; } my ptr $c = Cnt->new(total => 0); return $c->_count;',
        3, '||= still replaces a false supplied value under a custom name' );
    answers( 'class Cnt { field i64 $_count :param(total) ||= 3; } my ptr $c = Cnt->new(total => 9); return $c->_count;',
        9, 'a true supplied value is kept under a custom name' );
};
done_testing;