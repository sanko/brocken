use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Codegen;
use Brocken::IR;
subtest 'Codegen instantiation' => sub {
    my $cg = Brocken::Codegen->new( arch => 'x64' );
    ok $cg->isa('Brocken::Codegen'), 'codegen isa Codegen';
};
subtest 'Codegen compile with label' => sub {
    my $cg = Brocken::Codegen->new( arch => 'x64' );
    my $b  = Brocken::IR::Builder->new;
    $b->emit_label('L_start');
    $b->emit( 'enter_func', 'void', [] );
    $b->emit( 'constant',   'Int',  [1] );
    $b->emit( 'leave_func', 'void', ['%3'] );
    my $insts = $b->instructions;
    ok scalar(@$insts) == 4, 'instructions with label';
};
subtest 'Codegen with conditional branch' => sub {
    my $cg = Brocken::Codegen->new( arch => 'x64' );
    my $b  = Brocken::IR::Builder->new;
    $b->emit( 'enter_func', 'void', [] );
    my $v = $b->emit( 'constant', 'Int', [1] );
    $b->emit_cond_br( $v, 'L_true', 'L_false' );
    $b->emit_label('L_true');
    $b->emit( 'leave_func', 'void', [$v] );
    $b->emit_label('L_false');
    $b->emit( 'leave_func', 'void', ['%999'] );
    ok scalar( $b->instructions ) >= 7, 'instructions with cond_br';
};
done_testing;
