use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

subtest 'build IR function with arithmetic' => sub {
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $func    = Brocken::Lindsay::IR::Function->new(
        name => 'test', return_type => Brocken::Lindsay::IR::Type::i32(),
    );
    my $block = $func->append_block('entry');
    $builder->position_at_end($block);

    my $lhs = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 );
    my $rhs = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 32 );
    my $add = $builder->build_add( $lhs, $rhs );
    $builder->build_ret($add);

    like $func->as_string, qr/define i32 \@test/, 'function definition';
    like $func->as_string, qr/add/, 'has add instruction';
    like $func->as_string, qr/ret/, 'has ret instruction';
};

subtest 'build IR function with control flow' => sub {
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $func    = Brocken::Lindsay::IR::Function->new(
        name => 'iftest', return_type => Brocken::Lindsay::IR::Type::i32(),
    );
    my $entry  = $func->append_block('entry');
    my $then   = $func->append_block('then');
    my $else_b = $func->append_block('else');
    my $merge  = $func->append_block('merge');

    $builder->position_at_end($entry);
    my $cond  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => 1 );
    my $cbr   = $builder->build_cond_br( $cond, $then, $else_b );

    $builder->position_at_end($then);
    my $tval = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 );
    $builder->build_br($merge);

    $builder->position_at_end($else_b);
    my $eval = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 );
    $builder->build_br($merge);

    $builder->position_at_end($merge);
    my $phi = $builder->build_phi( Brocken::Lindsay::IR::Type::i32() );
    $phi->add_incoming( $tval, $then );
    $phi->add_incoming( $eval, $else_b );
    $builder->build_ret($phi);

    my $ir = $func->as_string;
    like $ir, qr/define i32 \@iftest/, 'iftest function definition';
    like $ir, qr/br i1 1, label %then, label %else/, 'conditional branch';
    like $ir, qr/br label %merge/, 'unconditional branch';
    like $ir, qr/phi/, 'phi instruction';
    like $ir, qr/ret i32/, 'return';
};

subtest 'build IR module' => sub {
    my $module = Brocken::Lindsay::IR::Module->new( name => 'testmod' );

    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $func    = Brocken::Lindsay::IR::Function->new(
        name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(),
    );
    my $block = $func->append_block('entry');
    $builder->position_at_end($block);
    my $c   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 );
    $builder->build_ret($c);
    $module->add_function($func);

    my $ir = $module->as_string;
    like $ir, qr/ModuleID = 'testmod'/, 'module header';
    like $ir, qr/define i32 \@main/, 'module function';
};

done_testing;
