use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $platform = Brocken::Katsuro::Platform::parse();
my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
my $builder  = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func->append_block('entry') );
my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%ptr' );
$builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ), $ptr );
my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%val' );
$builder->build_ret($val);
my $codegen
    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
my $bytes = $codegen->emit_function($func);
ok( length($bytes) > 0, 'Generated memory op bytes for ' . $platform->friendly );
my $linker
    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
    Brocken::Jenny::Linker::ELF64->new();
SKIP: {
    skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
    my $output_file = 'mem_test' . $platform->bin_ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -x $output_file || $platform->is_windows, 'Memory binary exists' );
    run_exec( $output_file, expected_exit => 42, platform => $platform, name => 'Memory binary returned 42 on ' . $platform->friendly );
}
done_testing;
