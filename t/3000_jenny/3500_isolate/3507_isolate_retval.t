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
    skip 'Isolate retval test only on native hosts', 1 unless $host->is_native;
    my ( $codegen, $linker, $ext );
    if ( $host->is_x64 && $host->is_windows ) {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::PE->new();
        $ext     = '.exe';
    }
    elsif ( $host->is_x64 && $host->is_macos ) {
        skip 'Isolate retval not supported on macOS', 1;
    }
    elsif ( $host->is_x64 && $host->is_bsd ) {
        skip 'Isolate retval not supported on BSD', 1;
    }
    elsif ( $host->is_x64 ) {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
        $ext     = '';
    }
    elsif ( $host->is_arm64 && $host->is_windows ) {
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
        skip 'Isolate retval not supported on this ARM64 platform', 1;
    }
    elsif ( $host->is_riscv64 && $host->is_linux ) {
        $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
        $ext     = '';
    }
    elsif ( $host->is_riscv64 ) {
        skip 'Isolate retval not supported on this RISCV64 platform', 1;
    }
    else {
        skip 'Unsupported architecture for isolate retval', 1;
    }
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();
    subtest 'Isolate returns 42' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'worker', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $inner, [], '%iso' );
        my $ret = $mb->build_isolate_join( $iso, '%ret' );
        $mb->build_ret($ret);
        my $funcs = $codegen->emit_functions( [ $main, $inner ] );
        my $file  = 'isolate_retval_42' . $ext;
        $linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 42, name => 'isolate retval 42', platform => $host, keep => 1, gdb => $dbg );
    };
    subtest 'Isolate returns 0' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'worker', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $inner, [], '%iso' );
        my $ret = $mb->build_isolate_join( $iso, '%ret' );
        $mb->build_ret($ret);
        my $funcs = $codegen->emit_functions( [ $main, $inner ] );
        my $file  = 'isolate_retval_0' . $ext;
        $linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 0, name => 'isolate retval 0', platform => $host, keep => 1, gdb => $dbg );
    };
    subtest 'Isolate returns 99' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'worker', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $inner, [], '%iso' );
        my $ret = $mb->build_isolate_join( $iso, '%ret' );
        $mb->build_ret($ret);
        my $funcs = $codegen->emit_functions( [ $main, $inner ] );
        my $file  = 'isolate_retval_99' . $ext;
        $linker->write_executable( $file, $funcs, $host );
        my $dbg = $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'isolate retval 99', platform => $host, keep => 1, gdb => $dbg );
    };
}
done_testing;
