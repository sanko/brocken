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
my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
my $builder  = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func->append_block('entry') );
my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr' );
$builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), $fptr );
my $fv = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr, '%fv' );
$builder->build_sub( $fv, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 0.0 ), '%fres' );
my $fptr2 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr2' );
$builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 21.0 ), $fptr2 );
my $fv2 = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr2, '%fv2' );
$builder->build_mul( $fv2, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 2.0 ), '%fres2' );
my $fptr3 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr3' );
$builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 84.0 ), $fptr3 );
my $fv3 = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr3, '%fv3' );
$builder->build_div( $fv3, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 2.0 ), '%fres3' );
my $fptr4 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f64(), '%fptr4' );
$builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 21.25 ), $fptr4 );
my $fv4 = $builder->build_load( Brocken::Lindsay::IR::Type::f64(), $fptr4, '%fv4' );
$builder->build_add( $fv4, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 20.75 ), '%fres4' );
$builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
my $codegen
    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new( platform => $platform ) :
    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
my $bytes = $codegen->emit_function($func);
ok( length($bytes) > 0, 'Generated float battery bytes for ' . $platform->friendly );
my $linker
    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
    Brocken::Jenny::Linker::ELF64->new();
SKIP: {
    skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
    my $output_file = 'fbat_test' . $platform->bin_ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -e $output_file, 'Float battery binary exists' );
    my $cmd = $platform->is_windows ? $output_file : "./$output_file";
    my $ret = system {$cmd} $cmd;
SKIP: {
        skip "system() failed to spawn ($!)", 1 if $ret == -1;
        my $exit_code = $? >> 8;
        is( $exit_code, 42, 'Float battery returned 42 on ' . $platform->friendly );
    }
    unlink $output_file;
}
done_testing;
