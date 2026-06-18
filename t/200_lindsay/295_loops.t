use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
{
    my $module = Brocken::Lindsay::IR::Module->new( name => 'loop_test' );
    my $func   = Brocken::Lindsay::IR::Function->new(
        name        => 'sum_to_n',
        return_type => Brocken::Lindsay::IR::Type::i32(),
        params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%n' ) ]
    );
    $module->add_function($func);
    my $entry   = $func->append_block('entry');
    my $loop    = $func->append_block('loop');
    my $exit    = $func->append_block('exit');
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end($entry);
    $builder->build_br($loop);
    $builder->position_at_end($loop);
    my $i        = $builder->build_phi( Brocken::Lindsay::IR::Type::i32(), '%i' );
    my $sum      = $builder->build_phi( Brocken::Lindsay::IR::Type::i32(), '%sum' );
    my $next_i   = $builder->build_add( $i, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ), '%next_i' );
    my $next_sum = $builder->build_add( $sum, $i, '%next_sum' );
    my $cond     = $builder->build_icmp( 'slt', $i, $func->params->[0], '%cond' );
    $builder->build_cond_br( $cond, $loop, $exit );
    $i->add_incoming( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), $entry );
    $i->add_incoming( $next_i,                                                                                      $loop );
    $sum->add_incoming( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), $entry );
    $sum->add_incoming( $next_sum,                                                                                    $loop );
    $builder->position_at_end($exit);
    $builder->build_ret($sum);
    my $expected_ir = <<~'IR';
; ModuleID = 'loop_test'

define i32 @sum_to_n(i32 %n) {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %next_i, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %next_sum, %loop ]
  %next_i = add i32 %i, 1
  %next_sum = add i32 %sum, %i
  %cond = icmp slt i32 %i, %n
  br i1 %cond, label %loop, label %exit
exit:
  ret i32 %sum
}

IR
    is $module->as_string, $expected_ir, 'Generated Loop IR with PHI nodes matches expected output';
}
done_testing;
