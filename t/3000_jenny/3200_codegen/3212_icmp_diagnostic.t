use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $brocken  = Brocken->new();
my $platform = $brocken->platform;
SKIP: {
    skip 'Only for RISC-V', 2 unless $platform->is_riscv64 && $platform->is_native;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'icmp_only', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $entry   = $func->append_block('entry');
    $builder->position_at_end($entry);
    my $cond = $builder->build_icmp(
        'sgt',
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
    );
    $builder->build_ret($cond);
    my $codegen     = $brocken->codegen;
    my $bytes       = $codegen->emit_function($func);
    my $linker      = $brocken->linker;
    my $output_file = $brocken->tmpdir . '/icmp_only_test' . $brocken->ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    system $output_file;
    my $exit_code = $? >> 8;
    is( $exit_code, 1, 'ICmp result (42 sgt 0 = 1) returned 1' );
    unlink $output_file;
}
SKIP: {
    skip 'Only for RISC-V', 2 unless $platform->is_riscv64 && $platform->is_native;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'jmp_only', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $entry   = $func->append_block('entry');
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->position_at_end($entry);
    $builder->build_br($t_block);
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
    my $codegen     = $brocken->codegen;
    my $bytes       = $codegen->emit_function($func);
    my $linker      = $brocken->linker;
    my $output_file = $brocken->tmpdir . '/jmp_only_test' . $brocken->ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    system $output_file;
    my $exit_code = $? >> 8;
    is( $exit_code, 42, 'JMP (unconditional branch to if.then) returned 42' );
    unlink $output_file;
}
SKIP: {
    skip 'Only for RISC-V', 2 unless $platform->is_riscv64 && $platform->is_native;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'condbr_const', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $entry   = $func->append_block('entry');
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->position_at_end($entry);
    $builder->build_cond_br( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ), $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
    my $codegen     = $brocken->codegen;
    my $bytes       = $codegen->emit_function($func);
    my $linker      = $brocken->linker;
    my $output_file = $brocken->tmpdir . '/condbr_const_test' . $brocken->ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    system $output_file;
    my $exit_code = $? >> 8;
    is( $exit_code, 42, 'CondBr constant condition (1 = true) returned 42' );
    unlink $output_file;
}
done_testing;
