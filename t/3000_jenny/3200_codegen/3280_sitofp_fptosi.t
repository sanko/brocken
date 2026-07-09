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

# x86_64: SIToFP -> cvtsi2sd, FPToSI -> cvttsd2si
subtest 'x86_64 SIToFP and FPToSI lowering' => sub {
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new( platform => Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu') );

    # SIToFP: i64 -> f64
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'sitofp_test', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 42 );
        my $conv = $builder->build_sitofp( $val, Brocken::Lindsay::IR::Type::f64(), '%sitofp' );
        $builder->build_ret($conv);
        my $mf         = $lowerer->lower($func);
        my $ops        = $mf->blocks->[0]->instructions;
        my ($cvtsi2sd) = grep { $_->opcode eq 'cvtsi2sd' } $ops->@*;
        ok( defined $cvtsi2sd, 'x86_64 SIToFP: cvtsi2sd produced' );

        if ($cvtsi2sd) {
            my ( $dst, $src ) = $cvtsi2sd->operands->@*;
            is( $dst->kind, 'virt_reg', 'x86_64 SIToFP: dst is virt_reg' );
            ok( $dst->type->kind eq 'float' && $dst->type->bits == 64, 'x86_64 SIToFP: dst type is f64' );
        }
    }

    # SIToFP with imm materialization (imm GP -> tmp -> cvtsi2sd)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'sitofp_imm', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 99 );
        my $conv = $builder->build_sitofp( $val, Brocken::Lindsay::IR::Type::f64(), '%sitofp' );
        $builder->build_ret($conv);
        my $mf         = $lowerer->lower($func);
        my $ops        = $mf->blocks->[0]->instructions;
        my ($mov)      = grep { $_->opcode eq 'mov' && $_->operands->[1]->kind eq 'imm' } $ops->@*;
        my ($cvtsi2sd) = grep { $_->opcode eq 'cvtsi2sd' } $ops->@*;
        ok( defined $mov,      'x86_64 SIToFP imm: mov imm to tmp GP reg' );
        ok( defined $cvtsi2sd, 'x86_64 SIToFP imm: cvtsi2sd produced' );
    }

    # FPToSI: f64 -> i64
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'fptosi_test', return_type => Brocken::Lindsay::IR::Type::i64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f64(), '%fptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 42.7 ), $fptr );
        my $fv   = $builder->build_load( Brocken::Lindsay::IR::Type::f64(), $fptr, '%fv' );
        my $conv = $builder->build_fptosi( $fv, Brocken::Lindsay::IR::Type::i64(), '%fptosi' );
        $builder->build_ret($conv);
        my $mf          = $lowerer->lower($func);
        my $ops         = $mf->blocks->[0]->instructions;
        my ($cvttsd2si) = grep { $_->opcode eq 'cvttsd2si' } $ops->@*;
        ok( defined $cvttsd2si, 'x86_64 FPToSI: cvttsd2si produced' );

        if ($cvttsd2si) {
            my ( $dst, $src ) = $cvttsd2si->operands->@*;
            is( $dst->kind, 'virt_reg', 'x86_64 FPToSI: dst is virt_reg' );
            ok( $dst->type->kind eq 'int' && $dst->type->bits == 64, 'x86_64 FPToSI: dst type is i64' );
        }
    }
};

# ARM64: SIToFP -> scvtf, FPToSI -> fcvtzs
subtest 'ARM64 SIToFP and FPToSI lowering' => sub {
    my $lowerer = Brocken::Jenny::Lowerer::ARM64->new( platform => Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu') );

    # SIToFP: i64 -> f64
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'sitofp_test', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 42 );
        my $conv = $builder->build_sitofp( $val, Brocken::Lindsay::IR::Type::f64(), '%sitofp' );
        $builder->build_ret($conv);
        my $mf      = $lowerer->lower($func);
        my $ops     = $mf->blocks->[0]->instructions;
        my ($scvtf) = grep { $_->opcode eq 'scvtf' } $ops->@*;
        ok( defined $scvtf, 'ARM64 SIToFP: scvtf produced' );

        if ($scvtf) {
            my ( $dst, $src ) = $scvtf->operands->@*;
            ok( $dst->type->kind eq 'float' && $dst->type->bits == 64, 'ARM64 SIToFP: dst type is f64' );
        }
    }

    # SIToFP with imm materialization
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'sitofp_imm', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 99 );
        my $conv = $builder->build_sitofp( $val, Brocken::Lindsay::IR::Type::f64(), '%sitofp' );
        $builder->build_ret($conv);
        my $mf      = $lowerer->lower($func);
        my $ops     = $mf->blocks->[0]->instructions;
        my ($mov)   = grep { $_->opcode eq 'mov' && $_->operands->[1]->kind eq 'imm' } $ops->@*;
        my ($scvtf) = grep { $_->opcode eq 'scvtf' } $ops->@*;
        ok( defined $mov,   'ARM64 SIToFP imm: mov imm to tmp GP reg' );
        ok( defined $scvtf, 'ARM64 SIToFP imm: scvtf produced' );
    }

    # FPToSI: f64 -> i64
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'fptosi_test', return_type => Brocken::Lindsay::IR::Type::i64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f64(), '%fptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 42.7 ), $fptr );
        my $fv   = $builder->build_load( Brocken::Lindsay::IR::Type::f64(), $fptr, '%fv' );
        my $conv = $builder->build_fptosi( $fv, Brocken::Lindsay::IR::Type::i64(), '%fptosi' );
        $builder->build_ret($conv);
        my $mf       = $lowerer->lower($func);
        my $ops      = $mf->blocks->[0]->instructions;
        my ($fcvtzs) = grep { $_->opcode eq 'fcvtzs' } $ops->@*;
        ok( defined $fcvtzs, 'ARM64 FPToSI: fcvtzs produced' );

        if ($fcvtzs) {
            my ( $dst, $src ) = $fcvtzs->operands->@*;
            ok( $dst->type->kind eq 'int' && $dst->type->bits == 64, 'ARM64 FPToSI: dst type is i64' );
        }
    }
};

# RISCV64: SIToFP -> scvtf (FCVT.D.L), FPToSI -> fcvtzs (FCVT.L.D)
subtest 'RISCV64 SIToFP and FPToSI lowering' => sub {
    my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new( platform => Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu') );

    # SIToFP: i64 -> f64
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'sitofp_test', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 42 );
        my $conv = $builder->build_sitofp( $val, Brocken::Lindsay::IR::Type::f64(), '%sitofp' );
        $builder->build_ret($conv);
        my $mf      = $lowerer->lower($func);
        my $ops     = $mf->blocks->[0]->instructions;
        my ($scvtf) = grep { $_->opcode eq 'scvtf' } $ops->@*;
        ok( defined $scvtf, 'RISCV64 SIToFP: scvtf produced' );

        if ($scvtf) {
            my ( $dst, $src ) = $scvtf->operands->@*;
            ok( $dst->type->kind eq 'float' && $dst->type->bits == 64, 'RISCV64 SIToFP: dst type is f64' );
        }
    }

    # SIToFP with imm materialization (mov)
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'sitofp_imm', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 99 );
        my $conv = $builder->build_sitofp( $val, Brocken::Lindsay::IR::Type::f64(), '%sitofp' );
        $builder->build_ret($conv);
        my $mf      = $lowerer->lower($func);
        my $ops     = $mf->blocks->[0]->instructions;
        my ($mov)   = grep { $_->opcode eq 'mov' && $_->operands->[1]->kind eq 'imm' } $ops->@*;
        my ($scvtf) = grep { $_->opcode eq 'scvtf' } $ops->@*;
        ok( defined $mov,   'RISCV64 SIToFP imm: mov imm to tmp GP reg' );
        ok( defined $scvtf, 'RISCV64 SIToFP imm: scvtf produced' );
    }

    # FPToSI: f64 -> i64
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'fptosi_test', return_type => Brocken::Lindsay::IR::Type::i64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f64(), '%fptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 42.7 ), $fptr );
        my $fv   = $builder->build_load( Brocken::Lindsay::IR::Type::f64(), $fptr, '%fv' );
        my $conv = $builder->build_fptosi( $fv, Brocken::Lindsay::IR::Type::i64(), '%fptosi' );
        $builder->build_ret($conv);
        my $mf       = $lowerer->lower($func);
        my $ops      = $mf->blocks->[0]->instructions;
        my ($fcvtzs) = grep { $_->opcode eq 'fcvtzs' } $ops->@*;
        ok( defined $fcvtzs, 'RISCV64 FPToSI: fcvtzs produced' );

        if ($fcvtzs) {
            my ( $dst, $src ) = $fcvtzs->operands->@*;
            ok( $dst->type->kind eq 'int' && $dst->type->bits == 64, 'RISCV64 FPToSI: dst type is i64' );
        }
    }
};

# Wasm: SIToFP -> f64_convert_i64_s, FPToSI -> i64_trunc_f64_s
subtest 'Wasm SIToFP and FPToSI lowering' => sub {
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();

    # SIToFP: i64 -> f64
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'sitofp_test', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 42 );
        my $conv = $builder->build_sitofp( $val, Brocken::Lindsay::IR::Type::f64(), '%sitofp' );
        $builder->build_ret($conv);
        my $mf        = $lowerer->lower($func);
        my $ops       = $mf->blocks->[0]->instructions;
        my ($conv_op) = grep { $_->opcode eq 'f64_convert_i64_s' } $ops->@*;
        my @sets      = grep { $_->opcode eq 'local_set' } $ops->@*;
        ok( defined $conv_op,  'Wasm SIToFP: f64_convert_i64_s produced' );
        ok( scalar @sets >= 1, 'Wasm SIToFP: local_set produced' );
    }

    # FPToSI: f64 -> i64
    {
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'fptosi_test', return_type => Brocken::Lindsay::IR::Type::i64() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f64(), '%fptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 42.7 ), $fptr );
        my $fv   = $builder->build_load( Brocken::Lindsay::IR::Type::f64(), $fptr, '%fv' );
        my $conv = $builder->build_fptosi( $fv, Brocken::Lindsay::IR::Type::i64(), '%fptosi' );
        $builder->build_ret($conv);
        my $mf         = $lowerer->lower($func);
        my $ops        = $mf->blocks->[0]->instructions;
        my ($trunc_op) = grep { $_->opcode eq 'i64_trunc_f64_s' } $ops->@*;
        my @sets       = grep { $_->opcode eq 'local_set' } $ops->@*;
        ok( defined $trunc_op, 'Wasm FPToSI: i64_trunc_f64_s produced' );
        ok( scalar @sets >= 1, 'Wasm FPToSI: local_set produced' );
    }
};
done_testing;
