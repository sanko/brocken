use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# A dynamic (`Any`) field owns a reference to the box stored in it: the store takes its own incref and releases the
# value it displaces. Before this contract a field aliased whatever box the caller passed in, so once the caller's
# local went out of scope the field dangled and read recycled memory (F9). Each case below stores a caller's box in a
# field, drops the caller's own reference, and then reads the field back.
my @native = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
subtest 'assigning a method parameter into a field keeps it alive' => sub {
    answers(
        'class Holder { field Any $v;' .
            ' method put(Any $x) { $v = $x; }' .
            ' method get() :returns(Any) { return $v; } }' .
            ' my ptr $h = Holder->new();' .
            '{ my $tmp = 123; $h->put($tmp); }' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        123,
        'the field still holds the caller box after the block exits',
        targets => [@native]
    );
};
subtest 'a generated writer takes its own reference' => sub {
    answers(
        'class Holder { field Any $v :writer;' .
            ' method get() :returns(Any) { return $v; } }' .
            ' my ptr $h = Holder->new();' .
            ' my $src = 45;' .
            ' $h->set_v($src);' .
            ' $src = 0;' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        45,
        'overwriting the source local does not free the field box',
        targets => [@native]
    );
};
subtest 'a positional constructor field takes its own reference' => sub {
    answers(
        'class Holder { field Any $v :param; method get() :returns(Any) { return $v; } }' .
            ' my $src = 88;' .
            ' my ptr $h = Holder->new($src);' .
            ' $src = 999;' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        88,
        'the constructor incref keeps the box after the source is replaced',
        targets => [@native]
    );
};
subtest 'a named constructor field takes its own reference' => sub {
    answers(
        'class Holder { field Any $v :param; method get() :returns(Any) { return $v; } }' .
            ' my $src = 201;' .
            ' my ptr $h = Holder->new(v => $src);' .
            ' $src = 0;' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        201,
        'the hash-override store also increfs the caller box',
        targets => [@native]
    );
};
subtest 'a default field still reads back its initializer' => sub {
    answers(
        'class Holder { field Any $v = 12; method get() :returns(Any) { return $v; } }' .
            ' my ptr $h = Holder->new();' .
            ' my i64 $n = $h->get();' .
            ' return $n;',
        12,
        'the owned store leaves a plain default intact',
        targets => [@native]
    );
};
done_testing;
