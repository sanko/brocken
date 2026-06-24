use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $platform = Brocken::Katsuro::Platform::parse();
my $func     = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::i32() );
my $builder  = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func->append_block('entry') );
my $v1 = $builder->build_add(
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 ),
    '%v1'
);
my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 8 ), '%v2' );
$builder->build_ret($v2);
my $codegen
    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new( platform => $platform ) :
    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
my $bytes = $codegen->emit_function($func);
ok( length($bytes) > 0, 'Generated math bytes for ' . $platform->friendly );
my $linker
    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
    Brocken::Jenny::Linker::ELF64->new();
SKIP: {
    skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
    my $output_file = 'math_test' . $platform->bin_ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -x $output_file || $platform->is_windows, 'Math binary exists' );
    my $cmd = $platform->is_windows ? $output_file : "./$output_file";
    system {$cmd} $cmd;
    my $exit_code = $? >> 8;
    is( $exit_code, 42, 'Math binary returned 42 on ' . $platform->friendly );
    unlink $output_file;
}
done_testing;
