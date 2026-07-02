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

# Memory
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%ptr' );
    $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ), $ptr );
    my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%val' );
    $builder->build_ret($val);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm memory bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('mem_test') . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm memory file exists' );
SKIP: {
        if ( $wasmtime_path && -f $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            is $output, 42, 'Memory Wasm returned 42 via wasmtime';
        }
        elsif ( $node_path && -x $node_path ) {
            my $js
                = "const fs=require('fs');const buf=fs.readFileSync('" .
                $output_file . "');" .
                "WebAssembly.instantiate(buf)" .
                ".then(res=>{process.exit(res.instance.exports.main());})" .
                ".catch(e=>{console.error(e);process.exit(1);});";
            system( 'node', '-e', $js );
            is $? >> 8, 42, 'Memory Wasm returned 42 via node';
        }
        else {
            skip 'Neither wasmtime nor node are installed', 1;
        }
    }
    unlink $output_file if -e $output_file;
}

# Box/Unbox
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $boxed = $builder->build_box( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ), '%boxed' );
    my $val   = $builder->build_unbox( $boxed, Brocken::Lindsay::IR::Type::i32(), '%val' );
    $builder->build_ret($val);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm box/unbox bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('box_test') . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm box/unbox file exists' );
SKIP: {
        if ( $wasmtime_path && -f $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            is $output, 42, 'Box/unbox Wasm returned 42 via wasmtime';
        }
        elsif ( $node_path && -x $node_path ) {
            my $js
                = "const fs=require('fs');const buf=fs.readFileSync('" .
                $output_file . "');" .
                "WebAssembly.instantiate(buf)" .
                ".then(res=>{process.exit(res.instance.exports.main());})" .
                ".catch(e=>{console.error(e);process.exit(1);});";
            system( 'node', '-e', $js );
            is $? >> 8, 42, 'Box/unbox Wasm returned 42 via node';
        }
        else {
            skip 'Neither wasmtime nor node are installed', 1;
        }
    }
    unlink $output_file if -e $output_file;
}
done_testing;
