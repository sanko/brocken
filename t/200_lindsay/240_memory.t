use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
{
    my $module      = Brocken::Lindsay::IR::Module->new( name => 'mem_test' );
    my $param_input = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%input' );
    my $func = Brocken::Lindsay::IR::Function->new( name => 'copy_val', return_type => Brocken::Lindsay::IR::Type::void(), params => [$param_input] );
    $module->add_function($func);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%my_ptr' );
    $builder->build_store( $param_input, $ptr );
    my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%loaded_val' );
    $builder->build_ret();
    my $expected_ir = <<~'IR';
; ModuleID = 'mem_test'

define void @copy_val(i32 %input) {
entry:
  %my_ptr = alloca i32
  store i32 %input, ptr %my_ptr
  %loaded_val = load i32, ptr %my_ptr
  ret void
}

IR
    is $module->as_string, $expected_ir, 'Generated Memory IR matches expected LLVM-style output';
}
done_testing;
