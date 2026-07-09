use v5.42;
use Test2::V0;
use lib 'lib', '../../lib', '../../../lib';
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
no warnings qw[experimental::class];
use feature qw[class];
my $i32  = Brocken::Lindsay::IR::Type::i32();
my $i64  = Brocken::Lindsay::IR::Type::i64();
my $ptr  = Brocken::Lindsay::IR::Type::ptr();
my $void = Brocken::Lindsay::IR::Type::void();
my $dyn  = Brocken::Lindsay::IR::Type::dynamic();

# 1. Fiber IR instruction rendering
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $func = Brocken::Lindsay::IR::Function->new(
        name        => 'worker',
        return_type => $i32,
        params      => [ Brocken::Lindsay::IR::Value->new( type => $i32, name => '%arg' ) ]
    );
    $b->position_at_end( $func->append_block('entry') );
    my $fid = $b->build_fiber_id('%tid');
    like $fid->render, qr/fiber_id/, 'fiber_id renders';
    my $y = $b->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ), '%yv' );
    like $y->render, qr/fiber_yield/, 'fiber_yield renders';
    like $y->render, qr/i32 42/,      'fiber_yield includes sent value';
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    my $main_func = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    $b->position_at_end( $main_func->append_block('entry') );
    my $fc = $b->build_fiber_create( $func, [], '%f' );
    like $fc->render, qr/fiber_create/, 'fiber_create renders';
    like $fc->render, qr/\@worker/,     'fiber_create names the callee';
    my $send = Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 );
    my $ft   = $b->build_fiber_transfer( $fc, $send, '%res' );
    like $ft->render, qr/fiber_transfer/, 'fiber_transfer renders';
    my $pin_tid = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 );
    $b->build_fiber_pin( $fc, $pin_tid );
    ok 1, 'fiber_pin builds without error';
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    pass 'All fiber IR instructions built successfully';
}

# 2. Instruction type checks
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $func = Brocken::Lindsay::IR::Function->new( name => 't', return_type => $void );
    $b->position_at_end( $func->append_block('entry') );
    my $fid = $b->build_fiber_id('%t');
    is $fid->type->kind, 'int', 'fiber_id returns int';
    is $fid->type->bits, 64,    'fiber_id returns i64';
    my $fc = $b->build_fiber_create( $func, [], '%t' );
    is $fc->type->kind, 'ptr', 'fiber_create returns ptr';
    my $y = $b->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ), '%t' );
    is $y->type->kind, 'dynamic', 'fiber_yield returns dynamic';
    $b->build_ret();
    pass 'Fiber IR instruction types correct';
}
done_testing;
