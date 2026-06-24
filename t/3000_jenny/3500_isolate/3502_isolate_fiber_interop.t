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
    skip 'Isolate+fiber interop test only on native hosts', 1 unless $host->is_native;

    # 1. Fiber create/transfer/yield inside an isolate
    #    Tests ctx_swap works from a non-original thread stack.
    subtest 'Fiber create/transfer/yield inside isolate' => sub {
        my $i32   = Brocken::Lindsay::IR::Type::i32();
        my $i64   = Brocken::Lindsay::IR::Type::i64();
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'inner_fn', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 77 ), '%yv' );
        $ib->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        my $fcb = $wb->build_fiber_create( $inner, [], '%fcb' );
        $wb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r1' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $worker, [], '%iso' );
        $mb->build_isolate_join($iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker, $inner ] );
        my $file  = 'isolate_fiber_interop' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'fiber inside isolate exit 99', platform => $host, keep => 1, gdb => $dbg );
    };

    # 2. Isolate with chained fiber transfers
    #    Worker creates two fibers, transfers between them.
    #    Note: fiber functions must NOT end with ret because
    #    ctx_swap jumps (not calls) to the fiber entry point,
    #    so there is no valid return address on the fiber stack.
    subtest 'Isolate with chained fiber transfers' => sub {
        my $i32     = Brocken::Lindsay::IR::Type::i32();
        my $i64     = Brocken::Lindsay::IR::Type::i64();
        my $fiber_a = Brocken::Lindsay::IR::Function->new( name => 'fiber_a', return_type => $i32 );
        my $ab      = Brocken::Lindsay::IR::Builder->new();
        $ab->position_at_end( $fiber_a->append_block('entry') );
        $ab->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 111 ), '%y1' );
        my $fiber_b = Brocken::Lindsay::IR::Function->new( name => 'fiber_b', return_type => $i32 );
        my $bb      = Brocken::Lindsay::IR::Builder->new();
        $bb->position_at_end( $fiber_b->append_block('entry') );
        $bb->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 222 ), '%y2' );
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        my $f1 = $wb->build_fiber_create( $fiber_a, [], '%f1' );
        my $f2 = $wb->build_fiber_create( $fiber_b, [], '%f2' );
        $wb->build_fiber_transfer( $f1, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r1' );
        $wb->build_fiber_transfer( $f2, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r2' );
        $wb->build_fiber_transfer( $f1, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r3' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 55 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $worker, [], '%iso' );
        $mb->build_isolate_join($iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker, $fiber_a, $fiber_b ] );
        my $file  = 'isolate_chained_fibers' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'isolate with chained fibers exit 99', platform => $host, keep => 1, gdb => $dbg );
    };
}
done_testing;
