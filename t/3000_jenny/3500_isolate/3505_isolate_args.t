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
    skip 'Isolate args test only on X86_64',       1 unless $host->is_x64;
    skip 'Isolate args test only on native hosts', 1 unless $host->is_native;
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # 1. Isolate with a single integer argument
    #    Worker takes %arg (i64), adds it to a constant.
    subtest 'Isolate with a single argument' => sub {
        my $worker = Brocken::Lindsay::IR::Function->new(
            name        => 'worker_fn',
            return_type => $i32,
            params      => [ Brocken::Lindsay::IR::Value->new( type => $i64, name => '%arg' ) ]
        );
        my $wb = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $worker, [ Brocken::Lindsay::IR::Constant->new( type => $i64, value => 99 ) ], '%iso' );
        $mb->build_isolate_join($iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker ] );
        my $file  = $brocken->tmpdir . '/isolate_one_arg' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = 0;    # $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'isolate with one arg exit 99', platform => $host, keep => 1, gdb => $dbg );
    };

    # 2. Isolate with multiple arguments
    #    Worker takes 3 args (i64). Verifies no crash.
    subtest 'Isolate with multiple arguments' => sub {
        my $worker = Brocken::Lindsay::IR::Function->new(
            name        => 'worker_fn',
            return_type => $i32,
            params      => [
                Brocken::Lindsay::IR::Value->new( type => $i64, name => '%a' ),
                Brocken::Lindsay::IR::Value->new( type => $i64, name => '%b' ),
                Brocken::Lindsay::IR::Value->new( type => $i64, name => '%c' ),
            ]
        );
        my $wb = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create(
            $worker,
            [   Brocken::Lindsay::IR::Constant->new( type => $i64, value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => $i64, value => 20 ),
                Brocken::Lindsay::IR::Constant->new( type => $i64, value => 30 ),
            ],
            '%iso'
        );
        $mb->build_isolate_join($iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker ] );
        my $file  = $brocken->tmpdir . '/isolate_multi_args' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = 0;    # $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'isolate with 3 args exit 99', platform => $host, keep => 1, gdb => $dbg );
    };

    # 3. Isolate with no arguments (verify backward compatibility)
    subtest 'Isolate with no arguments (backward compat)' => sub {
        my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
        my $wb     = Brocken::Lindsay::IR::Builder->new();
        $wb->position_at_end( $worker->append_block('entry') );
        $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $iso = $mb->build_isolate_create( $worker, [], '%iso' );
        $mb->build_isolate_join($iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $worker ] );
        my $file  = $brocken->tmpdir . '/isolate_no_args_backward' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = 0;    # $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'isolate with no args exit 99', platform => $host, keep => 1, gdb => $dbg );
    };
}
done_testing;
