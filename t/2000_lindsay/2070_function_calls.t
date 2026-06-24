use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
{
    my $module    = Brocken::Lindsay::IR::Module->new( name => 'call_test' );
    my $ffi_param = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() );
    my $ffi_puts  = Brocken::Lindsay::IR::Function->new( name => 'puts', return_type => Brocken::Lindsay::IR::Type::i32(), params => [$ffi_param] );
    $module->add_function($ffi_puts);
    my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_main);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_main->append_block('entry') );
    my $str_ptr  = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '@hello_str' );
    my $puts_res = $builder->build_call( $ffi_puts, [$str_ptr], '%puts_res' );
    $builder->build_ret($puts_res);
    my $expected_ir = <<~'IR';
; ModuleID = 'call_test'

declare i32 @puts(ptr)

define i32 @main() {
entry:
  %puts_res = call i32 @puts(ptr @hello_str)
  ret i32 %puts_res
}

IR
    is $module->as_string, $expected_ir, 'Generated IR supports FFI declarations and calls';
}
done_testing;
