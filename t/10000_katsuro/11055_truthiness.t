use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# A conditional on a boxed (`Any`) value goes through the runtime `is_truthy` helper (src/runtime/core.brocken), which
# applies Perl's rules: undef (a null box), 0, 0.0, "", and "0" are false, while "00", "0.0", 0.5, and any reference
# are true. The helper also short-circuits on a null box, so `if (undef)` reads as false instead of faulting.
#
# A box holding a String needs a string-literal key to reach the box path, and the Wasm backend does not emit rodata
# yet, so the boxed subtests run on every native target but not on a Wasm one.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub run_case {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

# A native scalar keeps its plain zero test: this is not the box path, and 0/0.0 must stay false.
subtest 'a native scalar is false only at zero' => sub {
    answers( 'if (0) { return 1; } return 0;',   0, 'int zero is false' );
    answers( 'if (5) { return 1; } return 0;',   1, 'int five is true' );
    answers( 'if (-1) { return 1; } return 0;',  1, 'int minus one is true' );
    answers( 'if (0.0) { return 1; } return 0;', 0, 'zero float is false' );
    answers( 'if (0.5) { return 1; } return 0;', 1, 'half is true' );
};

# A boxed number follows the numeric part of the rule.
subtest 'a boxed number is false at zero' => sub {
    run_case( 'my %h; %h{"k"} = 0; if (%h{"k"}) { return 1; } return 0;',   0, 'boxed zero is false' );
    run_case( 'my %h; %h{"k"} = 5; if (%h{"k"}) { return 1; } return 0;',   1, 'boxed five is true' );
    run_case( 'my %h; %h{"k"} = 0.0; if (%h{"k"}) { return 1; } return 0;', 0, 'boxed zero float is false' );
    run_case( 'my %h; %h{"k"} = 0.5; if (%h{"k"}) { return 1; } return 0;', 1, 'boxed half is true' );
};

# A boxed string is where a naive unbox is wrong: "0" and "" must be false, but "00" and "0.0" are true.
subtest 'a boxed string is false only when empty or "0"' => sub {
    run_case( 'my %h; %h{"k"} = ""; if (%h{"k"}) { return 1; } return 0;',    0, 'the empty string is false' );
    run_case( 'my %h; %h{"k"} = "0"; if (%h{"k"}) { return 1; } return 0;',   0, 'the string "0" is false' );
    run_case( 'my %h; %h{"k"} = "00"; if (%h{"k"}) { return 1; } return 0;',  1, 'the string "00" is true' );
    run_case( 'my %h; %h{"k"} = "0.0"; if (%h{"k"}) { return 1; } return 0;', 1, 'the string "0.0" is true' );
    run_case( 'my %h; %h{"k"} = "x"; if (%h{"k"}) { return 1; } return 0;',   1, 'a non-empty string is true' );
};

# A missing key yields a null box, which must read as false rather than dereferencing address zero.
subtest 'a null box is false, not a fault' => sub {
    run_case( 'my %h; if (%h{"missing"}) { return 1; } return 0;', 0, 'a missing key (null box) is false' );
    run_case( 'my Any $a; if ($a) { return 1; } return 0;',       0, 'if (null_any) is false' );
    run_case( 'my Any $a; my Any $b = 5; if ($a) { return 1; } if ($b) { return 2; } return 0;', 2, 'a later true box is still reached' );
};

# Unary `!` is the same truthiness test, negated.
subtest 'unary ! follows the same truthiness' => sub {
    run_case( 'my %h; %h{"k"} = "0"; if (!%h{"k"}) { return 1; } return 0;',  1, '!("0") is true' );
    run_case( 'my %h; %h{"k"} = "00"; if (!%h{"k"}) { return 1; } return 0;', 0, '!("00") is false' );
    run_case( 'my Any $a; if (!$a) { return 1; } return 0;',                 1, '!(null box) is true' );
    run_case( 'my %h; %h{"k"} = 0; if (!%h{"k"}) { return 1; } return 0;',   1, 'boxed zero negates to true' );
    run_case( 'my %h; %h{"k"} = 5; if (!%h{"k"}) { return 1; } return 0;',   0, 'boxed five negates to false' );
};

# A boxed condition drives a while loop, and a false box never enters the body.
subtest 'a boxed condition drives a while loop' => sub {
    run_case(
        'my %h; %h{"s"} = "x"; my i64 $n = 0; while (%h{"s"}) { $n = $n + 1; if ($n == 3) { %h{"s"} = ""; } } return $n;',
        3, 'the loop runs while the box is true'
    );
    run_case(
        'my %h; %h{"s"} = "0"; my i64 $n = 0; while (%h{"s"}) { $n = $n + 1; %h{"s"} = ""; } return $n;',
        0, 'a false box never enters the body'
    );
};

# A boolean expression stored into the hash is a box too, and reads back by the same rule.
subtest 'a boxed comparison reads back by its value' => sub {
    run_case( 'my %h; %h{"k"} = (5 > 3); if (%h{"k"}) { return 1; } return 0;', 1, 'a true comparison is true' );
    run_case( 'my %h; %h{"k"} = (5 < 3); if (%h{"k"}) { return 1; } return 0;', 0, 'a false comparison is false' );
};

done_testing;
