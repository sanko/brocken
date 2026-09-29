use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);

# The integer-to-float conversion on Wasm.
#
# The two mnemonics sit at 0xB4 and 0xB9, in the middle of the conversion block
# where the neighbours are the float reinterpret forms. A byte off by one or
# three does not fail to assemble: it assembles as `f32.demote_f64` or a
# reinterpret, the module still validates, and the function returns a number of
# the right shape that is not the one that went in. So this checks a value, not
# a load.
#
# The values are chosen so a reinterpretation cannot produce them by accident:
# the bit patterns of 7 and -7 are 0x401C000000000000 and 0xC01C000000000000,
# and neither reads back as 7 or -7. Both signs are here because the mnemonics
# are the `_s` forms, so a negative source has to stay negative.
#
# Built through the IR directly, as in the float-to-integer test, because the
# frontend folds a constant conversion before it ever reaches a backend.
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $null     = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;
my %CASES = (
    'i64_f64_7'  => { f => 'f64', value =>  7, want =>  7 },
    'i64_f64_n7' => { f => 'f64', value => -7, want => -7 },
    'i64_f32_7'  => { f => 'f32', value =>  7, want =>  7 },
    'i64_f32_n7' => { f => 'f32', value => -7, want => -7 },
);
for my $name ( sort keys %CASES ) {
    my $case    = $CASES{$name};
    my $ftype   = $case->{f} eq 'f32' ? Brocken::Lindsay::IR::Type::f32() : Brocken::Lindsay::IR::Type::f64();
    my $itype   = Brocken::Lindsay::IR::Type::i64();
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $ftype );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $src = Brocken::Lindsay::IR::Constant->new( type => $itype, value => $case->{value} );
    my $out = $builder->build_sitofp( $src, $ftype, '%out' );
    $builder->build_ret($out);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, "Wasm $name: body emitted" );
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    my $output_file = temp_path("sitofp_$name") . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, "Wasm $name: file exists" );
SKIP: {
        skip 'wasmtime not available', 1 unless $wasmtime && -x $wasmtime;
        my $output = qx["$wasmtime" run --invoke main $output_file 2>$null];
        chomp $output;
        is( $output, $case->{want}, "Wasm $name: $case->{value} converts to $case->{want} (got $output)" );
    }
    unlink $output_file if -e $output_file;
}
done_testing;
