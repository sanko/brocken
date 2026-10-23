use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `//=` and `||=` on a dynamic (`Any`) slot store the RHS only when the slot is absent, but that store is still an
# owned store: the slot has to take its own reference to the replacement, or it aliases a box the caller later
# releases and then dangles (F2). The branchless `select` form stored the chosen value without the incref, because a
# select cannot express a conditional incref; the store now branches. Each case stores a caller's box in an absent
# slot, drops the caller's own reference, and reads the slot back.
my @native = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
subtest 'a //= into a dynamic field keeps the assigned box alive' => sub {
    answers(
        'class Holder { field Any $v;' .
            ' method put(Any $x) { $v //= $x; }' .
            ' method get() :returns(Any) { return $v; } }' .
            ' my ptr $h = Holder->new();' .
            '{ my $tmp = 123; $h->put($tmp); }' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        123,
        'the field owns the box after the caller block exits',
        targets => [@native]
    );
};
subtest 'a ||= into a dynamic field keeps the assigned box alive' => sub {
    answers(
        'class Holder { field Any $v;' .
            ' method put(Any $x) { $v ||= $x; }' .
            ' method get() :returns(Any) { return $v; } }' .
            ' my ptr $h = Holder->new();' .
            '{ my $tmp = 77; $h->put($tmp); }' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        77,
        'the field owns the box after the caller block exits',
        targets => [@native]
    );
};
subtest 'a //= through a field access keeps the assigned box alive' => sub {
    answers(
        'class Holder { field Any $v;' .
            ' method put(Any $x) { $self->v //= $x; }' .
            ' method get() :returns(Any) { return $v; } }' .
            ' my ptr $h = Holder->new();' .
            '{ my $tmp = 210; $h->put($tmp); }' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        210,
        'the field-access store also owns the box',
        targets => [@native]
    );
};
subtest 'a ||= default owns the box it substitutes for a supplied null' => sub {
    answers(
        'class Holder { field Any $v ||= 91;' .
            ' method get() :returns(Any) { return $v; } }' .
            ' my Any $z;' .
            ' my ptr $h = Holder->new(v => $z);' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        91,
        'the default is stored and owned when the supplied value is null',
        targets => [@native]
    );
};
subtest 'a //= on a present slot keeps the existing box' => sub {
    answers(
        'class Holder { field Any $v = 5;' .
            ' method put(Any $x) { $v //= $x; }' .
            ' method get() :returns(Any) { return $v; } }' .
            ' my ptr $h = Holder->new();' .
            ' my $src = 8;' .
            ' $h->put($src);' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        5,
        'an absent test that is false leaves the slot untouched',
        targets => [@native]
    );
};
done_testing;
