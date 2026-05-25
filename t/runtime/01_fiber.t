use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::AST;
use Brocken::AST::Async;

subtest 'FiberBlock node construction' => sub {
    my $body = Brocken::AST::Block->new( stmts => [] );
    my $fb   = Brocken::AST::Async::FiberBlock->new( body => $body );
    ok $fb->isa('Brocken::AST::Node'),              'FiberBlock isa Node';
    ok $fb->isa('Brocken::AST::Async::FiberBlock'), 'FiberBlock isa FiberBlock';
    is $fb->body, $body,                            'body accessor';
    is $fb->params, [],                             'default params is empty array';
};

subtest 'FiberBlock with params' => sub {
    my $body   = Brocken::AST::Block->new( stmts => [] );
    my $params = [{ name => '$x', type => 'Int' }];
    my $fb     = Brocken::AST::Async::FiberBlock->new( params => $params, body => $body );
    is scalar( @{ $fb->params } ), 1,  'one param';
    is $fb->params->[0]{name}, '$x', 'param name';
};

subtest 'Yield node construction' => sub {
    my $expr  = Brocken::AST::IntLiteral->new( value => 42 );
    my $yield = Brocken::AST::Async::Yield->new( expr => $expr );
    ok $yield->isa('Brocken::AST::Node'),          'Yield isa Node';
    ok $yield->isa('Brocken::AST::Async::Yield'),  'Yield isa Yield';
    is $yield->expr->value, 42,                    'yield expression value';
};

done_testing;
