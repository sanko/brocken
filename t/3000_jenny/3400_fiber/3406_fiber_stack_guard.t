use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::ICB;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
SKIP: {
    my $brocken  = Brocken->new();
    my $platform = $brocken->platform;
    skip 'Fiber stack-guard tests only on native hosts', 1 unless $platform->is_native;
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();
    my $ptr = Brocken::Lindsay::IR::Type::ptr();

    # Shared salted recursion driver.  Counts down from %n calling itself on the
    # 64 KiB fiber stack; guarded because its first parameter is the hidden
    # %__heap_base, so once the stack pointer crosses the fiber's limit the guard
    # fires inside the deepest call and that frame returns 0 gracefully.
    my $build_recurse = sub {
        my $f = Brocken::Lindsay::IR::Function->new(
            name        => 'recurse',
            return_type => $i32,
            params      => [
                Brocken::Lindsay::IR::Value->new( type => $ptr, name => '%__heap_base' ),
                Brocken::Lindsay::IR::Value->new( type => $i64, name => '%n' ),
            ],
        );
        my $b = Brocken::Lindsay::IR::Builder->new();
        $b->position_at_end( $f->append_block('entry') );
        my $done = $f->append_block('done');
        my $step = $f->append_block('step');
        my $zero = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 );
        my $isz  = $b->build_icmp( 'eq', $f->params->[1], $zero, '%nz' );
        $b->build_cond_br( $isz, $done, $step );
        $b->position_at_end($done);
        $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        $b->position_at_end($step);
        my $one = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 );
        my $nm1 = $b->build_sub( $f->params->[1], $one, '%nm1' );
        my $res = $b->build_call( $f, [ $f->params->[0], $nm1 ], '%rr' );
        $b->build_ret($res);
        return $f;
    };

    subtest 'guard fires on the 64 KiB fiber stack and unwinds gracefully' => sub {
        my $recurse = $build_recurse->();

        # worker(%__heap_base): pin the handler stack to empty so the guard takes
        # the graceful "return 0" path, recurse deep enough to cross the fiber
        # limit, then report whether err_code came back as ERR_STACK (6).
        my $worker = Brocken::Lindsay::IR::Function->new(
            name        => 'worker_fn',
            return_type => $i32,
            params      => [ Brocken::Lindsay::IR::Value->new( type => $ptr, name => '%__heap_base' ) ],
        );
        my $wb = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        my $ehp = $wb->build_add( $worker->params->[0],
            Brocken::Lindsay::IR::Constant->new( type => $i64, value => Brocken::ICB::EXCEPTION_HANDLER_STACK ), '%ehp' );
        $wb->build_store( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), $ehp );
        $wb->build_call( $recurse,
            [ $worker->params->[0], Brocken::Lindsay::IR::Constant->new( type => $i64, value => 200000 ) ], '%top' );
        my $ecp = $wb->build_add( $worker->params->[0],
            Brocken::Lindsay::IR::Constant->new( type => $i64, value => Brocken::ICB::ERR_CODE ), '%ecp' );
        my $err  = $wb->build_load( $i64, $ecp, '%err' );
        my $is6  = $wb->build_icmp( 'eq', $err, Brocken::Lindsay::IR::Constant->new( type => $i64, value => Brocken::ICB::ERR_STACK ), '%is6' );
        my $sel  = $wb->build_select( $is6,
            Brocken::Lindsay::IR::Constant->new( type => $i64, value => 77 ),
            Brocken::Lindsay::IR::Constant->new( type => $i64, value => 66 ), '%which' );
        $wb->build_fiber_yield( $sel, '%yv' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );

        my $main = Brocken::Lindsay::IR::Function->new( name => '_BROCKEN_ENTRY', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $fcb  = $mb->build_fiber_create( $worker, [], '%fcb' );
        my $recv = $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%recv' );
        $mb->build_ret($recv);

        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker, $recurse ] );
        is( scalar @$funcs, 4, '4 functions emitted (wrapper, _real_main, worker_fn, recurse)' ) or
            diag( 'got: ', [ map { $_->{name} } @$funcs ] );
        my $output_file = $brocken->tmpdir . '/fiber_guard_graceful' . $brocken->ext;
        $brocken->linker->write_executable( $output_file, $funcs, $platform );
        ok( -f $output_file, 'fiber guard executable exists' ) or do { unlink $output_file if -f $output_file; skip 'no binary', 0 };
        system $output_file;
        is( $? >> 8, 77, 'deep fiber recursion hit the guard: worker saw err_code=6 and yielded 77' );
        unlink $output_file;
    };

    subtest 'guard longjmps to a live try/catch handler on the fiber' => sub {
        my $recurse = $build_recurse->();

        # worker(%__heap_base): push a [next, jmp_buf] handler and setjmp before
        # recursing; the guard (deep on the fiber stack) sees the live handler and
        # longjmps here instead of returning 0.  The catch path reloads the ICB
        # from a frame slot (stable across longjmp) and reports err_code.
        my $worker = Brocken::Lindsay::IR::Function->new(
            name        => 'worker_fn',
            return_type => $i32,
            params      => [ Brocken::Lindsay::IR::Value->new( type => $ptr, name => '%__heap_base' ) ],
        );
        my $wb = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        my $hb_slot = $wb->build_alloca( $ptr, '%hb.slot' );
        $wb->build_store( $worker->params->[0], $hb_slot );
        my $handler = $wb->build_alloca( $i64, '%handler', 2 );                 # 16 bytes: [next, jmp_buf]
        my $jbuf    = $wb->build_alloca( $i64, '%jbuf', 32 );                   # 256 bytes, generous for all ABIs
        my $ehp     = $wb->build_add( $worker->params->[0],
            Brocken::Lindsay::IR::Constant->new( type => $i64, value => Brocken::ICB::EXCEPTION_HANDLER_STACK ), '%ehp' );
        my $old     = $wb->build_load( $i64, $ehp, '%old' );
        $wb->build_store( $old, $handler );                                     # handler[0] = prev head
        my $jbs = $wb->build_add( $handler, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 8 ), '%jbs' );
        $wb->build_store( $jbuf, $jbs );                                        # handler[8] = jmp_buf
        $wb->build_store( $handler, $ehp );                                     # push handler
        my $setjmp = Brocken::Lindsay::IR::Function->new(
            name        => 'setjmp',
            return_type => $i64,
            params      => [ Brocken::Lindsay::IR::Value->new( type => $ptr ) ],
        );
        my $sj    = $wb->build_call( $setjmp, [$jbuf], '%sj' );
        my $is_ex = $wb->build_icmp( 'ne', $sj, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%isx' );
        my $body  = $worker->append_block('try_body');
        my $land  = $worker->append_block('landing');
        $wb->build_cond_br( $is_ex, $land, $body );

        # try body: normal completion cannot happen for a passing run (the guard
        # longjmps out of here), so just signal "no exception was caught".
        $wb->position_at_end($body);
        $wb->build_call( $recurse,
            [ $worker->params->[0], Brocken::Lindsay::IR::Constant->new( type => $i64, value => 200000 ) ], '%top' );
        $wb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 66 ), '%yvB' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );

        $wb->position_at_end($land);
        my $hb2  = $wb->build_load( $ptr, $hb_slot, '%hb2' );
        my $ecp2 = $wb->build_add( $hb2, Brocken::Lindsay::IR::Constant->new( type => $i64, value => Brocken::ICB::ERR_CODE ), '%ecp2' );
        my $err2 = $wb->build_load( $i64, $ecp2, '%err2' );
        my $is62 = $wb->build_icmp( 'eq', $err2, Brocken::Lindsay::IR::Constant->new( type => $i64, value => Brocken::ICB::ERR_STACK ), '%is62' );
        my $sel2 = $wb->build_select( $is62,
            Brocken::Lindsay::IR::Constant->new( type => $i64, value => 77 ),
            Brocken::Lindsay::IR::Constant->new( type => $i64, value => 66 ), '%which2' );
        $wb->build_fiber_yield( $sel2, '%yv2' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );

        my $main = Brocken::Lindsay::IR::Function->new( name => '_BROCKEN_ENTRY', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $fcb  = $mb->build_fiber_create( $worker, [], '%fcb' );
        my $recv = $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%recv' );
        $mb->build_ret($recv);

        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker, $recurse, $setjmp ] );
        is( scalar @$funcs, 4, '4 functions emitted (wrapper, _real_main, worker_fn, recurse; setjmp is an extern stub)' ) or
            diag( 'got: ', [ map { $_->{name} } @$funcs ] );
        my $output_file = $brocken->tmpdir . '/fiber_guard_catch' . $brocken->ext;
        $brocken->linker->write_executable( $output_file, $funcs, $platform );
        ok( -f $output_file, 'fiber catch executable exists' ) or do { unlink $output_file if -f $output_file; skip 'no binary', 0 };
        system $output_file;
        is( $? >> 8, 77, 'guard longjmp to the fiber handler: catch saw err_code=6 and yielded 77' );
        unlink $output_file;
    };
}
done_testing;