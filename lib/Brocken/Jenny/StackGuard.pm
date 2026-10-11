# Shared MIR builder for the F17 stack-overflow guards.
#
# The guards live entirely in the native codegen pipeline: Wasm frames come out of the heap bump region and keep a
# zero stack limit, so a Wasm program never carries this code. The native lowerers flag which functions need which
# piece, and these builders emit the MIR for the only two shapes either destination ever needs:
#
#   seed_entry        -- emitted into _BROCKEN_ENTRY's entry block, right after the ICB parameter is materialized.
#                        It pinches ICB.stack_limit to `stack_reg - STACK_BUDGET`, giving the main thread a 2 MiB
#                        runway below wherever its stack pointer happens to start. Runs before _init, which is why
#                        _init must not touch stack_limit again.
#
#   guard_user_function -- emitted into every other function whose first parameter is the hidden %__heap_base (all
#                        user code, never the Brocken::Runtime::* helpers that take an explicit $hb). It compares
#                        the current stack pointer against [ICB+STACK_LIMIT] and, when it has crossed the line,
#                        records ERR_STACK (6). If a try/catch handler is live it longjmps to it exactly like
#                        `throw`, so the catch block runs and sees the error through ICB.thrown_value; otherwise it
#                        returns 0 so the recursion unwinds gracefully. The check runs at the top of the body, so
#                        it fires strictly before the OS guard page regardless of backend.
#
# The comparison source is the stack register, deliberately not the frame register: leaf functions without a
# frame skip the push/mov-frame-pointer prologue on x86-64 and RISC-V, so rbp/s0 would sit pinned at the
# caller's value for the whole recursion and the guard would never fire. The stack pointer tracks depth on every
# backend for every frame shape.
#
# Every compare/branch is emitted in the target's own idiom. There is no single MIR spelling for "unsigned less
# than" or "equal to zero": x86 sets flags with cmp and materializes them with setcc, AArch64 compares then
# cset, RISC-V folds the compare into slt/sltiu. The guard is the only place shared across all three backends.
#
# The offsets come from Brocken::ICB so the field map has one home; update ICB.pm and core.brocken together.
package Brocken::Jenny::StackGuard;
use v5.42;
use feature qw[class];
no warnings qw[experimental::class portable];
use Brocken::Jenny::MIR;
use Brocken::Lindsay::IR;
use Brocken::ICB;

use constant STACK_BUDGET => 2 * 1024 * 1024;    # main-thread margin below the entry stack pointer

sub _i64 { return Brocken::Lindsay::IR::Type::i64() }
sub _ptr { return Brocken::Lindsay::IR::Type::ptr() }
sub _i1  { return Brocken::Lindsay::IR::Type::i1() }

sub _mi ( $opcode, $operands, $comment ) {
    return Brocken::Jenny::MIR::MachineInstruction->new( opcode => $opcode, operands => $operands, comment => $comment );
}
sub _phys ( $name ) {
    return Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $name );
}
sub _imm ( $value ) {
    return Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm', value => $value, type => Brocken::Lindsay::IR::Type::i64() );
}
sub _mem ( $base, $disp, $type ) {

    # Machine operands name a memory base by the virtual register's *name*, not by its operand object (see the
    # lowerers' `base => $inst->name`). The liveness pass and insert_spill_code both key spill slots off that name;
    # an operand object stringifies to its OWN identity, so it would miss the slot map and leave a spilled base
    # unreloaded. Accept either shape and store the name.
    my $name = ref $base ? $base->value : $base;
    return Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => $name, disp => $disp }, type => $type );
}
sub _vreg ( $name, $type ) {
    return Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $name, type => $type );
}
sub _label ( $name ) {
    return Brocken::Jenny::MIR::MachineOperand->new( kind => 'label', value => $name );
}

# dst = (a < b), unsigned, in the target's idiom.
sub _set_ult ( $platform, $mbb, $dst, $a, $b, $comment ) {
    if ( $platform->is_arm64 ) {
        $mbb->add_instruction( _mi( 'cmp',      [ $a, $b ], $comment ) );
        $mbb->add_instruction( _mi( 'cset_cc',  [$dst],     $comment ) );
    }
    elsif ( $platform->is_riscv64 ) {

        # RISC-V folds the unsigned compare into sltu (three-operand form: rd, rs1, rs2).
        $mbb->add_instruction( _mi( 'sltu', [ $dst, $a, $b ], $comment ) );
    }
    else {
        $mbb->add_instruction( _mi( 'cmp',  [ $a, $b ],       $comment ) );
        $mbb->add_instruction( _mi( 'mov',  [ $dst, _imm(0) ], $comment ) );
        $mbb->add_instruction( _mi( 'setb', [$dst],           $comment ) );
    }
    return 1;
}

# dst = (a == 0), in the target's idiom.
sub _set_zeq ( $platform, $mbb, $dst, $a, $comment ) {
    if ( $platform->is_arm64 ) {
        $mbb->add_instruction( _mi( 'cmp',      [ $a, _imm(0) ], $comment ) );
        $mbb->add_instruction( _mi( 'cset_eq',  [$dst],          $comment ) );
    }
    elsif ( $platform->is_riscv64 ) {

        # sltiu is in-place (rs1 == rd): copy first, then dst = (dst <u 1).
        $mbb->add_instruction( _mi( 'mv',    [ $dst, $a ],  $comment ) );
        $mbb->add_instruction( _mi( 'sltiu', [ $dst, _imm(1) ], $comment ) );
    }
    else {
        $mbb->add_instruction( _mi( 'cmp',  [ $a, _imm(0) ], $comment ) );
        $mbb->add_instruction( _mi( 'mov',  [ $dst, _imm(0) ], $comment ) );
        $mbb->add_instruction( _mi( 'sete', [$dst],          $comment ) );
    }
    return 1;
}

# Seed ICB.stack_limit for the main thread from the entry stack pointer.
sub seed_entry ( $mbb, $hb_vreg, $platform ) {
    my $ptr  = _ptr();
    my $fp   = _vreg( '%stk.entry.fp',   $ptr );
    my $seed = _vreg( '%stk.entry.seed', $ptr );
    $mbb->add_instruction( _mi( 'mov', [ $fp, _phys( $platform->stack_reg ) ],     'stk: entry stack base' ) );
    $mbb->add_instruction( _mi( 'mov', [ $seed, $fp ],                             'stk: seed = stack base' ) );
    $mbb->add_instruction( _mi( 'sub', [ $seed, _imm( STACK_BUDGET ) ],            'stk: seed -= STACK_BUDGET' ) );
    $mbb->add_instruction( _mi( 'store', [ _mem( $hb_vreg, Brocken::ICB::STACK_LIMIT, $ptr ), $seed ], 'stk: ICB.stack_limit = sp - budget' ) );
    return 1;
}

# Compare the stack pointer to ICB.stack_limit. On overflow branch to cold blocks that record ERR_STACK and either
# longjmp to a live try/catch handler or return 0. Returns the cold blocks; the caller appends them to the
# MachineFunction *after* every normal block so the entry block keeps its block[0] position (the codegen and
# regalloc treat block[0] as the function entry).
sub guard_user_function ( $mbb, $hb_vreg, $platform ) {
    my $ptr  = _ptr();
    my $i64  = _i64();
    my $fp   = _vreg( '%stk.fp',   $ptr );
    my $lim  = _vreg( '%stk.lim',  $ptr );
    my $tmp  = _vreg( '%stk.tmp',  $ptr );
    my $over = _vreg( '%stk.over', _i1() );

    $mbb->add_instruction( _mi( 'mov',  [ $fp,  _phys( $platform->stack_reg ) ],                 'stk: stack base' ) );
    $mbb->add_instruction( _mi( 'load', [ $lim, _mem( $hb_vreg, Brocken::ICB::STACK_LIMIT, $ptr ) ], 'stk: load limit' ) );
    $mbb->add_instruction( _mi( 'mov',  [ $tmp, $fp ],                                          'stk: sp' ) );
    _set_ult( $platform, $mbb, $over, $tmp, $lim, 'stk: over = sp < limit' );

    my $fail = Brocken::Jenny::MIR::MachineBasicBlock->new( name => '%stk.fail' );
    $fail->add_instruction( _mi( 'label', [ _label('%stk.fail') ], 'stk: fail' ) );

    my $err = _vreg( '%stk.err', $i64 );
    $fail->add_instruction( _mi( 'mov',   [ $err, _imm( Brocken::ICB::ERR_STACK ) ],                  'stk: ERR_STACK' ) );
    $fail->add_instruction( _mi( 'store', [ _mem( $hb_vreg, Brocken::ICB::ERR_CODE, $i64 ), $err ],    'stk: err_code = ERR_STACK' ) );

    # A live try/catch handler (ICB.exception_handler_stack != 0) wins: unwind to it like `throw` does. The record
    # of the error is already in err_code and goes into thrown_value so the catch binding can inspect it.
    my $has  = _vreg( '%stk.has',  $ptr );
    my $none = _vreg( '%stk.none', _i1() );
    $fail->add_instruction( _mi( 'load', [ $has, _mem( $hb_vreg, Brocken::ICB::EXCEPTION_HANDLER_STACK, $ptr ) ], 'stk: handler head' ) );
    _set_zeq( $platform, $fail, $none, $has, 'stk: none = handler == 0' );
    $fail->add_instruction( _mi( 'bne', [ $none, _label('%stk.graceful') ], 'stk: no handler -> graceful return' ) );

    my ( $arg0, $arg1 ) = $platform->abi->argument_locations( [ 'int', 'int' ] )->@*;
    my $jb = _vreg( '%stk.jb', $ptr );
    $fail->add_instruction( _mi( 'load',      [ $jb, _mem( $has, 8, $ptr ) ],                                     'stk: jmp_buf = handler[8]' ) );
    $fail->add_instruction( _mi( 'store',     [ _mem( $hb_vreg, Brocken::ICB::THROWN_VALUE, $i64 ), $err ],       'stk: thrown_value = ERR_STACK' ) );
    $fail->add_instruction( _mi( 'mov',       [ _phys($arg0), $jb ],                                             'stk: longjmp arg0' ) );
    $fail->add_instruction( _mi( 'mov',       [ _phys($arg1), _imm(1) ],                                         'stk: longjmp arg1' ) );
    $fail->add_instruction( _mi( 'call_func', [ Brocken::Jenny::MIR::MachineOperand->new( kind => 'func', value => 'longjmp' ) ], 'stk: longjmp' ) );
    $fail->add_instruction( _mi( 'jmp',       [ _label('%stk.graceful') ],                                       'stk: longjmp never returns' ) );

    my $grace = Brocken::Jenny::MIR::MachineBasicBlock->new( name => '%stk.graceful' );
    $grace->add_instruction( _mi( 'label', [ _label('%stk.graceful') ],                                  'stk: graceful' ) );
    $grace->add_instruction( _mi( 'mov',   [ _phys( $platform->return_register ), _imm(0) ],             'stk: return 0' ) );
    $grace->add_instruction( _mi( 'ret',   [],                                                           'stk: ret' ) );

    $mbb->add_instruction(
        _mi( 'bne', [ $over, _label('%stk.fail') ], 'stk: trap on overflow' )
    );
    return ( $fail, $grace );
}

# Seed the main fiber's stack limit inside the fiber init wrapper. The wrapper owns the per-thread ICB and the main
# fiber's FCB, so both get the same margin below the current stack pointer and the first context switch can hand the
# ICB to a child fiber without losing the main thread's limit. Also load the ICB into the first argument register,
# because the wrapper calls the real main function which takes %__heap_base (the ICB) as its register parameter.
sub seed_main_fiber_limit ( $mbb, $platform, $fcb_vreg, $icb_vreg, $fcb_limit_off ) {
    my $ptr = _ptr();
    my $sp  = _vreg( '%stk.mf.sp',  $ptr );
    my $lim = _vreg( '%stk.mf.lim', $ptr );
    $mbb->add_instruction( _mi( 'mov',   [ $sp,  _phys( $platform->stack_reg ) ],                     'stk: main stack base' ) );
    $mbb->add_instruction( _mi( 'mov',   [ $lim, $sp ],                                              'stk: limit = sp' ) );
    $mbb->add_instruction( _mi( 'sub',   [ $lim, _imm( STACK_BUDGET ) ],                             'stk: limit -= budget' ) );
    $mbb->add_instruction( _mi( 'store', [ _mem( $fcb_vreg, $fcb_limit_off, $ptr ), $lim ],          'stk: FCB.stack_limit = sp - budget' ) );
    $mbb->add_instruction( _mi( 'store', [ _mem( $icb_vreg, Brocken::ICB::STACK_LIMIT, $ptr ), $lim ], 'stk: ICB.stack_limit = sp - budget' ) );
    my ($arg0) = $platform->abi->argument_locations( ['int'] )->@*;
    $mbb->add_instruction( _mi( 'mov', [ _phys($arg0), _vreg( $icb_vreg, $ptr ) ], 'stk: param0 = ICB for _real_main' ) );
    return 1;
}

# Pin the outgoing fiber's stack limit into its own FCB, lift the incoming fiber's limit into the shared ICB, and hand
# the ICB to the incoming fiber's first function call (a freshly scheduled fiber's callee reads %__heap_base from arg
# slot 0). Emitted around every context switch so each fiber's functions compare the stack pointer against their own
# stack, not the main thread's.
sub swap_stack_limit ( $mbb, $platform, $tag, $cur_fcb, $target, $os_thread_off, $fcb_limit_off ) {
    my $ptr  = _ptr();
    my $icb  = _vreg( "%stk.$tag.icb",  $ptr );
    my $live = _vreg( "%stk.$tag.live", $ptr );
    my $tgt  = _vreg( "%stk.$tag.tgt",  $ptr );
    $mbb->add_instruction( _mi( 'load',  [ $icb,  _mem( $cur_fcb, $os_thread_off, $ptr ) ],                       'stk: ICB = FCB.os_thread' ) );
    $mbb->add_instruction( _mi( 'load',  [ $live, _mem( $icb, Brocken::ICB::STACK_LIMIT, $ptr ) ],                 'stk: live limit' ) );
    $mbb->add_instruction( _mi( 'store', [ _mem( $cur_fcb, $fcb_limit_off, $ptr ), $live ],                        'stk: persist outgoing limit' ) );
    $mbb->add_instruction( _mi( 'load',  [ $tgt,  _mem( $target, $fcb_limit_off, $ptr ) ],                         'stk: incoming limit' ) );
    $mbb->add_instruction( _mi( 'store', [ _mem( $icb, Brocken::ICB::STACK_LIMIT, $ptr ), $tgt ],                  'stk: ICB.limit = incoming limit' ) );

    # Hand the ICB to the incoming fiber's first function so a guarded fresh fiber reads %__heap_base from arg slot 0.
    # On ABIs where the return register *is* arg0 (AArch64 x0, RISC-V a0) this would clobber the fiber transfer value,
    # which lives in the return register across ctx_swap (ctx_swap only saves callee-saved regs, so the value survives
    # the jump and the resumed side reads it back from the return register). There the transfer value wins: skipping
    # the handoff leaves the pre-existing fresh-fiber %__heap_base behaviour untouched while the stack_limit swap
    # above still lands correctly. x86-64 puts arg0 in rcx/rdi, distinct from rax, so it emits the handoff.
    my ($arg0) = $platform->abi->argument_locations( ['int'] )->@*;
    my $ret    = $platform->abi->return_register;
    if ( !defined $ret || $arg0 ne $ret ) {
        $mbb->add_instruction( _mi( 'mov', [ _phys($arg0), $icb ], 'stk: param0 = ICB' ) );
    }
    return 1;
}

1;
