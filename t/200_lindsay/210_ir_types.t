use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

subtest 'type singletons' => sub {
    isa_ok Brocken::Lindsay::IR::Type::i1(),      ['Brocken::Lindsay::IR::Type'], 'i1 singleton';
    isa_ok Brocken::Lindsay::IR::Type::i8(),      ['Brocken::Lindsay::IR::Type'], 'i8 singleton';
    isa_ok Brocken::Lindsay::IR::Type::i16(),     ['Brocken::Lindsay::IR::Type'], 'i16 singleton';
    isa_ok Brocken::Lindsay::IR::Type::i32(),     ['Brocken::Lindsay::IR::Type'], 'i32 singleton';
    isa_ok Brocken::Lindsay::IR::Type::i64(),     ['Brocken::Lindsay::IR::Type'], 'i64 singleton';
    isa_ok Brocken::Lindsay::IR::Type::i128(),    ['Brocken::Lindsay::IR::Type'], 'i128 singleton';
    isa_ok Brocken::Lindsay::IR::Type::f32(),     ['Brocken::Lindsay::IR::Type'], 'f32 singleton';
    isa_ok Brocken::Lindsay::IR::Type::f64(),     ['Brocken::Lindsay::IR::Type'], 'f64 singleton';
    isa_ok Brocken::Lindsay::IR::Type::ptr(),     ['Brocken::Lindsay::IR::Type'], 'ptr singleton';
    isa_ok Brocken::Lindsay::IR::Type::void(),    ['Brocken::Lindsay::IR::Type'], 'void singleton';
    isa_ok Brocken::Lindsay::IR::Type::dynamic(), ['Brocken::Lindsay::IR::Type'], 'dynamic singleton';
};

subtest 'type singleton identity' => sub {
    is Brocken::Lindsay::IR::Type::i32(), Brocken::Lindsay::IR::Type::i32(), 'i32 singletons are identical';
    is Brocken::Lindsay::IR::Type::i64(), Brocken::Lindsay::IR::Type::i64(), 'i64 singletons are identical';
    is Brocken::Lindsay::IR::Type::ptr(), Brocken::Lindsay::IR::Type::ptr(), 'ptr singletons are identical';
};

subtest 'type creation' => sub {
    my $custom = Brocken::Lindsay::IR::Type->new( kind => 'int', bits => 7 );
    isa_ok $custom, ['Brocken::Lindsay::IR::Type'], 'custom type';
    is $custom->kind, 'int', 'custom kind';
    is $custom->bits, 7,     'custom bits';
};

subtest 'type as_string' => sub {
    is Brocken::Lindsay::IR::Type::i1()->as_string,   'i1',   'i1 as_string';
    is Brocken::Lindsay::IR::Type::i8()->as_string,   'i8',   'i8 as_string';
    is Brocken::Lindsay::IR::Type::i32()->as_string,  'i32',  'i32 as_string';
    is Brocken::Lindsay::IR::Type::i64()->as_string,  'i64',  'i64 as_string';
    is Brocken::Lindsay::IR::Type::i128()->as_string, 'i128', 'i128 as_string';
    is Brocken::Lindsay::IR::Type::f32()->as_string,  'f32',  'f32 as_string';
    is Brocken::Lindsay::IR::Type::f64()->as_string,  'f64',  'f64 as_string';
    is Brocken::Lindsay::IR::Type::ptr()->as_string,  'ptr',  'ptr as_string';
    is Brocken::Lindsay::IR::Type::void()->as_string, 'void', 'void as_string';
    is Brocken::Lindsay::IR::Type::dynamic()->as_string, 'dynamic', 'dynamic as_string';
};

done_testing;
