use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken::Katsuro::Platform;
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
use Brocken::Jenny::Codegen::X86_64;
use Brocken::Jenny::Codegen::ARM64;
use Brocken::Jenny::Codegen::RISCV64;
use Brocken::Jenny::Linker::ELF64;
use Brocken::Jenny::Linker::MachO;
use Brocken::Jenny::Linker::PE;
subtest 'Zero-Cost Native Backtrace (Frame Pointers)' => sub {
    my $host = Brocken::Katsuro::Platform::parse();
    skip_all('Native backtrace test requires native host') unless $host->is_native;
    my $b   = Brocken::Lindsay::IR::Builder->new();
    my $i64 = Brocken::Lindsay::IR::Type::i64();
    my $ptr = Brocken::Lindsay::IR::Type::ptr();

    # -------------------------------------------------------------------
    # 1. Build bar()
    # It reads its own Frame Pointer, walks up to foo()'s frame,
    # and extracts the Return IP (which points directly to the next instruction in main)
    # -------------------------------------------------------------------
    my $bar = Brocken::Lindsay::IR::Function->new( name => 'bar', return_type => $i64, params => [] );
    $b->position_at_end( $bar->append_block('entry') );
    my $bar_fp = $b->build_frame_addr('bar_fp');
    my $foo_fp = $b->build_load( $ptr, $bar_fp, 'foo_fp' );

    # [foo_fp + 8] holds the Return IP back to main (FP+8 for all archs)
    my $offset = 8;
    my $ret_ip_ptr
        = $b->build_gep( Brocken::Lindsay::IR::Type::i8(), $foo_fp, [ Brocken::Lindsay::IR::Constant->new( type => $i64, value => $offset ) ] );
    my $main_ip = $b->build_load( $i64, $ret_ip_ptr, 'main_ip' );

    # Return 1 if we actually read a non-zero Return IP address
    my $is_valid = $b->build_icmp( 'ne', $main_ip, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ) );
    $b->build_ret($is_valid);

    # -------------------------------------------------------------------
    # 2. Build foo()
    # -------------------------------------------------------------------
    my $foo = Brocken::Lindsay::IR::Function->new( name => 'foo', return_type => $i64, params => [] );
    $b->position_at_end( $foo->append_block('entry') );
    my $res = $b->build_call( $bar, [] );
    $b->build_ret($res);

    # 3. Build main()
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64, params => [] );
    $b->position_at_end( $main->append_block('entry') );
    my $res2 = $b->build_call( $foo, [] );
    $b->build_ret($res2);

    # 4. Compile and Execute
    my ( $codegen, $linker );
    if ( $host->is_arm64 && $host->is_macos ) {
        $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::MachO->new();
    }
    elsif ( $host->is_arm64 && $host->is_windows ) {
        $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::PE->new();
    }
    elsif ( $host->is_arm64 && ( $host->is_bsd || $host->is_linux ) ) {
        $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
    }
    elsif ( $host->is_riscv64 ) {
        $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
    }
    elsif ( $host->is_x64 && $host->is_macos ) {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::MachO->new();
    }
    elsif ( $host->is_x64 && $host->is_windows ) {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::PE->new();
    }
    else {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
    }
    my $funcs       = $codegen->emit_functions( [ $bar, $foo, $main ] );
    my $output_file = 'backtrace_test' . $host->bin_ext;
    $linker->set_func_ranges(
        [ { name => 'bar', start => 0, end => 0 }, { name => 'foo', start => 0, end => 0 }, { name => 'main', start => 0, end => 0 } ] );
    $linker->write_executable( $output_file, $funcs, $host );
    ok( -e $output_file, 'Backtrace binary compiled successfully' );
    run_exec(
        $output_file,
        expected_exit => 1,
        platform      => $host,
        name          => 'Walked Frame Pointers and grabbed Return IP correctly on ' . $host->friendly
    );
};
done_testing;
