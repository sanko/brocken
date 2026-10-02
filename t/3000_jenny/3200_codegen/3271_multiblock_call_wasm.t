use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[temp_path];
use Brocken::Katsuro::Platform;
use Brocken::Lindsay;
use Brocken::Jenny::Codegen::Wasm;
use Brocken::Jenny::Linker::Wasm;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
#
# A call from a block other than the entry one. The call index is a fixup that
# Codegen::Wasm records against its own block and rebases onto the block start,
# so the block-relative offset is only right once that rebase happens: an
# offset left relative to the block, or one added to the wrong base, points the
# call at the middle of the dispatch loop and the module will not validate.
#
# The call in 3270_multi_func.t sits in the entry block, where the two bases
# coincide, so it cannot tell a correct rebase from a missing one.
#
subtest 'Wasm call from a non-entry block' => sub {
    my $host          = Brocken::Katsuro::Platform::parse();
    my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
    chomp $wasmtime_path if $wasmtime_path;
    # SKIP: so skip() has a block to last out of. Without the label it unwinds
    # the subtest closure itself, and the plan the subtest adds on the way out
    # collides with the trailing SKIP.
    SKIP: {
        skip 'wasmtime not available', 2 unless $wasmtime_path && -f $wasmtime_path;
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $b        = Brocken::Lindsay::IR::Builder->new();
        my $i32      = Brocken::Lindsay::IR::Type::i32();
        my $p        = Brocken::Lindsay::IR::Value->new( type => $i32, name => 'x' );
        my $helper   = Brocken::Lindsay::IR::Function->new( name => 'helper', return_type => $i32, params => [$p] );
        $b->position_at_end( $helper->append_block('entry') );
        $b->build_ret( $b->build_add( $p, Brocken::Lindsay::IR::Constant->new( type => $i32, value => 1 ) ) );

        # main is deliberately multi-block: the call goes in if.then, not in entry.
        my $main  = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32, params => [] );
        my $entry = $main->append_block('entry');
        my $then  = $main->append_block('if.then');
        my $else  = $main->append_block('if.else');
        $b->position_at_end($entry);
        my $cond = $b->build_icmp(
            'sgt',
            Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ), '%cmp'
        );
        $b->build_cond_br( $cond, $then, $else );
        $b->position_at_end($then);
        $b->build_ret( $b->build_call( $helper, [ Brocken::Lindsay::IR::Constant->new( type => $i32, value => 41 ) ] ) );
        $b->position_at_end($else);
        $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
        my $codegen     = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $funcs       = $codegen->emit_functions( [ $main, $helper ] );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = temp_path('multiblock_call') . '.wasm';
        $linker->write_executable( $output_file, $funcs, $platform );
        my $null = $host->is_windows ? 'NUL' : '/dev/null';
        my $cmd  = qq["$wasmtime_path" compile "$output_file" -o "$null" 2>&1];
        is system($cmd), 0, 'a call fixup in a non-entry block validates' or diag qx[$cmd];
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        is $output, 42, 'helper(41) called from if.then returns 42';
        unlink $output_file if -e $output_file;
    }
};
done_testing;
