use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
{
    my $module = Brocken::Lindsay::IR::Module->new( name => 'select_gep' );
    my $func   = Brocken::Lindsay::IR::Function->new(
        name        => 'test',
        return_type => Brocken::Lindsay::IR::Type::ptr(),
        params      => [
            Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i1(),  name => '%cond' ),
            Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%base' )
        ]
    );
    $module->add_function($func);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $c1  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 );
    my $c2  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 20 );
    my $val = $builder->build_select( $func->params->[0], $c1, $c2, '%val' );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $func->params->[1], [$val], '%element_ptr' );
    $builder->build_ret($gep);
    my $expected_ir = <<~'IR';
; ModuleID = 'select_gep'

define ptr @test(i1 %cond, ptr %base) {
entry:
  %val = select i1 %cond, i32 10, i32 20
  %element_ptr = getelementptr i32, ptr %base, i32 %val
  ret ptr %element_ptr
}

IR
    is $module->as_string, $expected_ir, 'Generated Select and GEP IR matches expected output';
}
done_testing;
