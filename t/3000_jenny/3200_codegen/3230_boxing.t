use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken;
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $brocken  = Brocken->new();
my $platform = $brocken->platform;
my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
my $builder  = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func->append_block('entry') );
my $boxed = $builder->build_box( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ), '%boxed' );
my $val   = $builder->build_unbox( $boxed, Brocken::Lindsay::IR::Type::i32(), '%val' );
$builder->build_ret($val);
my $codegen = $brocken->codegen;
my $bytes   = $codegen->emit_function($func);
ok( length($bytes) > 0, 'Generated box/unbox bytes for ' . $platform->friendly );
my $linker = $brocken->linker;
SKIP: {
    skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
    my $output_file = $brocken->tmpdir . '/box_test' . $brocken->ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -x $output_file || $platform->is_windows, 'Box/unbox binary exists' );
    run_exec( $output_file, expected_exit => 42, platform => $platform, name => 'Box/unbox binary returned 42 on ' . $platform->friendly );
}
done_testing;
