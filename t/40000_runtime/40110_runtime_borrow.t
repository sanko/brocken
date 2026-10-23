use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# Caller-Borrows: passing an `Any` argument does not transfer ownership. The caller does not incref on the way in, so
# the callee must not decref on the way out; otherwise the caller's box is freed (RC 1 -> 0) and both the caller and
# the callee can end up reading recycled memory. These cases all keep using the caller's value after the call.
my @native = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
subtest 'a callee does not release a borrowed Any argument' => sub {
    answers(
        'sub ignore($x) :returns(i64) { return 0; }' . ' my $a = 99;' . ' my i64 $r = ignore($a);' . ' my i64 $n = $a;' . ' return $n;',
        99,
        'the caller box survives the callee exit',
        targets => [@native]
    );
};
subtest 'a callee may read a borrowed Any argument' => sub {
    answers(
        'sub add1($x) :returns(i64) { my i64 $v = $x; return $v + 1; }' .
            ' my $a = 40;' .
            ' my i64 $r = add1($a);' .
            ' my i64 $n = $a;' .
            ' return $n + $r;',
        81,
        'the callee read and the caller box both see the value',
        targets => [@native]
    );
};
subtest 'reassigning a borrowed parameter does not release the caller value' => sub {
    answers(
        'sub reset($x) :returns(i64) { $x = 7; my i64 $v = $x; return $v; }' .
            ' my $a = 5;' .
            ' my i64 $r = reset($a);' .
            ' my i64 $n = $a;' .
            ' return $n + $r;',
        12,
        'the caller value was not freed by the parameter overwrite',
        targets => [@native]
    );
};
subtest 'returning a borrowed parameter keeps the caller value alive' => sub {
    answers(
        'sub ident($x) :returns(i64) { return $x; }' . ' my $a = 33;' . ' my i64 $r = ident($a);' . ' my i64 $n = $a;' . ' return $n + $r;',
        66,
        'borrowed parameter returned without freeing the caller box',
        targets => [@native]
    );
};
done_testing;
