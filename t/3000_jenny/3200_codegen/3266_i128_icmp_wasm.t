use v5.42;
use Math::BigInt;
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
my $BIG_ZERO  = Math::BigInt->new('0');
my $BIG_A     = Math::BigInt->new('0x123456789ABCDEF00FEDCBA987654321');
my $BIG_A1    = Math::BigInt->new('0x123456789ABCDEF00FEDCBA987654322');
my $BIG_B     = Math::BigInt->new('0x223456789ABCDEF00FEDCBA987654321');
my $BIG_HUGE  = Math::BigInt->new('0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF');
my $big_const = sub { Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $_[0] ) };
SKIP: {
    skip 'wasmtime not available', 328 unless $wasmtime_path && -f $wasmtime_path;
    for my $tc (
        [ eq  => 42, 42, 1, '42 eq 42' ],
        [ eq  => 42,  0, 0, '42 eq 0' ],
        [ ne  => 42,  0, 1, '42 ne 0' ],
        [ ne  => 42, 42, 0, '42 ne 42' ],
        [ ult =>  0, 42, 1, '0 ult 42' ],
        [ ult => 42,  0, 0, '42 ult 0' ],
        [ ugt => 42,  0, 1, '42 ugt 0' ],
        [ ugt =>  0, 42, 0, '0 ugt 42' ],
        [ ule =>  0, 42, 1, '0 ule 42' ],
        [ ule => 42,  0, 0, '42 ule 0' ],
        [ uge => 42,  0, 1, '42 uge 0' ],
        [ uge =>  0, 42, 0, '0 uge 42' ],
        [ slt =>  0, 42, 1, '0 slt 42' ],
        [ slt => 42,  0, 0, '42 slt 0' ],
        [ sgt => 42,  0, 1, '42 sgt 0' ],
        [ sgt =>  0, 42, 0, '0 sgt 42' ],
        [ sle =>  0, 42, 1, '0 sle 42' ],
        [ sle => 42,  0, 0, '42 sle 0' ],
        [ sge => 42,  0, 1, '42 sge 0' ],
        [ sge =>  0, 42, 0, '0 sge 42' ],
        [ eq  => -1, -1, 1, '-1 eq -1' ],
        [ eq  => -1,  0, 0, '-1 eq 0' ],
        [ ne  => -1,  0, 1, '-1 ne 0' ],
        [ ne  => -1, -1, 0, '-1 ne -1' ],
        [ ult => -1,  0, 0, '-1 ult 0 (false: -1 is huge unsigned)' ],
        [ ult =>  0, -1, 1, '0 ult -1 (true: 0 < huge)' ],
        [ ugt => -1,  0, 1, '-1 ugt 0 (true: -1 is huge)' ],
        [ ugt =>  0, -1, 0, '0 ugt -1 (false: 0 < huge)' ],
        [ ule => -1,  0, 0, '-1 ule 0 (false)' ],
        [ ule =>  0, -1, 1, '0 ule -1 (true)' ],
        [ uge => -1,  0, 1, '-1 uge 0 (true)' ],
        [ uge =>  0, -1, 0, '0 uge -1 (false)' ],
        [ slt => -1,  0, 1, '-1 slt 0 (true: signed)' ],
        [ slt =>  0, -1, 0, '0 slt -1 (false)' ],
        [ sgt => -1,  0, 0, '-1 sgt 0 (false)' ],
        [ sgt =>  0, -1, 1, '0 sgt -1 (true)' ],
        [ sle => -1,  0, 1, '-1 sle 0 (true)' ],
        [ sle =>  0, -1, 0, '0 sle -1 (false)' ],
        [ sge => -1,  0, 0, '-1 sge 0 (false)' ],
        [ sge =>  0, -1, 1, '0 sge -1 (true)' ],
    ) {
        my ( $pred, $a, $b, $expected, $desc ) = @$tc;
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        my $entry   = $func->append_block('entry');
        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp(
            $pred,
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $a ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $b ), '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, "Generated Wasm i128 icmp $desc bytes" );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = temp_path("i128_icmp_$pred") . '.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, "Wasm i128 icmp $desc file exists" );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], $expected ? 42 : 0, "Wasm i128 icmp $desc: lo = " . ( $expected ? 42 : 0 ) );
        is( $vals[1], 0,                  "Wasm i128 icmp $desc: hi = 0" );
        unlink $output_file if -e $output_file;
    }
    for my $tc (
        [ eq  => $BIG_A,    $BIG_A,    1, 'large same-hi eq (true)' ],
        [ eq  => $BIG_A,    $BIG_A1,   0, 'large same-hi eq (false)' ],
        [ ne  => $BIG_A,    $BIG_A1,   1, 'large same-hi ne (true)' ],
        [ ne  => $BIG_A,    $BIG_A,    0, 'large same-hi ne (false)' ],
        [ ult => $BIG_A,    $BIG_A1,   1, 'large same-hi ult (true)' ],
        [ ult => $BIG_A1,   $BIG_A,    0, 'large same-hi ult (false)' ],
        [ ugt => $BIG_A1,   $BIG_A,    1, 'large same-hi ugt (true)' ],
        [ ugt => $BIG_A,    $BIG_A1,   0, 'large same-hi ugt (false)' ],
        [ ule => $BIG_A,    $BIG_A1,   1, 'large same-hi ule (true)' ],
        [ ule => $BIG_A,    $BIG_A,    1, 'large same-hi ule (eq)' ],
        [ uge => $BIG_A1,   $BIG_A,    1, 'large same-hi uge (true)' ],
        [ uge => $BIG_A,    $BIG_A1,   0, 'large same-hi uge (false)' ],
        [ slt => $BIG_A,    $BIG_A1,   1, 'large same-hi slt (true)' ],
        [ slt => $BIG_A1,   $BIG_A,    0, 'large same-hi slt (false)' ],
        [ sgt => $BIG_A1,   $BIG_A,    1, 'large same-hi sgt (true)' ],
        [ sgt => $BIG_A,    $BIG_A1,   0, 'large same-hi sgt (false)' ],
        [ sle => $BIG_A,    $BIG_A1,   1, 'large same-hi sle (true)' ],
        [ sle => $BIG_A,    $BIG_A,    1, 'large same-hi sle (eq)' ],
        [ sge => $BIG_A1,   $BIG_A,    1, 'large same-hi sge (true)' ],
        [ sge => $BIG_A,    $BIG_A1,   0, 'large same-hi sge (false)' ],
        [ ult => $BIG_A,    $BIG_B,    1, 'large cross-hi ult (true)' ],
        [ ult => $BIG_B,    $BIG_A,    0, 'large cross-hi ult (false)' ],
        [ ugt => $BIG_B,    $BIG_A,    1, 'large cross-hi ugt (true)' ],
        [ ugt => $BIG_A,    $BIG_B,    0, 'large cross-hi ugt (false)' ],
        [ ule => $BIG_A,    $BIG_B,    1, 'large cross-hi ule (true)' ],
        [ ule => $BIG_B,    $BIG_A,    0, 'large cross-hi ule (false)' ],
        [ uge => $BIG_B,    $BIG_A,    1, 'large cross-hi uge (true)' ],
        [ uge => $BIG_A,    $BIG_B,    0, 'large cross-hi uge (false)' ],
        [ slt => $BIG_A,    $BIG_B,    1, 'large cross-hi slt (true)' ],
        [ slt => $BIG_B,    $BIG_A,    0, 'large cross-hi slt (false)' ],
        [ sgt => $BIG_B,    $BIG_A,    1, 'large cross-hi sgt (true)' ],
        [ sgt => $BIG_A,    $BIG_B,    0, 'large cross-hi sgt (false)' ],
        [ sle => $BIG_A,    $BIG_B,    1, 'large cross-hi sle (true)' ],
        [ sle => $BIG_B,    $BIG_A,    0, 'large cross-hi sle (false)' ],
        [ sge => $BIG_B,    $BIG_A,    1, 'large cross-hi sge (true)' ],
        [ sge => $BIG_A,    $BIG_B,    0, 'large cross-hi sge (false)' ],
        [ ult => $BIG_ZERO, $BIG_A,    1, 'zero ult large (true)' ],
        [ ugt => $BIG_A,    $BIG_ZERO, 1, 'large ugt zero (true)' ],
        [ slt => $BIG_ZERO, $BIG_A,    1, 'zero slt large (true)' ],
        [ sgt => $BIG_A,    $BIG_ZERO, 1, 'large sgt zero (true)' ],
        [ eq  => $BIG_HUGE, $BIG_HUGE, 1, 'max i128 eq (true)' ],
        [ ult => $BIG_A,    $BIG_HUGE, 1, 'large ult max (true)' ],
    ) {
        my ( $pred, $a, $b, $expected, $desc ) = @$tc;
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        my $entry   = $func->append_block('entry');
        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp( $pred, $big_const->($a), $big_const->($b), '%cmp' );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( $big_const->(42) );
        $builder->position_at_end($f_block);
        $builder->build_ret( $big_const->(0) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, "Generated Wasm i128 icmp $desc bytes" );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = temp_path("i128_icmp_large_$pred") . '.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, "Wasm i128 icmp $desc file exists" );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        my @vals = split /\n/, $output;
        is( $vals[0], $expected ? 42 : 0, "Wasm i128 icmp $desc: lo = " . ( $expected ? 42 : 0 ) );
        is( $vals[1], 0,                  "Wasm i128 icmp $desc: hi = 0" );
        unlink $output_file if -e $output_file;
    }
}
done_testing;
