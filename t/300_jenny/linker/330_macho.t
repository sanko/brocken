use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Mach-O executable
{
    my $platform  = Brocken::Katsuro::Platform::parse();
    my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_macho' );
    my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_main);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_main->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
        Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
    my $machine_bytes = $codegen->emit_function($func_main);
    my $output_file   = './test_prog';
    my $linker        = Brocken::Jenny::Linker::MachO->new();
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'Mach-O executable created successfully';
SKIP: {
        skip 'Mach-O binary execution test requires macOS (x64 or ARM64)', 1 unless $platform->is_macos;
        system($output_file);
        my $exit_code = $? >> 8;
        is $exit_code, 42, 'Standalone Mach-O binary executed natively and returned the correct exit code!';
    }
    unlink $output_file;
}

# Mach-O shared library
{
    my $platform = Brocken::Katsuro::Platform::parse();
    my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_macho' );
    my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_ext);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_ext->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
        Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
    my $machine_bytes = $codegen->emit_function($func_ext);
    my $output_file   = './libtest_prog.dylib';
    my $linker        = Brocken::Jenny::Linker::MachO->new( type => 'shared' );
    $linker->set_exported_funcs( ['my_func'] );
    $linker->set_labels( { E_my_func => 0 } );
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'Mach-O Shared library created successfully';
SKIP: {
        skip 'Shared library loading test requires macOS native host', 1 unless $platform->is_macos && $platform->is_native;
        require DynaLoader;
        require File::Spec;
        my $abs_path = File::Spec->rel2abs($output_file);
        my $libref   = DynaLoader::dl_load_file($abs_path);
        ok $libref, 'Loaded Mach-O shared library natively via DynaLoader';
        if ($libref) {
            my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
            ok $symref, 'Successfully resolved exported symbol "my_func"';
            DynaLoader::dl_unload_file($libref);
        }
    }
    unlink $output_file;
}
done_testing;
