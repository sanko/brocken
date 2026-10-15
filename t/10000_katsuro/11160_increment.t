use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers];

# `++`/`--` (spec 4.4). A native numeric slot is stepped with a plain load/add/store. A `String` slot takes the
# magical ASCII increment for `++` (Perl's carry rules) or a numeric decrement for `--`. An owned dynamic (`Any`)
# slot -- a local, an `Any` field, or an owned `Any` array element -- is stepped by the runtime, which carries the
# owning-store contract and returns the pre- or post-value as an owned reference. A borrowed `Any` parameter is
# promoted to an owned slot first, so the caller's box is never released.

subtest 'native integer pre- and post-increment/decrement' => sub {
    answers( 'my i64 $i = 5; return $i++;',  5, 'postfix increment yields the pre-value' );
    answers( 'my i64 $i = 5; return ++$i;',  6, 'prefix increment yields the post-value' );
    answers( 'my i64 $i = 5; return $i--;',  5, 'postfix decrement yields the pre-value' );
    answers( 'my i64 $i = 5; return --$i;',  4, 'prefix decrement yields the post-value' );
    answers( 'my i64 $i = 5; $i++; ++$i; --$i; return $i;', 6, 'a run of steps leaves the slot stepped once per operator' );
    answers( 'my i64 $i = 0; my i64 $a = $i++; my i64 $b = $i++; return $a * 10 + $b;', 1,
        'consecutive postfix steps each read the value before their own step' );
    answers( 'my i64 $i = 5; my i64 $j = -$i++; return $j + $i;', 1,
        'unary minus binds looser than postfix increment' );
};

subtest 'float slots step by one' => sub {
    answers( 'my f64 $f = 1.5; ++$f; return ($f == 2.5) ? 1 : 0;', 1, 'prefix increment of a float' );
    answers( 'my f64 $f = 1.5; $f++; return ($f == 2.5) ? 1 : 0;', 1, 'postfix increment of a float' );
    answers( 'my f64 $f = 1.5; $f--; --$f; return ($f == -0.5) ? 1 : 0;', 1, 'decrement of a float' );
    answers( 'my f64 $f = 1.5; my f64 $g = $f++; return ($g == 1.5 && $f == 2.5) ? 1 : 0;', 1,
        'postfix float yields the pre-value and steps the slot' );
};

subtest 'Any slots step numerically' => sub {
    answers( 'my Any $x = 5; my Any $y = $x++; return $y + $x;', 11, 'Any postfix increment' );
    answers( 'my Any $x = 5; my Any $y = ++$x; return $y + $x;', 12, 'Any prefix increment' );
    answers( 'my Any $x = 5; my Any $y = $x--; return $y + $x;', 9,  'Any postfix decrement' );
    answers( 'my Any $x = 5; my Any $y = --$x; return $y + $x;', 8,  'Any prefix decrement' );
    answers( 'my Any $x; $x++; return $x;', 1, 'undef increments to 1' );
    answers( 'my Any $x; $x--; return $x;', 255, 'undef decrements to -1' );
};

subtest 'magical ASCII increment for incrementable strings' => sub {

    # "az" -> "ba": the trailing 'z' carries to 'a' and the 'a' to its left is bumped.
    answers( 'my Any $s = "az"; $s++; my ptr $p = Brocken::Runtime::unbox_ptr($s);'
            . ' return (Brocken::load_i8($p) == 98 && Brocken::load_i8(Brocken::ptr_add($p,1)) == 97'
            . ' && Brocken::load_i8(Brocken::ptr_add($p,2)) == 0) ? 1 : 0;',
        1, '"az"++ -> "ba"' );

    # "99" -> "100": every digit carries and the carry out prepends '1'.
    answers( 'my Any $s = "99"; $s++; my ptr $p = Brocken::Runtime::unbox_ptr($s);'
            . ' return (Brocken::load_i8($p) == 49 && Brocken::load_i8(Brocken::ptr_add($p,1)) == 48'
            . ' && Brocken::load_i8(Brocken::ptr_add($p,2)) == 48 && Brocken::load_i8(Brocken::ptr_add($p,3)) == 0) ? 1 : 0;',
        1, '"99"++ -> "100"' );

    # "a9" -> "b0": the '9' carries, the 'a' is bumped, and nothing is prepended.
    answers( 'my Any $s = "a9"; $s++; my ptr $p = Brocken::Runtime::unbox_ptr($s);'
            . ' return (Brocken::load_i8($p) == 98 && Brocken::load_i8(Brocken::ptr_add($p,1)) == 48'
            . ' && Brocken::load_i8(Brocken::ptr_add($p,2)) == 0) ? 1 : 0;',
        1, '"a9"++ -> "b0"' );

    # "zz" -> "aaa": every 'z' carries and the carry out prepends 'a' (lowercase first character).
    answers( 'my Any $s = "zz"; $s++; my ptr $p = Brocken::Runtime::unbox_ptr($s);'
            . ' return (Brocken::load_i8($p) == 97 && Brocken::load_i8(Brocken::ptr_add($p,1)) == 97'
            . ' && Brocken::load_i8(Brocken::ptr_add($p,2)) == 97 && Brocken::load_i8(Brocken::ptr_add($p,3)) == 0) ? 1 : 0;',
        1, '"zz"++ -> "aaa"' );

    # "Z" -> "AA": the carry out prepends the uppercase 'A'.
    answers( 'my Any $s = "Z"; $s++; my ptr $p = Brocken::Runtime::unbox_ptr($s);'
            . ' return (Brocken::load_i8($p) == 65 && Brocken::load_i8(Brocken::ptr_add($p,1)) == 65'
            . ' && Brocken::load_i8(Brocken::ptr_add($p,2)) == 0) ? 1 : 0;',
        1, '"Z"++ -> "AA"' );

    answers( 'my String $s = "az"; $s++; return Brocken::load_i8($s);', 98,
        'a String slot takes the magical increment too' );
};

subtest 'a non-incrementable string falls back to the numeric 1' => sub {
    answers( 'my Any $s = "!!"; $s++; return $s;',  1, 'symbols numify to 0, then increment to 1' );
    answers( 'my Any $s = "a!"; $s++; return $s;',  1, 'a trailing symbol forces the numeric fallback' );
    answers( 'my Any $s = "1.5"; $s++; return $s;', 1, 'a decimal point forces the numeric fallback' );
    answers( 'my Any $s = ""; $s++; return $s;',    1, 'the empty string numifies to 0, then increments to 1' );
    answers( 'my String $s = "abc!"; $s++; return Brocken::load_i8($s);', 49,
        'a String fallback stores the decimal result "1"' );
};

subtest 'string decrement is never magical' => sub {
    answers( 'my Any $s = "5"; $s--; return $s;',   4,   '"5"-- -> 4' );
    answers( 'my Any $s = "abc"; $s--; return $s;', 255, '"abc"-- -> -1 (numifies to 0)' );
    answers( 'my Any $s = "1.5"; $s--; return $s;', 0,   '"1.5"-- -> 0 (integer coercion, float simplified)' );
    answers( 'my Any $s = "10"; --$s; return $s;',  9,   'prefix string decrement' );
    answers( 'my String $s = "5"; $s--; return Brocken::load_i8($s);',   52, 'a String slot stores the decimal result "4"' );
    answers( 'my String $s = "abc"; $s--; return Brocken::load_i8($s);', 45, 'a String slot stores "-1"' );
};

subtest 'field and array-element targets' => sub {
    answers( 'class Counter { field i64 $n :param; } my ptr $c = Counter->new(n => 4); $c->n++; return $c->n;', 5,
        'a field postfix increments the field' );
    answers( 'class Counter { field i64 $n :param; } my ptr $c = Counter->new(n => 4); ++$c->n; return $c->n;', 5,
        'a field prefix increments the field' );
    answers( 'class Counter { field i64 $n :param; method bump() :returns(i64) { return $n++; } }'
            . ' my ptr $c = Counter->new(n => 7); return $c->bump();',
        7, 'a bare field name in a method body is an lvalue' );
    answers( 'class Box { field Any $v :param; } my ptr $b = Box->new(v => 9); $b->v++; return $b->v;', 10,
        'an Any field steps through the runtime' );
    answers( 'my [i64; 3] @a; @a[1] = 10; @a[1]++; return @a[1];', 11, 'an inline array element steps in place' );
    answers( 'my [Any; 1] @a; @a[0] = 5; @a[0]++; return @a[0];', 6, 'an owned Any element steps through the runtime' );
    answers( 'my [Any; 1] @a; @a[0] = 5; my Any $y = @a[0]++; return $y + @a[0];', 11,
        'postfix on an Any element yields the pre-value' );
};

subtest 'a borrowed Any parameter is stepped without releasing the caller value' => sub {
    answers( 'sub step(Any $x) :returns(i64) { $x++; return $x; }'
            . ' my Any $v = 10; my i64 $r = step($v); return $r + $v;',
        21, 'the parameter is promoted to an owned slot, leaving the caller box alone' );
};

subtest 'discarded Any steps stay bounded' => sub {

    # Materialising a pre-value for a `$x++;` statement would briefly give the displaced box a second owner, which the
    # runtime then buffers as a cycle suspect and never reclaims on its own. Stepping the slot in place keeps the slot
    # the sole owner, so each displaced box is freed outright and the Immix bump cursor stays inside a 4 KiB guard.
    answers(
        'my ptr $hb = Brocken::heap_base(); my Any $x = 0;'
            . ' my ptr $before = Brocken::Runtime::immix_cursor($hb);'
            . ' my i64 $i = 0;'
            . ' while ($i < 1000) { $i++; $x++; }'
            . ' my ptr $after = Brocken::Runtime::immix_cursor($hb);'
            . ' if (Brocken::ptr_cmp_gt($after, Brocken::ptr_add($before, 4096))) { return 1; }'
            . ' return 0;',
        0, 'a loop of discarded Any postfix steps reclaims each displaced box'
    );
    answers(
        'my ptr $hb = Brocken::heap_base(); my [Any; 1] @a; @a[0] = 0;'
            . ' my ptr $before = Brocken::Runtime::immix_cursor($hb);'
            . ' my i64 $i = 0;'
            . ' while ($i < 1000) { $i++; @a[0]++; }'
            . ' my ptr $after = Brocken::Runtime::immix_cursor($hb);'
            . ' if (Brocken::ptr_cmp_gt($after, Brocken::ptr_add($before, 4096))) { return 1; }'
            . ' return 0;',
        0, 'a loop of discarded Any element steps stays bounded'
    );
};

subtest 'unsupported targets are rejected at compile time' => sub {
    my $c = Brocken->new;
    eval { $c->compile('my %h; %h{"k"}++;') };
    like( $@, qr/hash element/, 'incrementing a hash element is not supported yet' );
    eval { $c->compile('++5;') };
    like( $@, qr/target must be a variable, field access, or array index/, 'incrementing a literal is rejected' );
    eval { $c->compile('my Any $x = 0; $x++++;') };
    like( $@, qr/target must be a variable, field access, or array index/, 'a doubled postfix is not an lvalue' );
};

done_testing;
