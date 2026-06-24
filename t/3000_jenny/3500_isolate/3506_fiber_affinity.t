use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $host = Brocken::Katsuro::Platform::parse();
SKIP: {
    skip 'Fiber affinity test only on native hosts', 1 unless $host->is_native;
    my ( $codegen, $linker, $ext );
    if ( $host->is_arm64 && $host->is_windows ) {
        $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::PE->new();
        $ext     = '.exe';
    }
    elsif ( $host->is_arm64 && $host->is_linux ) {
        $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
        $ext     = '';
    }
    elsif ( $host->is_arm64 ) {
        skip 'FiberPin not supported on this ARM64 platform', 1;
    }
    elsif ( $host->is_riscv64 && $host->is_linux ) {
        $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
        $ext     = '';
    }
    elsif ( $host->is_riscv64 ) {
        skip 'FiberPin not supported on this RISCV64 platform', 1;
    }
    elsif ( $host->is_x64 && $host->is_windows ) {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::PE->new();
        $ext     = '.exe';
    }
    elsif ( $host->is_x64 && $host->is_macos ) {
        skip 'FiberPin not supported on macOS', 1;
    }
    elsif ( $host->is_x64 && $host->is_bsd ) {
        skip 'FiberPin not supported on BSD', 1;
    }
    elsif ( $host->is_x64 ) {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
        $ext     = '';
    }
    else {
        skip 'Unsupported architecture for FiberPin', 1;
    }
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # 1. Create a fiber, pin it to CPU 0, transfer to it
    #    Tests that fiber_pin lowering works without crashing.
    subtest 'Pin fiber to CPU 0' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'inner_fn', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 77 ), '%yv' );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $fcb = $mb->build_fiber_create( $inner, [], '%fcb' );
        $mb->build_fiber_pin( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ) );
        $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r1' );
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $codegen->emit_functions( [ $main, $inner ] );
        my $file  = 'fiber_pin_cpu0' . $ext;
        $linker->write_executable( $file, $funcs, $host );
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
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $fcb = $mb->build_fiber_create( $inner, [], '%fcb' );
        $mb->build_fiber_pin( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ) );
        $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), '%r1' );
        $mb->build_fiber_transfer( $fcb, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 2 ), '%r2' );
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $codegen->emit_functions( [ $main, $inner ] );
        my $file  = 'fiber_pin_chained' . $ext;
        $linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'fiber pin chained exit 99', platform => $host, keep => 1, gdb => $dbg );
    };
}
done_testing;
