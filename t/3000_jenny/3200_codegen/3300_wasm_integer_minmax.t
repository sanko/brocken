use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

# WebAssembly has no i32_min/i32_max/i64_min/i64_max opcode; the lowerer must synthesize the operation. Before
# the fix the generated module referenced an opcode the encoder could not encode.
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $null = $host->is_windows ? 'NUL' : '/dev/null';

sub run_module {
    my ( $ret_type, $build ) = @_;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $ret_type );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $build->($builder);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $res     = $codegen->emit_function($func);
    my $linker  = Brocken::Jenny::Linker::Wasm->new();
    my $file    = temp_path('minmax') . '.wasm';
    $linker->write_executable( $file, $res, $platform );
    my $output;
    if ( $wasmtime_path && -x $wasmtime_path ) {
        $output = qx["$wasmtime_path" run --invoke main $file 2>$null];
        chomp $output if $output;
    }
    unlink $file if -e $file;
    return $output;
}

subtest 'wasm i32 integer min/max' => sub {
    my $out = run_module(
        Brocken::Lindsay::IR::Type::i32(),
        sub {
            my ($b)  = @_;
            my $t    = Brocken::Lindsay::IR::Type::i32();
            my $c30  = Brocken::Lindsay::IR::Constant->new( type => $t, value => 30 );
            my $c7   = Brocken::Lindsay::IR::Constant->new( type => $t, value => 7 );
            my $mn   = $b->build_min( $c30, $c7, '%mn' );
            my $mx   = $b->build_max( $c30, $c7, '%mx' );
            $b->build_ret( $b->build_sub( $mx, $mn, '%r' ) );
        }
    );
    skip 'wasmtime is not installed', 1 unless defined $out;
    is( $out, 23, 'max(30,7) - min(30,7) = 23' );
};

subtest 'wasm i64 integer min/max' => sub {
    my $out = run_module(
        Brocken::Lindsay::IR::Type::i64(),
        sub {
            my ($b)    = @_;
            my $t      = Brocken::Lindsay::IR::Type::i64();
            my $big    = Brocken::Lindsay::IR::Constant->new( type => $t, value => 5_000_000_000 );
            my $small  = Brocken::Lindsay::IR::Constant->new( type => $t, value => 3 );
            my $mn     = $b->build_min( $big, $small, '%mn' );
            my $mx     = $b->build_max( $big, $small, '%mx' );
            $b->build_ret( $b->build_sub( $mx, $mn, '%r' ) );
        }
    );
    skip 'wasmtime is not installed', 1 unless defined $out;
    is( $out, 4_999_999_997, 'max(5e9,3) - min(5e9,3)' );
};

done_testing;
