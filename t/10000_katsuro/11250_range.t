use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers];

# `for my $i (LO .. HI)` lowers to a native induction loop, not a list, so it needs no rodata and runs on every
# executable target (Wasm included). A total past 255 wraps to the exit code, so each check returns a value that fits.
sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label );
}

subtest 'an ascending range visits both ends' => sub {
    check( <<'BROCKEN', 10, 'the sum of 0..4 is 10' );
my i64 $s = 0;
for my $i (0 .. 4) { $s = $s + $i; }
return $s;
BROCKEN
    check( <<'BROCKEN', 10, 'the range operator wins next to digits (0..4, no spaces)' );
my i64 $s = 0;
for my $i (0..4) { $s = $s + $i; }
return $s;
BROCKEN
    check( <<'BROCKEN', 6, 'the range is inclusive at the top' );
my i64 $s = 0;
for my $i (1 .. 3) { $s = $s + $i; }
return $s;
BROCKEN
    check( <<'BROCKEN', 3, 'a one-element range runs once' );
my i64 $s = 0;
for my $i (3 .. 3) { $s = $s + $i; }
return $s;
BROCKEN
};

subtest 'an empty or descending range never runs' => sub {
    check( <<'BROCKEN', 0, 'LO > HI is empty' );
my i64 $s = 0;
for my $i (5 .. 1) { $s = $s + 1; }
return $s;
BROCKEN
    check( <<'BROCKEN', 7, 'the body before a descending loop still runs' );
my i64 $s = 7;
for my $i (100 .. 99) { $s = 99; }
return $s;
BROCKEN
};

subtest 'the bound expressions are evaluated once' => sub {
    check( <<'BROCKEN', 9, 'a bound may be a variable' );
my i64 $a = 2;
my i64 $b = 4;
my i64 $s = 0;
for my $i ($a .. $b) { $s = $s + $i; }
return $s;
BROCKEN
    check( <<'BROCKEN', 14, 'a bound may be an expression' );
my i64 $s = 0;
for my $i (1 + 1 .. 3 + 2) { $s = $s + $i; }
return $s;
BROCKEN
};

subtest 'last and next' => sub {
    check( <<'BROCKEN', 5, 'next skips a pass, last ends the loop' );
my i64 $n = 0;
for my $i (0 .. 10) {
    if ($i == 3) { next; }
    if ($i == 6) { last; }
    $n = $n + 1;
}
return $n;
BROCKEN
};

subtest 'the loop variable is a native integer' => sub {
    check( <<'BROCKEN', 6, 'an i64 loop variable' );
my i64 $s = 0;
for my i64 $i (1 .. 3) { $s = $s + $i; }
return $s;
BROCKEN
    check( <<'BROCKEN', 6, 'an i32 loop variable' );
my i64 $s = 0;
for my i32 $i (1 .. 3) { $s = $s + $i; }
return $s;
BROCKEN
    check( <<'BROCKEN', 6, 'an unsigned loop variable' );
my i64 $s = 0;
for my u64 $i (1 .. 3) { $s = $s + $i; }
return $s;
BROCKEN
};

subtest 'the body sees and may reassign the loop variable' => sub {
    # The lowering is `$i = LO; while ($i <= HI) { ...; $i++ }`, so a write to `$i` in the body changes where the
    # induction resumes -- the loop runs once here because the body jumps it past the top.
    check( <<'BROCKEN', 1, 'a body write drives the induction' );
my i64 $n = 0;
for my $i (0 .. 10) { $n = $n + 1; $i = 100; }
return $n;
BROCKEN
    check( <<'BROCKEN', 3, 'the body reads the current value' );
my i64 $n = 0;
for my $i (0 .. 2) { if ($i >= 0) { $n = $n + 1; } }
return $n;
BROCKEN
};

subtest 'ranges nest' => sub {
    check( <<'BROCKEN', 18, 'an inner range runs fully for each outer value' );
my i64 $s = 0;
for my $i (1 .. 2) { for my $j (1 .. 3) { $s = $s + $i * $j; } }
return $s;
BROCKEN
};

subtest 'a range is only valid as the whole for list' => sub {
    my $range = eval { Brocken->new->parse('for my $i (0 .. 3) { }')->statements->[0]->expr };
    isa_ok( $range, ['Brocken::Katsuro::AST::Expr::Range'], 'the loop header parses to a range' );

    like(
        dies { Brocken->new->compile('for my $i (1, 2 .. 3) { } return 0;') },
        qr/a range must be the whole 'for' list/,
        'a range mixed into a list is rejected',
    );
    like(
        dies { Brocken->new->compile('for my ($i, $j) (0 .. 3) { } return 0;') },
        qr/a range loop takes exactly one variable/,
        'a two-target range is rejected',
    );
    like(
        dies { Brocken->new->compile('for my f64 $i (0 .. 3) { } return 0;') },
        qr/a range loop variable must be an integer/,
        'a non-integer loop variable is rejected',
    );
    like(
        dies { Brocken->new->compile('my i64 $x = 0 .. 3; return $x;') },
        qr/Expected ';'/,
        'a range outside a for header is a parse error',
    );
};

done_testing;
