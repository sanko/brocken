use v5.42;
use Test2::V0;
use lib 'lib', '../../lib', '../../../lib';
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
no warnings qw[experimental::class];
use feature qw[class];
my $i64  = Brocken::Lindsay::IR::Type::i64();
my $i1   = Brocken::Lindsay::IR::Type::i1();
my $ptr  = Brocken::Lindsay::IR::Type::ptr();
my $void = Brocken::Lindsay::IR::Type::void();
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    $b->position_at_end( $main->append_block('entry') );

    my $ch = $b->build_chan_create( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 16 ), '%ch' );
    like $ch->render, qr/chan_create/, 'chan_create renders';
    like $ch->render, qr/i64 16/,     'chan_create shows capacity';
    ok $ch->type->kind eq 'ptr', 'chan_create returns ptr';

    $b->build_chan_send( $ch, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 42 ) );
    ok 1, 'chan_send builds without error';

    my $rv = $b->build_chan_recv( $ch, '%rv' );
    like $rv->render, qr/chan_recv/, 'chan_recv renders';
    ok $rv->type->bits == 64, 'chan_recv returns i64';

    $b->build_chan_close($ch);
    ok 1, 'chan_close builds without error';

    my $ts = $b->build_chan_try_send( $ch, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 99 ), '%ts' );
    like $ts->render, qr/chan_try_send/, 'chan_try_send renders';
    ok $ts->type->kind eq 'int' && $ts->type->bits == 1, 'chan_try_send returns i1';

    my $tr = $b->build_chan_try_recv( $ch, '%tr' );
    like $tr->render, qr/chan_try_recv/, 'chan_try_recv renders';
    ok $tr->type->kind eq 'int' && $tr->type->bits == 64, 'chan_try_recv returns i64';

    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ) );
    pass 'All channel IR instructions built successfully';
}
done_testing;
