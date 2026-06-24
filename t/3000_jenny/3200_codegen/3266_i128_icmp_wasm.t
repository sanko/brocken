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
    skip 'wasmtime not available', 80 unless $wasmtime_path && -f $wasmtime_path;
    for my $tc (
        [ eq  => 42, 42, 1, '42 eq 42' ],
        [ eq  => 42, 0,  0, '42 eq 0' ],
        [ ne  => 42, 0,  1, '42 ne 0' ],
        [ ne  => 42, 42, 0, '42 ne 42' ],
        [ ult => 0,  42, 1, '0 ult 42' ],
        [ ult => 42, 0,  0, '42 ult 0' ],
        [ ugt => 42, 0,  1, '42 ugt 0' ],
        [ ugt => 0,  42, 0, '0 ugt 42' ],
        [ ule => 0,  42, 1, '0 ule 42' ],
        [ ule => 42, 0,  0, '42 ule 0' ],
        [ uge => 42, 0,  1, '42 uge 0' ],
        [ uge => 0,  42, 0, '0 uge 42' ],
        [ slt => 0,  42, 1, '0 slt 42' ],
        [ slt => 42, 0,  0, '42 slt 0' ],
        [ sgt => 42, 0,  1, '42 sgt 0' ],
        [ sgt => 0,  42, 0, '0 sgt 42' ],
        [ sle => 0,  42, 1, '0 sle 42' ],
        [ sle => 42, 0,  0, '42 sle 0' ],
        [ sge => 42, 0,  1, '42 sge 0' ],
        [ sge => 0,  42, 0, '0 sge 42' ],
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
        my $output_file = "i128_icmp_$pred.wasm";
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
