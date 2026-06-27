use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $host          = Brocken::Katsuro::Platform::parse();
my $null          = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;

# ICmp signed Wasm
SKIP: {
    my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
    my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder  = Brocken::Lindsay::IR::Builder->new();
    my $entry    = $func->append_block('entry');
    my $t_block  = $func->append_block('if.then');
    my $f_block  = $func->append_block('if.else');
    $builder->position_at_end($entry);
    my $cond = $builder->build_icmp(
        'sgt',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
    );
    $builder->build_cond_br( $cond, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm icmp bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = 'icmp_test.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm icmp file exists' );
SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            is $output, 42, 'Wasm icmp (42 sgt 0 = true) returned 42';
        }
        else {
            skip 'wasmtime not available', 1;
        }
    }
    unlink $output_file;
}

# ICmp unsigned Wasm
SKIP: {
    my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
    my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder  = Brocken::Lindsay::IR::Builder->new();
    my $entry    = $func->append_block('entry');
    my $t_block  = $func->append_block('if.then');
    my $f_block  = $func->append_block('if.else');
    $builder->position_at_end($entry);
    my $cond = $builder->build_icmp(
        'ugt',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
    );
    $builder->build_cond_br( $cond, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm unsigned icmp bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = 'icmp_unsigned_test.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm unsigned icmp file exists' );
SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            is $output, 42, 'Wasm unsigned icmp (42 ugt 0 = true) returned 42';
        }
        else {
            skip 'wasmtime not available', 1;
        }
    }
    unlink $output_file;
}
done_testing;
