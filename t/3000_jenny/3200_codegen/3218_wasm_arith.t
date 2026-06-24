use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $func     = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::i32() );
my $builder  = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func->append_block('entry') );
my $v1 = $builder->build_add(
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 ),
    '%v1'
);
my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 8 ), '%v2' );
$builder->build_ret($v2);
my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
my $res     = $codegen->emit_function($func);
ok( length( $res->{body} ) > 0, 'Generated Wasm math bytes' );
my $linker      = Brocken::Jenny::Linker::Wasm->new();
my $output_file = 'math_test.wasm';
$linker->write_executable( $output_file, $res, $platform );
ok( -e $output_file, 'Wasm math file exists' );
my $null          = $host->is_windows ? 'NUL' : '/dev/null';
my $wasmtime_path = `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $node_path = `which node 2>/dev/null`;
chomp $node_path if $node_path;
SKIP: {
    if ( $wasmtime_path && -x $wasmtime_path ) {
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        is $output, 42, 'Math Wasm returned 42 via wasmtime';
    }
    elsif ( $node_path && -x $node_path ) {
        my $js = sprintf <<~'', $output_file;
            const fs = require('fs'); const buf = fs.readFileSync('%s');
            WebAssembly.instantiate(buf)
                .then(res => { process.exit(res.instance.exports.main()); })
                .catch(e => { console.error(e); process.exit(1); });

        system( 'node', '-e', $js );
        is $? >> 8, 42, 'Math Wasm returned 42 via node';
    }
    else {
        skip 'Neither wasmtime nor node are installed', 1;
    }
}
unlink $output_file if -e $output_file;
done_testing;
