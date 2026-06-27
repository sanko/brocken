use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);
my $host          = Brocken::Katsuro::Platform::parse();
my $platform      = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $null          = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $node_path = $host->is_windows ? `where node 2>NUL` : `which node 2>/dev/null`;
chomp $node_path if $node_path;

# i64 arithmetic
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i64() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $v1 = $builder->build_add(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 4000000000 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1000000000 ),
        '%v1'
    );
    my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 8 ), '%v2' );
    $builder->build_ret($v2);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm i64 math bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('i64_math_test') . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm i64 math file exists' );
SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            is $output, 4999999992, 'i64 math (4000000000+1000000000-8=4999999992) via wasmtime';
        }
        elsif ( $node_path && -x $node_path ) {
            my $js = sprintf <<~'', $output_file;
                const fs = require('fs'); const buf = fs.readFileSync('%s');
                WebAssembly.instantiate(buf)
                    .then(res => {
                        const result = res.instance.exports.main();
                        const big = BigInt(result);
                        process.exit(big === 4999999992n ? 0 : 1);
                    })
                    .catch(e => { console.error(e); process.exit(1); });

            system( 'node', '-e', $js );
            is $? >> 8, 0, 'i64 math (4000000000+1000000000-8=4999999992) via node';
        }
        else {
            skip 'Neither wasmtime nor node are installed', 1;
        }
    }
    unlink $output_file if -e $output_file;
}

# i64 memory
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i64() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%ptr' );
    $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 5000000000 ), $ptr );
    my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $ptr, '%val' );
    $builder->build_ret($val);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm i64 memory bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('i64_mem_test') . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm i64 memory file exists' );
SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            is $output, 5000000000, 'i64 memory store/load 5000000000 via wasmtime';
        }
        elsif ( $node_path && -x $node_path ) {
            my $js = sprintf <<~'', $output_file;
                const fs = require('fs'); const buf = fs.readFileSync('%s');
                WebAssembly.instantiate(buf)
                    .then(res => {
                        const result = res.instance.exports.main();
                        const big = BigInt(result);
                        process.exit(big === 5000000000n ? 0 : 1);
                    })
                    .catch(e => { console.error(e); process.exit(1); });

            system( 'node', '-e', $js );
            is $? >> 8, 0, 'i64 memory store/load 5000000000 via node';
        }
        else {
            skip 'Neither wasmtime nor node are installed', 1;
        }
    }
    unlink $output_file if -e $output_file;
}
done_testing;
