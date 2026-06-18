use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
{
    my $module  = Brocken::Lindsay::IR::Module->new( name => 'control_flow' );
    my $param_a = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%a' );
    my $param_b = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%b' );
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'max_val', return_type => Brocken::Lindsay::IR::Type::i32(),
        params => [ $param_a, $param_b ] );
    $module->add_function($func);
    my $entry_blk = $func->append_block('entry');
    my $then_blk  = $func->append_block('if.then');
    my $else_blk  = $func->append_block('if.else');
    my $builder   = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end($entry_blk);
    my $cond = $builder->build_icmp( 'sgt', $param_a, $param_b, '%cmp' );
    $builder->build_cond_br( $cond, $then_blk, $else_blk );
    $builder->position_at_end($then_blk);
    $builder->build_ret($param_a);
    $builder->position_at_end($else_blk);
    $builder->build_ret($param_b);
    my $expected_ir = <<~'IR';
; ModuleID = 'control_flow'

define i32 @max_val(i32 %a, i32 %b) {
entry:
  %cmp = icmp sgt i32 %a, %b
  br i1 %cmp, label %if.then, label %if.else
if.then:
  ret i32 %a
if.else:
  ret i32 %b
}

IR
    is $module->as_string, $expected_ir, 'Generated If/Else IR matches expected output';
}
done_testing;
