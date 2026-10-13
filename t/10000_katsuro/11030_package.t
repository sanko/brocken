use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::AST;
use Test2::Tools::Brocken qw[answers];

# `package NAME;` sets a namespace for the declarations that follow in the same scope, and `package NAME { ... }`
# scopes it to the block. `package NAME VERSION` records the version, in the manner of Perl's package statement. The
# short name is what the source writes; the lowerer stores the qualified name (`NAME::short`), so two packages can each
# own a function or class called the same thing.

subtest 'parser: package NAME;' => sub {
    my $c = Brocken->new;
    my $prog = $c->parse(<<'BROCKEN');
package Foo::Bar;
sub seven() :returns(i64) { return 7; }
BROCKEN
    is( $prog->statements->@*, 2, 'package plus sub' );
    my $pkg = $prog->statements->[0];
    isa_ok( $pkg, ['Brocken::Katsuro::AST::Stmt::PackageDecl'] );
    is( $pkg->name,  'Foo::Bar', 'package name' );
    is( $pkg->version, undef,    'no version' );
    is( $pkg->body,  undef,      'semicolon form has no body' );
    my $sub = $prog->statements->[1];
    isa_ok( $sub, ['Brocken::Katsuro::AST::Stmt::SubDecl'] );
    is( $sub->package, 'Foo::Bar', 'the following sub is in the package' );
};

subtest 'parser: package NAME VERSION' => sub {
    my $c = Brocken->new;
    my $prog = $c->parse('package Foo v1.2.3; sub x() :returns(i64) { return 1; }');
    my $pkg  = $prog->statements->[0];
    is( $pkg->name,    'Foo',    'name' );
    is( $pkg->version, 'v1.2.3', 'v-string version' );
    is( $prog->statements->[1]->package, 'Foo', 'sub carries the package' );

    my $dotted = $c->parse('package Math::Geometry 1.0.0;');
    is( $dotted->statements->[0]->version, '1.0.0', 'dotted-decimal version' );
};

subtest 'parser: package NAME BLOCK' => sub {
    my $c = Brocken->new;
    my $prog = $c->parse(<<'BROCKEN');
package Scoped {
    sub inside() :returns(i64) { return 1; }
}
sub after() :returns(i64) { return 2; }
BROCKEN
    is( $prog->statements->@*, 2, 'package block plus sub' );
    my $pkg = $prog->statements->[0];
    isa_ok( $pkg, ['Brocken::Katsuro::AST::Stmt::PackageDecl'] );
    is( $pkg->name, 'Scoped', 'block package name' );
    isa_ok( $pkg->body, ['Brocken::Katsuro::AST::Stmt::Block'] );
    my ($inner) = $pkg->body->statements->@*;
    isa_ok( $inner, ['Brocken::Katsuro::AST::Stmt::SubDecl'] );
    is( $inner->package, 'Scoped', 'inner sub is scoped to the package' );
    my $after = $prog->statements->[1];
    is( $after->package, undef, 'the package block does not leak past it' );
};

subtest 'parser: versioned block' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('package V::W v2.0.0 { sub x() :returns(i64) { return 6; } }');
    my $pkg  = $prog->statements->[0];
    is( $pkg->name,    'V::W',   'name' );
    is( $pkg->version, 'v2.0.0', 'version' );
    isa_ok( $pkg->body, ['Brocken::Katsuro::AST::Stmt::Block'] );
};

subtest 'lowering: declarations are qualified' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
package Foo::Bar;
sub seven() :returns(i64) { return 7; }
class Point { field i64 $x :param; }
BROCKEN
    my %names = map { $_->name => 1 } $mod->functions->@*;
    ok( $names{'Foo::Bar::seven'}, 'sub is stored under the qualified name' );
    ok( !$names{'seven'},         'the bare name is not a function' );
    ok( $mod->class_info->{'Foo::Bar::Point'}, 'class is stored under the qualified name' );
};

subtest 'lowering: recorded package versions' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
package Math::Geometry 1.0.0;
sub distance() :returns(i64) { return 5; }
BROCKEN
    is( $mod->package_versions->{'Math::Geometry'}, '1.0.0', 'version is recorded on the module' );
};

subtest 'sibling calls resolve within the package' => sub {
    answers( 'package Foo; sub seven() :returns(i64) { return 7; } return seven();',
        7, 'an unqualified call finds the packaged sub' );
    answers( 'package Foo; sub a() :returns(i64) { return 4; } sub b() :returns(i64) { return a() + 1; } return b();',
        5, 'a packaged sub calls its sibling unqualified' );
};

subtest 'block form scopes the prefix' => sub {
    answers(
        'sub outside() :returns(i64) { return 9; } package Scope { sub outside() :returns(i64) { return 5; } } return outside() + Scope::outside();',
        14, 'the block name and the top-level name coexist' );
    answers( 'package P { sub inside() :returns(i64) { return 6; } } return P::inside();',
        6, 'a packaged sub is reachable by its qualified name' );
};

subtest 'classes and methods inside a package' => sub {
    answers( <<'BROCKEN', 22, 'constructor, reader, and method all resolve in-package' );
package Geo;
class Point {
    field i64 $x :param;
    method double() :returns(i64) { return $x * 2; }
}
my ptr $p = Point->new(x => 11);
return $p->double();
BROCKEN
    answers( <<'BROCKEN', 7, 'fields read back through a packaged class' );
package Geo;
class Box {
    field i64 $v :param;
}
my ptr $b = Box->new(v => 7);
return $b->v;
BROCKEN
};

subtest 'versioned package declarations run' => sub {
    answers( 'package Math::Geometry 1.0.0; sub area() :returns(i64) { return 3; } return area();',
        3, 'semicolon form with a version' );
    answers( 'package V::W v2.0.0 { sub x() :returns(i64) { return 6; } } return V::W::x();',
        6, 'block form with a version' );
};

subtest 'an already-qualified sub name is not double-prefixed' => sub {
    answers(
        'package Brocken::Thing; sub Brocken::Thing::already() :returns(i64) { return 8; } return already();',
        8, 'an absolute name stays absolute and is callable unqualified' );
};

done_testing;
