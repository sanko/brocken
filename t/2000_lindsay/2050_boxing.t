use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
{
    my $module    = Brocken::Lindsay::IR::Module->new( name => 'gradual_typing' );
    my $param_dyn = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::dynamic(), name => '%input_dyn' );
    my $func
        = Brocken::Lindsay::IR::Function->new( name => 'double_it', return_type => Brocken::Lindsay::IR::Type::dynamic(), params => [$param_dyn] );
    $module->add_function($func);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $native_i64   = $builder->build_unbox( $param_dyn, Brocken::Lindsay::IR::Type::i64(), '%native_val' );
    my $doubled      = $builder->build_add( $native_i64, $native_i64, '%doubled' );
    my $boxed_result = $builder->build_box( $doubled, '%boxed_res' );
    $builder->build_ret($boxed_result);
    my $expected_ir = <<~'IR';
; ModuleID = 'gradual_typing'

define dynamic @double_it(dynamic %input_dyn) {
entry:
  %native_val = unbox dynamic %input_dyn to i64
  %doubled = add i64 %native_val, %native_val
  %boxed_res = box i64 %doubled to dynamic
  ret dynamic %boxed_res
}

IR
    is $module->as_string, $expected_ir, 'Generated Boxing IR matches expected output';
}
done_testing;
