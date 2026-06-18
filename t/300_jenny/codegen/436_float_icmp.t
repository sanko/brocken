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
my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_float', return_type => Brocken::Lindsay::IR::Type::i32() );
my $builder  = Brocken::Lindsay::IR::Builder->new();
my $entry    = $func->append_block('entry');
my $t_block  = $func->append_block('if.then');
my $f_block  = $func->append_block('if.else');
$builder->position_at_end($entry);
my $cond = $builder->build_icmp(
    'lt',
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ), '%cmp'
);
$builder->build_cond_br( $cond, $t_block, $f_block );
$builder->position_at_end($t_block);
$builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
$builder->position_at_end($f_block);
$builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
my $codegen
    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
my $bytes = $codegen->emit_function($func);
ok( length($bytes) > 0, 'Generated float icmp bytes for ' . $platform->friendly );
my $linker
    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
    Brocken::Jenny::Linker::ELF64->new();
SKIP: {
    skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
    my $output_file = 'ficmp_test' . $platform->bin_ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -e $output_file, 'Float icmp binary exists' );
    my $cmd = $platform->is_windows ? $output_file : "./$output_file";
    my $ret = system {$cmd} $cmd;
SKIP: {
        skip "system() failed to spawn ($!)", 1 if $ret == -1;
        my $exit_code = $? >> 8;
        is( $exit_code, 42, 'Float icmp returned 42 on ' . $platform->friendly );
    }
    unlink $output_file;
}
done_testing;
