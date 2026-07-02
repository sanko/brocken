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

# f32 arithmetic
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::f32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $v1 = $builder->build_add(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ),
        '%v1'
    );
    $builder->build_ret($v1);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm f32 math bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('f32_math_test') . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm f32 math file exists' );
SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            ok( abs( $output - 31.0 ) < 0.001, "f32 math (10.5+20.5=31.0) via wasmtime (got $output)" );
        }
        else {
            skip 'wasmtime not available', 1;
        }
    }
    unlink $output_file if -e $output_file;
}

# f64 arithmetic
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::f64() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $v1 = $builder->build_add(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 100.5 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 200.25 ),
        '%v1'
    );
    $builder->build_ret($v1);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm f64 math bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('f64_math_test') . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm f64 math file exists' );
SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            ok( abs( $output - 300.75 ) < 0.001, "f64 math (100.5+200.25=300.75) via wasmtime (got $output)" );
        }
        else {
            skip 'wasmtime not available', 1;
        }
    }
    unlink $output_file if -e $output_file;
}

# Float ICmp Wasm
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $c1 = $builder->build_icmp(
        'eq',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c1'
    );
    my $c2 = $builder->build_icmp(
        'ne',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 0.0 ), '%c2'
    );
    my $c3 = $builder->build_icmp(
        'lt',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ), '%c3'
    );
    my $c4 = $builder->build_icmp(
        'gt',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ), '%c4'
    );
    my $c5 = $builder->build_icmp(
        'le',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c5'
    );
    my $c6 = $builder->build_icmp(
        'ge',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ), '%c6'
    );
    my $all = $builder->build_and( $c1, $c2, '%a' );
    $all = $builder->build_and( $all, $c3, '%b' );
    $all = $builder->build_and( $all, $c4, '%c' );
    $all = $builder->build_and( $all, $c5, '%d' );
    $all = $builder->build_and( $all, $c6, '%e' );
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->build_cond_br( $all, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm float icmp bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('ficmp_test') . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm float icmp file exists' );
SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            is( $output, 42, 'Float icmp Wasm returned 42 via wasmtime' );
        }
        else {
            skip 'wasmtime not available', 1;
        }
    }
    unlink $output_file if -e $output_file;
}

# Float Unary MinMax Wasm
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $neg = $builder->build_neg( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ), '%neg' );
    my $c1
        = $builder->build_icmp( 'eq', $neg, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c1' );
    my $abs = $builder->build_abs( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ), '%abs' );
    my $c2
        = $builder->build_icmp( 'eq', $abs, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c2' );
    my $sqrt = $builder->build_sqrt( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 1764.0 ), '%sqrt' );
    my $c3
        = $builder->build_icmp( 'eq', $sqrt, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c3' );
    my $min = $builder->build_min(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 99.0 ),
        '%min'
    );
    my $c4
        = $builder->build_icmp( 'eq', $min, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c4' );
    my $max = $builder->build_max(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -1.0 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
        '%max'
    );
    my $c5
        = $builder->build_icmp( 'eq', $max, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c5' );
    my $all = $builder->build_and( $c1, $c2, '%a' );
    $all = $builder->build_and( $all, $c3, '%b' );
    $all = $builder->build_and( $all, $c4, '%c' );
    $all = $builder->build_and( $all, $c5, '%d' );
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->build_cond_br( $all, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, 'Generated Wasm float unary/minmax bytes' );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path('fum_test') . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, 'Wasm float unary/minmax file exists' );
SKIP: {
        if ( $wasmtime_path && -x $wasmtime_path ) {
            my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
            chomp $output;
            is( $output, 42, 'Float unary/minmax Wasm returned 42 via wasmtime' );
        }
        else {
            skip 'wasmtime not available', 1;
        }
    }
    unlink $output_file if -e $output_file;
}
done_testing;
