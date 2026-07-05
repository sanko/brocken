use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use List::Util ();
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Lowerer::ARM64;
use Brocken::Jenny::RegAlloc;
use Brocken::Jenny::MIR;

class Brocken::Jenny::Codegen::ARM64 {
    use Brocken::Jenny::Codegen::ARM64::Inst qw[:all];
    field $platform : param;
    use constant {
        B              => 0x14000000,
        CBZ            => 0xB4000000,
        CBNZ           => 0xB5000000,
        ADD_W          => 0x0B000000,
        SUB_W          => 0x4B000000,
        AND_W          => 0x0A000000,
        ORR_W          => 0x2A000000,
        EOR_W          => 0x4A000000,
        MUL_W          => 0x1B007C00,
        ADD_X          => 0x8B000000,
        ADD_X_EXT      => 0x8B200000,
        UXTX_OPT       => 0b011,
        SUB_X          => 0xCB000000,
        ADCS_X         => 0x9A000000,
        SBCS_X         => 0xDA000000,
        AND_X          => 0x8A000000,
        ORR_X          => 0xAA000000,
        EOR_X          => 0xCA000000,
        MUL_X          => 0x9B007C00,
        UMULH_X        => 0x9BC07C00,
        UDIV_X         => 0x9AC00800,
        ADD_IMM        => 0x11000000,
        ADD_IMM_64     => 0x91000000,    # ADD_IMM | SF
        SUB_IMM        => 0x51000000,
        UBFM           => 0xD3400000,
        SBFM           => 0x93400000,
        MOVZ_32        => 0x52800000,
        MOVZ_64        => 0xD2800000,
        MOVK_32        => 0x72800000,
        MOVK_64        => 0xF2800000,
        MOV_X          => 0xAA0003E0,
        SUB_SP         => 0xD10003FF,
        ADD_SP         => 0x910003FF,
        MOV_SP         => 0x910003E0,
        LDR_32         => 0xB9400000,
        LDR_64         => 0xF9400000,
        STR_32         => 0xB9000000,
        STR_64         => 0xF9000000,
        LDR_32_REG     => 0xB8408000,
        LDR_64_REG     => 0xF8408000,
        STR_32_REG     => 0xB8208000,
        STR_64_REG     => 0xF8208000,
        FLDR_32        => 0xBD400000,
        FLDR_64        => 0xFD400000,
        FSTR_32        => 0xBD000000,
        FSTR_64        => 0xFD000000,
        FLDR_32_REG    => 0xBC408000,
        FLDR_64_REG    => 0xFC408000,
        FSTR_32_REG    => 0xBC208000,
        FSTR_64_REG    => 0xFC208000,
        CMP_IMM        => 0x7100001F,
        CMP_REG        => 0x6B00001F,
        CSINC          => 0x9A9F07E0,
        FABS_32        => 0x1E20C000,
        FNEG_32        => 0x1E214000,
        FSQRT_32       => 0x1E21C000,
        FMOV_32        => 0x1E204000,
        FMOV_GP2F_32   => 0x1E270000,
        FMOV_GP2F_64   => 0x9E670000,
        FCMP_32        => 0x1E202000,
        FCMP_64        => 0x1E602000,
        FP_SZ          => 0x00400000,
        FADD           => 0x1E202800,
        FSUB           => 0x1E203800,
        FMUL           => 0x1E200800,
        FDIV           => 0x1E201800,
        FMIN           => 0x1E205800,
        FMAX           => 0x1E204800,
        SF             => 0x80000000,
        BR             => 0xD61F0000,
        ADR            => 0x10000000,
        BL             => 0x94000000,
        BLR            => 0xD63F0000,
        FCB_RESUME_OFF => 112,
        RET            => 0xD65F03C0,
    };

    method emit_function($ir_func) {
        my $lowerer = Brocken::Jenny::Lowerer::ARM64->new( platform => $platform );
        my $mf      = $lowerer->lower($ir_func);
        my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
        my $int_res = $alloc->allocate( $mf, $platform, 0 );
        $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
        my $fp_res = $alloc->allocate( $mf, $platform, 1 );
        $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
        my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );
        my %skip;
        @skip{ $platform->return_register, $platform->fp_return_register } = ( 1, 1 );
        my @gp_caller   = grep { !$skip{$_} } $platform->registers('caller')->@*;
        my @fp_caller   = grep { !$skip{$_} } $platform->fp_registers('caller')->@*;
        my $caller_base = $self->_caller_save_base( $int_res->{spill_slots}, $fp_res->{spill_slots} );
        $alloc->insert_caller_save_code( $mf, \@gp_caller, $platform->stack_reg, 0, $caller_base );
        $alloc->insert_caller_save_code( $mf, \@fp_caller, $platform->stack_reg, 1, $caller_base + scalar(@gp_caller) );
        $alloc->remove_redundant_moves( $mf, \%assignment );
        $alloc->remove_redundant_caller_restores($mf);
        $alloc->fix_entry_shuffle(
            $mf, \%assignment,
            [ $platform->abi->param_registers->@*, $platform->abi->fp_param_registers->@* ],
            $int_res->{spill_temp}
        );
        my %callee_seen;
        @callee_seen{ $int_res->{used_callee}->@* } = ();
        @callee_seen{ $fp_res->{used_callee}->@* }  = ();

        if ( $self->_has_fiber_ops_mf($mf) ) {
            $callee_seen{ $platform->fiber_reg } = 1;
        }
        my @used_callee = sort keys %callee_seen;
        my ($bytes) = $self->_encode( $mf, \%assignment, \@used_callee );
        return $bytes;
    }

    method emit_functions($ir_funcs) {
        my @mfs;
        my $has_fiber   = 0;
        my $has_isolate = 0;
        my $entry_index = -1;
        for my $i ( 0 .. $#$ir_funcs ) {
            my $func = $ir_funcs->[$i];
            $entry_index = $i if $func->name eq '_BROCKEN_ENTRY';
            next unless $func->blocks->@*;    # skip external declarations
            my $lowerer = Brocken::Jenny::Lowerer::ARM64->new( platform => $platform );
            my $mf      = $lowerer->lower($func);
            $has_fiber   ||= $self->_has_fiber_ops_mf($mf);
            $has_isolate ||= $self->_has_isolate_ops_ir($func);
            push @mfs, $mf;
        }
        my $emit_init = $has_fiber && $entry_index >= 0;
        my @result;
        for my $i ( 0 .. $#mfs ) {
            my $mf    = $mfs[$i];
            my $fname = $ir_funcs->[$i]->name;
            if ( $emit_init && $i == $entry_index ) {
                $fname = '_real_main';
            }
            my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
            my $int_res = $alloc->allocate( $mf, $platform, 0 );
            $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
            my $fp_res = $alloc->allocate( $mf, $platform, 1 );
            $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
            my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );
            my %skip;
            @skip{ $platform->return_register, $platform->fp_return_register } = ( 1, 1 );
            my @gp_caller   = grep { !$skip{$_} } $platform->registers('caller')->@*;
            my @fp_caller   = grep { !$skip{$_} } $platform->fp_registers('caller')->@*;
            my $caller_base = $self->_caller_save_base( $int_res->{spill_slots}, $fp_res->{spill_slots} );
            $alloc->insert_caller_save_code( $mf, \@gp_caller, $platform->stack_reg, 0, $caller_base );
            $alloc->insert_caller_save_code( $mf, \@fp_caller, $platform->stack_reg, 1, $caller_base + scalar(@gp_caller) );
            $alloc->remove_redundant_moves( $mf, \%assignment );
            $alloc->remove_redundant_caller_restores($mf);
            $alloc->fix_entry_shuffle(
                $mf, \%assignment,
                [ $platform->abi->param_registers->@*, $platform->abi->fp_param_registers->@* ],
                $int_res->{spill_temp}
            );
            my %callee_seen;
            @callee_seen{ $int_res->{used_callee}->@* } = ();
            @callee_seen{ $fp_res->{used_callee}->@* }  = ();

            if ( $self->_has_fiber_ops_mf($mf) ) {
                $callee_seen{ $platform->fiber_reg } = 1;
            }
            my @used_callee = sort keys %callee_seen;
            my %alloca_map;
            my %source_map;
            my ( $bytes, $func_fixups, $unwind_info ) = $self->_encode( $mf, \%assignment, \@used_callee, \%alloca_map, \%source_map );
            push @result,
                {
                name       => $fname,
                bytes      => $bytes,
                fixups     => $func_fixups,
                alloca_map => \%alloca_map,
                source_map => \%source_map,
                unwind     => $unwind_info
                };
        }
        if ($emit_init) {
            my $init_mf = $self->_build_fiber_init_mf;
            unshift @result, $self->_emit_single_mf($init_mf);
        }
        if ($has_isolate) {
            my $tramp_mf = $self->_build_isolate_trampoline_mf;
            push @result, $self->_emit_single_mf($tramp_mf);
        }
        if ( $has_isolate && $platform->is_windows ) {
            push @result, $self->_build_create_thread_fn;
        }
        return \@result;
    }

    method _emit_single_mf($mf) {
        my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
        my $int_res = $alloc->allocate( $mf, $platform, 0 );
        $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temp}, $platform->stack_reg, 0 );
        my $fp_res = $alloc->allocate( $mf, $platform, 1 );
        $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temp}, $platform->stack_reg, 1 );
        my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );
        my %skip;
        @skip{ $platform->return_register, $platform->fp_return_register } = ( 1, 1 );
        my @gp_caller   = grep { !$skip{$_} } $platform->registers('caller')->@*;
        my @fp_caller   = grep { !$skip{$_} } $platform->fp_registers('caller')->@*;
        my $caller_base = $self->_caller_save_base( $int_res->{spill_slots}, $fp_res->{spill_slots} );
        $alloc->insert_caller_save_code( $mf, \@gp_caller, $platform->stack_reg, 0, $caller_base );
        $alloc->insert_caller_save_code( $mf, \@fp_caller, $platform->stack_reg, 1, $caller_base + scalar(@gp_caller) );
        $alloc->remove_redundant_moves( $mf, \%assignment );
        $alloc->remove_redundant_caller_restores($mf);
        $alloc->fix_entry_shuffle(
            $mf, \%assignment,
            [ $platform->abi->param_registers->@*, $platform->abi->fp_param_registers->@* ],
            $int_res->{spill_temp}
        );
        my %callee_seen;
        @callee_seen{ $int_res->{used_callee}->@* } = ();
        @callee_seen{ $fp_res->{used_callee}->@* }  = ();

        if ( $self->_has_fiber_ops_mf($mf) ) {
            $callee_seen{ $platform->fiber_reg } = 1;
        }
        my @used_callee = sort keys %callee_seen;
        my ( $bytes, $func_fixups, $unwind_info ) = $self->_encode( $mf, \%assignment, \@used_callee );
        return { name => $mf->name, bytes => $bytes, fixups => $func_fixups, unwind => $unwind_info };
    }

    method _has_fiber_ops_mf($mf) {
        my $fiber_reg = $platform->fiber_reg;
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                return 1 if $inst->opcode eq 'ctx_swap';
                if ( $inst->opcode eq 'mov' || $inst->opcode eq 'mv' ) {
                    my $dst = $inst->operands->[0];
                    if ( $dst->kind eq 'phys_reg' && $dst->value eq $fiber_reg ) {
                        return 1;
                    }
                }
            }
        }
        return 0;
    }

    method _has_isolate_ops_ir($func) {
        for my $block ( $func->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                return 1
                    if $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateCreate') || $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateJoin');
            }
        }
        return 0;
    }

    method _build_create_thread_fn() {
        my $bytes = pack( 'V', stp_pre( 29, 30, 31, -32 ) );
        $bytes .= pack( 'V', add_imm( 29, 31, 0 ) );
        $bytes .= pack( 'V', str_64( 19, 31, 16 ) );         # save x19
        $bytes .= pack( 'V', mov_64( 19, 0 ) );
        $bytes .= pack( 'V', movz_64( 0, 0 ) );              # x0 = NULL
        $bytes .= pack( 'V', movz_64( 1, 0 ) );              # x1 = 0
        $bytes .= pack( 'V', movz_64( 4, 0 ) );              # x4 = 0
        $bytes .= pack( 'V', movz_64( 5, 0 ) );              # x5 = 0
        my $call_off = length($bytes);
        $bytes .= pack( 'V', bl(0) );                        # call CreateThread
        $bytes .= pack( 'V', str_64( 0, 19, 0 ) );           # *handle = rax
        $bytes .= pack( 'V', ldr_64( 19, 31, 16 ) );         # restore x19
        $bytes .= pack( 'V', ldp_post( 29, 30, 31, 32 ) );
        $bytes .= pack( 'V', ret() );
        my @fixups = ( { offset => $call_off, type => 'call_bl', target => 'CreateThread' } );
        return { name => '_create_thread', bytes => $bytes, fixups => \@fixups };
    }

    method _build_isolate_trampoline_mf() {
        my $i64     = Brocken::Lindsay::IR::Type::i64();
        my $ptr     = Brocken::Lindsay::IR::Type::ptr();
        my $mf      = Brocken::Jenny::MIR::MachineFunction->new( name => '_isolate_trampoline' );
        my $mbb     = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
        my $arg_ptr = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%arg', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'mov',
                operands => [ $arg_ptr, Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x0' ) ],
                comment  => 'arg = x0'
            )
        );
        my $fcb_ptr = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%fcb', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'load',
                operands =>
                    [ $fcb_ptr, Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%arg', disp => 0 }, type => $ptr ) ],
                comment => 'fcb = arg->fcb'
            )
        );
        my $icb_ptr = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%icb', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'load',
                operands =>
                    [ $icb_ptr, Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%arg', disp => 8 }, type => $ptr ) ],
                comment => 'icb = arg->icb'
            )
        );

        # FCB.os_thread = icb (offset 120)
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'store',
                operands =>
                    [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%fcb', disp => 120 }, type => $ptr ), $icb_ptr ],
                comment => 'FCB.os_thread = ICB'
            )
        );

        # x28 = fcb (fiber register)
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'mov',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x28' ), $fcb_ptr ],
                comment  => 'init fiber register x28'
            )
        );

        # func_addr = FCB.resume_pc (offset 112)
        my $func_addr = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%func', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'load',
                operands =>
                    [ $func_addr, Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%fcb', disp => 112 }, type => $ptr ) ],
                comment => 'func = FCB.resume_pc'
            )
        );

        # Load up to 6 args from arg struct (offsets 16-56) into calling-convention registers
        my @arg_regs = qw(x0 x1 x2 x3 x4 x5);
        for my $ai ( 0 .. $#arg_regs ) {
            my $a_val = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => "%a$ai", type => $i64 );
            $mbb->add_instruction(
                Brocken::Jenny::MIR::MachineInstruction->new(
                    opcode   => 'load',
                    operands => [
                        $a_val,
                        Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%arg', disp => 16 + 8 * $ai }, type => $i64 )
                    ],
                    comment => "load arg$ai"
                )
            );
            $mbb->add_instruction(
                Brocken::Jenny::MIR::MachineInstruction->new(
                    opcode   => 'mov',
                    operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $arg_regs[$ai] ), $a_val ],
                    comment  => "arg$ai -> $arg_regs[$ai]"
                )
            );
        }

        # result = call_indirect func_addr
        my $result = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%ret', type => $i64 );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'call_indirect',
                operands => [ $result, $func_addr ],
                comment  => 'call user function'
            )
        );

        # return result
        $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => 'return' ) );
        $mf->add_block($mbb);
        return $mf;
    }

    method _build_fiber_init_mf() {
        my $i64 = Brocken::Lindsay::IR::Type::i64();
        my $ptr = Brocken::Lindsay::IR::Type::ptr();
        my $mf  = Brocken::Jenny::MIR::MachineFunction->new( name => 'main' );
        my $mbb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
        my $fcb = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%init.fcb', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'alloca',
                operands => [ $fcb, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 128, type => $i64 ) ],
                comment  => 'main fiber FCB'
            )
        );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'store',
                operands =>
                    [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%init.fcb', disp => 72 }, type => $i64 ), $fcb ],
                comment => 'FCB.self = FCB addr'
            )
        );

        # Allocate main Isolate Control Block (ICB) - thread-local state holder
        my $icb = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%init.icb', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'alloca',
                operands => [ $icb, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 64, type => $i64 ) ],
                comment  => 'main thread ICB'
            )
        );

        # Zero ICB.heap_cursor (offset 0) - marks "not yet initialized"
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'store_imm',
                operands => [
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%init.icb', disp => 0 }, type => $i64 ),
                    Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 0,                                  type => $i64 )
                ],
                comment => 'ICB.heap_cursor = NULL'
            )
        );

        # Store ICB pointer in FCB.os_thread slot (offset 120)
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'store',
                operands =>
                    [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%init.fcb', disp => 120 }, type => $i64 ), $icb ],
                comment => 'FCB.os_thread = &ICB'
            )
        );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'mov',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'x28' ), $fcb ],
                comment  => 'init fiber register x28'
            )
        );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'call_func',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => '_real_main' ) ],
                comment  => 'call original main'
            )
        );
        $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => 'return to _start' ) );
        $mf->add_block($mbb);
        $mf->compute_cfg;
        return $mf;
    }

    method _encode( $mf, $assignment, $used_callee, $alloca_map = undef, $source_map = undef ) {
        my $bytes        = '';
        my $alloca_frame = 0;
        my $total_alloca = 0;
        my $is_leaf      = 1;
        my $spill_frame  = $self->_compute_spill_frame( $mf, $platform->stack_reg );
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                $is_leaf = 0 if $inst->opcode eq 'call_func' || $inst->opcode eq 'call_indirect';
                if ( $inst->opcode eq 'alloca' ) {
                    my ( undef, $src ) = $inst->operands->@*;
                    $total_alloca += $src->value;
                    $total_alloca = ( $total_alloca + 15 ) & ~15;
                }
            }
        }
        my @to_save = $used_callee->@*;
        push @to_save, 'x29';    # Always save frame pointer for backtrace support
        if ( !$is_leaf ) {
            push @to_save, 'x30';
        }
        my $callee_size    = scalar(@to_save) * 8;
        my $unified_frame  = ( $callee_size + $spill_frame + 15 ) & ~15;
        my $extra_frame    = $unified_frame - $callee_size;
        my $aligned_alloca = ( $total_alloca + 15 ) & ~15;
        if ( $aligned_alloca > 0 && $extra_frame < 8 ) {
            $unified_frame += 16;
            $extra_frame = $unified_frame - $callee_size;
        }
        my $total_frame = $unified_frame + $aligned_alloca;
        $alloca_frame = $unified_frame;
        my $reg_id = sub ($r) {
            return 31 if $r eq 'sp';
            return $1 if $r =~ /^[xw](\d+)$/;
            return $1 if $r =~ /^v(\d+)$/;
            return 0;
        };
        state $phys_re = do {
            my @regs = $platform->registers('available')->@*;
            my $pat  = join '|', map quotemeta, @regs;
            qr/^($pat)$/;
        };
        my $resolve = sub ($op) {
            return $assignment->{ $op->value } // $op->value if $op->kind eq 'virt_reg';
            return $op->value                                if $op->kind eq 'phys_reg';
            die "Unexpected operand kind: ${$op->kind}";
        };
        if ( $total_frame > 0 ) {

            # Windows ARM64 requires stack probing for frames > 4KB to
            # ensure the guard page is expanded one page at a time.
            if ( $platform->is_windows && $total_frame > 4096 ) {
                my $pages     = int( $total_frame / 4096 );
                my $remainder = $total_frame % 4096;
                if ( $pages > 0 ) {
                    my $emitted = 0;
                    for my $hw ( 0 .. 3 ) {
                        my $chunk = ( $pages >> ( $hw * 16 ) ) & 0xFFFF;
                        if ( $chunk || !$emitted ) {
                            my $base = $emitted ? MOVK_64 : MOVZ_64;
                            $bytes .= pack( 'V', SF | $base | ( $chunk << 5 ) | ( $hw << 21 ) | 16 );
                            $emitted = 1;
                        }
                    }
                    my $loop_start = length $bytes;
                    $bytes .= pack( 'V', SUB_SP | ( 1 << 10 ) | ( 1 << 22 ) );
                    $bytes .= pack( 'V', LDR_64 | ( 31 << 5 ) | 31 );
                    $bytes .= pack( 'V', ( SUB_IMM | SF ) | ( 1 << 10 ) | ( 16 << 5 ) | 16 );
                    my $imm19 = ( ( $loop_start - length($bytes) ) >> 2 ) & 0x7FFFF;
                    $bytes .= pack( 'V', CBNZ | ( $imm19 << 5 ) | 16 );
                }
                if ( $remainder > 0 ) {
                    $bytes .= pack( 'V', SUB_SP | ( $remainder << 10 ) );
                }
            }
            else {
                my $frame = $total_frame;
                if ( $frame <= 0xFFF ) {
                    $bytes .= pack( 'V', SUB_SP | ( $frame << 10 ) );
                }
                else {
                    my $hi = $frame >> 12;
                    my $lo = $frame & 0xFFF;
                    $bytes .= pack( 'V', SUB_SP | ( $hi << 10 ) | ( 1 << 22 ) );
                    $bytes .= pack( 'V', SUB_SP | ( $lo << 10 ) ) if $lo;
                }
            }
            for my $i ( 0 .. $#to_save ) {
                my $reg   = $to_save[$i];
                my $rid   = $reg_id->($reg);
                my $base  = $reg =~ /^v/ ? FSTR_64 : STR_64;
                my $imm12 = ( $extra_frame + $i * 8 ) >> 3;
                $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( 31 << 5 ) | $rid );
            }

            # Set x29 to point to saved x29 (frame pointer for backtrace)
            my $fp_idx = 0;
            for my $i ( 0 .. $#to_save ) {
                $fp_idx = $i if $to_save[$i] eq 'x29';
            }
            my $fp_off = $extra_frame + $fp_idx * 8;
            if ( $fp_off <= 0xFFF ) {
                $bytes .= pack( 'V', ADD_IMM_64 | ( 31 << 5 ) | 29 | ( $fp_off << 10 ) );
            }
            else {
                my $hi = $fp_off >> 12;
                my $lo = $fp_off & 0xFFF;
                $bytes .= pack( 'V', ADD_IMM_64 | ( 31 << 5 ) | 29 | ( $hi << 10 ) | ( 1 << 22 ) );
                $bytes .= pack( 'V', ADD_IMM_64 | ( 29 << 5 ) | 29 | ( $lo << 10 ) ) if $lo;
            }
        }
        my %labels;
        my @fixups;
        my @func_fixups;
        my $current_offset = sub { return length $bytes };
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                if ( $source_map && $inst->ir_inst_idx >= 0 && !exists $source_map->{ $inst->ir_inst_idx } ) {
                    $source_map->{ $inst->ir_inst_idx } = length($bytes);
                }
                my $opcode = $inst->opcode;
                my ( $dst, $src ) = $inst->operands->@*;
                if ( $opcode eq 'label' ) {
                    $labels{ $dst->value } = $current_offset->();
                }
                elsif ( $opcode eq 'jmp' ) {
                    push @fixups, { offset => $current_offset->(), type => 'b', target => $dst->value };
                    $bytes .= pack( 'V', B );
                }
                elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                    my $cond_r = $resolve->($dst);
                    my $cid    = $reg_id->($cond_r);
                    my $base   = ( $opcode eq 'bne' ? CBNZ : CBZ );
                    push @fixups, { offset => $current_offset->(), type => 'cbz', target => $src->value, rid => $cid, base => $base };
                    $bytes .= pack( 'V', $base | $cid );
                }
                elsif ( $opcode eq 'mov' || $opcode eq 'mv' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    if ( $src->kind eq 'imm' ) {
                        my $bits    = $dst->type      ? $dst->type->bits : 64;
                        my $sf      = ( $bits >= 64 ) ? SF               : 0x00000000;
                        my $value   = $src->value;
                        my $max_hw  = int( ( $bits + 15 ) / 16 ) - 1;
                        my $emitted = 0;
                        for my $hw ( 0 .. $max_hw ) {
                            my $chunk = ( $value >> ( $hw * 16 ) ) & 0xFFFF;
                            if ( $chunk || !$emitted ) {
                                my $base = $emitted ? MOVK_32 : MOVZ_32;
                                $bytes .= pack( 'V', $sf | $base | ( $chunk << 5 ) | ( $hw << 21 ) | $did );
                                $emitted = 1;
                            }
                        }
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        $bytes .= pack( 'V', MOV_X | ( $sid << 16 ) | $did );
                    }
                }
                elsif ( $opcode eq 'movzx' ) {
                    my $src_bits = $src->type ? $src->type->bits : 64;
                    my $dst_r    = $resolve->($dst);
                    my $did      = $reg_id->($dst_r);
                    my $src_r    = $resolve->($src);
                    my $sid      = $reg_id->($src_r);
                    if ( $src_bits >= 32 ) {

                        # 32-bit zext: MOV Wd, Wn (zeros upper 32)
                        $bytes .= pack( 'V', 0x2A0003E0 | ( $sid << 16 ) | $did );
                    }
                    elsif ( $src_bits >= 16 ) {

                        # UXTH Wd, Wn
                        $bytes .= pack( 'V', 0x53003C00 | ( $sid << 16 ) | $did );
                    }
                    else {
                        # UXTB Wd, Wn
                        $bytes .= pack( 'V', 0x53001C00 | ( $sid << 16 ) | $did );
                    }
                }
                elsif ( $opcode eq 'movsx' ) {
                    my $src_bits = $src->type ? $src->type->bits : 64;
                    my $dst_r    = $resolve->($dst);
                    my $did      = $reg_id->($dst_r);
                    my $src_r    = $resolve->($src);
                    my $sid      = $reg_id->($src_r);
                    if ( $src_bits >= 32 ) {

                        # SXTW Xd, Wn
                        $bytes .= pack( 'V', 0x93407C00 | ( $sid << 16 ) | $did );
                    }
                    elsif ( $src_bits >= 16 ) {

                        # SXTH Wd, Wn
                        $bytes .= pack( 'V', 0x13003C00 | ( $sid << 16 ) | $did );
                    }
                    else {
                        # SXTB Wd, Wn
                        $bytes .= pack( 'V', 0x13001C00 | ( $sid << 16 ) | $did );
                    }
                }
                elsif ( $opcode eq 'add' ||
                    $opcode eq 'sub'   ||
                    $opcode eq 'and'   ||
                    $opcode eq 'or'    ||
                    $opcode eq 'xor'   ||
                    $opcode eq 'mul'   ||
                    $opcode eq 'umulh' ||
                    $opcode eq 'udiv'  ||
                    $opcode eq 'adc'   ||
                    $opcode eq 'sbb' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $bits   = $dst->type ? $dst->type->bits : 64;    # width-aware
                    my %reg_op = (
                        add   => ( $bits >= 64 ? ADD_X : ADD_W ),
                        sub   => ( $bits >= 64 ? SUB_X : SUB_W ),
                        and   => ( $bits >= 64 ? AND_X : AND_W ),
                        or    => ( $bits >= 64 ? ORR_X : ORR_W ),
                        xor   => ( $bits >= 64 ? EOR_X : EOR_W ),
                        mul   => ( $bits >= 64 ? MUL_X : MUL_W ),
                        umulh => UMULH_X,
                        udiv  => UDIV_X,
                        adc   => ADCS_X,
                        sbb   => SBCS_X,
                    );
                    if ( $src->kind eq 'imm' && ( $opcode eq 'add' || $opcode eq 'sub' ) ) {
                        my $sf    = ( $bits >= 64 ) ? SF : 0x00000000;
                        my $op    = $sf | ( $opcode eq 'add' ? ADD_IMM : SUB_IMM );
                        my $imm12 = $src->value & 0xFFF;
                        $bytes .= pack( 'V', $op | ( $imm12 << 10 ) | ( $did << 5 ) | $did );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $op    = $reg_op{$opcode};
                        $bytes .= pack( 'V', $op | ( $sid << 16 ) | ( $did << 5 ) | $did );
                    }
                }
                elsif ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    if ( $src->kind eq 'imm' ) {
                        my $imm = $src->value;
                        if ( $opcode eq 'shl' ) {
                            my $immr = ( 64 - $imm ) & 0x3F;
                            my $imms = ( 63 - $imm ) & 0x3F;
                            $bytes .= pack( 'V', UBFM | ( $immr << 16 ) | ( $imms << 10 ) | ( $did << 5 ) | $did );
                        }
                        elsif ( $opcode eq 'lshr' ) {
                            $bytes .= pack( 'V', UBFM | ( $imm << 16 ) | ( 63 << 10 ) | ( $did << 5 ) | $did );
                        }
                        else {
                            $bytes .= pack( 'V', SBFM | ( $imm << 16 ) | ( 63 << 10 ) | ( $did << 5 ) | $did );
                        }
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my %base  = ( shl => 0x9AC02000, lshr => 0x9AC02400, ashr => 0x9AC02C00 );
                        $bytes .= pack( 'V', $base{$opcode} | ( $sid << 16 ) | ( $did << 5 ) | $did );
                    }
                }
                elsif ( $opcode eq 'alloca' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $size  = $src->value;
                    my $off   = $alloca_frame;
                    $alloca_map->{ $dst->value } = $off if $alloca_map;
                    if ( $off <= 0xFFF ) {
                        $bytes .= pack( 'V', MOV_SP | ( $off << 10 ) | $did );
                    }
                    else {
                        my $value   = $off;
                        my $emitted = 0;
                        for my $hw ( 0 .. 3 ) {
                            my $chunk = ( $value >> ( $hw * 16 ) ) & 0xFFFF;
                            if ( $chunk || !$emitted ) {
                                my $base = $emitted ? MOVK_64 : MOVZ_64;
                                $bytes .= pack( 'V', SF | $base | ( $chunk << 5 ) | ( $hw << 21 ) | $did );
                                $emitted = 1;
                            }
                        }
                        $bytes .= pack( 'V', ADD_X_EXT | ( $did << 16 ) | ( UXTX_OPT << 13 ) | ( 31 << 5 ) | $did );
                    }
                    $alloca_frame += $size;
                    $alloca_frame = ( $alloca_frame + 15 ) & ~15;
                }
                elsif ( $opcode eq 'load' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $addr   = $src->value;
                    my $base_r = $resolve->(
                        Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => ( $addr->{base} =~ $phys_re ? 'phys_reg' : 'virt_reg' ),
                            value => $addr->{base}
                        )
                    );
                    my $bid  = $reg_id->($base_r);
                    my $bits = ( $dst->type && $dst->type->kind eq 'int' ) ? $dst->type->bits : 64;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $reg_op  = $bits == 32 ? LDR_32_REG : LDR_64_REG;
                        $bytes .= pack( 'V', $reg_op | ( $iid << 16 ) | ( $bid << 5 ) | $did );
                    }
                    else {
                        my $disp  = $addr->{disp} // 0;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? LDR_32 : LDR_64;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $did );
                    }
                }
                elsif ( $opcode eq 'store' ) {
                    my $src_r  = $resolve->($src);
                    my $sid    = $reg_id->($src_r);
                    my $addr   = $dst->value;
                    my $base_r = $resolve->(
                        Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => ( $addr->{base} =~ $phys_re ? 'phys_reg' : 'virt_reg' ),
                            value => $addr->{base}
                        )
                    );
                    my $bid  = $reg_id->($base_r);
                    my $bits = ( $src->type && $src->type->kind eq 'int' ) ? $src->type->bits : 64;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $reg_op  = $bits == 32 ? STR_32_REG : STR_64_REG;
                        $bytes .= pack( 'V', $reg_op | ( $iid << 16 ) | ( $bid << 5 ) | $sid );
                    }
                    else {
                        my $disp  = $addr->{disp} // 0;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? STR_32 : STR_64;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $sid );
                    }
                }
                elsif ( $opcode eq 'store_imm' ) {
                    my ( $mem, $imm ) = $inst->operands->@*;
                    my $addr   = $mem->value;
                    my $base_r = $resolve->(
                        Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => ( $addr->{base} =~ $phys_re ? 'phys_reg' : 'virt_reg' ),
                            value => $addr->{base}
                        )
                    );
                    my $bid  = $reg_id->($base_r);
                    my $bits = ( $imm->type && $imm->type->kind eq 'int' ) ? $imm->type->bits : 64;

                    # find a temporary register not in use
                    my %used;
                    @used{ values %$assignment } = ();
                    my $tmp_r;
                    for my $r ( $platform->registers('caller')->@* ) { $tmp_r = $r, last unless exists $used{$r} }
                    die 'no temp register for store_imm' unless $tmp_r;
                    my $tid     = $reg_id->($tmp_r);
                    my $imm_val = $imm->value;
                    my $max_hw  = int( ( $bits + 15 ) / 16 ) - 1;

                    for my $hw ( 0 .. $max_hw ) {
                        my $chunk = ( $imm_val >> ( $hw * 16 ) ) & 0xFFFF;
                        if ( $chunk || $hw == 0 ) {
                            my $base = $hw == 0 ? ( $bits >= 64 ? MOVZ_64 : MOVZ_32 ) : ( $bits >= 64 ? MOVK_64 : MOVK_32 );
                            $bytes .= pack( 'V', $base | ( $chunk << 5 ) | ( $hw << 21 ) | $tid );
                        }
                    }
                    if ( defined $addr->{index} ) {
                        my $index_r  = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid      = $reg_id->($index_r);
                        my $str_base = $bits >= 64 ? STR_64_REG : STR_32_REG;
                        $bytes .= pack( 'V', $str_base | ( $iid << 16 ) | ( $bid << 5 ) | $tid );
                    }
                    else {
                        my $disp     = $addr->{disp} // 0;
                        my $imm12    = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $str_base = $bits >= 64 ? STR_64 : STR_32;
                        $bytes .= pack( 'V', $str_base | ( $imm12 << 10 ) | ( $bid << 5 ) | $tid );
                    }
                }
                elsif ( $opcode eq 'cmp' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $dst->type      ? $dst->type->bits : 64;
                    my $sf    = ( $bits >= 64 ) ? SF               : 0x00000000;
                    if ( $src->kind eq 'imm' ) {
                        my $imm12 = $src->value & 0xFFF;
                        $bytes .= pack( 'V', $sf | CMP_IMM | ( $imm12 << 10 ) | ( $did << 5 ) );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        $bytes .= pack( 'V', $sf | CMP_REG | ( $sid << 16 ) | ( $did << 5 ) );
                    }
                }
                elsif ( $opcode eq 'cset_eq' ||
                    $opcode eq 'cset_ne' ||
                    $opcode eq 'cset_lt' ||
                    $opcode eq 'cset_gt' ||
                    $opcode eq 'cset_le' ||
                    $opcode eq 'cset_ge' ||
                    $opcode eq 'cset_cc' ||
                    $opcode eq 'cset_cs' ||
                    $opcode eq 'cset_hi' ||
                    $opcode eq 'cset_ls' ||
                    $opcode eq 'cset_vc' ||
                    $opcode eq 'cset_vs' ) {
                    my %arm_cond = (
                        cset_eq => 1,
                        cset_ne => 0,
                        cset_lt => 0xA,
                        cset_gt => 0xD,
                        cset_le => 0xC,
                        cset_ge => 0xB,
                        cset_cc => 2,
                        cset_cs => 3,
                        cset_hi => 9,
                        cset_ls => 8,
                        cset_vc => 6,
                        cset_vs => 7
                    );
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $cond  = $arm_cond{$opcode};
                    $bytes .= pack( 'V', CSINC | ( 31 << 16 ) | ( $cond << 12 ) | ( 31 << 5 ) | $did );
                }
                elsif ( $opcode eq 'sltu' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    $bytes .= pack( 'V', SF | CMP_REG | ( $sid << 16 ) | ( $did << 5 ) );
                    $bytes .= pack( 'V', CSINC | ( 31 << 16 ) | ( 2 << 12 ) | ( 31 << 5 ) | $did );
                }
                elsif ( $opcode eq 'fload' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $addr   = $src->value;
                    my $base_r = $resolve->(
                        Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => ( $addr->{base} =~ $phys_re ? 'phys_reg' : 'virt_reg' ),
                            value => $addr->{base}
                        )
                    );
                    my $bid  = $reg_id->($base_r);
                    my $bits = $dst->type ? $dst->type->bits : 64;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $reg_op  = $bits == 32 ? FLDR_32_REG : FLDR_64_REG;
                        $bytes .= pack( 'V', $reg_op | ( $iid << 16 ) | ( $bid << 5 ) | $did );
                    }
                    else {
                        my $disp  = $addr->{disp} // 0;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? FLDR_32 : FLDR_64;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $did );
                    }
                }
                elsif ( $opcode eq 'fstore' ) {
                    my $mem    = $dst;
                    my $src_r  = $resolve->($src);
                    my $sid    = $reg_id->($src_r);
                    my $addr   = $mem->value;
                    my $base_r = $resolve->(
                        Brocken::Jenny::MIR::MachineOperand->new(
                            kind  => ( $addr->{base} =~ $phys_re ? 'phys_reg' : 'virt_reg' ),
                            value => $addr->{base}
                        )
                    );
                    my $bid  = $reg_id->($base_r);
                    my $bits = $src->type ? $src->type->bits : 64;
                    if ( defined $addr->{index} ) {
                        my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                        my $iid     = $reg_id->($index_r);
                        my $reg_op  = $bits == 32 ? FSTR_32_REG : FSTR_64_REG;
                        $bytes .= pack( 'V', $reg_op | ( $iid << 16 ) | ( $bid << 5 ) | $sid );
                    }
                    else {
                        my $disp  = $addr->{disp} // 0;
                        my $imm12 = $disp >> ( $bits == 32 ? 2 : 3 );
                        my $base  = $bits == 32 ? FSTR_32 : FSTR_64;
                        $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( $bid << 5 ) | $sid );
                    }
                }
                elsif ( $opcode eq 'fmov' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits : 64;
                    my $base  = $bits == 32 ? FMOV_32          : ( FMOV_32 | FP_SZ );
                    $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                }
                elsif ( $opcode eq 'fmov_gp2f' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits : 64;
                    my $base  = $bits == 32 ? FMOV_GP2F_32     : FMOV_GP2F_64;
                    $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                }
                elsif ( $opcode eq 'fadd' || $opcode eq 'fsub' || $opcode eq 'fmul' || $opcode eq 'fdiv' || $opcode eq 'fmin' || $opcode eq 'fmax' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    my %fop   = ( fadd => FADD, fsub => FSUB, fmul => FMUL, fdiv => FDIV, fmin => FMIN, fmax => FMAX );
                    my $base  = $fop{$opcode};
                    $base = $bits == 32 ? $base : ( $base | FP_SZ );
                    $bytes .= pack( 'V', $base | ( $sid << 16 ) | ( $did << 5 ) | $did );
                }
                elsif ( $opcode eq 'fsqrt' || $opcode eq 'fabs' || $opcode eq 'fneg' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    my %fop   = ( fsqrt => FSQRT_32, fabs => FABS_32, fneg => FNEG_32 );
                    my $base  = $fop{$opcode};
                    $base = $bits == 32 ? $base : ( $base | FP_SZ );
                    $bytes .= pack( 'V', $base | ( $sid << 5 ) | $did );
                }
                elsif ( $opcode eq 'fcmp' ) {
                    my $lhs_r = $resolve->($dst);
                    my $lid   = $reg_id->($lhs_r);
                    my $rhs_r = $resolve->($src);
                    my $rid   = $reg_id->($rhs_r);
                    my $bits  = $dst->type  ? $dst->type->bits : 64;
                    my $base  = $bits == 32 ? FCMP_32          : FCMP_64;
                    $bytes .= pack( 'V', $base | ( $rid << 16 ) | ( $lid << 5 ) );
                }
                elsif ( $opcode eq 'ctx_swap' ) {
                    my $ctx_r    = $resolve->($dst);           # fiber register (x28)
                    my $cid      = $reg_id->($ctx_r);
                    my $target_r = $resolve->($src);           # target FCB pointer
                    my $tid      = $reg_id->($target_r);
                    my @callee   = map {"x$_"} ( 19 .. 28 );
                    push @callee, 'x29', 'x30', 'sp';

                    # 1. MOV X17, SP -- save current SP
                    $bytes .= pack( 'V', MOV_SP | 17 );

                    # 2. Save callee regs to current FCB
                    for my $off_idx ( 0 .. $#callee ) {
                        my $reg = $callee[$off_idx];
                        my $rid = $reg_id->($reg);
                        $rid = 17 if $reg eq 'sp';    # use x17 (SP value) not XZR
                        my $imm12 = ( $off_idx * 8 ) >> 3;
                        $bytes .= pack( 'V', STR_64 | ( $imm12 << 10 ) | ( $cid << 5 ) | $rid );
                    }

                    # 3. ADR x16, #0 placeholder, patched after BR x16 (step 10)
                    my $adr_off = $current_offset->();
                    $bytes .= pack( 'V', ADR | 16 );

                    # 4. Store resume_pc at FCB[FCB_RESUME_OFF]
                    my $res_imm12 = FCB_RESUME_OFF >> 3;
                    $bytes .= pack( 'V', STR_64 | ( $res_imm12 << 10 ) | ( $cid << 5 ) | 16 );

                    # 5. Switch fiber register to target FCB
                    $bytes .= pack( 'V', ADD_IMM_64 | ( $tid << 5 ) | 28 );

                    # 6. Load target resume_pc from target FCB[FCB_RESUME_OFF] (using X28 as base)
                    $bytes .= pack( 'V', LDR_64 | ( $res_imm12 << 10 ) | ( 28 << 5 ) | 16 );

                    # 7. Restore callee regs from target FCB (using X28 as base)
                    #    Skip x28 (idx 9) - will restore separately at the end since
                    #    loading it would clobber the base pointer
                    for my $off_idx ( 0 .. $#callee ) {
                        next if $callee[$off_idx] eq 'x28';
                        my $reg = $callee[$off_idx];
                        my $rid = $reg_id->($reg);
                        $rid = 17 if $reg eq 'sp';    # load into x17, not XZR
                        my $imm12 = ( $off_idx * 8 ) >> 3;
                        $bytes .= pack( 'V', LDR_64 | ( $imm12 << 10 ) | ( 28 << 5 ) | $rid );
                    }

                    # 7b. Restore x28 last (offset 72 = idx 9 * 8) - clobbers base, safe now
                    $bytes .= pack( 'V', LDR_64 | ( ( 9 * 8 >> 3 ) << 10 ) | ( 28 << 5 ) | 28 );

                    # 8. MOV SP, X17 -- restore SP from target
                    $bytes .= pack( 'V', ADD_IMM_64 | ( 17 << 5 ) | 31 );

                    # 9. BR x16 -- jump to target resume_pc
                    $bytes .= pack( 'V', BR | ( 16 << 5 ) );

                    # 10. Patch ADR to point after BR x16
                    my $after   = $current_offset->();
                    my $rel     = $after - $adr_off;
                    my $adr_enc = ADR | 16 | ( ( ( $rel >> 2 ) & 0x7FFFF ) << 5 ) | ( ( $rel & 3 ) << 29 );
                    substr $bytes, $adr_off, 4, pack( 'V', $adr_enc );
                }
                elsif ( $opcode eq 'syscall' ) {

                    # svc #0
                    $bytes .= pack( 'V', 0xD4000001 );
                }
                elsif ( $opcode eq 'lea_func' ) {
                    my $dst_r     = $resolve->($dst);
                    my $did       = $reg_id->($dst_r);
                    my $func_name = $src->value;
                    push @func_fixups, { offset => $current_offset->(), type => 'adr', target => $func_name, rd => $did };
                    $bytes .= pack( 'V', ADR | $did );
                }
                elsif ( $opcode eq 'lea_rodata' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $label = $src->value;
                    push @func_fixups, { offset => $current_offset->(), type => 'lea_rodata_adr', target => $label, rd => $did };
                    $bytes .= pack( 'V', ADR | $did );
                }
                elsif ( $opcode eq 'call_func' ) {
                    my $func_name = $dst->value;
                    my $num_extra = scalar( $inst->operands->@* ) - 1;
                    if ( $num_extra >= 2 && $platform->is_macos ) {
                        my $num_named   = $inst->operands->[1]->value;
                        my $num_unnamed = $inst->operands->[2]->value;
                        my $raw_size    = $num_unnamed * 8;
                        my $save_size   = ( $raw_size + 15 ) & ~15;
                        $bytes .= pack( 'V', SUB_SP | ( $save_size << 10 ) );
                        for my $j ( 0 .. $num_unnamed - 1 ) {
                            my $reg_num = $num_named + $j;
                            $bytes .= pack( 'V', STR_64 | ( $j << 10 ) | ( 31 << 5 ) | $reg_num );
                        }
                        push @func_fixups, { offset => $current_offset->(), type => 'call_bl', target => $func_name };
                        $bytes .= pack( 'V', BL );
                        $bytes .= pack( 'V', ADD_SP | ( $save_size << 10 ) );
                    }
                    else {
                        $bytes .= pack( 'V', SUB_SP | ( 64 << 10 ) );
                        push @func_fixups, { offset => $current_offset->(), type => 'call_bl', target => $func_name };
                        $bytes .= pack( 'V', BL );
                        $bytes .= pack( 'V', ADD_SP | ( 64 << 10 ) );
                    }
                }
                elsif ( $opcode eq 'call_indirect' ) {
                    $bytes .= pack( 'V', SUB_SP | ( 64 << 10 ) );
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    $bytes .= pack( 'V', BLR | ( $sid << 5 ) );
                    $bytes .= pack( 'V', ADD_SP | ( 64 << 10 ) );
                }
                elsif ( $opcode eq 'ret' ) {
                    if ( $callee_size > 0 ) {
                        for my $i ( reverse 0 .. $#to_save ) {
                            my $reg   = $to_save[$i];
                            my $rid   = $reg_id->($reg);
                            my $base  = $reg =~ /^v/ ? FLDR_64 : LDR_64;
                            my $imm12 = ( $extra_frame + $i * 8 ) >> 3;
                            $bytes .= pack( 'V', $base | ( $imm12 << 10 ) | ( 31 << 5 ) | $rid );
                        }
                    }
                    if ( $total_frame > 0 ) {
                        my $frame = $total_frame;
                        if ( $frame <= 0xFFF ) {
                            $bytes .= pack( 'V', ADD_SP | ( $frame << 10 ) );
                        }
                        else {
                            my $lo = $frame & 0xFFF;
                            my $hi = $frame >> 12;
                            $bytes .= pack( 'V', ADD_SP | ( $lo << 10 ) ) if $lo;
                            $bytes .= pack( 'V', ADD_SP | ( $hi << 10 ) | ( 1 << 22 ) );
                        }
                    }
                    $bytes .= pack( 'V', RET );
                }
            }
        }
        for my $fixup (@fixups) {
            my $target_pos = $labels{ $fixup->{target} };
            die "undefined label: $fixup->{target}" unless defined $target_pos;
            my $rel = $target_pos - $fixup->{offset};
            if ( $fixup->{type} eq 'b' ) {
                substr $bytes, $fixup->{offset}, 4, pack( 'V', B | ( ( $rel / 4 ) & 0x3FFFFFF ) );
            }
            elsif ( $fixup->{type} eq 'cbz' ) {
                my $inst = unpack( 'V', substr $bytes, $fixup->{offset}, 4 );
                $inst = ( $inst & 0xFF00001F ) | ( ( ( $rel / 4 ) & 0x7FFFF ) << 5 );
                substr $bytes, $fixup->{offset}, 4, pack( 'V', $inst );
            }
        }
        my %unwind_info = ( frame_size => $total_frame, num_saved_int => scalar( grep { !/^x(29|30)$/ } @to_save ), saves_lr => !$is_leaf, );
        return ( $bytes, \@func_fixups, \%unwind_info );
    }

    method _compute_spill_frame( $mf, $stack_reg ) {
        my $max_disp = 0;
        my $found    = 0;
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                for my $op ( $inst->operands->@* ) {
                    next unless $op->kind eq 'mem';
                    my $addr = $op->value;
                    next unless defined $addr->{base} && !ref $addr->{base} && $addr->{base} eq $stack_reg;
                    $max_disp = List::Util::max( $max_disp, $addr->{disp} // 0 );
                    $found    = 1;
                }
            }
        }
        return $found ? ( ( $max_disp + 8 + 15 ) & ~15 ) : 0;
    }

    method _caller_save_base( $gp_spill, $fp_spill ) {
        my $max_off = 0;
        for my $off ( values $gp_spill->%* ) { $max_off = $off if $off > $max_off; }
        for my $off ( values $fp_spill->%* ) { $max_off = $off if $off > $max_off; }
        return $max_off ? int( $max_off / 8 ) + 1 : 0;
    }

    method build_debug_data( $ir_funcs, $func_blobs, $source_file = 'source.brocken', $text_base = 0, $class_info = {}, $debug_level = 0 ) {
        require Brocken::Jenny::Linker::DWARF;
        my @func_ranges;
        my @source_locs;
        my $text_offset = 0;
        for my $i ( 0 .. $#$ir_funcs ) {
            my $ir_fn      = $ir_funcs->[$i];
            my $blob       = $func_blobs->[$i];
            my $fname      = $blob->{name};
            my $fstart     = $text_offset;
            my $fend       = $text_offset + length( $blob->{bytes} );
            my $alloca_map = $blob->{alloca_map} // {};
            my @params;
            for my $p ( $ir_fn->params->@* ) {
                next if $p->name && $p->name eq '%__heap_base';
                my $vreg = '%' . $p->name . '.addr';
                my $slot = $alloca_map->{$vreg};
                push @params,
                    { name => ( $p->name =~ s/^%//r ), type => 'Int', slot => defined $slot ? $slot : 0, line => 0, col => 0, artificial => 0, };
            }
            my @locals;
            for my $block ( $ir_fn->blocks->@* ) {
                for my $inst ( $block->instructions->@* ) {
                    next unless $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca') && $inst->debug_name;
                    my $slot = $alloca_map->{ $inst->name };
                    push @locals,
                        {
                        name       => $inst->debug_name,
                        type       => $inst->debug_type_name // 'Int',
                        slot       => defined $slot ? $slot : 0,
                        line       => $inst->line // 0,
                        col        => $inst->col  // 0,
                        artificial => 0,
                        };
                }
            }
            my $func_source_file = $fname =~ /^Brocken::Runtime::/ ? '<runtime>' : $source_file;
            push @func_ranges,
                { name => $fname, start => $fstart, end => $fend, params => \@params, locals => \@locals, source_file => $func_source_file };
            my $source_map = $blob->{source_map} // {};
            my $inst_idx   = 0;
            for my $block ( $ir_fn->blocks->@* ) {
                for my $inst ( $block->instructions->@* ) {
                    if ( $inst->line ) {
                        my $offset = defined( $source_map->{$inst_idx} ) ? $fstart + $source_map->{$inst_idx} : $fstart;
                        push @source_locs, { offset => $offset, line => $inst->line, col => $inst->col, file => $func_source_file };
                    }
                    $inst_idx++;
                }
            }
            $text_offset = $fend;
        }
        my %seen;
        my @uniq_files = grep { !$seen{$_}++ } map { $_->{source_file} // $source_file } @func_ranges;
        my $dwarf      = Brocken::Jenny::Linker::DWARF->new(
            source_locs  => \@source_locs,
            text_base    => $text_base,
            source_file  => $source_file,
            source_files => \@uniq_files,
            func_ranges  => \@func_ranges,
            class_info   => $class_info,
            arch         => 'arm64',
            platform     => $platform,
            debug        => $debug_level,
        );
        return $dwarf->build_all;
    }
}

=encoding utf-8

=head1 NAME

Brocken::Jenny::Codegen::ARM64 - ARM64 (AArch64) Machine Code Generator

=head1 DESCRIPTION

Generates ARM64 machine code from MIR. Implements full instruction encoding for the AAPCS64 calling convention.

=head2 Supported Instructions

=over 4

=item B<Data movement>: mov (reg/imm), movk, adrp (for LEA), ldr, str, ldrsw, ldrb, strb, ldp, stp

=item B<Arithmetic>: add, sub, adds, subs, and, orr, eor, mul, neg, sxtw

=item B<Comparison>: cmp, cset (for setcc), sltu (for unsigned setcc)

=item B<Shift>: lsl, lsr, asr

=item B<Floating point>: fmov (gp2f and f2gp), fadd, fsub, fmul, fdiv, fcmp, fcsel, fabs, fneg, fmin, fmax, fsqrt, fcvt (single/double), scvtf (int->float)

=item B<Control flow>: b (unconditional/cond), cbz, cbnz, bl (call), ret

=item B<Stack>: alloca (pre-scanned, prologue-only SUB), stp/ldp for callee save/restore

=back

=head2 Frame Layout

    SP -> [spill/caller-save slots] [callee saves] [alloca area] <- FP (x29)

The alloca area is pre-scanned and allocated in the prologue. Placing it above the spill and callee-saved slots
guarantees that memory load/store offsets from SP remain small enough to fit within 12-bit encoding boundaries.

=head2 Key Constants

=over 4

=item ADD_IMM = 0x91000000 (add register, immediate, 12-bit shifted)

=item MOV_IMM = 0xD2800000 (mov register, immediate, using ORR)

=item LDR_IMM = 0xF9400000 (ldr register, unsigned offset, scaled)

=item STR_IMM = 0xF9000000 (str register, unsigned offset, scaled)

=item B_IMM   = 0x14000000 (unconditional branch, 28-bit offset)

=item BL_IMM  = 0x94000000 (branch-and-link, 28-bit offset)

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
