use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
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
#
# A box is a 16-byte heap cell, and it used to come from the same module-global
# bump cursor that arrays did -- a second cursor, with no limit and no growth,
# that could hand out bytes the object allocator had already claimed. Boxes now
# come from Brocken::Runtime::bump_alloc like every other heap block, so a box
# needs the allocator to be present and the heap base to have been seeded by
# _BROCKEN_ENTRY. The hand-built single-function module above cannot supply
# either, so this drives the box through the real pipeline: `my Any $x` has
# dynamic type, which is what boxes on store and unboxes on read.
{
    my $module  = Brocken::Compiler->new->compile("my Any \$x = 42;\nreturn \$x;\n");
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $funcs   = $codegen->emit_functions( $module->functions );
    ok(
        ( grep { $_->{name} eq 'Brocken::Runtime::bump_alloc' } @$funcs ),
        'the box/unbox module carries the shared runtime allocator alongside the entry'
    );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('box_test') . '.wasm';
    $linker->write_executable( $output_file, $funcs, $platform );
    ok( -e $output_file, 'Wasm box/unbox file exists' );
SKIP: {
        if ( $wasmtime_path && -f $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY $output_file 1024 2>$null];
            chomp $output;
            $output =~ s/^warning: using .*$//mg;
            is $output, 42, 'Box/unbox Wasm returned 42 via wasmtime';
        }
        elsif ( $node_path && -x $node_path ) {

            # An i64 result arrives as a BigInt, and process.exit rejects a
            # BigInt with ERR_INVALID_ARG_TYPE, so the comparison has to happen
            # in node rather than in the exit status.
            my $js = sprintf <<~'', $output_file;
                const fs = require('fs'); const buf = fs.readFileSync('%s');
                WebAssembly.instantiate(buf)
                    .then(res => {
                        const result = res.instance.exports._BROCKEN_ENTRY();
                        const big = BigInt(result);
                        process.exit(big === 42n ? 0 : 1);
                    })
                    .catch(e => { console.error(e); process.exit(1); });

            system( 'node', '-e', $js );
            is $? >> 8, 0, 'Box/unbox Wasm returned 42 via node';
        }
        else {
            skip 'Neither wasmtime nor node are installed', 1;
        }
    }
    unlink $output_file if -e $output_file;
}
done_testing;
