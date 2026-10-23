use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# String literals are the one case that needs the pointer-shaped select path, and Wasm has no rodata support yet, so
# the string subtests run on every native target but not on a Wasm one.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

# On a native scalar there is no undefined value, so `//=` is just `=`: the RHS is stored unconditionally. The old
# lowering compared the existing value against literal zero for every type, which made `my i64 $x = 5; $x //= 42;`
# keep the 5 -- an integer 0 is not "undefined" on an int, it is a value like any other.
subtest '//= stores the RHS on a native scalar' => sub {
    answers( 'my i64 $x = 5; $x //= 42; return $x;', 42, 'a non-zero scalar is overwritten' );
    answers( 'my i64 $x = 0; $x //= 42; return $x;', 42, 'zero is overwritten too' );
};

# The null test is kept where "undefined" really is a null pointer.
subtest '//= keeps the null test for ptr' => sub {
    answers( 'my ptr $p = 0; $p //= 100; if ($p) { return 1; } return 0;',      1, 'a null pointer is replaced' );
    answers( 'my ptr $p = 7; $p //= 100; if ($p == 7) { return 1; } return 0;', 1, 'a live pointer is kept' );
};

# `//` is the defined-or operator in expression position: its left operand unless that is undefined, the right
# operand otherwise. It is eager, like `&&` and `||` here.
subtest '// is the left operand when it is defined' => sub {
    answers( 'my i64 $x = 5; my i64 $y = 42; return $x // $y;', 5, 'a defined scalar wins' );
    answers( 'my i64 $x = 0; my i64 $y = 42; return $x // $y;', 0, 'zero is defined, so it beats the right operand' );
};

# On an untyped (Any) slot a null box stands in for undef.
subtest '// falls back on a null Any box' => sub {
    answers( 'my Any $a; my Any $b = 7; return $a // $b;',                  7, 'a null box takes the right operand' );
    answers( 'my Any $a = 5; my Any $b = 7; return $a // $b;',              5, 'a set box keeps its value' );
    answers( 'my Any $a = 0; my Any $b = 6; return $a // $b;',              0, 'a boxed zero is defined' );
    answers( 'my Any $a; my Any $b; my Any $c = 9; return $a // $b // $c;', 9, 'a chain reaches the first set box' );
};

# `||=` stores the RHS when the slot is false, not merely when it is undefined.
subtest '||= replaces a false value' => sub {
    answers( 'my i64 $x = 0; $x ||= 5; return $x;',     5, 'a false scalar takes the RHS' );
    answers( 'my i64 $x = 3; $x ||= 5; return $x;',     3, 'a true scalar is kept' );
    answers( 'my f64 $x = 0.0; $x ||= 8.0; return $x;', 8, 'a false float takes the RHS' );
    answers( 'my f64 $x = 3.0; $x ||= 8.0; return $x;', 3, 'a true float is kept' );
    answers( 'my Any $a; $a ||= 4; return $a;',         4, 'a null box takes the RHS' );
    answers( 'my Any $a = 2; $a ||= 8; return $a;',     2, 'a boxed two is kept' );
};

# An `Any` box holding a false payload is inspected: `||=` tests Perl truthiness of the payload through the runtime
# `is_truthy`, so a box holding `0` or `"0"` is replaced just like a null box. The same helper backs `if`/`while`
# conditions and unary `!`, and it short-circuits on a null box, so `if (null_any)` no longer faults.
subtest '||= on an Any box uses payload truthiness' => sub {
    answers( 'my Any $a = 0; $a ||= 4; return $a;', 4, 'a boxed zero is false, so the RHS wins' );
    answers( 'my Any $a = 2; $a ||= 4; return $a;', 2, 'a boxed true value is kept' );
    answers( 'my Any $a = "0"; $a ||= 4; if ($a) { return 1; } return 0;', 1, 'a boxed string "0" is false too', targets => [@native_targets] );
};

# A declaration has no previous value, so the conditional form always takes its initializer, exactly as `=` would.
# The spelling is accepted so that Perl-shaped source parses.
subtest 'a declaration initialises with //= or ||=' => sub {
    answers( 'my Any $x //= 5; return $x;', 5, 'my $x //= 5' );
    answers( 'my Any $x ||= 5; return $x;', 5, 'my $x ||= 5' );
};

# A String on each side makes `//` a pointer-shaped select whose taken arm is a rodata address -- the case a plain
# `_lower_opnd` could not build, on any backend.
subtest '// and //= on a String' => sub {
    answers(
        'my String $s; my String $t = "abc"; return length($s // $t);',
        3,
        'a null String takes the rodata fallback',
        targets => [@native_targets]
    );
    answers( 'my String $s = "hello"; my String $t = "abc"; return length($s // $t);', 5, 'a set String is kept', targets => [@native_targets] );
    answers( 'my String $s; $s //= "hi"; return length($s);',         2, 'a null String is filled in by //=',     targets => [@native_targets] );
    answers( 'my String $s; $s ||= "yes"; return length($s);',        3, 'a null String is filled in by ||=',     targets => [@native_targets] );
    answers( 'my String $s = "no"; $s ||= "yes"; return length($s);', 2, 'a live String keeps ||= away',          targets => [@native_targets] );
};
done_testing;
