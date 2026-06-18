use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'compute_unified_frame' => sub {
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    is $alloc->compute_unified_frame( 0,  0,  0 ),  0,   'zero frame';
    is $alloc->compute_unified_frame( 2,  0,  0 ),  16,  'two callee saves (16 bytes) rounded to 16';
    is $alloc->compute_unified_frame( 1,  8,  0 ),  16,  'one callee save + 8 spill = 16';
    is $alloc->compute_unified_frame( 0,  0,  8 ),  16,  '8 caller-save -> rounded to 16';
    is $alloc->compute_unified_frame( 2,  4,  0 ),  32,  '16 callee + 4 spill = 20 -> 32';
    is $alloc->compute_unified_frame( 1,  1,  0 ),  16,  '8 callee + 1 spill = 9 -> 16';
    is $alloc->compute_unified_frame( 10, 10, 10 ), 112, '80+10+10=100 -> 112';
};
subtest 'insert_caller_save_code_integer' => sub {
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    my $mf    = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb    = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $vreg_a      = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%a' );
    my $imm_1       = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm',      value => 1 );
    my $call_target = Brocken::Jenny::MIR::MachineOperand->new( kind => 'func',     value => 'helper' );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add',       operands => [ $vreg_a, $imm_1 ] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'call_func', operands => [$call_target] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret',       operands => [] ) );
    $alloc->insert_caller_save_code( $mf, [ 'rax', 'rcx', 'rdx' ], 'rsp', 0 );
    my @insts = $bb->instructions->@*;
    is scalar(@insts),     9,                    'added 6 save/restore instructions around call_func (3 regs * 2)';
    is $insts[1]->opcode,  'store',              'save before call is store';
    is $insts[1]->comment, 'caller-save rax',    'store comment for rax';
    is $insts[2]->opcode,  'store',              'second save';
    is $insts[2]->comment, 'caller-save rcx',    'store comment for rcx';
    is $insts[3]->opcode,  'store',              'third save';
    is $insts[3]->comment, 'caller-save rdx',    'store comment for rdx';
    is $insts[4]->opcode,  'call_func',          'call in middle';
    is $insts[5]->opcode,  'load',               'first restore after call is load';
    is $insts[5]->comment, 'caller-restore rdx', 'restore comment first is rdx (reverse)';
    is $insts[6]->opcode,  'load',               'second restore';
    is $insts[6]->comment, 'caller-restore rcx', 'restore comment second is rcx';
    is $insts[7]->opcode,  'load',               'third restore';
    is $insts[7]->comment, 'caller-restore rax', 'restore comment third is rax';
    ok $insts[1]->operands->[0]->kind eq 'mem',      'store has mem operand';
    ok $insts[5]->operands->[0]->kind eq 'phys_reg', 'load dest is phys_reg';
    is $insts[5]->operands->[0]->value, 'rdx', 'first restored reg is rdx (last saved, first restored)';
};
subtest 'insert_caller_save_code_float' => sub {
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    my $mf    = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb    = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $call_target = Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'helper' );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'call_func', operands => [$call_target] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret',       operands => [] ) );
    $alloc->insert_caller_save_code( $mf, [ 'xmm0', 'xmm1' ], 'rsp', 1 );
    my @insts = $bb->instructions->@*;
    is scalar(@insts),    6,           'added 4 fsave/frestore around call (2 regs * 2)';
    is $insts[0]->opcode, 'fstore',    'float save uses fstore';
    is $insts[1]->opcode, 'fstore',    'second float save';
    is $insts[2]->opcode, 'call_func', 'call in middle';
    is $insts[3]->opcode, 'fload',     'float restore uses fload';
    is $insts[4]->opcode, 'fload',     'second float restore';
    is $insts[5]->opcode, 'ret',       'ret preserved';
};
subtest 'insert_caller_save_code_no_call' => sub {
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    my $mf    = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb    = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    $alloc->insert_caller_save_code( $mf, ['rax'], 'rsp', 0 );
    is scalar( $bb->instructions->@* ), 1, 'no call -> no save/restore inserted';
};
subtest 'insert_caller_save_code_multi_block' => sub {
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    my $mf    = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb1   = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'b1' );
    my $bb2   = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'b2' );
    $mf->add_block($bb1);
    $mf->add_block($bb2);
    $bb1->add_successor($bb2);
    my $call_target = Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'helper' );
    $bb1->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'call_func', operands => [$call_target] ) );
    $bb1->add_instruction(
        Brocken::Jenny::MIR::MachineInstruction->new(
            opcode   => 'jmp',
            operands => [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => 'b2' ) ]
        )
    );
    $bb2->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    $alloc->insert_caller_save_code( $mf, [ 'rax', 'rcx' ], 'rsp', 0 );
    my @b1 = $bb1->instructions->@*;
    is scalar(@b1),                      6,           'b1: call + 4 save/restore + jmp';
    is $b1[0]->opcode,                   'store',     'b1 save store';
    is $b1[1]->opcode,                   'store',     'b1 second save';
    is $b1[2]->opcode,                   'call_func', 'b1 call in middle';
    is $b1[3]->opcode,                   'load',      'b1 restore load';
    is $b1[4]->opcode,                   'load',      'b1 second restore';
    is $b1[5]->opcode,                   'jmp',       'b1 jmp unchanged';
    is scalar( $bb2->instructions->@* ), 1,           'b2 unchanged (no call)';
};
subtest 'remove_redundant_moves' => sub {
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    my $mf    = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb    = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $vreg_a = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%a' );
    my $vreg_b = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%b' );
    my $vreg_c = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%c' );
    my $imm_1  = Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm',      value => 1 );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add', operands => [ $vreg_a, $imm_1 ] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $vreg_b, $vreg_a ] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $vreg_c, $vreg_b ] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    my %assignment = ( '%a' => 'rax', '%b' => 'rax', '%c' => 'rbx' );
    $alloc->remove_redundant_moves( $mf, \%assignment );
    my @insts = $bb->instructions->@*;
    is scalar(@insts),                  3,     'removed one redundant mov (%b = %a, both mapped to rax)';
    is $insts[0]->opcode,               'add', 'add preserved';
    is $insts[1]->opcode,               'mov', 'non-redundant mov (%c = %b, rax vs rbx) preserved';
    is $insts[2]->opcode,               'ret', 'ret preserved';
    is $insts[1]->operands->[1]->value, '%b',  'non-redundant mov still references %b';
};
subtest 'remove_redundant_moves_all_redundant' => sub {
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    my $mf    = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb    = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $vreg_a = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%a' );
    my $vreg_b = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%b' );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $vreg_b, $vreg_a ] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    my %assignment = ( '%a' => 'rax', '%b' => 'rax' );
    $alloc->remove_redundant_moves( $mf, \%assignment );
    is scalar( $bb->instructions->@* ), 1,     'single redundant mov removed entirely';
    is $bb->instructions->[0]->opcode,  'ret', 'only ret remains';
};
subtest 'remove_redundant_moves_no_assignment' => sub {
    my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new();
    my $mf    = Brocken::Jenny::MIR::MachineFunction->new( name => 'test', frame_size => 0 );
    my $bb    = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    my $vreg_a = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%a' );
    my $vreg_b = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%b' );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'mov', operands => [ $vreg_b, $vreg_a ] ) );
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    my %assignment = ( '%a' => 'rax' );
    $alloc->remove_redundant_moves( $mf, \%assignment );
    is scalar( $bb->instructions->@* ), 2,     'mov preserved when %b has no assignment';
    is $bb->instructions->[0]->opcode,  'mov', 'mov not removed';
};
subtest 'x86_64 leaf vs non-leaf prologue' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu');
    my $codegen  = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );

    # Build a leaf MIR function (no call_func) with callee-save regs pre-assigned
    # We call _encode directly with non-empty used_callee to force callee-save path
    my $mf_leaf = Brocken::Jenny::MIR::MachineFunction->new( name => 'leaf', frame_size => 0 );
    my $bb_l    = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf_leaf->add_block($bb_l);
    my $v_a = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%a' );
    my $v_b = Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%b' );
    $bb_l->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add', operands => [ $v_a, $v_b ] ) );
    $bb_l->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ) );
    my %assign_leaf = ( '%a' => 'rbx', '%b' => 'r12' );
    my ($leaf_bytes) = $codegen->_encode( $mf_leaf, \%assign_leaf, [ 'rbx', 'r12' ] );

    # Build a non-leaf MIR function (has call_func) with same callee-save regs
    my $mf_non = Brocken::Jenny::MIR::MachineFunction->new( name => 'nonleaf', frame_size => 0 );
    my $bb_n   = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf_non->add_block($bb_n);
    my $func_target = Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'helper' );
    $bb_n->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'add',       operands => [ $v_a, $v_b ] ) );
    $bb_n->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'call_func', operands => [$func_target] ) );
    $bb_n->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret',       operands => [] ) );
    my %assign_non = ( '%a' => 'rbx', '%b' => 'r12' );
    my ($nonleaf_bytes) = $codegen->_encode( $mf_non, \%assign_non, [ 'rbx', 'r12' ] );
    ok( length($leaf_bytes) > 0,    'leaf generated bytes' );
    ok( length($nonleaf_bytes) > 0, 'nonleaf generated bytes' );

    # Leaf prologue: sub rsp, N then mov [rsp+off], reg  (no PUSH)
    # Encoding: 48 81 EC <N as i32>  (sub rsp, N)
    # Then: 48 89 24 24 <off>  (mov [rsp+off], rbx)
    # Then: 49 89 64 24 <off>  (mov [rsp+off], r12) with REX.B
    my $leaf_pro = substr( $leaf_bytes, 0, 3 );
    is( $leaf_pro, pack( 'CCC', 0x48, 0x81, 0xEC ), 'leaf pro: sub rsp, imm32' );

    # Non-leaf prologue: PUSH rbx (0x53), PUSH r12 (0x41 0x54)
    my $non_pro = unpack 'C', substr( $nonleaf_bytes, 0, 1 );
    is( $non_pro, 0x53, 'non-leaf pro: PUSH rbx' );

    # Both end with RET (0xC3)
    ok( unpack( 'C', substr( $leaf_bytes,    -1, 1 ) ) == 0xC3, 'leaf ends with RET' );
    ok( unpack( 'C', substr( $nonleaf_bytes, -1, 1 ) ) == 0xC3, 'non-leaf ends with RET' );

    # Leaf epilogue pre-ret: mov reg, [rsp+off] (0x8B) then add rsp (0x48 0x81 0xC4)
    # Non-leaf epilogue pre-ret: POP (0x5B or 0x41 0x5C)
    my $non_pre_ret = unpack 'C', substr( $nonleaf_bytes, -2, 1 );
    ok( $non_pre_ret == 0x5B || $non_pre_ret == 0x41, 'non-leaf pre-ret is POP rbx or REX.B' );

    # Verify no POP in leaf bytes (0x58-0x5F standalone)
    my $found_pop_leaf = 0;
    for my $i ( 0 .. length($leaf_bytes) - 1 ) {
        my $b = unpack 'C', substr( $leaf_bytes, $i, 1 );
        if ( $b >= 0x58 && $b <= 0x5F ) { $found_pop_leaf = 1 }
    }
    ok( !$found_pop_leaf, 'leaf function has no standalone POP bytes' );
};
subtest 'leaf function runtime correctness' => sub {
    my $platform = Brocken::Katsuro::Platform::parse();
SKIP: {
        skip 'Only for x86_64 native', 3 unless $platform->is_x64 && $platform->is_native;
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'leaf_test', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my @vars;
        for my $i ( 1 .. 14 ) {
            my $v = $builder->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => $i ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ),
                "%v$i"
            );
            push @vars, $v;
        }
        my $sum = $vars[0];
        for my $i ( 1 .. 13 ) {
            $sum = $builder->build_add( $sum, $vars[$i], "%s$i" );
        }
        $builder->build_ret($sum);
        my $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes   = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'leaf runtime test generated bytes' );
        my $linker      = $platform->is_macos  ? Brocken::Jenny::Linker::MachO->new() :
                          $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                                                  Brocken::Jenny::Linker::ELF64->new();
        my $output_file = 'leaf_test' . $platform->bin_ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -f $output_file, 'leaf test executable exists' ) or do { unlink $output_file if -f $output_file; skip 'no binary', 0 };
        run_exec( $output_file, expected_exit => 105, platform => $platform, keep => 1,
            name => 'leaf function returned sum of 1..14 = 105' );
        unlink $output_file;
    }
};
done_testing;
