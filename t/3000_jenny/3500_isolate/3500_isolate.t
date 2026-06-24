use v5.42;
use Test2::V0;
use lib 'lib', '../../lib', '../../../lib';
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
no warnings qw[experimental::class];
use feature qw[class];
my $i64  = Brocken::Lindsay::IR::Type::i64();
my $ptr  = Brocken::Lindsay::IR::Type::ptr();
my $void = Brocken::Lindsay::IR::Type::void();
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $func = Brocken::Lindsay::IR::Function->new(
        name        => 'worker',
        return_type => $i64,
        params      => [ Brocken::Lindsay::IR::Value->new( type => $i64, name => '%arg' ) ]
    );
    $b->position_at_end( $func->append_block('entry') );
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ) );
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    $b->position_at_end( $main->append_block('entry') );
    my $ic = $b->build_isolate_create( $func, [ Brocken::Lindsay::IR::Constant->new( type => $i64, value => 42 ) ], '%iso' );
    like $ic->render, qr/isolate_create/, 'isolate_create renders';
    like $ic->render, qr/\@worker/,       'isolate_create names the callee';
    ok $ic->type->kind eq 'int' && $ic->type->bits == 64, 'isolate_create returns i64';
    $b->build_isolate_join($ic);
    ok 1, 'isolate_join builds without error';
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ) );
    pass 'All isolate IR instructions built successfully';
}
done_testing;
