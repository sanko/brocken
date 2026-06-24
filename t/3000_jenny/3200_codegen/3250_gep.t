use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# x86_64 GEP: constant index -> lea with disp
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'gep_const', return_type => Brocken::Lindsay::IR::Type::ptr() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(),
        $ptr, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) ], '%elem' );
    $builder->build_ret($gep);
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new( platform => Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu') );
    my $mf      = $lowerer->lower($func);
    my $ops     = $mf->blocks->[0]->instructions;
    my ($lea)   = grep { $_->opcode eq 'lea' } $ops->@*;
    ok( defined $lea, 'x86_64 const GEP: lea produced' );

    if ($lea) {
        my $mem = $lea->operands->[1];
        is( $mem->kind,          'mem',  'x86_64 const GEP: second operand is mem' );
        is( $mem->value->{base}, '%arr', 'x86_64 const GEP: base = %arr' );
        is( $mem->value->{disp}, 168,    'x86_64 const GEP: disp = 42*4' );
        ok( !defined $mem->value->{index}, 'x86_64 const GEP: no index for const' );
    }
}

# x86_64 GEP: variable index -> lea with index+scale
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'gep_var', return_type => Brocken::Lindsay::IR::Type::ptr() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
    my $idx = $builder->build_add(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
        '%idx'
    );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $ptr, [$idx], '%elem' );
    $builder->build_ret($gep);
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new( platform => Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu') );
    my $mf      = $lowerer->lower($func);
    my $ops     = $mf->blocks->[0]->instructions;
    my ($lea)   = grep { $_->opcode eq 'lea' } $ops->@*;
    ok( defined $lea, 'x86_64 var GEP: lea produced' );

    if ($lea) {
        my $mem = $lea->operands->[1];
        is( $mem->value->{base},  '%arr', 'x86_64 var GEP: base = %arr' );
        is( $mem->value->{index}, '%idx', 'x86_64 var GEP: index = %idx' );
        is( $mem->value->{scale}, 4,      'x86_64 var GEP: scale = 4 (i32)' );
        is( $mem->value->{disp},  0,      'x86_64 var GEP: disp = 0' );
    }
}

# ARM64 GEP: constant index -> add with imm
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'gep_const', return_type => Brocken::Lindsay::IR::Type::ptr() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(),
        $ptr, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) ], '%elem' );
    $builder->build_ret($gep);
    my $lowerer = Brocken::Jenny::Lowerer::ARM64->new( platform => Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu') );
    my $mf      = $lowerer->lower($func);
    my $ops     = $mf->blocks->[0]->instructions;
    my @adds    = grep { $_->opcode eq 'add' } $ops->@*;
    ok( scalar @adds >= 1, 'ARM64 const GEP: add produced' );

    if (@adds) {
        my $gep_add = ( grep { $_->operands->[1]->kind eq 'imm' } @adds )[0];
        ok( defined $gep_add, 'ARM64 const GEP: add with imm' );
        if ($gep_add) {
            is( $gep_add->operands->[1]->value, 168, 'ARM64 const GEP: offset = 42*4' );
        }
    }
}

# ARM64 GEP: variable index -> add with vreg
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'gep_var', return_type => Brocken::Lindsay::IR::Type::ptr() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
    my $idx = $builder->build_add(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
        '%idx'
    );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $ptr, [$idx], '%elem' );
    $builder->build_ret($gep);
    my $lowerer = Brocken::Jenny::Lowerer::ARM64->new( platform => Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu') );
    my $mf      = $lowerer->lower($func);
    my $ops     = $mf->blocks->[0]->instructions;
    my @adds    = grep { $_->opcode eq 'add' } $ops->@*;
    ok( scalar @adds >= 1, 'ARM64 var GEP: add produced' );

    if (@adds) {
        my $gep_add = ( grep { $_->operands->[1]->kind eq 'virt_reg' } @adds )[0];
        ok( defined $gep_add, 'ARM64 var GEP: add with vreg operand' );
        if ($gep_add) {
            is( $gep_add->operands->[1]->value, '%idx', 'ARM64 var GEP: index = %idx' );
        }
    }
}

# RISCV64 GEP: constant index -> mv + add imm
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'gep_const', return_type => Brocken::Lindsay::IR::Type::ptr() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(),
        $ptr, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) ], '%elem' );
    $builder->build_ret($gep);
    my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new( platform => Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu') );
    my $mf      = $lowerer->lower($func);
    my $ops     = $mf->blocks->[0]->instructions;
    my @mvs     = grep { $_->opcode eq 'mv' } $ops->@*;
    my @adds    = grep { $_->opcode eq 'add' } $ops->@*;
    ok( scalar @mvs >= 1,  'RISCV64 const GEP: mv produced' );
    ok( scalar @adds >= 1, 'RISCV64 const GEP: add produced' );

    if (@adds) {
        my $add_imm = $adds[0]->operands->[1];
        is( $add_imm->kind,  'imm', 'RISCV64 const GEP: add with imm' );
        is( $add_imm->value, 168,   'RISCV64 const GEP: offset = 42*4' );
    }
}

# RISCV64 GEP: variable index -> add with ptr
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'gep_var', return_type => Brocken::Lindsay::IR::Type::ptr() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
    my $idx = $builder->build_add(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
        '%idx'
    );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $ptr, [$idx], '%elem' );
    $builder->build_ret($gep);
    my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new( platform => Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu') );
    my $mf      = $lowerer->lower($func);
    my $ops     = $mf->blocks->[0]->instructions;
    my @adds    = grep { $_->opcode eq 'add' } $ops->@*;
    ok( scalar @adds >= 1, 'RISCV64 var GEP: add produced' );

    if (@adds) {
        my $gep_add = ( grep { $_->operands->[1]->kind eq 'virt_reg' } @adds )[0];
        ok( defined $gep_add, 'RISCV64 var GEP: add with vreg' );
        if ($gep_add) {
            is( $gep_add->operands->[1]->value, '%arr', 'RISCV64 var GEP: add base = %arr' );
        }
    }
}

# Wasm GEP: constant index -> i32_const, i32_add, local_set
{
    my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
    my $func     = Brocken::Lindsay::IR::Function->new( name => 'gep_const', return_type => Brocken::Lindsay::IR::Type::ptr() );
    my $builder  = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(),
        $ptr, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) ], '%elem' );
    $builder->build_ret($gep);
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my $mf      = $lowerer->lower($func);
    my $ops     = $mf->blocks->[0]->instructions;
    my @consts  = grep { $_->opcode eq 'i32_const' } $ops->@*;
    my @adds    = grep { $_->opcode eq 'i32_add' } $ops->@*;
    my @sets    = grep { $_->opcode eq 'local_set' } $ops->@*;
    ok( scalar @consts >= 1, 'Wasm const GEP: i32_const produced' );
    ok( scalar @adds >= 1,   'Wasm const GEP: i32_add produced' );
    ok( scalar @sets >= 1,   'Wasm const GEP: local_set produced' );

    if (@consts) {
        is( $consts[-1]->operands->[0]->value, 168, 'Wasm const GEP: offset = 42*4' );
    }
}

# Wasm GEP: variable index -> i32_const, i32_mul, i32_add, local_set
{
    my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
    my $func     = Brocken::Lindsay::IR::Function->new( name => 'gep_var', return_type => Brocken::Lindsay::IR::Type::ptr() );
    my $builder  = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
    my $idx = $builder->build_add(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
        '%idx'
    );
    my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $ptr, [$idx], '%elem' );
    $builder->build_ret($gep);
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my $mf      = $lowerer->lower($func);
    my $ops     = $mf->blocks->[0]->instructions;
    my @consts  = grep { $_->opcode eq 'i32_const' } $ops->@*;
    my @muls    = grep { $_->opcode eq 'i32_mul' } $ops->@*;
    my @adds    = grep { $_->opcode eq 'i32_add' } $ops->@*;
    my @sets    = grep { $_->opcode eq 'local_set' } $ops->@*;
    ok( scalar @consts >= 1, 'Wasm var GEP: i32_const produced (scale)' );
    ok( scalar @muls >= 1,   'Wasm var GEP: i32_mul produced (scale=4)' );
    ok( scalar @adds >= 1,   'Wasm var GEP: i32_add produced' );
    ok( scalar @sets >= 1,   'Wasm var GEP: local_set produced' );
}
done_testing;
