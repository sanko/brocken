use v5.42;
use lib 'lib', '../../lib', '../lib';
use Test::More;
use Brocken;
use Brocken::Compiler;

subtest 'set_default_policy sets class defaults' => sub {
    Brocken::Compiler->set_default_policy(
        fuel         => 999,
        mem_limit    => 5000,
        capabilities => 0x0F,
    );

    my $c = Brocken::Compiler->new();
    my $mod = $c->compile(<<'BROCKEN');
return 0;
BROCKEN
    ok( $mod, 'compiled with custom policy' );

    Brocken::Compiler->set_default_policy(
        fuel         => 1000000,
        mem_limit    => 0,
        capabilities => ~0,
    );
};

subtest 'set_default_policy globals match' => sub {
    Brocken::Compiler->set_default_policy(
        fuel         => 42,
        mem_limit    => 1234,
        capabilities => 0xFF,
    );
    is( $Brocken::default_fuel,         42,    'global fuel updated' );
    is( $Brocken::default_mem_limit,    1234,  'global mem_limit updated' );
    is( $Brocken::default_capabilities, 0xFF,  'global capabilities updated' );

    Brocken::Compiler->set_default_policy(
        fuel         => 1000000,
        mem_limit    => 0,
        capabilities => ~0,
    );
};

subtest 'per-instance override' => sub {
    Brocken::Compiler->set_default_policy( fuel => 500 );

    my $c = Brocken::Compiler->new( fuel => 999 );
    my $mod = $c->compile(<<'BROCKEN');
return 0;
BROCKEN
    ok( $mod, 'compiled with per-instance fuel override' );

    Brocken::Compiler->set_default_policy( fuel => 1000000 );
};

subtest 'policy flows to IR constants' => sub {
    Brocken::Compiler->set_default_policy( fuel => 777, mem_limit => 8888, capabilities => 0x55 );

    my $c = Brocken::Compiler->new();
    my $mod = $c->compile(<<'BROCKEN');
return 0;
BROCKEN

    my $text = $mod->as_string();
    like( $text, qr/store\s+i64\s+777/,  'fuel constant in IR' );
    like( $text, qr/store\s+i64\s+8888/, 'mem_limit constant in IR' );
    like( $text, qr/store\s+i64\s+85/,   'capabilities constant in IR (0x55=85)' );

    Brocken::Compiler->set_default_policy( fuel => 1000000, mem_limit => 0, capabilities => ~0 );
};

done_testing;
