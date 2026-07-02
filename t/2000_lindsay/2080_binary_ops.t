use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
{
    my $module = Brocken::Lindsay::IR::Module->new( name => 'binops' );
    my $a      = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%a' );
    my $b      = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%b' );
    my $func   = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::void(), params => [ $a, $b ] );
    $module->add_function($func);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_sub( $a, $b );
    $builder->build_mul( $a, $b );
    $builder->build_and( $a, $b );
    $builder->build_or( $a, $b );
    $builder->build_xor( $a, $b );
    $builder->build_shl( $a, $b );
    $builder->build_lshr( $a, $b );
    $builder->build_ashr( $a, $b );
    $builder->build_ret();
    my $expected_ir = <<~'IR';
; ModuleID = 'binops'

define void @math(i32 %a, i32 %b) {
entry:
  %0 = sub i32 %a, %b
  %1 = mul i32 %a, %b
  %2 = and i32 %a, %b
  %3 = or i32 %a, %b
  %4 = xor i32 %a, %b
  %5 = shl i32 %a, %b
  %6 = lshr i32 %a, %b
  %7 = ashr i32 %a, %b
  ret void
}

IR
    is $module->as_string, $expected_ir, 'Generated Binary Operators IR matches expected output';
}
done_testing;
