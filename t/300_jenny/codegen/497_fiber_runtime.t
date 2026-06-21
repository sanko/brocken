use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

my $platform = Brocken::Katsuro::Platform::parse();

subtest 'fiber yield passes value to main exit code' => sub {
    SKIP: {
        skip 'Only for x86_64 native hosts', 3 unless $platform->is_x64 && $platform->is_native;

        my $i32 = Brocken::Lindsay::IR::Type::i32();
        my $i64 = Brocken::Lindsay::IR::Type::i64();

        # Worker: yield 99 back to main
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        my $yield_val = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 99 );
        $wb->build_fiber_yield( $yield_val, '%yv' );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );

        # Main: create worker fiber and transfer to it
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $fcb     = $mb->build_fiber_create( $worker, [], '%fcb' );
        my $send    = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 42 );
        my $recv    = $mb->build_fiber_transfer( $fcb, $send, '%recv' );
        $mb->build_ret($recv);

        # Compile with fiber init wrapper support
        my $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $funcs   = $codegen->emit_functions( [ $main, $worker ] );

        ok( scalar @$funcs == 3, 'emit_functions produced 3 functions (main wrapper, _real_main, worker_fn)' )
            or diag( explain( $funcs ) );

        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
        my $output_file = 'fiber_test' . $platform->bin_ext;
        $linker->write_executable( $output_file, $funcs, $platform );
        ok( -f $output_file, 'Fiber test executable exists' )
            or do { unlink $output_file if -f $output_file; skip 'no binary', 0 };

        my $cmd = $platform->is_windows ? $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit_code = $? >> 8;
        is( $exit_code, 99, 'Fiber test exited with 99 (yield value propagated)' );

        unlink $output_file;
    }
};

done_testing;
