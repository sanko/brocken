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
SKIP: {
    skip 'Execution test only supported on native hosts', 60 unless $platform->is_native;
    for my $tc (
        [ eq  => 42, 42, 1, '42 eq 42' ],
        [ eq  => 42, 0,  0, '42 eq 0' ],
        [ ne  => 42, 0,  1, '42 ne 0' ],
        [ ne  => 42, 42, 0, '42 ne 42' ],
        [ ult => 0,  42, 1, '0 ult 42' ],
        [ ult => 42, 0,  0, '42 ult 0' ],
        [ ugt => 42, 0,  1, '42 ugt 0' ],
        [ ugt => 0,  42, 0, '0 ugt 42' ],
        [ ule => 0,  42, 1, '0 ule 42' ],
        [ ule => 42, 0,  0, '42 ule 0' ],
        [ uge => 42, 0,  1, '42 uge 0' ],
        [ uge => 0,  42, 0, '0 uge 42' ],
        [ slt => 0,  42, 1, '0 slt 42' ],
        [ slt => 42, 0,  0, '42 slt 0' ],
        [ sgt => 42, 0,  1, '42 sgt 0' ],
        [ sgt => 0,  42, 0, '0 sgt 42' ],
        [ sle => 0,  42, 1, '0 sle 42' ],
        [ sle => 42, 0,  0, '42 sle 0' ],
        [ sge => 42, 0,  1, '42 sge 0' ],
        [ sge => 0,  42, 0, '0 sge 42' ],
    ) {
        my ( $pred, $a, $b, $expected, $desc ) = @$tc;
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        my $entry   = $func->append_block('entry');
        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp(
            $pred,
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $a ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $b ), '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, "Generated native i128 icmp $desc bytes for " . $platform->friendly );
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
        my $output_file = "i128_icmp_${pred}_native" . $platform->bin_ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, "Native i128 icmp $desc file exists" );
        my $cmd = $platform->is_windows ? $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit_code = $? >> 8;
        is( $exit_code, $expected ? 42 : 0, "Native i128 icmp $desc returned " . ( $expected ? 42 : 0 ) . " on " . $platform->friendly );
        unlink $output_file if -e $output_file;
    }
}
done_testing;
