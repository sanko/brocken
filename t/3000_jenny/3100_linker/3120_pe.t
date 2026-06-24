use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken;
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# PE executable
{
    my $brocken   = Brocken->new();
    my $platform  = $brocken->platform;
    my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_win' );
    my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_main);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_main->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen       = $brocken->codegen;
    my $machine_bytes = $codegen->emit_function($func_main);
    my $output_file   = 'test_prog.exe';
    my $linker        = Brocken::Jenny::Linker::PE->new();
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'Windows executable file created successfully';
SKIP: {
        skip 'PE binary execution test requires x86_64 Windows', 1 unless $platform->is_windows;
        run_exec(
            $output_file,
            expected_exit => 42,
            platform      => $platform,
            name          => 'Standalone Windows binary executed natively and returned the correct exit code!'
        );
    }
    unlink $output_file;
}

# PE shared library
{
    my $brocken  = Brocken->new();
    my $platform = $brocken->platform;
    my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_pe' );
    my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_ext);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_ext->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen       = $brocken->codegen;
    my $machine_bytes = $codegen->emit_function($func_ext);
    my $output_file   = './libtest_prog.dll';
    my $linker        = Brocken::Jenny::Linker::PE->new( type => 'shared' );
    $linker->set_exported_funcs( ['my_func'] );
    $linker->set_labels( { E_my_func => 0 } );
    $linker->write_shared_library( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'PE Shared library (DLL) created successfully';
SKIP: {
        use Config;
        skip 'Shared library loading test requires native execution support (no emulation mismatch)', 1
            unless $platform->is_windows && $platform->is_native && ( $platform->is_arm64 ? ( $Config{archname} !~ /x86_64|x64/i ) : 1 );
        require DynaLoader;
        require File::Spec;
        my $abs_path = File::Spec->rel2abs($output_file);
        my $libref   = DynaLoader::dl_load_file($abs_path);
        ok $libref, 'Loaded PE DLL natively via DynaLoader';
        if ($libref) {
            my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
            ok $symref, 'Successfully resolved exported symbol "my_func" natively via DynaLoader';
            DynaLoader::dl_unload_file($libref);
        }
    }
    unlink $output_file;
}
done_testing;
