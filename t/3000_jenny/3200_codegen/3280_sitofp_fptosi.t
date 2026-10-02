use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Jenny::Linker::Wasm;
use Test2::Tools::Brocken qw[temp_path];
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

# A Wasm conversion opcode names both widths, so the source and the destination
# pick it rather than the direction alone. Choosing it from the direction alone
# emitted `i32.trunc_f32_s` for an f64 source, which is a module wasmtime
# refuses to compile, and nothing here noticed: the checks above look for an
# opcode by name and never look at its width.
my @CONV = (
    { dir => 'sitofp', src => 'i64', dst => 'f64', op => 'f64_convert_i64_s' },
    { dir => 'sitofp', src => 'i32', dst => 'f64', op => 'f64_convert_i32_s' },
    { dir => 'sitofp', src => 'i64', dst => 'f32', op => 'f32_convert_i64_s' },
    { dir => 'sitofp', src => 'i32', dst => 'f32', op => 'f32_convert_i32_s' },
    { dir => 'fptosi', src => 'f64', dst => 'i64', op => 'i64_trunc_f64_s' },
    { dir => 'fptosi', src => 'f64', dst => 'i32', op => 'i32_trunc_f64_s' },
    { dir => 'fptosi', src => 'f32', dst => 'i64', op => 'i64_trunc_f32_s' },
    { dir => 'fptosi', src => 'f32', dst => 'i32', op => 'i32_trunc_f32_s' },
);
sub ty { my $m = shift; return Brocken::Lindsay::IR::Type->$m() }

# Stored through a slot and loaded back so the conversion is a real instruction
# rather than a folded constant. 42.5 truncates to 42 and 42 converts to 42.0,
# so every shape here is worth 42.
sub conversion_function {
    my ( $c, $entry ) = @_;
    my $from = $c->{dir} eq 'fptosi' ? 42.5 : 42;
    my $func = Brocken::Lindsay::IR::Function->new(
        name        => ( $entry ? '_BROCKEN_ENTRY' : 'conv' ),
        return_type => ty( $c->{dst} ),
        params      => ( $entry ? [ Brocken::Lindsay::IR::Value->new( type => ty('i64'), name => 'heap_base' ) ] : [] ),
    );
    my $b = Brocken::Lindsay::IR::Builder->new();
    $b->position_at_end( $func->append_block('entry') );
    my $slot = $b->build_alloca( ty( $c->{src} ), '%slot' );
    $b->build_store( Brocken::Lindsay::IR::Constant->new( type => ty( $c->{src} ), value => $from ), $slot );
    my $ld = $b->build_load( ty( $c->{src} ), $slot, '%ld' );
    my $cv = $c->{dir} eq 'fptosi' ? $b->build_fptosi( $ld, ty( $c->{dst} ), '%cv' ) : $b->build_sitofp( $ld, ty( $c->{dst} ), '%cv' );
    $b->build_ret($cv);
    return $func;
}
subtest 'Wasm picks the conversion opcode for both widths' => sub {
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    for my $c (@CONV) {
        my $mf  = $lowerer->lower( conversion_function($c) );
        my $ops = $mf->blocks->[0]->instructions;
        my @hit = grep { $_->opcode eq $c->{op} } $ops->@*;
        ok( scalar @hit, "$c->{src} -> $c->{dst} emits $c->{op}" ) or
            diag( 'saw: ' . join( ', ', grep { $_->opcode =~ /(?:trunc|convert)/ } map { $_->opcode } $ops->@* ) );
    }
};
subtest 'every int/float width pair compiles to a module that runs' => sub {
    my $host = Brocken::Katsuro::Platform::parse();
    my $null = $host->is_windows ? 'NUL'                  : '/dev/null';
    my $wt   = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
    chomp $wt if $wt;
    skip_all('wasmtime not available') unless $wt && -f $wt;
    my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
    my $codegen  = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    for my $c (@CONV) {
        my $module = temp_path( 'conv_' . $c->{src} . '_' . $c->{dst} ) . '.wasm';
        Brocken::Jenny::Linker::Wasm->new->write_executable( $module, $codegen->emit_functions( [ conversion_function( $c, 1 ) ] ), $platform );

        # Validation is the assertion that matters: the byte for a conversion is
        # what decides whether the module is loadable at all.
        my $compile = qq["$wt" compile "$module" -o "$null" 2>&1];
        is( system($compile), 0, "$c->{src} -> $c->{dst} validates" ) or diag qx[$compile];
        my $got = qx["$wt" run --invoke _BROCKEN_ENTRY "$module" 1024 2>$null];
        chomp $got;
        is( $got, 42, "$c->{src} -> $c->{dst} round-trips 42" );
        unlink $module if -e $module;
    }
};
done_testing;
