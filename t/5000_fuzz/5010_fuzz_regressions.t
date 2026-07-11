use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Fuzz;
no warnings qw[experimental::class];

# Regression tests for bugs found by the fuzzer.
# Each test is a specific Brocken program that triggered a miscompilation.
# Keep these as standalone programs so they remain valid regression tests
# even if the fuzzer's internal logic changes.
sub test_prog {
    my ( $name, $source, $expected ) = @_;
    my $fuzz   = Brocken::Fuzz->new();
    my $result = $fuzz->test_program( { source => $source, expected => $expected } );
    ok $result->{status} eq 'pass', $name or diag "FAIL: $result->{reason}\nSource:\n$source";
}

# Bug: signed div/rem used unsigned DIV (IDIV missing).
#   - / and % with negative operands computed wrong results.
#   - Fix: added sdiv MIR opcode emitting CQO + IDIV.
#   - Fuzzer seed 42, program ~#10.
subtest 'signed division regressions' => sub {
    test_prog( 'neg / neg => pos', <<'PROG', 8 );
my i64 $v = -8;
$v = $v / -1;
return $v;
PROG
    test_prog( 'pos / neg => neg', <<'PROG', -21 );
my i64 $v = 42;
$v = $v / -2;
return $v;
PROG
    test_prog( 'neg / pos => neg', <<'PROG', -21 );
my i64 $v = -42;
$v = $v / 2;
return $v;
PROG
    test_prog( 'neg / neg => pos (large)', <<'PROG', 4 );
my i64 $v = -100;
$v = $v / -25;
return $v;
PROG
    test_prog( 'zero / neg => zero', <<'PROG', 0 );
my i64 $v = 0;
$v = $v / -42;
return $v;
PROG
};
subtest 'signed remainder regressions' => sub {
    test_prog( 'neg % neg => zero', <<'PROG', 0 );
my i64 $v = -84;
$v = $v % -84;
return $v;
PROG
    test_prog( 'pos % pos => pos remainder', <<'PROG', 2 );
my i64 $v1 = 100;
my i64 $v2 = 7;
$v1 = $v1 % $v2;
return $v1;
PROG
    test_prog( 'neg % pos => neg remainder', <<'PROG', -2 );
my i64 $v = -42;
$v = $v % 5;
return $v;
PROG
    test_prog( 'pos % neg => pos remainder', <<'PROG', 2 );
my i64 $v = 42;
$v = $v % -5;
return $v;
PROG
    test_prog( 'neg % neg => neg remainder', <<'PROG', -2 );
my i64 $v = -42;
$v = $v % -5;
return $v;
PROG
};

# Bug: div/rem chain with mixed signs (fuzzer seed 42, program ~#10).
#   The program computed: v3/v1 where v3=8 and v1=-1, expected -8.
#   Unsigned DIV gave 0, signed IDIV gives -8.
subtest 'mixed-sign div/rem chain (seed 42 reproduction)' => sub {
    test_prog( 'signed div chain', <<'PROG', 17 );
my i64 $v1 = -9;
my i64 $v2 = 56;
my i64 $v3 = 91;
$v2 = $v3 - $v3;
$v2 = $v3 / $v3;
$v1 = $v2 ^ $v1;
$v1 = -$v3;
$v1 = $v1 ^ $v2;
$v3 = -$v1;
$v3 = $v1 ^ $v3;
$v1 = -$v2;
$v2 = $v3 / $v1;
$v3 = $v2 / $v3;
$v3 = $v2 * $v3;
$v2 = $v3 - $v2;
$v3 = $v2 | $v3;
$v3 = $v1 * $v2;
$v2 = $v2 / $v1;
$v3 = $v1 - $v2;
$v1 = $v2 - $v1;
return $v1;
PROG
};

# Bug: fuzzer's _eval_i64 lacked 'use integer', so bitwise ops on negative
#   values gave wrong expected values.  The compiler was actually correct,
#   but the fuzzer mispredicted.  Still, guard against regressions where
#   the compiler gets bitwise ops wrong on negative values.
subtest 'bitwise ops with negatives (fuzzer expected-value fix)' => sub {
    test_prog( '-78 & -78 = -78', <<'PROG', -78 );
my i64 $v = -78;
$v = $v & $v;
return $v;
PROG
    test_prog( '-78 | -78 = -78', <<'PROG', -78 );
my i64 $v = -78;
$v = $v | $v;
return $v;
PROG
    test_prog( '-78 ^ -78 = 0', <<'PROG', 0 );
my i64 $v = -78;
$v = $v ^ $v;
return $v;
PROG
    test_prog( '-78 & 1 = 0', <<'PROG', 0 );
my i64 $v1 = -78;
my i64 $v2 = 1;
$v1 = $v1 & $v2;
return $v1;
PROG
};

# Bug: udiv/sdiv codegen clobbers RAX and RDX internally (MOV RAX,dst;
# XOR RDX,RDX / CQO; DIV/IDIV src; MOV dst,RAX) without the register
# allocator knowing about it.  If the allocator assigned a live virtual
# register to RAX or RDX, its value would be silently corrupted.
# Fix: exclude RAX and RDX from allocation when udiv/sdiv/umulh/div128_64
# are present in the function.
subtest 'register clobber (rax/rdx) regressions' => sub {

    # Simple case: v2 is used both as divisor and as return value.
    # If v2 gets allocated to RAX or RDX, the division clobbers it.
    test_prog( 'divisor and return are same variable', <<'PROG', 3 );
my i64 $v1 = 40;
my i64 $v2 = 3;
$v1 = $v1 % $v2;
return $v2;
PROG

    # Many live values across a division to exhaust registers, forcing
    # some value into RAX or RDX before the fix.  All values must survive.
    test_prog( 'many live values across division', <<'PROG', 78 );
my i64 $a = 1;
my i64 $b = 2;
my i64 $c = 3;
my i64 $d = 4;
my i64 $e = 5;
my i64 $f = 6;
my i64 $g = 7;
my i64 $h = 8;
my i64 $i = 9;
my i64 $j = 10;
my i64 $k = 11;
my i64 $l = 12;
my i64 $m = 13;
$j = $j / $k;
return $c + $d + $e + $f + $g + $h + $i + $j + $k + $l + $m;
PROG

    # Division/modulo chain from fuzzer seed 42 where the return value is
    # a variable that also appears as a division operand.
    test_prog( 'div/rem chain with reused variable', <<'PROG', 60 );
my i64 $v1 = -6;
my i64 $v2 = -68;
my i64 $v3 = -64;
my i64 $v4 = 60;
$v3 = $v2 % $v3;
return $v4;
PROG
};

# Bug: shift opcode codegen (shl/lshr/ashr) uses %cl for the shift count
# inline (MOV src->ecx; SHL dst,%cl) without the register allocator
# knowing. If the allocator assigned a live virtual register to rcx,
# its value would be silently corrupted by the MOV to ecx. This is
# the same class of bug as the rax/rdx clobber for div.
# Fix: exclude rcx from allocation when shl/lshr/ashr are present.
subtest 'register clobber (rcx) regressions' => sub {

    # Many live values across a shift to exhaust registers, forcing
    # some value into rcx before the fix. Return $h=8 which must
    # survive the shift.
    test_prog( 'many live values across shift', <<'PROG', 8 );
my i64 $a = 1;
my i64 $b = 2;
my i64 $c = 3;
my i64 $d = 4;
my i64 $e = 5;
my i64 $f = 6;
my i64 $g = 7;
my i64 $h = 8;
my i64 $i = 9;
my i64 $j = 10;
my i64 $k = 11;
my i64 $l = 12;
my i64 $m = 13;
my i64 $n = 14;
$j = $j << $i;
return $h;
PROG

    # Shift right with variable count, from fuzzer seed 1943945120.
    test_prog( 'ashr with many live values', <<'PROG', 8 );
my i64 $v1 = 4;
my i64 $v2 = -64;
my i64 $v3 = 0;
my i64 $v4 = 73;
my i64 $v5 = 8;
my i64 $v6 = -40;
$v6 = $v6 & $v3;
$v2 = $v5 - $v2;
if ($v3 != $v2) {
    $v6 = $v4 | $v2;
} else {
    $v6 = $v4 * $v6;
}
if ($v4 != $v4) {
    $v1 = $v4 << $v1;
} else {
    $v1 = $v4 | $v2;
}
$v2 = $v3 << $v3;
if ($v3 > $v1) {
    $v1 = $v1 << $v2;
} else {
    $v1 = $v3 & $v4;
}
$v3 = $v6 << $v2;
$v3 = $v2 & $v5;
$v6 = $v6 | $v1;
$v1 = $v6 - $v1;
$v6 = -$v2;
return $v5;
PROG

    # Shifts with multiple live ranges - return value is never shifted.
    test_prog( 'return value untouhed by shift chain', <<'PROG', 42 );
my i64 $a = 1;
my i64 $b = 2;
my i64 $c = 3;
my i64 $d = 4;
my i64 $e = 5;
my i64 $f = 6;
my i64 $g = 7;
my i64 $h = 8;
my i64 $i = 42;
$b = $a << $b;
$c = $c >> $d;
$e = $f << $a;
$h = $g >> $a;
return $i;
PROG
};

# Bug: mixed-sign-width division/comparison (fuzzer seed 20260705, case #7).
#   RISC-V backend used 64-bit DIV for signed division on <64-bit types and
#   zero-extended u32 values via LWU in signed slt comparisons.  This program
#   has u64 LHS and i64 RHS with negative values, exercising the cross-type
#   eval and codegen paths.
#   Fix: DIVW/MULW for <64-bit signed types; movsx before slt for signed cmp.
subtest 'mixed-sign-width div/cmp (seed 20260705 case 7)' => sub {
    test_prog( 'u64|i64 mixed ops with negatives', <<'PROG', 255 );
my u64 $v1 = 1116444021;
my i64 $v2 = -3;
$v1 = $v2 | $v2;
if ($v2 < $v2) {
    $v2 = $v1 + $v2;
} else {
    $v2 = $v1 ^ $v2;
}
$v1 = -$v1;
$v2 = $v2 - $v1;
if ($v1 != $v2) {
    $v2 = $v1 | $v2;
} else {
    $v2 = $v1 * $v2;
}
$v2 = $v2 >> $v1;
$v1 = $v1 * $v2;
$v1 = $v2 | $v2;
$v2 = $v2 | $v2;
$v1 = $v2 | $v1;
$v2 = $v2 / $v2;
$v2 = $v1 | $v2;
$v2 = $v2 | $v2;
return $v2;
PROG
};

# Bug: i128 negation produced wrong value on ARM64 (and RISCV64)
#   The 64-bit `neg` handler (0 - val) was used instead of 128-bit
#   negation with borrow propagation (subs lo, 0, val; sbc hi, 0, val).
#   Fix: added i128 dispatch in the `neg` handler for both ARM64 and RISCV64.
subtest 'i128 negation (arm64/riscv64 fix)' => sub {
    test_prog( 'neg -50 => 50', <<'PROG', 50 );
use feature 'brocken_native_types';
my i128 $v = -50;
$v = -$v;
return $v;
PROG
    test_prog( 'neg -1 => 1', <<'PROG', 1 );
use feature 'brocken_native_types';
my i128 $v = -1;
$v = -$v;
return $v;
PROG
    test_prog( 'neg 42 => -42 masked', <<'PROG', 214 );
use feature 'brocken_native_types';
my i128 $v = 42;
$v = -$v;
return $v;
PROG
};

# Bug: int→int constant widening created zext/sext instructions with `imm`
#   operands, causing ARM64 codegen crash in `$resolve` (line 521).
#   Fix: fold constants in `maybe_convert_type` before creating zext/sext.
subtest 'int-to-int constant widening (all backends)' => sub {
    test_prog( 'u32 const widened to u128 for AND', <<'PROG', 73 );
use feature 'brocken_native_types';
my u128 $v1 = 77;
my u32 $v2 = 89;
$v2 = $v1 & $v2;
return $v2;
PROG
};

# Bug: same constant-widening crash triggered by mixed f64/i128 operations
#   where the int→float or float→int constant folding happens, preventing
#   zext/sext of intermediate constants from reaching the backend.
subtest 'mixed f64/i128 with constants (all backends)' => sub {
    test_prog( 'f64 / i128 constant => i64', <<'PROG', 0 );
use feature 'brocken_native_types';
my i128 $v1 = 90;
my f64 $v2 = 87.0;
$v1 = $v2 / $v1;
my i64 $r = $v1;
return $r;
PROG
};

# Bug: binop with LHS narrower than RHS (e.g. u32 - u128) produced mixed-type
#   IR. The backend checked only the result type (from LHS) for i128 detection.
#   A u128 operand split into _lo/_hi registers was referenced by its unsplit
#   name in the non-i128 code path, getting an undefined register (value 0).
#   Fix: promote the narrower operand to match the wider type in lower_binop.
subtest 'narrow-LHS wide-RHS binop type promotion (all backends)' => sub {
    test_prog( 'u32 - u128', <<'PROG', 12 );
use feature 'brocken_native_types';
my u128 $v1 = 77;
my u32 $v2 = 89;
$v2 = $v2 - $v1;
return $v2;
PROG
    test_prog( 'u32 + u128', <<'PROG', 166 );
use feature 'brocken_native_types';
my u128 $v1 = 77;
my u32 $v2 = 89;
$v2 = $v2 + $v1;
return $v2;
PROG
    test_prog( 'u32 & u128', <<'PROG', 73 );
use feature 'brocken_native_types';
my u128 $v1 = 77;
my u32 $v2 = 89;
$v2 = $v2 & $v1;
return $v2;
PROG
    test_prog( 'u32 | u128', <<'PROG', 93 );
use feature 'brocken_native_types';
my u128 $v1 = 77;
my u32 $v2 = 89;
$v2 = $v2 | $v1;
return $v2;
PROG
    test_prog( 'u32 ^ u128', <<'PROG', 20 );
use feature 'brocken_native_types';
my u128 $v1 = 77;
my u32 $v2 = 89;
$v2 = $v2 ^ $v1;
return $v2;
PROG
};

# Bug: _gen_while could corrupt $vars when returning { code => undef }
# after detecting a non-terminating loop. The simulation ran body closures
# that modified $vars, but $vars was not restored when the loop was skipped.
# Subsequent statements computed expected values against corrupted state.
# Fix: save/restore $vars in _gen_while before/after simulation.
subtest 'ghost while loop does not corrupt fuzzer state' => sub {
    my $f = Brocken::Fuzz->new( seed => 20260705 );

    # Case 10 with this seed triggered a ghost while loop. Before the fix,
    # the corrupted $vars caused expected=18 (wrong). Correct expected is
    # 238 (= 2205418478 & 0xFF).
    my $result = $f->run_case( 10, 10, 4 );
    ok $result->{status} eq 'pass', 'case 10 passes (expected=238)' or diag "got $result->{status}: $result->{reason}";
};

# Bug: _eval_i64_typed returned $lv for unsigned % signed_negative when RHS
# is wider, but the compiler promotes the narrow LHS to the wider signed type
# and does a signed remainder.  Same issue in _eval_cmp_typed for comparisons.
# Fix: width-guard in both methods -- when RHS is wider, do a signed op/comparison;
# otherwise (RHS same/narrower) treat the negative RHS as huge unsigned.
subtest 'unsigned LHS vs wider signed RHS (div/rem/cmp)' => sub {

    # u8 % i64: compiler promotes u8 to i64 (zext), does signed remainder.
    # 50 % (-5) = 0.
    test_prog( 'u8 % i64 (50 % -5)', <<'PROG', 0 );
my u8 $v1 = 50;
my i64 $v2 = -5;
$v2 = $v1 % $v2;
return $v2;
PROG

    # u8 / i64: 50 / (-5) = -10, exit code -10 & 0xFF = 246.
    test_prog( 'u8 / i64 (50 / -5)', <<'PROG', 246 );
my u8 $v1 = 50;
my i64 $v2 = -5;
$v2 = $v1 / $v2;
return $v2;
PROG

    # u8 <= i64(-5): signed comparison, 50 <= -5 is FALSE.
    test_prog( 'u8 <= i64 (50 <= -5=F)', <<'PROG', 3 );
my u8 $v1 = 50;
my i64 $v2 = -5;
if ($v1 <= $v2) { return 2; } else { return 3; }
PROG

    # u64 % i8(-5): LHS wider, compiler promotes i8 to u64 (unsigned).
    # 50 % (2^64-5) = 50 (since 50 < huge).
    test_prog( 'u64 % i8 (50 % -5, LHS wider)', <<'PROG', 50 );
my u64 $v1 = 50;
my i8 $v2 = -5;
$v2 = $v1 % $v2;
return $v2;
PROG

    # u16 % i64(-3): 50000 % (-3) signed = 50000 - (-16556)*(-3) = 2.
    test_prog( 'u16 % i64 (50000 % -3)', <<'PROG', 2 );
my u16 $v1 = 50000;
my i64 $v2 = -3;
$v2 = $v1 % $v2;
return $v2;
PROG
};

# Bug: _clamp_to_type for i1 used $val ? 1 : 0 (returning 1 for any non-zero
#   value instead of only bit 0). This caused mismatches with the compiler's
#   maybe_convert_type which masks to bit 0 (AND with 1) for narrowing to i1.
#   Fix: use $val & 1 to match compiler narrowing behavior.
subtest 'clamp_to_type i1 bool range' => sub {
    my $f = Brocken::Fuzz->new( seed => 1 );
    is $f->_clamp_to_type( 0,   1, 1 ), 0, 'i1 clamp: 0 => 0';
    is $f->_clamp_to_type( 1,   1, 1 ), 1, 'i1 clamp: 1 => 1';
    is $f->_clamp_to_type( 42,  1, 1 ), 0, 'i1 clamp: 42 => 0 (bit 0)';
    is $f->_clamp_to_type( 174, 1, 1 ), 0, 'i1 clamp: 174 => 0 (bit 0)';
    is $f->_clamp_to_type( 255, 1, 1 ), 1, 'i1 clamp: 255 => 1 (bit 0)';
    is $f->_clamp_to_type( -5,  1, 1 ), 1, 'i1 clamp: -5 => 1 (bit 0)';
};

# Bug: _clamp_to_type for f64 returned the raw Perl value without forcing
#   float conversion (missing sitofp semantics). When an int operation result
#   was stored to an f64 variable, the simulation kept a Perl int while the
#   compiler did sitofp conversion. If the f64 variable was later read as an
#   int (via fptosi), the simulation used the raw int instead of the float-
#   rounded value.
#   Fix: return 0.0 + $val for f64 destinations to force float promotion.
subtest 'clamp_to_type f64 forces float conversion' => sub {
    my $f = Brocken::Fuzz->new( seed => 1 );
    is $f->_clamp_to_type(  13,  64, 'f' ),  13.0,  'f64 clamp: int 13 stays 13.0';
    is $f->_clamp_to_type(  0,   64, 'f' ),  0.0,   'f64 clamp: int 0 stays 0.0';
    is $f->_clamp_to_type( -123, 64, 'f' ), -123.0, 'f64 clamp: int -123 stays';
    test_prog( 'u64 OR to f64, returned via fptosi', <<'PROG', 13 );
my f64 $v1 = 0.0;
my u64 $v2 = 13;
$v1 = $v2 | $v2;
my i64 $r = $v1;
return $r;
PROG
    test_prog( 'int neg stored to f64, read back as int', <<'PROG', 123 );
my i64 $v1 = -123;
my f64 $v2 = 0.0;
$v2 = -$v1;
my i64 $r = $v2;
return $r;
PROG
    test_prog( 'cmp result stored to f64, read back as int', <<'PROG', 1 );
my i64 $v1 = 10;
my i64 $v2 = 20;
my f64 $v3 = 0.0;
$v3 = $v1 < $v2;
my i64 $r = $v3;
return $r;
PROG
};

# Bug: AMD Zen 4 erratum workaround in fmov_gp2f stored to [rsp+0x20],
#   which collided with $v2's alloca at the same offset. The else-branch
#   assignment $v3 = 0.0 wrote 0 through $v2's alloca, making the
#   subsequent $v2 % $v2 compute 0 / 0 → SIGFPE.
#   Fix: use RAX as intermediary instead of stack scratch.
#   Fuzzer seed 20260705, case 6.
subtest 'fmov_gp2f scratch slot no longer clobbers variable alloca' => sub {
    test_prog( '$v3=0 else-branch no longer kills $v2', <<'PROG', 0 );
my u16 $v1 = 88;
my i64 $v2 = -35;
my f64 $v3 = 85.0;
$v2 = $v1 - $v2;
$v1 = $v3;
$v1 = $v3 - $v1;
$v3 = -$v2;
$v1 = $v1 | $v2;
if ($v1 != $v1 || $v1 < $v2) {
    $v3 = 1;
} else {
    $v3 = 0;
}
$v3 = -$v2;
$v1 = $v2 % $v2;
return $v1;
PROG
};

# Bug: int->int narrowing missing in maybe_convert_type (Lowerer.pm).
#   When a wider int result (e.g. i16 from ^) was assigned to a narrower
#   variable (e.g. bool/i1), no truncation/masking was applied. The full
#   low byte was stored to the alloca (e.g. 0xD1 from i16(-47)=0xFFD1),
#   and on reload + zext the value became 209 instead of 1, causing wrong
#   comparison results.
#   Fix: added AND mask in maybe_convert_type for val->bits > target->bits.
#   Fuzzer seed 20260705, case 10.
subtest 'int->int narrowing in maybe_convert_type (seed 20260705 case 10)' => sub {
    test_prog( 'i16^u8 to bool then f64 cmp', <<'PROG', 175 );
my i64 $v1 = -99;
my bool $v2 = true;
my i16 $v3 = 9;
my i8 $v4 = -40;
if ($v3 > $v3) {
    $v2 = $v2 / $v2;
} else {
    $v2 = $v1 & $v2;
}
$v2 = $v3 ^ $v4;
if ($v2 >= $v3) {
    $v1 = $v4 | $v2;
} else {
    $v1 = $v3 + $v1;
}
$v1 = $v1 ^ $v3;
$v2 = $v2 & $v1;
$v4 = $v1 - $v1;
return $v1;
PROG
};

# Bug: sub call return type widening — sub adder() -> i128 returns $p3 (i32=61)
#   but compiled binary returns 0 instead of 61. The fuzzer simulation correctly
#   predicts 61, so this is a compiler codegen bug, likely involving mixed-width
#   parameter/return types or stack frame interference from the f64→i128 fptosi
#   that follows the call.
#   Fuzzer seed 20260705, case 73.
# NOTE: expected value set to 0 (current buggy output). Correct expected is 61.
subtest 'i128 sub return with i32 return_var (Fuzz #73)' => sub {
    test_prog( 'fptosi + neg + call', <<'PROG', 61 );
use feature 'brocken_native_types';
sub adder(i64 $p1, i32 $p2, i32 $p3) -> i128 {
    return $p3;
}
my i32 $v1 = 61;
my u8 $v2 = 236;
my f64 $v3 = 4.0;
my i128 $v5 = 88;
$v3 = $v3 / $v3;
$v2 = -$v5;
$v5 = adder(-80, $v1, $v1);
$v5 = $v3;
return $v1;
PROG
    test_prog( 'i128 sub return with i32 return_var', <<'PROG', 61 );
use feature 'brocken_native_types';
sub double() -> i8 {
    my i16 $l1 = 47;
    my u32 $l2 = 4294967238;
    my i8 $l3 = 30;
    my i8 $l4 = 81;
    $l4 = $l4 * $l2;
    return $l3;
}

sub adder(i64 $p1, i32 $p2, i32 $p3) -> i128 {
    my u16 $l1 = 65518;
    my i32 $l2 = -59;
    my u8 $l3 = 232;
    my u32 $l4 = 46;
    $p2 = $p3 & $p2;
    $p1 = $l1 | $l3;
    $l4 = -$l2;
    return $p3;
}

my i32 $v1 = 61;
my u8 $v2 = 236;
my f64 $v3 = 4.0;
my f64 $v4 = 37.0;
my i128 $v5 = 88;
$v3 = $v3 / $v3;
$v2 = -$v5;
$v5 = adder(-80, $v1, $v1);
$v5 = $v3;
return $v1;
PROG
};

# Bug: _gen_logic_assign evaluated ||/&& as Perl logical (truthy→0/1),
# but Brocken lowers them to bitwise MIR or/and (X86_64 Lowerer.pm:226-227).
# These tests verify the bitwise semantics.
# Fuzzer seed 20260702, cases 6/8/15.
subtest '|| and && are bitwise (not logical) in Brocken' => sub {

    # Case 6 pattern: 0 || -26 → bitwise OR = -26 → bool truncates to 0
    test_prog( '0 || -26 stored to bool gives 0', <<'PROG', 0 );
my bool $b = false;
$b = $b || -26;
my i64 $r = $b;
return $r;
PROG

    # || on ints returns bitwise OR value
    test_prog( '0 || -26 stored to i64 gives -26', <<'PROG', 230 );
my i64 $a = 0;
my i64 $b = -26;
$a = $a || $b;
return $a;
PROG

    # Case 8 pattern: -34 && -34 → bitwise AND = -34 → f64 sitofp → i16 fptosi
    test_prog( '-34 && -34 via f64 and i16 gives -34', <<'PROG', 222 );
my f64 $f = 63.0;
my i64 $n = -34;
$f = $n && $n;
my i16 $z = $f;
return $z;
PROG

    # Case 15 pattern: -82 && 8 → bitwise AND = 8
    test_prog( '-82 && 8 gives 8 (bitwise, not logical)', <<'PROG', 8 );
my i64 $a = -82;
my i32 $b = 8;
$b = $a && $b;
return $b;
PROG

    # && on unsigned values preserves bitwise semantics
    test_prog( '42 && 7 gives 2 (42 & 7 = 2)', <<'PROG', 2 );
my i64 $a = 42;
my i64 $b = 7;
$a = $a && $b;
return $a;
PROG

    # || on negative values preserves sign
    test_prog( '-1 || -2 gives -1 (-1 | -2 = -1)', <<'PROG', 255 );
my i64 $a = -1;
my i64 $b = -2;
$a = $a || $b;
return $a;
PROG
};

# Phase F7: Loop iteration guard prevents infinite while loops.
# Without the guard, a while loop whose body never modifies the
# condition variables hangs the compiled binary indefinitely.
subtest 'loop iteration guard prevents infinite while with next' => sub {
    local $Brocken::default_fuel = 6;
    test_prog( 'next-only loop exits via guard and returns constant', <<'PROG', 42 );
my i64 $v1 = 999;
while ($v1 > 0) {
    next;
}
return 42;
PROG
    test_prog( 'infinite while (no next) exits via guard', <<'PROG', 7 );
my i64 $a = 1;
my i64 $b = 0;
while ($a > $b) {
    $a = $a;  # no progress toward exit
}
return 7;
PROG
};

# Debug: u128 helper function to test entry shuffle
subtest 'u128 helper entry shuffle debug' => sub {
    test_prog( 'u128 param helper', <<'PROG', 0xEF );
use feature 'brocken_native_types';
sub helper(u128 $x) -> u64 {
    return $x;
}
return helper(0xDEADBEEF);
PROG
};
done_testing;
