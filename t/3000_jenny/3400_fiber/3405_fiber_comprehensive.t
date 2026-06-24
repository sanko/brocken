use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
SKIP: {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    skip 'Comprehensive fiber tests only on native hosts', 1 unless $host->is_native;
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # ────────────────────────────────────────────────────────────
    # 1. Multi-yield from a single fiber
    #    Worker yields 3 different values; main collects the last.
    # ────────────────────────────────────────────────────────────
    subtest 'Multi-yield from single fiber' => sub {
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 100 ), '%y1' );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 200 ), '%y2' );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 77 ),  '%y3' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $fcb = $mb->build_fiber_create( $worker, [], '%fcb' );
        $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r1' );
        $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 2 ), '%r2' );
        my $r3 = $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 3 ), '%r3' );
        $mb->build_ret($r3);
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker ] );
        is( scalar @$funcs, 3, '3 functions emitted (wrapper, _real_main, worker_fn)' );
        my $file = 'fiber_multi_yield' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        run_exec( $file, expected_exit => 77, name => 'multi-yield fiber exit 77', platform => $host );
    };

    # ────────────────────────────────────────────────────────────
    # 2. Two independent fibers
    #    Main creates 2 workers, transfers to each, gets distinct values.
    # ────────────────────────────────────────────────────────────
    subtest 'Two independent fibers' => sub {
        my $worker1 = Brocken::Lindsay::IR::Function->new( name => 'worker_one', return_type => $i32 );
        my $wb1     = Brocken::Lindsay::IR::Builder->new();
        $wb1->position_at_end( $worker1->append_block('entry') );
        $wb1->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 111 ), '%y1' );
        $wb1->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 111 ), '%y1b' );
        $wb1->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $worker2 = Brocken::Lindsay::IR::Function->new( name => 'worker_two', return_type => $i32 );
        my $wb2     = Brocken::Lindsay::IR::Builder->new();
        $wb2->position_at_end( $worker2->append_block('entry') );
        $wb2->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 222 ), '%y2' );
        $wb2->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $f1 = $mb->build_fiber_create( $worker1, [], '%f1' );
        my $f2 = $mb->build_fiber_create( $worker2, [], '%f2' );
        $mb->build_fiber_transfer( $f1, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r1' );
        $mb->build_fiber_transfer( $f2, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r2' );

        # Resume worker1 again after worker2 yielded back
        my $r3 = $mb->build_fiber_transfer( $f1, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r3' );
        $mb->build_ret($r3);
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker1, $worker2 ] );
        is( scalar @$funcs, 4, '4 functions emitted (wrapper, _real_main, worker_one, worker_two)' );
        my $file = 'fiber_two_workers' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        run_exec( $file, expected_exit => 111, name => 'two-fiber resume worker1 yields 111', platform => $host );
    };

    # ────────────────────────────────────────────────────────────
    # 3. Stack stress test
    #    Worker alloca's a large buffer (~16KB) to stress stack
    #    probing in the worker's own frame, then yields a value.
    # ────────────────────────────────────────────────────────────
    subtest 'Stack stress with large frame' => sub {
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );

        # alloca 16384 bytes via a custom int type with enough bits
        my $big_type = Brocken::Lindsay::IR::Type->new( kind => 'int', bits => 16384 * 8 );
        $wb->build_alloca( $big_type, '%big' );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 55 ), '%yv' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $fcb  = $mb->build_fiber_create( $worker, [], '%fcb' );
        my $recv = $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%recv' );
        $mb->build_ret($recv);
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker ] );
        is( scalar @$funcs, 3, '3 functions emitted (wrapper, _real_main, worker_fn)' );
        my $file = 'fiber_stack_stress' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        run_exec( $file, expected_exit => 55, name => 'stack stress fiber exit 55', platform => $host );
    };

    # ────────────────────────────────────────────────────────────
    # 4. Chain: worker yields multiple times then returns
    #    Main does 4 transfers, gets 4 different values.
    # ────────────────────────────────────────────────────────────
    subtest 'Multi-transfer chain' => sub {
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 10 ), '%y1' );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 20 ), '%y2' );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 30 ), '%y3' );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 42 ), '%y4' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $fcb = $mb->build_fiber_create( $worker, [], '%fcb' );
        $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r1' );
        $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r2' );
        $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r3' );
        my $r4 = $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r4' );
        $mb->build_ret($r4);
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker ] );
        is( scalar @$funcs, 3, '3 functions emitted' );
        my $file = 'fiber_chain' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 42, name => 'chain fiber last yield 42', platform => $host, keep => 1, gdb => $dbg );
    };

    # ────────────────────────────────────────────────────────────
    # 5. Interleaved transfers between three fibers
    #    Main -> W1 (yields) -> Main -> W2 (yields) -> Main -> W1 again
    # ────────────────────────────────────────────────────────────
    subtest 'Interleaved three-fiber transfer' => sub {
        my $worker1 = Brocken::Lindsay::IR::Function->new( name => 'worker_one', return_type => $i32 );
        my $wb1     = Brocken::Lindsay::IR::Builder->new();
        $wb1->position_at_end( $worker1->append_block('entry') );
        $wb1->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 50 ), '%y1' );
        $wb1->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 50 ), '%y1b' );
        $wb1->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $worker2 = Brocken::Lindsay::IR::Function->new( name => 'worker_two', return_type => $i32 );
        my $wb2     = Brocken::Lindsay::IR::Builder->new();
        $wb2->position_at_end( $worker2->append_block('entry') );
        $wb2->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 60 ), '%y2' );
        $wb2->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $worker3 = Brocken::Lindsay::IR::Function->new( name => 'worker_three', return_type => $i32 );
        my $wb3     = Brocken::Lindsay::IR::Builder->new();
        $wb3->position_at_end( $worker3->append_block('entry') );
        $wb3->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 70 ), '%y3' );
        $wb3->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $f1 = $mb->build_fiber_create( $worker1, [], '%f1' );
        my $f2 = $mb->build_fiber_create( $worker2, [], '%f2' );
        my $f3 = $mb->build_fiber_create( $worker3, [], '%f3' );

        # Transfer to each in sequence, then resume worker1
        $mb->build_fiber_transfer( $f1, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r1' );
        $mb->build_fiber_transfer( $f2, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r2' );
        $mb->build_fiber_transfer( $f3, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r3' );
        my $r4 = $mb->build_fiber_transfer( $f1, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r4' );
        $mb->build_ret($r4);
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker1, $worker2, $worker3 ] );
        is( scalar @$funcs, 5, '5 functions emitted' );
        my $file = 'fiber_interleave' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        run_exec( $file, expected_exit => 50, name => 'interleaved three-fiber exit 50', platform => $host );
    };
}
done_testing;
