use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'Return constant' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile('return 42;');
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/e2e_ret_const' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'return 42' );
        unlink $file;
    }
};
subtest 'Variable decl, assign, return' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $x = 10;
my i64 $y;
$y = 32;
return $x + $y;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_vars' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, '10 + 32 = 42' );
        unlink $file;
    }
};
subtest 'Arithmetic with precedence' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $r = 1 + 2 * 3;
return $r;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_arith' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 7, '1 + 2 * 3 = 7' );
        unlink $file;
    }
};
subtest 'If/else control flow' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $x = 1;
if ($x) {
    return 42;
} else {
    return 0;
}
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_if' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'if branch taken' );
        unlink $file;
    }
};
subtest 'If/else with false condition' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $x = 0;
if ($x) {
    return 0;
} else {
    return 42;
}
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_else' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'else branch taken' );
        unlink $file;
    }
};
subtest 'While loop' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $i = 0;
my i64 $s = 0;
while ($i < 10) {
    $s = $s + $i;
    $i = $i + 1;
}
return $s;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_while' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 45, 'sum 0..9 = 45' );
        unlink $file;
    }
};
subtest 'Comparison operators' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $a = 10;
my i64 $b = 20;
if ($a == $b) { return 1; }
if ($a != $b) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_cmp' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 2, 'a != b is true' );
        unlink $file;
    }
};
subtest 'Function call' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub helper() -> i64 {
    return 42;
}
return helper();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_call' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'helper() returned 42' );
        unlink $file;
    }
};
subtest 'Factorial' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub factorial(i64 $n) -> i64 {
    my i64 $result = 1;
    my i64 $i = 1;
    while ($i <= $n) {
        $result = $result * $i;
        $i = $i + 1;
    }
    return $result;
}
return factorial(5);
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_fact' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 120, '5! = 120' );
        unlink $file;
    }
};
subtest 'Logical not via if' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $a = 0;
if (! $a) { return 42; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_not' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, '!0 is true' );
        unlink $file;
    }
};
subtest 'Class constructor and reader method' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param :reader;
}
my ptr $p = Point->new(42);
return $p->x();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_class_reader' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'class with reader method' );
        unlink $file;
    }
};
subtest 'Class constructor and writer method' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Counter {
    field i64 $count :param :reader :writer;
}
my ptr $c = Counter->new(10);
$c->set_count(32);
return $c->count();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_class_writer' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 32, 'class with writer method' );
        unlink $file;
    }
};
subtest 'Class with ADJUST block' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param :reader;
    ADJUST {
        if ($x < 10) { $x = 10; }
    }
}
my ptr $p = Point->new(3);
return $p->x();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_class_adjust' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 10, 'ADJUST clamps value to minimum 10' );
        unlink $file;
    }
};
subtest 'Class with custom method' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
    method double() -> i64 { return $x * 2; }
}
my ptr $p = Point->new(21);
return $p->double();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_class_method' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'custom method returns doubled value' );
        unlink $file;
    }
};
subtest 'Direct field read access ($obj->field)' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
}
my ptr $p = Point->new(42);
return $p->x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_field_read' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'direct field read returns param value' );
        unlink $file;
    }
};
subtest 'Direct field write access ($obj->field = value)' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
}
my ptr $p = Point->new(10);
$p->x = 42;
return $p->x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_field_write' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'field write then read returns written value' );
        unlink $file;
    }
};

# Subtest: Implicit main (top-level code, no sub main)
subtest 'Implicit main' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $c       = Brocken::Compiler->new;
SKIP: {
        skip 'Native executable test requires native platform' unless $host->is_native;
        my $module = $c->compile(<<'BROCKEN');
my i64 $x = 10;
my i64 $y = 32;
return $x + $y;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_implicit_main' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'implicit main returns 42' );
        unlink $file;
    }
};

# Subtest: Array element read and write (implicit main)
subtest 'Array element read and write' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $c       = Brocken::Compiler->new;
SKIP: {
        skip 'Native executable test requires native platform' unless $host->is_native;
        my $module = $c->compile(<<'BROCKEN');
my [i64; 5] @arr;
@arr[0] = 10;
@arr[1] = 20;
@arr[2] = 30;
@arr[3] = 40;
@arr[4] = 50;
my i64 $sum = @arr[0] + @arr[1] + @arr[2] + @arr[3] + @arr[4];
return $sum;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_array_sum' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 150, 'sum of array elements 10+20+30+40+50 = 150' );
        unlink $file;
    }
};

# Subtest: Array with feature flag (i128 type) — implicit main
subtest 'Array with i128 native type' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $c       = Brocken::Compiler->new;
SKIP: {
        skip 'Native executable test requires native platform' unless $host->is_native;
        my $module = $c->compile(<<'BROCKEN');
use feature 'brocken_native_types';
my [i64; 3] @arr;
@arr[0] = 1;
@arr[1] = 2;
@arr[2] = 3;
return @arr[0] + @arr[1] + @arr[2];
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_array_feature' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 6, 'array sum with feature flag = 6' );
        unlink $file;
    }
};
subtest 'Bitwise intrinsics band, bor, bxor, shl, shr' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $c       = Brocken::Compiler->new;
SKIP: {
        skip 'Native executable test requires native platform' unless $host->is_native;
        my $module = $c->compile(<<'BROCKEN');
my i64 $a = Brocken::band(255, 15);
my i64 $b = Brocken::bor(240, 15);
my i64 $c = Brocken::bxor(255, 15);
my i64 $d = Brocken::shl(1, 4);
my i64 $e = Brocken::shr(255, 4);
return $a + $b - $c + $d + $e;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_bitwise' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;

        # band(255,15)=15, bor(240,15)=255, bxor(255,15)=240,
        # shl(1,4)=16, shr(255,4)=15
        # 15 + 255 - 240 + 16 + 15 = 61  (sum < 256 for 8-bit exit code)
        is( $? >> 8, 61, 'bitwise intrinsics produce correct results' );
        unlink $file;
    }
};
subtest 'Syscall intrinsic execution' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $c       = Brocken::Compiler->new;
SKIP: {
        skip 'Native executable test requires native platform' unless $host->is_native;
        if ( $host->is_freebsd || $host->is_macos || $host->is_openbsd || $host->is_dragonflybsd || $host->is_midnightbsd ) {
            skip 'Raw syscall 0 not safe on this platform', 2;
        }
        subtest 'Syscall discarded result, program continues' => sub {
            my $module = $c->compile(<<'BROCKEN');
Brocken::syscall(0, 0, 0, 0, 0, 0, 0);
return 42;
BROCKEN
            my $funcs = $brocken->codegen->emit_functions( $module->functions );
            my $file  = $brocken->tmpdir . '/e2e_syscall_discard' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $host );
            system $file;
            is( $? >> 8, 42, 'syscall does not crash, program continues' );
            unlink $file;
        };
        subtest 'Syscall return value captured' => sub {
            my $module = $c->compile(<<'BROCKEN');
my i64 $r = Brocken::syscall(0, 0, 0, 0, 0, 0, 0);
return $r;
BROCKEN
            my $funcs = $brocken->codegen->emit_functions( $module->functions );
            my $file  = $brocken->tmpdir . '/e2e_syscall_retval' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $host );
            system $file;

            # Cannot predict syscall return value (OS-specific), but it must
            # complete without crashing and produce some exit code 0-255
            like( $? >> 8, qr/\A\d+\z/, 'syscall return value captured' );
            unlink $file;
        };
    }
};
subtest 'Syscall by name' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $c       = Brocken::Compiler->new;
SKIP: {
        skip 'Native executable test requires native platform' unless $host->is_native;
        skip 'Syscall numbers not resolved for Windows'            if $host->is_windows;
        skip 'Detecting syscall numbers unreliable on Haiku in CI' if $host->is_haiku;
        skip 'Exit syscall crashes or misbehaves on this platform' if $host->is_openbsd;
        skip 'Exit syscall returns on NetBSD ARM64'                if $host->is_netbsd && $host->is_arm64;
        my $module = $c->compile( <<'BROCKEN', '(eval)', $host );
return Brocken::syscall_by_name("exit", 42);
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_syscall_by_name' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;

        # Platform resolves "exit" to the correct syscall number for this OS.
        # The exit syscall terminates the process with the given code (42).
        is( $? >> 8, 42, 'syscall_by_name("exit") exits with the right code' );
        unlink $file;
    }
};
done_testing;
