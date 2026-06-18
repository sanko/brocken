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
my $platform      = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $null          = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
SKIP: {
    skip 'wasmtime not available', 40 unless $wasmtime_path && -f $wasmtime_path;

    # Test 1: constant i128 return (42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 constant bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_const.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 constant file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( scalar @vals, 2,  'Wasm i128 constant returns two i64 values' );
        is( $vals[0],     42, 'Wasm i128 constant lo = 42' );
        is( $vals[1],     0,  'Wasm i128 constant hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 2: i128 add (40 + 2 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 40 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 add bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_add.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 add file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 add (40+2): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 add (40+2): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 3: i128 sub (100 - 58 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_sub(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 100 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 58 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 sub bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_sub.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 sub file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 sub (100-58): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 sub (100-58): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 4: i128 and (63 & 42 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_and(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 63 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 and bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_and.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 and file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 and (63&42): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 and (63&42): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 5: i128 or (40 | 2 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_or(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 40 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 or bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_or.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 or file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 or (40|2): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 or (40|2): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 6: i128 xor (40 ^ 2 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_xor(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 40 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 xor bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_xor.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 xor file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 xor (40^2): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 xor (40^2): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 7: i128 shl (21 << 1 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_shl(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 shl bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_shl.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 shl file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 shl (21<<1): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 shl (21<<1): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 8: i128 lshr (84 >> 1 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_lshr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 84 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 lshr bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_lshr.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 lshr file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 lshr (84>>1): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 lshr (84>>1): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 9: i128 ashr (84 >> 1 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_ashr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 84 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 ashr bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_ashr.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 ashr file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 ashr (84>>1): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 ashr (84>>1): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 10: i128 mul (21 * 2 = 42)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_mul(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 mul bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_mul.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 mul file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], 42, 'Wasm i128 mul (21*2): lo = 42' );
        is( $vals[1], 0,  'Wasm i128 mul (21*2): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 11: i128 div (42 / 2 = 21)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_div(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 div bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_div.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 div file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0] + 0, 21, 'Wasm i128 div (42/2): lo = 21' );
        is( $vals[1] + 0, 0,  'Wasm i128 div (42/2): hi = 0' );
        unlink $output_file if -e $output_file;
    }

    # Test 12: i128 rem (21 % 10 = 1)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_ret(
            $builder->build_rem(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                '%r'
            )
        );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i128 rem bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i128_rem.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i128 rem file exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0] + 0, 1, 'Wasm i128 rem (21%10): lo = 1' );
        is( $vals[1] + 0, 0, 'Wasm i128 rem (21%10): hi = 0' );
        unlink $output_file if -e $output_file;
    }
}
done_testing;
