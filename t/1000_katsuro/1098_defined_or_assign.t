use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers];

# On a native scalar there is no undefined value, so `//=` is just `=`: the RHS is stored unconditionally. The old
# lowering compared the existing value against literal zero for every type, which made `my i64 $x = 5; $x //= 42;`
# keep the 5 -- an integer 0 is not "undefined" on an int, it is a value like any other.
subtest '//= stores the RHS on a native scalar' => sub {
    answers( 'my i64 $x = 5; $x //= 42; return $x;', 42, 'a non-zero scalar is overwritten' );
    answers( 'my i64 $x = 0; $x //= 42; return $x;', 42, 'zero is overwritten too' );
};

# The null test is kept where "undefined" really is a null pointer.
subtest '//= keeps the null test for ptr' => sub {
    answers( 'my ptr $p = 0; $p //= 100; if ($p) { return 1; } return 0;', 1, 'a null pointer is replaced' );
    answers( 'my ptr $p = 7; $p //= 100; if ($p == 7) { return 1; } return 0;', 1, 'a live pointer is kept' );
};
done_testing;