use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro::Platform;
use Test2::Tools::Brocken qw[run_cross cross_available];
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

# A cross-execution baseline for the AArch64 and RISCV64 backends.
#
# Comparing a single instruction against an assembler proves the encoder agrees
# with one instruction in isolation. It says nothing about the program around
# it: the frame layout, the register assignment, the argument placement and the
# epilogue are all only ever exercised in combination, and those are where the
# faults on these two backends live. Every case here failed to execute at some
# point while the matching single instruction still encoded correctly.
#
# So these run the generated binary. qemu-aarch64 and qemu-riscv64 are both
# present, and the cross libc for each is installed, so a real ELF for the other
# architecture can be linked and started; a binary that needs libc.so.6 will not
# run without the matching loader, which is why the -L root matters as much as
# qemu itself.
#
# Every program returns 0 when it agrees with itself and a distinct nonzero code
# otherwise, so the same source compiles for all three targets and each one
# reports its own verdict. The exit code is the assertion.

my @TARGETS = (
    [ 'aarch64-unknown-linux-gnu', 'aarch64' ],
    [ 'riscv64-unknown-linux-gnu', 'riscv64' ],
);

my @CASES = (
    {   name => 'single arg',
        src  => 'sub f1(i64 $a) -> i64 { return $a; } if (f1(42) != 42) { return 1; } return 0;',
    },
    {   name => 'two args',
        src  => 'sub f2(i64 $a, i64 $b) -> i64 { return $a - $b; } if (f2(10, 4) != 6) { return 1; } return 0;',
    },
    {   name => 'four args',
        src  => 'sub f4(i64 $a, i64 $b, i64 $c, i64 $d) -> i64 { return $a - $b - $c - $d; }
                  if (f4(10, 4, 3, 2) != 1) { return 1; } return 0;',
    },
    {   name => 'six args',
        src  => 'sub f6(i64 $a, i64 $b, i64 $c, i64 $d, i64 $e, i64 $g) -> i64 { return $a - $b - $c - $d - $e - $g; }
                  if (f6(10, 4, 3, 2, 1, 0) != 0) { return 1; } return 0;',
    },
    {   name => 'eight args',
        src  => 'sub f8(i64 $a, i64 $b, i64 $c, i64 $d, i64 $e, i64 $g, i64 $h, i64 $i) -> i64
                  { return $a - $b - $c - $d - $e - $g - $h - $i; }
                  if (f8(10, 4, 3, 2, 1, 0, 0, 0) != 0) { return 1; } return 0;',
        note => 'eight is the last count that fits in registers; a ninth spills, which no backend implements yet',
    },
    {   name => 'int to float',
        src  => 'sub w(i32 $i) -> f64 { my f64 $f = $i; return $f; } if (w(7) != 7) { return 1; } return 0;',
        note => 'the sitofp lowering, which was only ever checked against an assembler',
    },
    {   name => 'float to int',
        src  => 'sub w(i32 $i) -> i64 { my f64 $f = $i; my i64 $j = $f; return $j; }
                  if (w(3) != 3) { return 1; } return 0;',
        note => 'truncation back to an integer, via a computed float so no literal is involved',
    },
    {   name => 'float local and loop',
        src  => 'my f64 $t = 0; my f64 $one = 1; my i64 $i = 1;
                  while ($i <= 10) { $t = $t + $one; $i = $i + 1; }
                  if ($t != 10) { return 1; } return 0;',
    },

    # The float cases below are the ones that actually caught bugs. On AArch64 a
    # literal argument reached fmov as an immediate, which is register-to-register
    # only. On RISCV64 that same path died, and once past it two more faults were
    # sitting behind it: the fadd family never set funct3, so it decoded as fsgnj
    # and quietly threw the arithmetic away, and a float return fell through to
    # the integer move and handed back the return address in a0.

    {   name => 'float const local',
        src  => 'sub f() -> f64 { my f64 $s = 1; return $s; } if (f() != 1) { return 1; } return 0;',
        note => 'a literal has to be given a register before anything can move it',
    },
    {   name => 'float local from float param',
        src  => 'sub f(f64 $a) -> f64 { my f64 $n = $a; return $n; } if (f(1) != 1) { return 1; } return 0;',
    },
    {   name => 'float arg is a literal',
        src  => 'sub f(f64 $a) -> f64 { return $a; } if (f(1) != 1) { return 1; } return 0;',
        note => 'the literal arrives at the call site, not the callee',
    },
    {   name => 'float add two params',
        src  => 'sub f(f64 $a, f64 $b) -> f64 { my f64 $n = $a; return $n + $b; }
                  if (f(1, 2) != 3) { return 1; } return 0;',
    },
    {   name => 'float add const and local',
        src  => 'sub f(f64 $a) -> f64 { my f64 $s = 1; my f64 $n = $a; return $n + $s; }
                  if (f(2) != 3) { return 1; } return 0;',
    },
    {   name => 'float sub, mul and div',
        src  => 'sub s(f64 $a) -> f64 { my f64 $b = $a - 1; my f64 $c = $b * 4; return $c / 2; }
                  if (s(5) != 8) { return 1; } return 0;',
        note => 'the whole fadd family shares one encoder, so this covers fsub, fmul and fdiv too',
    },
    {   name => 'float compare',
        src  => 'sub s(f64 $a, f64 $b) -> i64 { if ($a < $b) { return 1; } return 0; }
                  if (s(1, 2) != 1) { return 1; } return 0;',
    },
    {   name => 'float return from a nested call',
        src  => 'sub s(i64 $n, f64 $a) -> f64 { my f64 $q = 1; my f64 $b = $a + $q; return $b; }
                  if (s(1, 1) != 2) { return 1; } return 0;',
    },
    {   name => 'float recursion, accumulator in a callee-save register',
        src  => 'sub sum(i64 $n, f64 $acc) -> f64 { if ($n == 0) { return $acc; }
                        my f64 $next = $acc; my f64 $step = 1; return sum($n - 1, $next + $step); }
                  if (sum(10, 0) != 10) { return 1; } return 0;',
        note => 'the call has to survive a frame push, since the float lives in a callee-save register',
    },
    {   name => 'recursion',
        src  => 'sub fac(i64 $n) -> i64 { if ($n <= 1) { return 1; } return $n * fac($n - 1); }
                  if (fac(10) != 3628800) { return 1; } return 0;',
    },
);

for my $target (@TARGETS) {
    my ( $triple, $label ) = @$target;
    my $platform = Brocken::Katsuro::Platform::parse($triple);

    SKIP: {
        skip "$label: qemu or the cross libc is not available here", scalar @CASES * 2
            unless cross_available($platform);

        for my $case (@CASES) {
            my $label_line = "$label: $case->{name}";
            $label_line .= " ($case->{note})" if $case->{note};

            my $rc = run_cross( $case->{src}, $platform,
                name          => $label_line,
                expected_exit => 0
            );
            is( $rc, 0, "$label_line returns 0" );
        }
    }
}

done_testing;
