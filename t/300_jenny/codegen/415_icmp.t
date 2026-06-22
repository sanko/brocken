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

# ICmp signed
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'icmp_signed', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $entry   = $func->append_block('entry');
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->position_at_end($entry);
    my $cond = $builder->build_icmp(
        'sgt',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
    );
    $builder->build_cond_br( $cond, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
    my $codegen
        = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
        $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new( platform => $platform ) :
        Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated signed icmp bytes for ' . $platform->friendly );
    my $linker
        = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
        $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
        Brocken::Jenny::Linker::ELF64->new();
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'icmp_test' . $platform->bin_ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file || $platform->is_windows, 'ICmp binary exists' );
        my $cmd = $platform->is_windows ? $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit_code = $? >> 8;
        is( $exit_code, 42, 'ICmp signed (42 sgt 0 = true) returned 42 on ' . $platform->friendly );
        unlink $output_file;
    }
}

# ICmp unsigned
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'icmp_unsigned', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $entry   = $func->append_block('entry');
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->position_at_end($entry);
    my $cond = $builder->build_icmp(
        'ugt',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
    );
    $builder->build_cond_br( $cond, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
    my $codegen
        = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
        $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new( platform => $platform ) :
        Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated unsigned icmp bytes for ' . $platform->friendly );
    my $linker
        = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
        $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
        Brocken::Jenny::Linker::ELF64->new();
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'icmp_unsigned_test' . $platform->bin_ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file || $platform->is_windows, 'ICmp unsigned binary exists' );
        my $cmd = $platform->is_windows ? $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit_code = $? >> 8;
        is( $exit_code, 42, 'ICmp unsigned (42 ugt 0 = true) returned 42 on ' . $platform->friendly );
        unlink $output_file;
    }
}
done_testing;
