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

done_testing;
