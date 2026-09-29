use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use List::Util ();
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Lowerer::X86_64;
use Brocken::Jenny::RegAlloc;
use Brocken::Jenny::MIR;

class Brocken::Jenny::Codegen::X86_64 {
    field $platform : param;
    use constant {
        REX_W       => 0x08,
        REX_B       => 0x01,
        MOV_EAX_IMM => 0xB8,
        MOV_RM_R    => 0x8B,
        MOV_R_RM    => 0x89,
        MOV_RM8_R   => 0x8A,
        MOV_R8_RM   => 0x88,
        MOV_IMM_RM  => 0xC7,
        MOV_IMM8_RM => 0xC6,
        ARITH_IMM   => 0x81,
        CMP_IMM8    => 0x83,
        SHIFT_IMM   => 0xC1,
        IMUL_IMM    => 0x69,
        GRP3_RM     => 0xF7,
        JMP_REL32   => 0xE9,
        JE          => 0x84,
        JNE         => 0x85,
        RET_BYTE    => 0xC3,
        NOP_BYTE    => 0x90,
        POP_BASE    => 0x58,
        PUSH_BASE   => 0x50,
    };

    # Lower Lindsay IR to MIR, allocate registers, then encode to x86_64 machine code
    method emit_function($ir_func) {
        my $lowerer = Brocken::Jenny::Lowerer::X86_64->new( platform => $platform );
        my $mf      = $lowerer->lower($ir_func);
        my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
        my $int_res = $alloc->allocate( $mf, $platform, 0 );
        $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temps}, $platform->stack_reg, 0, $self->_mem_source_opcodes );
        my $fp_res = $alloc->allocate( $mf, $platform, 1 );
        $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temps}, $platform->stack_reg, 1, $self->_mem_source_opcodes );
        my %assignment = ( $int_res->{assignment}->%*, $fp_res->{assignment}->%* );

        # Caller-save: save/restore caller regs around call_func (exclude return registers)
        my %skip;
        @skip{ $platform->return_register, $platform->fp_return_register } = ( 1, 1 );
        my @gp_caller   = grep { !$skip{$_} } $platform->registers('caller')->@*;
        my @fp_caller   = grep { !$skip{$_} } $platform->fp_registers('caller')->@*;
        my $caller_base = $self->_caller_save_base( $int_res->{spill_slots}, $fp_res->{spill_slots} );
        $alloc->insert_caller_save_code( $mf, \@gp_caller, $platform->stack_reg, 0, $caller_base );
        $alloc->insert_caller_save_code( $mf, \@fp_caller, $platform->stack_reg, 1, $caller_base + scalar(@gp_caller) );
        $alloc->remove_redundant_moves( $mf, \%assignment );
        $alloc->remove_redundant_caller_restores($mf);
        $alloc->fix_entry_shuffle( $mf, \%assignment, $int_res->{spill_temp}, $fp_res->{spill_temp} );
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

    # Emit multiple functions with cross-function call fixups
    method emit_functions($ir_funcs) {
        my @mfs;
        my $has_fiber   = 0;
        my $has_isolate = 0;
        my $entry_index = -1;
        for my $i ( 0 .. $#$ir_funcs ) {
            my $func    = $ir_funcs->[$i];
            my $lowerer = Brocken::Jenny::Lowerer::X86_64->new( platform => $platform );
            my $mf      = $lowerer->lower($func);
            $has_fiber   ||= $self->_has_fiber_ops_mf($mf);
            $has_isolate ||= $self->_has_isolate_ops_ir($func);
            $entry_index = $i if $func->name eq '_BROCKEN_ENTRY';
            push @mfs, $mf;
        }

        # If fiber ops exist and there's a main function, emit an init wrapper
        # that allocates the main FCB, initializes r12, and calls the original
        # main (emitted as _real_main).
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
            $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temps}, $platform->stack_reg, 0, $self->_mem_source_opcodes );
            my $fp_res = $alloc->allocate( $mf, $platform, 1 );
            $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temps}, $platform->stack_reg, 1, $self->_mem_source_opcodes );
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
            $alloc->fix_entry_shuffle( $mf, \%assignment, $int_res->{spill_temp}, $fp_res->{spill_temp} );
            my %callee_seen;
            @callee_seen{ $int_res->{used_callee}->@* } = ();
            @callee_seen{ $fp_res->{used_callee}->@* }  = ();

            if ( $self->_has_fiber_ops_mf($mf) ) {
                $callee_seen{ $platform->fiber_reg } = 1;
            }
            my @used_callee = sort keys %callee_seen;
            my ( $bytes, $func_fixups ) = $self->_encode( $mf, \%assignment, \@used_callee );
            push @result, { name => $fname, bytes => $bytes, fixups => $func_fixups };
        }

        # Prepend the init wrapper
        if ($emit_init) {
            my $init_mf = $self->_build_fiber_init_mf;
            unshift @result, $self->_emit_single_mf($init_mf);
        }

        # Emit isolate trampoline so pthread_create can reference it
        if ($has_isolate) {
            my $tramp_mf = $self->_build_isolate_trampoline_mf;
            push @result, $self->_emit_single_mf($tramp_mf);
        }

        # On Windows x86_64, emit _create_thread thunk wrapping CreateThread
        if ( $has_isolate && $platform->is_windows ) {
            push @result, $self->_build_create_thread_fn;
        }
        return \@result;
    }

    # Encode a single MachineFunction through allocation and encoding
    method _emit_single_mf($mf) {
        my $alloc   = Brocken::Jenny::RegAlloc::LinearScan->new();
        my $int_res = $alloc->allocate( $mf, $platform, 0 );
        $alloc->insert_spill_code( $mf, $int_res->{spill_slots}, $int_res->{spill_temps}, $platform->stack_reg, 0, $self->_mem_source_opcodes );
        my $fp_res = $alloc->allocate( $mf, $platform, 1 );
        $alloc->insert_spill_code( $mf, $fp_res->{spill_slots}, $fp_res->{spill_temps}, $platform->stack_reg, 1, $self->_mem_source_opcodes );
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
        $alloc->fix_entry_shuffle( $mf, \%assignment, $int_res->{spill_temp}, $fp_res->{spill_temp} );
        my %callee_seen;
        @callee_seen{ $int_res->{used_callee}->@* } = ();
        @callee_seen{ $fp_res->{used_callee}->@* }  = ();

        if ( $self->_has_fiber_ops_mf($mf) ) {
            $callee_seen{ $platform->fiber_reg } = 1;
        }
        my @used_callee = sort keys %callee_seen;
        my ( $bytes, $func_fixups ) = $self->_encode( $mf, \%assignment, \@used_callee );
        return { name => $mf->name, bytes => $bytes, fixups => $func_fixups };
    }

    # Check if a MachineFunction contains ctx_save or ctx_restore instructions
    method _has_fiber_ops_mf($mf) {
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                return 1 if $inst->opcode eq 'ctx_swap';
            }
        }
        return 0;
    }

    # Check if an IR function contains isolate operations
    method _has_isolate_ops_ir($func) {
        for my $block ( $func->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                return 1
                    if $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateCreate') || $inst->isa('Brocken::Lindsay::IR::Instruction::IsolateJoin');
            }
        }
        return 0;
    }

    # Build the isolate trampoline MIR function.
    # Called by pthread_create (Unix, rdi=arg) or CreateThread (Windows, rcx=arg)
    # on a new OS thread. Receives a void* arg pointing to { FCB* fcb, ICB* icb, i64 args[6] }.
    # Sets r12 = FCB, stores ICB in FCB.os_thread, loads up to 6 args into the
    # platform calling-convention registers, then calls FCB.resume_pc via
    # call_indirect. The callee's return value (rax) is passed through.
    method _build_isolate_trampoline_mf() {
        my $i64     = Brocken::Lindsay::IR::Type::i64();
        my $ptr     = Brocken::Lindsay::IR::Type::ptr();
        my $mf      = Brocken::Jenny::MIR::MachineFunction->new( name => '_isolate_trampoline' );
        my $mbb     = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
        my $arg_reg = $platform->is_windows ? 'rcx' : 'rdi';
        my $arg_ptr = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%arg', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'mov',
                operands => [ $arg_ptr, Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $arg_reg ) ],
                comment  => "arg = $arg_reg"
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

        # FCB.os_thread = icb  (offset 72)
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'store',
                operands =>
                    [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%fcb', disp => 72 }, type => $ptr ), $icb_ptr ],
                comment => 'FCB.os_thread = ICB'
            )
        );

        # r12 = fcb
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'mov',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r12' ), $fcb_ptr ],
                comment  => 'init fiber register r12'
            )
        );

        # func_addr = FCB.resume_pc (offset 64)
        my $func_addr = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%func', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'load',
                operands =>
                    [ $func_addr, Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%fcb', disp => 64 }, type => $ptr ) ],
                comment => 'func = FCB.resume_pc'
            )
        );

        # Load up to 6 args from arg struct (offsets 16-56) into calling-convention registers
        my @arg_regs = $platform->is_windows ? qw(rcx rdx r8 r9) : qw(rdi rsi rdx rcx r8 r9);
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
        $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => 'return to pthread' ) );
        $mf->add_block($mbb);
        $mf->compute_cfg;
        return $mf;
    }

    # Build the _create_thread thunk: wraps CreateThread with Win64 ABI.
    # Receives args in Win64 convention: rcx=&handle, rdx=0(ignored), r8=start, r9=arg.
    # Allocates shadow space + stack args, calls CreateThread, stores handle to *rcx.
    # Returns raw bytes with fixups.
    method _build_create_thread_fn() {
        my $bytes = pack( 'C', 0x53 );                                       # push rbx
        $bytes .= pack( 'C3', 0x48, 0x89, 0xCB );                            # mov rbx, rcx
        $bytes .= pack( 'C2', 0x41, 0x50 );                                  # push r8 (start_routine)
        $bytes .= pack( 'C2', 0x41, 0x51 );                                  # push r9 (arg)
        $bytes .= pack( 'C4', 0x48, 0x83, 0xEC, 0x30 );                      # sub rsp, 48 (shadow + 2 stack args)
        $bytes .= pack( 'C2', 0x31, 0xC9 );                                  # xor ecx, ecx
        $bytes .= pack( 'C2', 0x31, 0xD2 );                                  # xor edx, edx
        $bytes .= pack( 'C5', 0x4C, 0x8B, 0x44, 0x24, 0x38 );                # mov r8, [rsp+56] (saved r8)
        $bytes .= pack( 'C5', 0x4C, 0x8B, 0x4C, 0x24, 0x30 );                # mov r9, [rsp+48] (saved r9)
        $bytes .= pack( 'C9', 0x48, 0xC7, 0x44, 0x24, 0x20, 0, 0, 0, 0 );    # mov [rsp+32], 0 (flags)
        $bytes .= pack( 'C9', 0x48, 0xC7, 0x44, 0x24, 0x28, 0, 0, 0, 0 );    # mov [rsp+40], 0 (threadId)
        my $call_off = length($bytes);
        $bytes .= pack( 'C',  0xE8 ) . pack( 'V', 0 );                       # call CreateThread (fixup placeholder)
        $bytes .= pack( 'C3', 0x48, 0x89, 0x03 );                            # mov [rbx], rax
        $bytes .= pack( 'C4', 0x48, 0x83, 0xC4, 0x40 );                      # add rsp, 64 (48+8+8 = skip reserved + r8/r9)
        $bytes .= pack( 'C',  0x5B );                                        # pop rbx
        $bytes .= pack( 'C',  0xC3 );                                        # ret
        my @fixups = ( { offset => $call_off, type => 'call_rel32', target => 'CreateThread' } );
        return { name => '_create_thread', bytes => $bytes, fixups => \@fixups };
    }

    # Build the fiber init wrapper MIR function that sets up the main fiber's FCB.
    # Calls _real_main normally; the standard epilogue (mov rsp,rbp; pop rbp; ret)
    # correctly unwinds the frame.
    method _build_fiber_init_mf() {
        my $i64 = Brocken::Lindsay::IR::Type::i64();
        my $ptr = Brocken::Lindsay::IR::Type::ptr();
        my $mf  = Brocken::Jenny::MIR::MachineFunction->new( name => 'main' );
        my $mbb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
        my $fcb = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%init.fcb', type => $ptr );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'alloca',
                operands => [ $fcb, Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => 80, type => $i64 ) ],
                comment  => 'main fiber FCB'
            )
        );

        # Store self-pointer at FCB[16] (r12 slot)
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'store',
                operands =>
                    [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%init.fcb', disp => 16 }, type => $i64 ), $fcb ],
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

        # Store ICB pointer in FCB.os_thread slot (offset 72)
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'store',
                operands =>
                    [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => '%init.fcb', disp => 72 }, type => $i64 ), $icb ],
                comment => 'FCB.os_thread = &ICB'
            )
        );

        # mov r12, fcb
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'mov',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => 'r12' ), $fcb ],
                comment  => 'init fiber register r12'
            )
        );

        # call _real_main
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'call_func',
                operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => '_real_main' ) ],
                comment  => 'call original main'
            )
        );

        # ret - standard epilogue does mov rsp,rbp; pop rbp; ret
        $mbb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => 'return to _start' ) );
        $mf->add_block($mbb);
        $mf->compute_cfg;
        return $mf;
    }

    # Encode MIR to x86_64 machine code bytes (registers pre-allocated)
    method _encode( $mf, $assignment, $used_callee ) {
        my $bytes        = '';
        my $alloca_frame = 0;
        my %reg_id_map   = ( rax => 0, rcx => 1, rdx => 2, rbx => 3, rsp => 4, rbp => 5, rsi => 6, rdi => 7 );
        for my $i ( 0 .. 15 ) { $reg_id_map{"xmm$i"} = $i }
        my $reg_id = sub ($r) {
            return $reg_id_map{$r} if exists $reg_id_map{$r};
            return $1              if $r =~ /^r(\d+)$/ && $1 < 16;

            # Returning 0 here looked like register rax, so a register that was
            # never assigned read as a real one and the instruction encoded with
            # the wrong operand. An unknown name is a lowering bug and has to say
            # so rather than pick a register.
            die "Unknown x86-64 register: '$r'";
        };
        my $spill_frame    = $self->_compute_spill_frame( $mf, 'rsp' );
        my $call_arg_frame = $self->_compute_call_arg_frame( $mf, 'rsp' );
        my $callee_size    = scalar(@$used_callee) * 8;
        my $unified_frame  = ( $callee_size + $spill_frame + 15 ) & ~15;
        my $is_leaf        = 1;
        my $total_alloca   = 0;
        my $needs_fmov_scratch;

        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                $is_leaf            = 0 if $inst->opcode eq 'call_func' || $inst->opcode eq 'call_indirect';
                $needs_fmov_scratch = 1 if $inst->opcode eq 'fmov_gp2f';
                if ( $inst->opcode eq 'alloca' ) {
                    my ( undef, $src ) = $inst->operands->@*;
                    $total_alloca += $src->value;
                    $total_alloca = ( $total_alloca + 15 ) & ~15;
                }
            }
        }
        my $shadow_space = ( $platform->is_windows && !$is_leaf ) ? 32 : 0;

        # The Zen 4 workaround for MOVD/MOVQ out of R8-R15 (see the fmov_gp2f
        # case below) has to park the GPR in memory and read the XMM back from
        # there, so it needs one scratch slot of its own.  It used to use a
        # literal +0x20, which only lands in dead space when the frame happens
        # to be empty: any local sitting at that offset was silently overwritten
        # with the constant being moved, so `my f64 $a=1; my f64 $b=2;
        # my f64 $c=3` read 3.0 back out of $b.  Reserve the slot at the top of
        # the alloca area instead, which nothing else is addressed out of.
        my $fmov_scratch_off;
        if ($needs_fmov_scratch) {
            $fmov_scratch_off = $shadow_space + $call_arg_frame + $total_alloca;
            $total_alloca += 16;
        }

        # Ensure the spill area (which includes caller-saved register slots) does not
        # overlap with the callee-saved register save area at the top of the frame.
        # On Win64, rsp-relative displacements are shifted by (total_alloca + shadow_space)
        # during encoding (see mem_modrm).  Without this extra padding the caller-save
        # slots can land at the same rsp-relative offset as the callee saves.
        # The outgoing argument area sits at the very bottom of the frame, so
        # everything the allocator addresses through rsp has to move up past it.
        $spill_frame += $shadow_space if $shadow_space;
        my $total_frame = ( $callee_size + $spill_frame + $shadow_space + $total_alloca + $call_arg_frame + 15 ) & ~15;
        my $needs_frame = $total_frame > 0 || $used_callee->@* > 0 || $total_alloca > 0 || $call_arg_frame > 0;

        # How far the prologue below moves the stack pointer away from where the
        # caller left it.  An argument passed on the stack is positioned against
        # the *entry* stack pointer, but the entry block's loads run after the
        # prologue, so their displacements have to be biased back up by this.
        my $has_prologue = !( $is_leaf && !$needs_frame );
        my $entry_bias   = $has_prologue ? 8 + $total_frame : 0;
        if ( $is_leaf && !$needs_frame ) {

            # Leaf function with no frame: skip all prologue bytes
        }
        else {
            # X86_64 Standard Frame Pointer Prologue
            $bytes .= pack( 'C', PUSH_BASE + 5 );         # push rbp
            $bytes .= pack( 'CCC', 0x48, 0x89, 0xE5 );    # mov rbp, rsp
            if ( $total_frame > 0 ) {

                # Windows x64 requires stack probing for frames > 4KB to
                # ensure the guard page is expanded one page at a time.
                if ( $platform->is_windows && $total_frame > 4096 ) {
                    my $pages = int( $total_frame / 4096 );
                    my $rem   = $total_frame % 4096;
                    if ( $pages > 0 ) {
                        $bytes .= pack( 'CV', 0xB9, $pages );                # mov ecx, pages
                        my $loop_start = length $bytes;
                        $bytes .= pack( 'CCCV', 0x48, 0x81, 0xEC, 4096 );    # sub rsp, 4096
                        $bytes .= pack( 'CCC',  0x85, 0x04, 0x24 );          # test [rsp], eax  (probe)
                        $bytes .= pack( 'CCC',  0x83, 0xE9, 0x01 );          # sub ecx, 1
                        my $disp = $loop_start - length($bytes) - 2;
                        $bytes .= pack( 'Cc', 0x75, $disp );                 # jne loop
                    }
                    if ( $rem > 0 ) {
                        $bytes .= pack( 'CCCV', 0x48, 0x81, 0xEC, $rem );    # sub rsp, rem
                    }
                }
                else {
                    $bytes .= pack( 'CCCV', 0x48, 0x81, 0xEC, $total_frame );    # sub rsp, total_frame
                }
            }
            for my $i ( 0 .. $#$used_callee ) {
                my $reg = $used_callee->[$i];
                my $rid = $reg_id->($reg);
                my $off = $total_frame - $shadow_space - ( $i * 8 ) - 8;
                my $rex = 0x48 | ( $rid >= 8 ? 4 : 0 );
                $bytes .= pack( 'C', $rex ) . pack( 'CCCV', 0x89, ( 2 << 6 ) | ( ( $rid & 7 ) << 3 ) | 4, 0x24, $off );
            }
        }
        my $resolve = sub ($op) {
            return $assignment->{ $op->value } // $op->value if $op->kind eq 'virt_reg';
            return $op->value                                if $op->kind eq 'phys_reg';
            die "Unexpected operand kind: " . $op->kind;
        };
        my %labels;
        my @fixups;
        my @func_fixups;
        my $current_offset = sub { return length $bytes };
        my $mem_modrm      = sub ( $mem_op, $reg_idx ) {
            my $addr = $mem_op->value;
            state $phys_re = do {
                my @regs = $platform->registers('available')->@*;
                my $pat  = join '|', map quotemeta, @regs;
                qr/^($pat)$/;
            };
            my $base_kind = $addr->{base} =~ $phys_re ? 'phys_reg' : 'virt_reg';

            # A raw displacement is positioned by the ABI against the real stack
            # pointer.  The same string names a base for the spill and
            # caller-save slots, which the resolver treats as a virtual register
            # the allocator places where it likes, so a raw operand has to bypass
            # it and address the hardware stack pointer directly.
            my $base_r = ( $addr->{raw} && $addr->{base} eq $platform->stack_reg ) ? $platform->stack_reg :
                $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => $base_kind, value => $addr->{base} ) );
            my $bid  = $reg_id->($base_r);
            my $disp = $addr->{disp} // 0;

            # A raw displacement is relative to the stack pointer itself, so
            # it must not pick up the shift that lifts allocator-owned slots
            # (spills, caller-saves, allocas) above the outgoing argument area.
            $disp += $total_alloca + $shadow_space + $call_arg_frame if !$addr->{raw} && $base_r eq 'rsp';

            # An incoming stack argument is stated relative to the stack
            # pointer on entry, so undo the prologue's own adjustment.
            $disp += $entry_bias if ( $addr->{raw} // '' ) eq 'entry';
            if ( defined $addr->{index} ) {
                my $index_r = $resolve->( Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $addr->{index} ) );
                my $iid     = $reg_id->($index_r);
                my $scale   = $addr->{scale} // 1;
                my $sibits  = ( $scale == 1 ) ? 0 : ( $scale == 2 ) ? 1 : ( $scale == 4 ) ? 2 : 3;
                my $sib_idx = $iid & 7;
                $sib_idx = 4 if $sib_idx == 4;
                my $sib_base = $bid & 7;
                my $sib      = ( $sibits << 6 ) | ( $sib_idx << 3 ) | $sib_base;
                my $mod;
                if    ( $disp == 0 && $sib_base != 5 )  { $mod = 0 }
                elsif ( $disp >= -128 && $disp <= 127 ) { $mod = 1 }
                else                                    { $mod = 2 }
                my $modrm = ( $mod << 6 ) | ( ( $reg_idx & 7 ) << 3 ) | 4;
                my @extra = ( pack( 'C', $sib ) );
                if    ( $mod == 1 ) { push @extra, pack( 'c', $disp ) }
                elsif ( $mod == 2 ) { push @extra, pack( 'V', $disp ) }
                my $rex_x = ( $iid >= 8 ) ? 2 : 0;
                my $rex_b = ( $bid >= 8 ) ? 1 : 0;
                return ( $modrm, \@extra, $rex_x, $rex_b );
            }
            my $rm = $bid & 7;
            my ( $mod, @extra );
            if ( $rm == 4 ) {
                if    ( $disp == 0 )                    { $mod = 0; @extra = ("\x24") }
                elsif ( $disp >= -128 && $disp <= 127 ) { $mod = 1; @extra = ( "\x24", pack( 'c', $disp ) ) }
                else                                    { $mod = 2; @extra = ( "\x24", pack( 'V', $disp ) ) }
            }
            elsif ( $disp == 0 && $rm != 5 ) {
                $mod = 0;
            }
            else {
                if   ( $disp >= -128 && $disp <= 127 ) { $mod = 1; @extra = ( pack( 'c', $disp ) ) }
                else                                   { $mod = 2; @extra = ( pack( 'V', $disp ) ) }
            }
            my $modrm = ( $mod << 6 ) | ( ( $reg_idx & 7 ) << 3 ) | $rm;
            my $rex_b = ( $bid >= 8 ) ? 1 : 0;
            return ( $modrm, \@extra, 0, $rex_b );
        };
        my $alloca_top = $shadow_space + $call_arg_frame;
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                my $opcode = $inst->opcode;
                my ( $dst, $src ) = $inst->operands->@*;
                if ( $opcode eq 'mov' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $dst->type ? $dst->type->bits : 64;
                    if ( $src->kind eq 'imm' ) {
                        my $rex_w = ( $bits >= 64 ) ? REX_W : 0;
                        my $rex_b = $did >= 8       ? REX_B : 0;
                        if ( $rex_w && ( abs( $src->value ) > 0x7FFFFFFF ) ) {
                            $bytes .= pack( 'C', 0x48 | $rex_b ) . pack( 'C', MOV_EAX_IMM + ( $did & 7 ) ) . pack( 'Q', $src->value );
                        }
                        elsif ($rex_w) {
                            $bytes .= pack( 'CCC', 0x48 | $rex_b, MOV_IMM_RM, 0xC0 | ( $did & 7 ) );
                            $bytes .= pack( 'V', $src->value );
                        }
                        elsif ($rex_b) {
                            $bytes .= pack( 'CCV', 0x41, MOV_EAX_IMM + ( $did & 7 ), $src->value );
                        }
                        else {
                            $bytes .= pack( 'CV', MOV_EAX_IMM + $did, $src->value );
                        }
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $rex_w = ( $bits >= 64 ) ? REX_W : 0;
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'CCC', $rex, MOV_RM_R, $modrm );
                    }
                }
                elsif ( $opcode eq 'movzx' || $opcode eq 'movsx' ) {
                    my $src_bits = $src->type ? $src->type->bits : 64;
                    my $dst_bits = $dst->type ? $dst->type->bits : 64;
                    my $dst_r    = $resolve->($dst);
                    my $did      = $reg_id->($dst_r);
                    my $src_r    = $resolve->($src);
                    my $sid      = $reg_id->($src_r);
                    my $rex_w    = ( $dst_bits >= 64 ) ? REX_W : 0;
                    my $rex      = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm    = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );

                    # Nothing to widen, or a narrowing truncation: a same-width mov
                    # already zeroes the upper half, so a plain copy is correct.
                    # MOVSXD would instead reinterpret the low 32 bits as signed,
                    # silently truncating any 64-bit source.
                    if ( $src_bits >= $dst_bits ) {
                        $bytes .= pack( 'CCC', $rex, MOV_RM_R, $modrm );
                    }
                    elsif ( $src_bits == 32 ) {
                        if ( $opcode eq 'movzx' ) {

                            # 32 -> 64 zero-extend: a plain 32-bit mov already
                            # zeroes the upper half, whereas MOVSXD would
                            # sign-extend.
                            my $rex32 = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                            $bytes .= pack( 'CCC', $rex32, MOV_RM_R, $modrm );
                        }
                        else {
                            # 32 -> 64 sign-extend: MOVSXD (0x63)
                            $bytes .= pack( 'CCC', $rex, 0x63, $modrm );
                        }
                    }
                    elsif ( $opcode eq 'movzx' && $src_bits <= 8 ) {
                        $bytes .= pack( 'CCCC', $rex, 0x0F, 0xB6, $modrm );
                    }
                    elsif ( $opcode eq 'movzx' && $src_bits <= 16 ) {
                        $bytes .= pack( 'CCCC', $rex, 0x0F, 0xB7, $modrm );
                    }
                    elsif ( $opcode eq 'movsx' && $src_bits <= 8 ) {
                        $bytes .= pack( 'CCCC', $rex, 0x0F, 0xBE, $modrm );
                    }
                    else {
                        $bytes .= pack( 'CCCC', $rex, 0x0F, 0xBF, $modrm );
                    }
                }
                elsif ( $opcode eq 'add' ||
                    $opcode eq 'sub' ||
                    $opcode eq 'and' ||
                    $opcode eq 'or'  ||
                    $opcode eq 'xor' ||
                    $opcode eq 'adc' ||
                    $opcode eq 'sbb' ) {
                    my $dst_r   = $resolve->($dst);
                    my $did     = $reg_id->($dst_r);
                    my $bits    = $dst->type ? $dst->type->bits : 64;
                    my %imm_ext = ( add => 0,    sub => 5,    and => 4,    or => 1,    xor => 6,    adc => 2,    sbb => 3 );
                    my %reg_op  = ( add => 0x01, sub => 0x29, and => 0x21, or => 0x09, xor => 0x31, adc => 0x11, sbb => 0x19 );
                    my %reg_mem = ( add => 0x03, sub => 0x2B, and => 0x23, or => 0x0B, xor => 0x33, adc => 0x13, sbb => 0x1B );
                    my $rex_w   = ( $bits >= 64 ) ? REX_W : 0;
                    if ( $src->kind eq 'imm' ) {
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                        my $ext   = $imm_ext{$opcode};
                        my $modrm = 0xC0 | ( $ext << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCCV', $rex, ARITH_IMM, $modrm, $src->value );
                    }
                    elsif ( $src->kind eq 'mem' ) {
                        my $op = $reg_mem{$opcode};
                        my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $src, $did & 7 );
                        my $rex = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | $rex_x | $rex_b;
                        $bytes .= pack( 'CCC', $rex, $op, $modrm );
                        $bytes .= join '', $extra->@*;
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $rex   = 0x40 | $rex_w | ( $sid >= 8 ? 4 : 0 ) | ( $did >= 8 ? 1 : 0 );
                        my $op    = $reg_op{$opcode};
                        my $modrm = 0xC0 | ( ( $sid & 7 ) << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCC', $rex, $op, $modrm );
                    }
                }
                elsif ( $opcode eq 'mul' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $dst->type      ? $dst->type->bits : 64;
                    my $rex_w = ( $bits >= 64 ) ? REX_W            : 0;
                    if ( $src->kind eq 'imm' ) {

                        # imul dst, dst, imm32  => REX.W 69 /r
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $did >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCCV', $rex, IMUL_IMM, $modrm, $src->value );
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );

                        # imul dst, src  => REX.W 0F AF /r
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'CCC', $rex, 0x0F, 0xAF ) . pack( 'C', $modrm );
                    }
                }
                elsif ( $opcode eq 'umulh' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $rex_w = REX_W;

                    # MOV RAX, dst  (RAX = dst, first operand)
                    my $rax_rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $rax_modrm = 0xC0 | ( 0 << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $rax_rex, 0x8B, $rax_modrm );

                    # MUL src  (RDX:RAX = RAX * src; /4 = MUL opcode extension)
                    my $mul_rex   = 0x40 | $rex_w | ( $sid >= 8 ? 1 : 0 );
                    my $mul_modrm = 0xC0 | ( 4 << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'CCC', $mul_rex, 0xF7, $mul_modrm );

                    # MOV dst, RDX  (dst = high 64 bits)
                    my $rdx_rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $rdx_modrm = 0xC0 | ( 2 << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $rdx_rex, 0x8B, $rdx_modrm );
                }
                elsif ( $opcode eq 'udiv' || $opcode eq 'idiv' || $opcode eq 'irem' ) {
                    my $dst_r     = $resolve->($dst);
                    my $src_r     = $resolve->($src);
                    my $did       = $reg_id->($dst_r);
                    my $sid       = $reg_id->($src_r);
                    my $rex_w     = REX_W;
                    my $is_signed = $opcode ne 'udiv';
                    my $want_rem  = $opcode eq 'irem';

                    # MOV RAX, dst  (RAX = low 64 bits of dividend)
                    my $rax_rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $rax_modrm = 0xC0 | ( 0 << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $rax_rex, 0x8B, $rax_modrm );

                    # Unsigned divides the full 128-bit RDX:RAX, so RDX must be 0.
                    # Signed divides the 128-bit sign extension of RAX, so RDX must
                    # repeat RAX's sign bit; CQTO does exactly that. Leaving RDX
                    # zeroed for a negative dividend makes the divisor see a huge
                    # unsigned value instead.
                    if ($is_signed) {
                        $bytes .= pack( 'CC', 0x40 | $rex_w, 0x99 );    # CQTO
                    }
                    else {
                        my $rdx_rex = 0x40 | $rex_w;
                        $bytes .= pack( 'CCC', $rdx_rex, 0x31, 0xD2 );    # XOR RDX, RDX
                    }

                    # DIV src  (RDX:RAX / src -> RAX = quotient, RDX = remainder; /6 = DIV)
                    # IDIV src (same, signed; /7 = IDIV)
                    my $div_rex   = 0x40 | $rex_w | ( $sid >= 8 ? 1 : 0 );
                    my $div_modrm = 0xC0 | ( ( $is_signed ? 7 : 6 ) << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'CCC', $div_rex, 0xF7, $div_modrm );

                    # MOV dst, RAX (quotient) or MOV dst, RDX (remainder)
                    my $mov_rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $mov_modrm = 0xC0 | ( ( $want_rem ? 2 : 0 ) << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $mov_rex, 0x89, $mov_modrm );
                }
                elsif ( $opcode eq 'div128_64' || $opcode eq 'rem128_64' ) {
                    my ( $dst, $src_lo, $src_hi, $src_div ) = $inst->operands->@*;
                    my $dst_r  = $resolve->($dst);
                    my $lo_r   = $resolve->($src_lo);
                    my $hi_r   = $resolve->($src_hi);
                    my $div_r  = $resolve->($src_div);
                    my $did    = $reg_id->($dst_r);
                    my $lo_id  = $reg_id->($lo_r);
                    my $hi_id  = $reg_id->($hi_r);
                    my $div_id = $reg_id->($div_r);
                    my $rex_w  = REX_W;

                    # MOV RAX, src_lo  (0x8B: MOV r64, r/m64; reg=dest=RAX, r/m=src_lo)
                    my $rax_rex   = 0x40 | $rex_w | ( $lo_id >= 8 ? 1 : 0 );
                    my $rax_modrm = 0xC0 | ( 0 << 3 ) | ( $lo_id & 7 );
                    $bytes .= pack( 'CCC', $rax_rex, 0x8B, $rax_modrm );

                    # MOV RDX, src_hi
                    my $rdx_rex   = 0x40 | $rex_w | ( $hi_id >= 8 ? 1 : 0 );
                    my $rdx_modrm = 0xC0 | ( 2 << 3 ) | ( $hi_id & 7 );
                    $bytes .= pack( 'CCC', $rdx_rex, 0x8B, $rdx_modrm );

                    # DIV src_div  (RDX:RAX / src_div -> RAX = quotient, RDX = remainder)
                    my $div_rex   = 0x40 | $rex_w | ( $div_id >= 8 ? 1 : 0 );
                    my $div_modrm = 0xC0 | ( 6 << 3 ) | ( $div_id & 7 );
                    $bytes .= pack( 'CCC', $div_rex, 0xF7, $div_modrm );
                    my $store_reg   = $opcode eq 'div128_64' ? 0 : 2;
                    my $store_rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $store_modrm = 0xC0 | ( $store_reg << 3 ) | ( $did & 7 );
                    $bytes .= pack( 'CCC', $store_rex, 0x89, $store_modrm );
                }
                elsif ( $opcode eq 'shl' || $opcode eq 'lshr' || $opcode eq 'ashr' ) {
                    my $dst_r  = $resolve->($dst);
                    my $did    = $reg_id->($dst_r);
                    my $bits   = $dst->type ? $dst->type->bits : 64;
                    my %ext    = ( shl => 4, lshr => 5, ashr => 7 );
                    my $rex_w  = ( $bits >= 64 ) ? REX_W : 0;
                    my $rex    = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $extval = $ext{$opcode};
                    if ( $src->kind eq 'imm' ) {

                        # shift by imm8: REX.W C1 /ext ib
                        my $modrm = 0xC0 | ( $extval << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCCC', $rex, SHIFT_IMM, $modrm, $src->value );
                    }
                    else {
                        # shift by CL: REX.W D3 /ext rm
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        if ( $sid != 1 ) {
                            my $mrex   = 0x40 | ( $sid >= 8 ? 1 : 0 );
                            my $mmodrm = 0xC0 | ( 1 << 3 ) | ( $sid & 7 );
                            $bytes .= pack( 'CCC', $mrex, 0x8B, $mmodrm );
                        }
                        my $smodrm = 0xC0 | ( $extval << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCC', $rex, 0xD3, $smodrm );
                    }
                }
                elsif ( $opcode eq 'neg' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $dst->type      ? $dst->type->bits : 64;
                    my $rex_w = ( $bits >= 64 ) ? REX_W            : 0;

                    # RMW: the target is the r/m operand, so a high register needs REX.B, not REX.R.
                    my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( 3 << 3 ) | ( $did & 7 );

                    # NEG r/m64 => REX.W F7 /3
                    $bytes .= pack( 'CCC', $rex, GRP3_RM, $modrm );
                }
                elsif ( $opcode eq 'alloca' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $size  = $src->value;
                    $alloca_frame = ( $alloca_frame + 15 ) & ~15;
                    $alloca_frame += $size;
                    my $aligned_top = ( $alloca_top + 15 ) & ~15;
                    my $rex         = 0x48 | ( $did >= 8 ? 4 : 0 );
                    my $mod         = ( $aligned_top == 0 ) ? 0 : ( $aligned_top >= -128 && $aligned_top <= 127 ) ? 1 : 2;
                    my $modrm       = ( $mod << 6 ) | ( ( $did & 7 ) << 3 ) | 4;
                    my $sib         = 0x24;
                    $bytes .= pack( 'C', $rex ) . pack( 'CC', 0x8D, $modrm ) . pack( 'C', $sib );
                    $bytes .= pack( 'c', $aligned_top ) if $mod == 1;
                    $bytes .= pack( 'V', $aligned_top ) if $mod == 2;
                    $alloca_top = $aligned_top + $size;
                }
                elsif ( $opcode eq 'lea' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $src, $did );
                    my $rex = 0x48 | $rex_x | $rex_b | ( $did >= 8 ? 4 : 0 );
                    $bytes .= pack( 'C', $rex ) . pack( 'C', 0x8D ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'load' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $src, $did );
                    my $bits = ( $dst->type && $dst->type->kind eq 'int' ) ? $dst->type->bits : 64;

                    # A sub-word load has to read only the bytes it claims.
                    # MOV_RM_R with REX.W cleared is still a 4-byte access, so
                    # an i8 or i16 field reached through it read three or two
                    # bytes belonging to whatever follows it, and a store of
                    # the same width wrote over them. Single-field access
                    # round-tripped because the lane holds a sign-extended
                    # value, which is why only a neighbouring access exposed
                    # it.
                    if ( $bits <= 8 ) {

                        # 0F BE is MOVSX r32, r/m8: a one-byte read that
                        # leaves the whole destination defined, in the form the
                        # rest of the IR expects. A bare 0x8A also reads one
                        # byte, but it writes only the low 8 bits of the
                        # register and leaves the upper 56 holding whatever
                        # the previous value put there.
                        #
                        # MOVSX, not MOVZX: an i8 or i16 is carried
                        # sign-extended in the whole register, and arithmetic
                        # on it is plain 32-bit arithmetic. Zero-extending
                        # turned -7 into 0xF9 and abs() of that into 249.
                        #
                        # A REX byte is required to reach spl/bpl/dil at all,
                        # and changes the meaning of ids 0-3 (al -> sil). It
                        # must not carry REX.W, which would select the r64
                        # form.
                        my $rex = $rex_x | $rex_b | ( $did >= 8 ? 4 : 0 );
                        $bytes .= pack( 'C', 0x40 | $rex ) if $rex;
                        $bytes .= pack( 'CCC', 0x0F, 0xBE, $modrm );
                    }
                    elsif ( $bits <= 16 ) {

                        # 0F BF is MOVSX r32, r/m16, for the same reason: a
                        # 2-byte read whose result is sign-extended to fill the
                        # register, so later arithmetic sees what it expects.
                        my $rex = $rex_x | $rex_b | ( $did >= 8 ? 4 : 0 );
                        $bytes .= pack( 'C', 0x40 | $rex ) if $rex;
                        $bytes .= pack( 'CCC', 0x0F, 0xBF, $modrm );
                    }
                    else {
                        my $rex_w    = ( $bits == 64 ) ? REX_W : 0;
                        my $rex_bits = $rex_x | $rex_b | ( $did >= 8 ? 4 : 0 );
                        $bytes .= pack( 'C', 0x40 | $rex_w | $rex_bits ) if ( $rex_w | $rex_bits );
                        $bytes .= pack( 'C', MOV_RM_R ) . pack( 'C', $modrm );
                    }
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'store' ) {
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $dst, $sid );
                    my $bits = ( $src->type && $src->type->kind eq 'int' ) ? $src->type->bits : 64;

                    # Sized like the load above: 0x88 writes one byte and a
                    # 66-prefixed 0x89 writes two, where plain MOV_R_RM writes
                    # four and clobbers whatever field follows this one.
                    if ( $bits <= 8 ) {

                        # Here the source is the ModRM reg field, so the
                        # high-byte ambiguity applies: with no REX byte
                        # present, ids 4-7 name AH/CH/DH/BH rather than
                        # SPL/BPL/SIL/DIL, and a store out of rsi or rdi
                        # writes the high byte of rdx or rcx instead. The
                        # load above dodges this only because its byte
                        # operand is the memory side, and the extension
                        # registers need REX for the obvious reason.
                        my $rex = $rex_x | $rex_b | ( $sid >= 8 ? 4 : 0 );
                        $bytes .= pack( 'C', 0x40 | $rex ) if $rex || $sid >= 4;
                        $bytes .= pack( 'C', MOV_R8_RM ) . pack( 'C', $modrm );
                    }
                    elsif ( $bits <= 16 ) {

                        # The legacy prefix has to precede REX, not follow it.
                        $bytes .= pack( 'C', 0x66 );
                        my $rex = $rex_x | $rex_b | ( $sid >= 8 ? 4 : 0 );
                        $bytes .= pack( 'C', 0x40 | $rex ) if $rex;
                        $bytes .= pack( 'C', MOV_R_RM ) . pack( 'C', $modrm );
                    }
                    else {
                        my $rex_w    = ( $bits == 64 ) ? REX_W : 0;
                        my $rex_bits = $rex_x | $rex_b | ( $sid >= 8 ? 4 : 0 );
                        $bytes .= pack( 'C', 0x40 | $rex_w | $rex_bits ) if ( $rex_w | $rex_bits );
                        $bytes .= pack( 'C', MOV_R_RM ) . pack( 'C', $modrm );
                    }
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'store_imm' ) {
                    my ( $mem, $imm ) = $inst->operands->@*;
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $mem, 0 );    # /0 ext = mov
                    my $bits = ( $imm->type && $imm->type->kind eq 'int' ) ? $imm->type->bits : 64;

                    # The same defect as the register store, which is how a
                    # constant initialiser into an i8 or i16 field took out its
                    # neighbour. The immediate is truncated to the access width
                    # as well, because 0xC6 sign-extends its byte and a
                    # 16-bit C7 only has room for the low half.
                    #
                    # The immediate is staged rather than emitted here: in this
                    # instruction form it follows the displacement, so the
                    # opcode, ModRM and displacement go out first and the
                    # immediate is appended once the shared tail below has run.
                    my $imm_bytes;
                    if ( $bits <= 8 ) {
                        my $rex = $rex_x | $rex_b;
                        $bytes .= pack( 'C', 0x40 | $rex ) if $rex;
                        $bytes .= pack( 'C', MOV_IMM8_RM ) . pack( 'C', $modrm );
                        $imm_bytes = pack( 'C', $imm->value & 0xFF );
                    }
                    elsif ( $bits <= 16 ) {

                        # Legacy prefix before REX, as above.
                        $bytes .= pack( 'C', 0x66 );
                        my $rex = $rex_x | $rex_b;
                        $bytes .= pack( 'C', 0x40 | $rex ) if $rex;
                        $bytes .= pack( 'C', MOV_IMM_RM ) . pack( 'C', $modrm );
                        $imm_bytes = pack( 'v', $imm->value & 0xFFFF );
                    }
                    else {
                        my $rex_w    = ( $bits == 64 ) ? REX_W : 0;
                        my $rex_bits = $rex_x | $rex_b;
                        $bytes .= pack( 'C', 0x40 | $rex_w | $rex_bits ) if ( $rex_w | $rex_bits );
                        $bytes .= pack( 'C', MOV_IMM_RM ) . pack( 'C', $modrm );
                        $imm_bytes = pack( 'V', $imm->value );
                    }
                    $bytes .= join '', $extra->@*;
                    $bytes .= $imm_bytes;
                }

                # SSE float opcodes
                elsif ( $opcode eq 'fload' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $src, $did );
                    my $bits = $dst->type  ? $dst->type->bits     : 32;
                    my $op   = $bits >= 64 ? [ 0xF2, 0x0F, 0x10 ] : [ 0xF3, 0x0F, 0x10 ];
                    my $rex  = 0x40 | $rex_x | $rex_b | ( $did >= 8 ? 4 : 0 );

                    # Prefix first, REX second: see the `fmov` case below.
                    $bytes .= pack( 'C', $op->[0] );
                    if ( $rex > 0x40 ) { $bytes .= pack( 'C', $rex ) }
                    $bytes .= pack( 'CC', $op->[1], $op->[2] ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'fstore' ) {
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $dst, $sid );
                    my $bits = $src->type  ? $src->type->bits     : 32;
                    my $op   = $bits >= 64 ? [ 0xF2, 0x0F, 0x11 ] : [ 0xF3, 0x0F, 0x11 ];
                    my $rex  = 0x40 | $rex_x | $rex_b | ( $sid >= 8 ? 4 : 0 );

                    # Prefix first, REX second: see the `fmov` case below.
                    $bytes .= pack( 'C', $op->[0] );
                    if ( $rex > 0x40 ) { $bytes .= pack( 'C', $rex ) }
                    $bytes .= pack( 'CC', $op->[1], $op->[2] ) . pack( 'C', $modrm );
                    $bytes .= join '', $extra->@*;
                }
                elsif ( $opcode eq 'fmov' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits     : 32;
                    my $op    = $bits >= 64 ? [ 0xF2, 0x0F, 0x10 ] : [ 0xF3, 0x0F, 0x10 ];
                    my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );

                    # F2 or F3 ahead of the REX, not behind it. A REX byte is
                    # only a REX byte as the last prefix before the opcode, so
                    # putting one in front of a legacy prefix has it discarded
                    # and the instruction decodes without it. REX.R is what
                    # reaches xmm8-xmm15 at all, so every move involving one
                    # read or wrote a register below it. Five f64 parameters are
                    # where that starts: the eighth floating-point register is
                    # the first to need the bit, and the sum is correct until
                    # then.
                    $bytes .= pack( 'C',   $op->[0] );
                    $bytes .= pack( 'C',   $rex ) if $rex > 0x40;
                    $bytes .= pack( 'CCC', $op->[1], $op->[2], $modrm );
                }
                elsif ( $opcode eq 'fmov_gp2f' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 32;
                    if ( $sid >= 8 ) {

                        # AMD Zen 4 erratum: MOVD/MOVQ from R8-R15 to XMM
                        # produces wrong results.  Work around by storing the
                        # GPR to a scratch slot and loading into XMM from memory.
                        # That slot is reserved above the allocas (see the
                        # frame layout), so it cannot collide with a local.
                        my $scratch   = $fmov_scratch_off // 0x20;
                        my $sfit      = ( $scratch >= -128 && $scratch <= 127 );
                        my $sib       = $sfit ? "\x24" . pack( 'c', $scratch ) : "\x24" . pack( 'V', $scratch );
                        my $smod      = $sfit ? 0x44                           : 0x84;
                        my $rex_store = 0x40 | ( $bits >= 64 ? 8 : 0 ) | ( $sid >= 8 ? 4 : 0 );
                        my $modrm_st  = $smod | ( ( $sid & 7 ) << 3 );
                        $bytes .= pack( 'C', $rex_store ) if $rex_store > 0x40;
                        $bytes .= pack( 'CC', 0x89, $modrm_st ) . $sib;
                        my $op_load  = $bits >= 64 ? [ 0xF2, 0x0F, 0x10 ] : [ 0xF3, 0x0F, 0x10 ];
                        my $rex_load = 0x40 | ( $did >= 8 ? 4 : 0 );
                        my $modrm_ld = $smod | ( ( $did & 7 ) << 3 );

                        # Prefix before REX, as in the MOVD form below: F2 or
                        # F3 ahead of a REX discards it, and REX.R is what
                        # reaches xmm8-xmm15 at all.
                        $bytes .= pack( 'C',   $op_load->[0] );
                        $bytes .= pack( 'C',   $rex_load ) if $rex_load > 0x40;
                        $bytes .= pack( 'CCC', $op_load->[1], $op_load->[2], $modrm_ld ) . $sib;
                    }
                    else {
                        my $rex = $bits >= 64 ? 0x48 : 0x40;
                        $rex |= ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );

                        # The operand-size prefix has to precede REX, not
                        # follow it, or the REX is discarded and 0F 6E stays
                        # MOVD at 32 bits however wide the REX said to be.
                        # That put 0x3ff0000000000000 through the low half of
                        # a register and left the high half zero, so 1.0
                        # arrived as 0.0 and every comparison against it was
                        # decided against a zero. REX.B went with it, so a
                        # source in r8-r15 read the wrong register.
                        $bytes .= pack( 'C',  0x66 );
                        $bytes .= pack( 'C',  $rex ) if $rex > 0x40;
                        $bytes .= pack( 'CC', 0x0F, 0x6E ) . pack( 'C', $modrm );
                    }
                }
                elsif ( $opcode eq 'fadd' ||
                    $opcode eq 'fsub'  ||
                    $opcode eq 'fmul'  ||
                    $opcode eq 'fdiv'  ||
                    $opcode eq 'fsqrt' ||
                    $opcode eq 'fmin'  ||
                    $opcode eq 'fmax' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 32;
                    my %ss_op = ( fadd => 0x58, fsub => 0x5C, fmul => 0x59, fdiv => 0x5E, fsqrt => 0x51, fmin => 0x5D, fmax => 0x5F );
                    my $op    = $bits >= 64 ? [ 0xF2, 0x0F, $ss_op{$opcode} ] : [ 0xF3, 0x0F, $ss_op{$opcode} ];
                    my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );

                    # Prefix first, REX second: see the `fmov` case above.
                    $bytes .= pack( 'C',   $op->[0] );
                    $bytes .= pack( 'C',   $rex ) if $rex > 0x40;
                    $bytes .= pack( 'CCC', $op->[1], $op->[2], $modrm );
                }
                elsif ( $opcode eq 'fxor' || $opcode eq 'fand' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type ? $dst->type->bits : 32;
                    my %ss_op = ( fxor => 0x57, fand => 0x54 );
                    my $op    = $bits >= 64 ? [ 0x66, 0x0F, $ss_op{$opcode} ] : [ undef, 0x0F, $ss_op{$opcode} ];
                    my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );

                    # The operand-size prefix has to precede REX, as in the MOVD
                    # form above. A bare 0x40 before the opcode is just an empty
                    # REX and is left out.
                    $bytes .= pack( 'C',  $op->[0] ) if defined $op->[0];
                    $bytes .= pack( 'C',  $rex )     if $did >= 8 || $sid >= 8;
                    $bytes .= pack( 'CC', $op->[1], $op->[2] ) . pack( 'C', $modrm );
                }
                elsif ( $opcode eq 'fptosi' ) {

                    # CVTTSD2SI / CVTTSS2SI: the double- and single-precision
                    # forms differ only in the mandatory prefix, and both
                    # truncate toward zero rather than rounding, which is what a
                    # cast is. The destination is a GPR and the source an XMM, so
                    # the registers come from two different allocator pools and
                    # the ModRM is register-to-register with no memory form.
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $sbits = $src->type ? $src->type->bits : 64;
                    my $dbits = $dst->type ? $dst->type->bits : 64;

                    # REX.W is what widens the destination to 64 bits; without it
                    # the same opcode is the 32-bit form. REX.B extends the XMM
                    # source, which is a register number and not a general
                    # register, so it is bit 0 here as in the moves above.
                    my $rex   = 0x40 | ( $dbits >= 64 ? 8 : 0 ) | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );

                    # Prefix first, REX second: see the `fmov` case above. A REX
                    # byte in front of the F2/F3 is discarded, which would leave
                    # the destination at 32 bits and the value truncated to fit.
                    $bytes .= pack( 'C',   $sbits >= 64 ? 0xF2 : 0xF3 );
                    $bytes .= pack( 'C',   $rex ) if $rex > 0x40;
                    $bytes .= pack( 'CCC', 0x0F, 0x2C, $modrm );
                }
                elsif ( $opcode eq 'sitofp' ) {

                    # CVTSI2SD / CVTSI2SS: the same opcode as the moves, told
                    # apart by the mandatory prefix, which here follows the
                    # *float* destination rather than the source as it did for
                    # CVTTSD2SI. The integer is the source, named in r/m, and
                    # the float the destination in reg, so the two ModRM fields
                    # sit the other way round from the fptosi case above.
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $sbits = $src->type ? $src->type->bits : 64;
                    my $fbits = $dst->type ? $dst->type->bits : 64;

                    # REX.W widens the integer source, REX.R names an XMM
                    # destination of 8 or above and REX.B a GPR source of 8 or
                    # above. The instruction has no unsigned form, which is why
                    # the frontend never hands one over: a u32 arrives here
                    # already zero-extended into a positive i64.
                    my $rex   = 0x40 | ( $sbits >= 64 ? 8 : 0 ) | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                    $bytes .= pack( 'C',   $fbits >= 64 ? 0xF2 : 0xF3 );
                    $bytes .= pack( 'C',   $rex ) if $rex > 0x40;
                    $bytes .= pack( 'CCC', 0x0F, 0x2A, $modrm );
                }
                elsif ( $opcode eq 'fcmp' ) {
                    my $dst_r = $resolve->($dst);
                    my $src_r = $resolve->($src);
                    my $did   = $reg_id->($dst_r);
                    my $sid   = $reg_id->($src_r);
                    my $bits  = $dst->type  ? $dst->type->bits     : 32;
                    my $op    = $bits >= 64 ? [ 0x66, 0x0F, 0x2E ] : [ undef, 0x0F, 0x2E ];
                    my $rex   = 0x40 | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );

                    # Prefix before REX, as above: otherwise the 66 is kept
                    # and the REX dropped, and a compare against xmm8-xmm15
                    # would read the wrong register.
                    $bytes .= pack( 'C',  $op->[0] ) if defined $op->[0];
                    $bytes .= pack( 'C',  $rex )     if $did >= 8 || $sid >= 8;
                    $bytes .= pack( 'CC', $op->[1], $op->[2] ) . pack( 'C', $modrm );
                }
                elsif ( $opcode eq 'label' ) {
                    $labels{ $dst->value } = $current_offset->();
                }
                elsif ( $opcode eq 'jmp' ) {
                    push @fixups, { offset => $current_offset->(), type => 'jmp_rel32', target => $dst->value, size => 5 };
                    $bytes .= pack( 'C', JMP_REL32 ) . "\x00\x00\x00\x00";
                }
                elsif ( $opcode eq 'beq' || $opcode eq 'bne' ) {
                    my $cond_r = $resolve->($dst);
                    my $cid    = $reg_id->($cond_r);

                    # cmp reg, 0: REX.W 83 /7 0  (4 bytes)
                    my $rex   = 0x48 | ( $cid >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( 7 << 3 ) | ( $cid & 7 );
                    $bytes .= pack( 'CCCC', $rex, CMP_IMM8, $modrm, 0 );
                    my $jcc = ( $opcode eq 'beq' ? JE : JNE );
                    push @fixups, { offset => $current_offset->(), type => 'jcc_rel32', jcc => $jcc, target => $src->value, size => 6 };
                    $bytes .= pack( 'CC', 0x0F, $jcc ) . "\x00\x00\x00\x00";
                }
                elsif ( $opcode eq 'cmp' ) {
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);
                    my $bits  = $src->type      ? $src->type->bits : 64;
                    my $rex_w = ( $bits >= 64 ) ? REX_W            : 0;
                    if ( $src->kind eq 'imm' ) {
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( 7 << 3 ) | ( $did & 7 );
                        $bytes .= pack( 'CCCV', $rex, ARITH_IMM, $modrm, $src->value );
                    }
                    elsif ( $src->kind eq 'mem' ) {
                        my ( $modrm, $extra, $rex_x, $rex_b ) = $mem_modrm->( $src, $did & 7 );
                        my $rex = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | $rex_x | $rex_b;
                        $bytes .= pack( 'CCC', $rex, 0x3B, $modrm );
                        $bytes .= join '', $extra->@*;
                    }
                    else {
                        my $src_r = $resolve->($src);
                        my $sid   = $reg_id->($src_r);
                        my $rex   = 0x40 | $rex_w | ( $did >= 8 ? 4 : 0 ) | ( $sid >= 8 ? 1 : 0 );
                        my $modrm = 0xC0 | ( ( $did & 7 ) << 3 ) | ( $sid & 7 );
                        $bytes .= pack( 'CCC', $rex, 0x3B, $modrm );
                    }
                }
                elsif ( $opcode eq 'sete' ||
                    $opcode eq 'setne' ||
                    $opcode eq 'setl'  ||
                    $opcode eq 'setg'  ||
                    $opcode eq 'setle' ||
                    $opcode eq 'setge' ||
                    $opcode eq 'setb'  ||
                    $opcode eq 'seta'  ||
                    $opcode eq 'setbe' ||
                    $opcode eq 'setae' ||
                    $opcode eq 'setp'  ||
                    $opcode eq 'setnp' ) {
                    my %cc = (
                        sete  => 0x94,
                        setne => 0x95,
                        setl  => 0x9C,
                        setg  => 0x9F,
                        setle => 0x9E,
                        setge => 0x9D,
                        setb  => 0x92,
                        seta  => 0x97,
                        setbe => 0x96,
                        setae => 0x93,
                        setp  => 0x9A,
                        setnp => 0x9B
                    );
                    my $dst_r = $resolve->($dst);
                    my $did   = $reg_id->($dst_r);

                    # Zero register first (32-bit mov reg,0 clears upper 32 on x86_64, doesn't clobber flags)
                    my $zx_rex = 0x40 | ( $did >= 8 ? 1 : 0 );
                    $bytes .= pack( 'C', $zx_rex ) if $zx_rex != 0x40;
                    $bytes .= pack( 'C', 0xB8 + ( $did & 7 ) ) . pack( 'V', 0 );
                    my $rex   = 0x40 | ( $did >= 8 ? 1 : 0 );
                    my $modrm = 0xC0 | ( $did & 7 );
                    $bytes .= pack( 'CCC', $rex, 0x0F, $cc{$opcode} ) . pack( 'C', $modrm );
                }
                elsif ( $opcode eq 'ctx_swap' ) {
                    my $ctx_r    = $resolve->($dst);       # fiber register (r12)
                    my $cid      = $reg_id->($ctx_r);
                    my $target_r = $resolve->($src);       # target FCB pointer
                    my $tid      = $reg_id->($target_r);

                    # 1. mov r11, rsp -- save current SP
                    $bytes .= pack( 'CCC', 0x4C, 0x8B, 0xDC );

                    # 2. Save callee regs to current FCB
                    my @callee = qw(rbx rbp r12 r13 r14 r15);
                    for my $off_idx ( 0 .. $#callee ) {
                        my $reg  = $callee[$off_idx];
                        my $rid  = $reg_id->($reg);
                        my $disp = $off_idx * 8;
                        my $rex  = 0x48 | ( $rid >= 8 ? 4 : 0 ) | ( $cid >= 8 ? 1 : 0 );
                        my $rm   = $cid & 7;
                        my $mod  = $disp ? 2 : 0;
                        $mod = 1 if $mod == 0 && $rm == 5;
                        my $modrm = ( $mod << 6 ) | ( ( $rid & 7 ) << 3 ) | $rm;
                        $bytes .= pack( 'C', $rex ) . pack( 'C', 0x89 );

                        if ( $rm == 4 ) {
                            $bytes .= pack( 'CC', $modrm, 0x24 );
                        }
                        else {
                            $bytes .= pack( 'C', $modrm );
                        }
                        if    ( $mod == 2 ) { $bytes .= pack( 'V', $disp ) }
                        elsif ( $mod == 1 ) { $bytes .= "\x00" }
                    }

                    # 3. Save SP (r11) at FCB[48]
                    my $rsp_off = 48;
                    my $rex_s   = 0x48 | 0x04 | ( $cid >= 8 ? 0x01 : 0 );
                    my $rm_s    = $cid & 7;
                    my $mod_s   = $rsp_off ? 2 : 0;
                    $mod_s = 1 if $mod_s == 0 && $rm_s == 5;
                    my $modrm_s = ( $mod_s << 6 ) | ( ( 0xB & 7 ) << 3 ) | $rm_s;
                    $bytes .= pack( 'C', $rex_s ) . pack( 'C', 0x89 );
                    if ( $rm_s == 4 ) { $bytes .= pack( 'CC', $modrm_s, 0x24 ) }
                    else              { $bytes .= pack( 'C', $modrm_s ) }
                    if    ( $mod_s == 2 ) { $bytes .= pack( 'V', $rsp_off ) }
                    elsif ( $mod_s == 1 ) { $bytes .= "\x00" }

                    # 4. Compute resume_pc -- LEA r10, [rip + rel] placeholder
                    my $lea_off = $current_offset->();
                    $bytes .= pack( 'C*', 0x4C, 0x8D, 0x15, 0x00, 0x00, 0x00, 0x00 );

                    # 5. Store resume_pc at FCB[64]
                    $bytes .= pack( 'C*', 0x4D, 0x89, 0x54, 0x24, 0x40 );

                    # 6. Switch fiber register to target FCB
                    my $rex_m   = 0x48 | ( $cid >= 8 ? 1 : 0 ) | ( $tid >= 8 ? 4 : 0 );
                    my $modrm_m = 0xC0 | ( ( $tid & 7 ) << 3 ) | ( $cid & 7 );
                    $bytes .= pack( 'C', $rex_m ) . pack( 'CC', 0x89, $modrm_m );

                    # 7. Load target resume_pc FIRST (before restoring r12)
                    $bytes .= pack( 'C*', 0x4D, 0x8B, 0x54, 0x24, 0x40 );

                    # 8. Restore callee regs from target FCB (rsp last -- r12 not restored,
                    #    it was set to the target FCB address in step 6 and the FCB
                    #    self-pointer at FCB[16] equals the same value, so skipping it
                    #    avoids a redundant load that clobbers the base register mid-loop)
                    my @cregs = qw(rbx rbp r12 r13 r14 r15 rsp);
                    for my $off_idx ( 0 .. $#cregs ) {
                        my $reg = $cregs[$off_idx];
                        next if $reg eq 'r12';
                        my $rid  = $reg_id->($reg);
                        my $disp = $off_idx * 8;
                        my $rex  = 0x48 | ( $rid >= 8 ? 4 : 0 ) | ( $cid >= 8 ? 1 : 0 );
                        my $rm   = $cid & 7;
                        my $mod  = $disp ? 2 : 0;
                        $mod = 1 if $mod == 0 && $rm == 5;
                        my $modrm = ( $mod << 6 ) | ( ( $rid & 7 ) << 3 ) | $rm;
                        $bytes .= pack( 'C', $rex ) . pack( 'C', 0x8B );

                        if ( $rm == 4 ) {
                            $bytes .= pack( 'CC', $modrm, 0x24 );
                        }
                        else {
                            $bytes .= pack( 'C', $modrm );
                        }
                        if    ( $mod == 2 ) { $bytes .= pack( 'V', $disp ) }
                        elsif ( $mod == 1 ) { $bytes .= "\x00" }
                    }

                    # 9. jmp r10 -- jump to target's resume_pc
                    $bytes .= pack( 'C*', 0x41, 0xFF, 0xE2 );

                    # 10. Patch LEA to point after jmp r10
                    my $after = $current_offset->();
                    my $rel   = $after - $lea_off - 7;
                    substr $bytes, $lea_off + 3, 4, pack( 'V', $rel );
                }
                elsif ( $opcode eq 'lea_func' ) {
                    my $dst_r     = $resolve->($dst);
                    my $did       = $reg_id->($dst_r);
                    my $func_name = $src->value;
                    my $rex       = 0x48 | ( $did >= 8 ? 4 : 0 );
                    my $modrm     = 0x05 | ( ( $did & 7 ) << 3 );
                    push @func_fixups, { offset => $current_offset->() + 3, type => 'lea_rel32', target => $func_name };
                    $bytes .= pack( 'C', $rex ) . pack( 'CC', 0x8D, $modrm ) . "\x00\x00\x00\x00";
                }
                elsif ( $opcode eq 'call_func' ) {
                    my $func_name = $dst->value;
                    push @func_fixups, { offset => $current_offset->(), type => 'call_rel32', target => $func_name };
                    $bytes .= pack( 'C', 0xE8 ) . "\x00\x00\x00\x00";
                }
                elsif ( $opcode eq 'call_indirect' ) {
                    my $src_r = $resolve->($src);
                    my $sid   = $reg_id->($src_r);
                    my $rex   = $sid >= 8 ? 0x41 : 0x00;
                    my $modrm = 0xD0 | ( $sid & 7 );
                    if ($rex) { $bytes .= pack( 'C', $rex ) }
                    $bytes .= pack( 'CC', 0xFF, $modrm );
                }
                elsif ( $opcode eq 'jmp_func' ) {
                    my $func_name = $dst->value;
                    push @func_fixups, { offset => $current_offset->(), type => 'jmp_func_rel32', target => $func_name };
                    $bytes .= pack( 'C', 0xE9 ) . "\x00\x00\x00\x00";
                }
                elsif ( $opcode eq 'ret' ) {
                    if ( $is_leaf && !$needs_frame ) {
                        $bytes .= pack( 'C', RET_BYTE );
                    }
                    else {
                        for my $i ( reverse 0 .. $#$used_callee ) {
                            my $reg = $used_callee->[$i];
                            my $rid = $reg_id->($reg);
                            my $off = $total_frame - $shadow_space - ( $i * 8 ) - 8;
                            my $rex = 0x48 | ( $rid >= 8 ? 4 : 0 );
                            $bytes .= pack( 'C', $rex ) . pack( 'CCCV', 0x8B, ( 2 << 6 ) | ( ( $rid & 7 ) << 3 ) | 4, 0x24, $off );
                        }
                        $bytes .= pack( 'CCC', 0x48, 0x89, 0xEC );    # mov rsp, rbp
                        $bytes .= pack( 'C',   POP_BASE + 5 );        # pop rbp
                        $bytes .= pack( 'C',   RET_BYTE );
                    }
                }
                elsif ( $opcode eq 'nop' ) {
                    $bytes .= pack( 'C', NOP_BYTE );
                }
                else {
                    die "Brocken::Jenny::Codegen::X86_64: no encoder for MIR opcode '$opcode'";
                }
            }
        }
        for my $fixup (@fixups) {
            my $target_pos = $labels{ $fixup->{target} };
            die "undefined label: $fixup->{target}" unless defined $target_pos;
            my $src_pos = $fixup->{offset};
            my $rel     = $target_pos - ( $src_pos + $fixup->{size} );
            if ( $fixup->{type} eq 'jmp_rel32' ) {
                substr $bytes, $fixup->{offset} + 1, 4, pack( 'V', $rel & 0xFFFFFFFF );
            }
            elsif ( $fixup->{type} eq 'jcc_rel32' ) {
                substr $bytes, $fixup->{offset} + 2, 4, pack( 'V', $rel & 0xFFFFFFFF );
            }
        }
        return ( $bytes, \@func_fixups );
    }

    # Opcodes this backend can encode with a memory operand as the source, so
    # a spilled source is read straight out of its slot instead of through a
    # reload into a temp. x86 folds the address into the instruction's ModRM
    # byte, so the form is free and worth having.
    method _mem_source_opcodes { [qw(add sub adc sbb and or xor cmp)] }

    method _compute_spill_frame( $mf, $stack_reg ) {
        my $max_disp = 0;
        my $found    = 0;
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                for my $op ( $inst->operands->@* ) {
                    next unless $op->kind eq 'mem';
                    my $addr = $op->value;
                    next unless defined $addr->{base} && !ref $addr->{base} && $addr->{base} eq $stack_reg;

                    # A raw displacement is already expressed relative to the
                    # stack pointer, so counting it here would both size the
                    # spill area against the outgoing argument area and
                    # double-book the space.  _compute_call_arg_frame sizes
                    # that region instead.
                    next if $addr->{raw};
                    $max_disp = List::Util::max( $max_disp, $addr->{disp} // 0 );
                    $found    = 1;
                }
            }
        }
        return $found ? ( ( $max_disp + 8 + 15 ) & ~15 ) : 0;
    }

    # Size of the outgoing argument area at the bottom of the frame, holding
    # the shadow space and any arguments that the register set could not
    # carry.  Callers write those arguments at fixed stack pointer offsets, so
    # the area has to be reserved before the call rather than pushed onto the
    # stack at the call site: that keeps the register allocator's stack
    # pointer relative spill slots valid across the call, and leaves rsp
    # 16-byte aligned as the SysV ABI requires at a call.
    method _compute_call_arg_frame( $mf, $stack_reg ) {
        my $max_disp = -1;
        for my $mbb ( $mf->blocks->@* ) {
            for my $inst ( $mbb->instructions->@* ) {
                for my $op ( $inst->operands->@* ) {
                    next unless $op->kind eq 'mem';
                    my $addr = $op->value;

                    # Only the caller's outgoing arguments occupy this area.
                    # An entry-relative load reads an incoming argument, which
                    # belongs to whoever called here, and its displacement is
                    # measured from the entry stack pointer anyway.
                    next unless $addr->{raw} && $addr->{raw} ne 'entry';
                    next unless defined $addr->{base} && !ref $addr->{base} && $addr->{base} eq $stack_reg;
                    $max_disp = List::Util::max( $max_disp, $addr->{disp} // 0 );
                }
            }
        }
        return 0 if $max_disp < 0;
        return ( $max_disp + 8 + 15 ) & ~15;
    }

    method _caller_save_base( $gp_spill, $fp_spill ) {
        my $max_off;
        for my $off ( values $gp_spill->%*, values $fp_spill->%* ) {

            # A single spill slot at offset 0 is still a spill: testing the
            # maximum for truth here reported it as "nothing spilled",
            # handed the caller-save area the same slot, and the save of a
            # caller's argument overwrote the spilled value underneath.
            $max_off = $off if !defined $max_off || $off > $max_off;
        }
        return 0 unless defined $max_off;
        return int( $max_off / 8 ) + 1;
    }
}
#
1;
