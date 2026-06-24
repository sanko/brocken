use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
SKIP: {
    my $brocken = Brocken->new();
    my $platform = $brocken->platform;
    skip 'Isolate runtime test only on native hosts', 1 unless $platform->is_native;
    subtest 'isolate_create and isolate_join basic lifecycle' => sub {
        my $i32 = Brocken::Lindsay::IR::Type::i32();
        my $i64 = Brocken::Lindsay::IR::Type::i64();

        # Worker: return 42 (verifies thread executes and function call works)
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );

        # Main: create isolate, join it, return 99 as proof of lifecycle
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $worker, [], '%iso' );
        $mb->build_isolate_join($iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );

        # Compile with isolate trampoline support
        my $funcs           = $brocken->codegen->emit_functions( [ $main, $worker ] );
        my $expect_fn_count = $platform->is_windows ? 4 : 3;
        ok( scalar @$funcs == $expect_fn_count, "emit_functions produced $expect_fn_count functions" ) or
            diag( join( ', ', map { $_->{name} // '?' } $funcs->@* ) );
        my $output_file = 'isolate_test' . $brocken->ext;
        $brocken->linker->write_executable( $output_file, $funcs, $platform );
        ok( -f $output_file, 'Isolate test executable exists' ) or do { unlink $output_file if -f $output_file; skip 'no binary', 0 };
        my $cmd = $platform->is_windows ? $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit_code = $? >> 8;
        is( $exit_code, 99, 'Isolate test exited with 99 (lifecycle completed)' );

        #~ unlink $output_file;
    };
}
done_testing;
