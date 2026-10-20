use v5.42;
use Test2::V0;
use blib;
use Brocken::Lindsay;
BEGIN {
    if (eval { require Test::LeakTrace; Test::LeakTrace->import('no_leaks_ok'); 1 }) {
        # ok
    } else {
        no warnings 'redefine';
        *no_leaks_ok = sub {
            my ($cb, $msg) = @_;
            $cb->();
            pass($msg // 'leak test skipped (Test::LeakTrace missing)');
            return;
        };
    }
}

# Build a small IR module with cycles (branch back to entry, call to another
# function) and verify it can be released/freed without leaking.
subtest 'IR module with cycles releases without leaks' => sub {
    no_leaks_ok {
        my $mod = Brocken::Lindsay::IR::Module->new( name => 'leaktest' );
        my $fn1 = Brocken::Lindsay::IR::Function->new(
            name        => 'f1',
            return_type => Brocken::Lindsay::IR::Type::i64(),
        );
        my $bb = $fn1->append_block('entry');
        my $fn2 = Brocken::Lindsay::IR::Function->new(
            name        => 'f2',
            return_type => Brocken::Lindsay::IR::Type::i64(),
        );
        my $bb2 = $fn2->append_block('entry2');
        my $b    = Brocken::Lindsay::IR::Builder->new();
        $b->position_at_end($bb);
        my $call = $b->build_call( $fn2, [], 'r' );
        $b->build_br($bb);    # cycle back to self
        $b->position_at_end($bb2);
        $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 42 ) );
        $mod->add_function($fn1);
        $mod->add_function($fn2);
        $mod->release;
    } 'module with cyclic references releases cleanly';
};

subtest 'module is freed on drop after release' => sub {
    my $freed;
    {
        my $mod = Brocken::Lindsay::IR::Module->new( name => 'leaktest2' );
        my $fn  = Brocken::Lindsay::IR::Function->new(
            name        => 'main',
            return_type => Brocken::Lindsay::IR::Type::i64(),
        );
        my $bb = $fn->append_block('entry');
        my $b  = Brocken::Lindsay::IR::Builder->new();
        $b->position_at_end($bb);
        $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 ) );
        $mod->add_function($fn);
        $mod->release;
        # weaken ref to check collection behavior
        weaken($mod);
        $freed = !defined $mod;
    }
    ok $freed, 'module freed after scope exit';
};

done_testing;
