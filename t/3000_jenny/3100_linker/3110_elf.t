use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# ELF executable
{
    my $brocken   = Brocken->new();
    my $platform  = $brocken->platform;
    my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_elf' );
    my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_main);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_main->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen       = $brocken->codegen;
    my $machine_bytes = $codegen->emit_function($func_main);
    my $output_file   = $brocken->tmpdir . '/test_prog';
    my $linker        = Brocken::Jenny::Linker::ELF64->new();
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'ELF executable created successfully';
SKIP: {
        skip 'ELF binary execution test requires Linux/BSD/Haiku' unless $platform->is_linux || $platform->is_bsd || $platform->is_haiku;
        ok -x $output_file, 'Binary is executable';
        system($output_file);
        my $exit_code = $? >> 8;
        is $exit_code, 42, 'ELF binary executed natively and returned the correct exit code!';
    }
    unlink $output_file;
}

# ELF shared library
{
    my $brocken  = Brocken->new();
    my $platform = $brocken->platform;
    my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_elf' );
    my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_ext);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_ext->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen       = $brocken->codegen;
    my $machine_bytes = $codegen->emit_function($func_ext);
    my $output_file   = $brocken->tmpdir . '/libtest_prog.so';
    my $linker        = Brocken::Jenny::Linker::ELF64->new( type => 'shared' );
    $linker->set_exported_funcs( ['my_func'] );
    $linker->set_labels( { E_my_func => 0 } );
    $linker->write_executable( $output_file, $machine_bytes, $platform, 1 );
    ok -e $output_file, 'ELF Shared library created successfully';
SKIP: {
        skip 'Shared library loading test requires Linux/BSD/Haiku native host', 1
            unless ( $platform->is_linux || $platform->is_bsd || $platform->is_haiku ) && $platform->is_native;
        require DynaLoader;
        require File::Spec;
        my $abs_path = File::Spec->rel2abs($output_file);
        my $libref   = DynaLoader::dl_load_file($abs_path);
        ok $libref, 'Loaded ELF shared library natively via DynaLoader';
        if ($libref) {
            my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
            ok $symref, 'Successfully resolved exported symbol "my_func"';
            DynaLoader::dl_unload_file($libref);
        }
    }
    unlink $output_file;
}
done_testing;
