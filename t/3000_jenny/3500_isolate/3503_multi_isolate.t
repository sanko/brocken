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
    skip 'Multi-isolate test only on native hosts', 1 unless $host->is_native;
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # 1. Three concurrent isolates
    #    Main spawns 3 isolates, each returns through join.
    subtest 'Three concurrent isolates' => sub {
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $i1 = $mb->build_isolate_create( $worker, [], '%i1' );
        my $i2 = $mb->build_isolate_create( $worker, [], '%i2' );
        my $i3 = $mb->build_isolate_create( $worker, [], '%i3' );
        $mb->build_isolate_join($i1);
        $mb->build_isolate_join($i2);
        $mb->build_isolate_join($i3);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker ] );
        my $file  = $brocken->tmpdir . '/three_isolates' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'three concurrent isolates exit 99', platform => $host, keep => 1, gdb => $dbg );
    };

    # 2. Isolate with fiber yield inside each worker
    #    4 isolates each create and yield from a fiber.
    subtest 'Four isolates with fiber yield' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'inner_fn', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 33 ), '%yv' );
        $ib->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        my $fcb = $wb->build_fiber_create( $inner, [], '%fcb' );
        $wb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), '%r1' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 77 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $i1 = $mb->build_isolate_create( $worker, [], '%i1' );
        my $i2 = $mb->build_isolate_create( $worker, [], '%i2' );
        my $i3 = $mb->build_isolate_create( $worker, [], '%i3' );
        my $i4 = $mb->build_isolate_create( $worker, [], '%i4' );
        $mb->build_isolate_join($i1);
        $mb->build_isolate_join($i2);
        $mb->build_isolate_join($i3);
        $mb->build_isolate_join($i4);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker, $inner ] );
        my $file  = $brocken->tmpdir . '/four_isolate_fibers' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'four isolates with fiber yield exit 99', platform => $host, keep => 1, gdb => $dbg );
    };

    # 3. Many concurrent isolates with fiber chaining
    #    8 isolates each run a two-fiber chain.
    subtest 'Eight isolates with fiber chaining' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'inner_fn', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 88 ), '%yv' );
        $ib->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 88 ), '%yv2' );
        $ib->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        my $fcb = $wb->build_fiber_create( $inner, [], '%fcb' );
        $wb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r1' );
        $wb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 2 ), '%r2' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 66 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my @handles;

        for my $i ( 1 .. 8 ) {
            push @handles, $mb->build_isolate_create( $worker, [], "%i$i" );
        }
        for my $h (@handles) {
            $mb->build_isolate_join($h);
        }
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker, $inner ] );
        my $file  = $brocken->tmpdir . '/eight_isolate_fibers' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'eight isolates with fiber chaining exit 99', platform => $host, keep => 1, gdb => $dbg );
    };
}
done_testing;
