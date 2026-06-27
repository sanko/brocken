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
    skip 'Fiber affinity test only on native hosts', 1 unless $host->is_native;
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # 1. Create a fiber, pin it to CPU 0, transfer to it
    #    Tests that fiber_pin lowering works without crashing.
    subtest 'Pin fiber to CPU 0' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'inner_fn', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 77 ), '%yv' );
        my $entry = Brocken::Lindsay::IR::Function->new( name => '_BROCKEN_ENTRY', return_type => $i32 );
        my $eb    = Brocken::Lindsay::IR::Builder->new();
        $eb->position_at_end( $entry->append_block('entry') );
        my $fcb = $eb->build_fiber_create( $inner, [], '%fcb' );
        $eb->build_fiber_pin( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ) );
        $eb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r1' );
        $eb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $entry, $inner ] );
        my $file  = 'fiber_pin_cpu0' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'fiber pin CPU 0 exit 99', platform => $host, keep => 1, gdb => $dbg );
    };

    # 2. Pin to CPU 0 then do chained fiber transfers
    subtest 'Pin fiber then chained transfer' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'inner_fn', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 111 ), '%yv' );
        $ib->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 222 ), '%yv2' );
        my $entry = Brocken::Lindsay::IR::Function->new( name => '_BROCKEN_ENTRY', return_type => $i32 );
        my $eb    = Brocken::Lindsay::IR::Builder->new();
        $eb->position_at_end( $entry->append_block('entry') );
        my $fcb = $eb->build_fiber_create( $inner, [], '%fcb' );
        $eb->build_fiber_pin( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ) );
        $eb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r1' );
        $eb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 2 ), '%r2' );
        $eb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $entry, $inner ] );
        my $file  = 'fiber_pin_chained' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'fiber pin chained exit 99', platform => $host, keep => 1, gdb => $dbg );
    };
}
done_testing;
