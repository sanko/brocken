use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);

# The float-to-integer conversion on Wasm.
#
# Wasm names all four width combinations separately and the choice is made in
# the lowerer, so the four mnemonics have to be right independently of each
# other and none of them is implied by another. A wrong byte does not fail to
# assemble here: it assembles as some other instruction, and the module still
# validates. The first draft of this used 0xB0 and 0xB2 for the two 64-bit
# results, which are `i64.trunc_f64_s` and `i32.reinterpret_f32`; the
# reinterpretation returns a plausible integer for the wrong reason and would
# have passed a test that only checked that the module loaded.
#
# So the values are checked by running them, and the input is fractional with a
# sign, since truncation toward zero is the whole meaning of the `_s` forms and
# a whole number cannot tell truncation from rounding.
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $null     = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;
my %CASES = (
    'f32->i32'  => { f => 'f32', i => 'i32', value =>  3.5, want =>  3 },
    'f32->i32n' => { f => 'f32', i => 'i32', value => -3.5, want => -3 },
    'f64->i64'  => { f => 'f64', i => 'i64', value =>  3.5, want =>  3 },
    'f64->i64n' => { f => 'f64', i => 'i64', value => -3.5, want => -3 },
);
for my $name ( sort keys %CASES ) {
    my $case    = $CASES{$name};
    my $ftype   = $case->{f} eq 'f32' ? Brocken::Lindsay::IR::Type::f32() : Brocken::Lindsay::IR::Type::f64();
    my $itype   = $case->{i} eq 'i32' ? Brocken::Lindsay::IR::Type::i32() : Brocken::Lindsay::IR::Type::i64();
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $itype );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );

    # Built through the IR directly rather than from source, because the
    # frontend folds a constant conversion before it ever reaches a backend.
    my $src = Brocken::Lindsay::IR::Constant->new( type => $ftype, value => $case->{value} );
    my $out = $builder->build_fptosi( $src, $itype, '%out' );
    $builder->build_ret($out);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    ok( length( $res->{body} ) > 0, "Wasm $name: body emitted" );
    my $linker = Brocken::Jenny::Linker::Wasm->new();

    # The case names carry an arrow, which is not a legal character in a
    # Windows filename and makes the write fail with EINVAL.
    my $stem = $name;
    $stem =~ s/[^A-Za-z0-9]+/_/g;
    my $output_file = temp_path("fptosi_$stem") . '.wasm';
    $linker->write_executable( $output_file, $res, $platform );
    ok( -e $output_file, "Wasm $name: file exists" );
SKIP: {
        skip 'wasmtime not available', 1 unless $wasmtime && -x $wasmtime;
        my $output = qx["$wasmtime" run --invoke main $output_file 2>$null];
        chomp $output;
        is( $output, $case->{want}, "Wasm $name: $case->{value} truncates to $case->{want} (got $output)" );
    }
    unlink $output_file if -e $output_file;
}
done_testing;
