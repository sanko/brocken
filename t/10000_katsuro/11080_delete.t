use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# `delete %h{key}` removes the entry and returns the value that was there as an owned `Any` box, or undef (a null box)
# when the key was absent. The deleted box's reference is transferred to the caller, so a discarded `delete` statement
# releases it and a slot that stores the result consumes it -- neither doubles a reference nor dangles one.
#
# Every case needs rodata (the string keys), which the Wasm backend does not emit yet, so they run on the native
# targets only. The exit code carries the answer home.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub run_case {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

# The return value is the deleted value: unboxed into a native slot, or kept as a box.
subtest 'delete returns the value it removed' => sub {
    run_case( 'my %h; %h{"k"} = 42; my i64 $v = delete %h{"k"}; return $v;', 42, 'the deleted integer is returned' );
    run_case( 'my %h; %h{"k"} = 7; my Any $v = delete %h{"k"}; return $v;',  7,  'the deleted box is returned' );
    run_case( 'my %h; %h{"k"} = "abc"; my String $s = delete %h{"k"}; return length($s);', 3,
        'the deleted string is returned' );
};

# The entry is gone afterwards, and only that entry.
subtest 'delete removes exactly one entry' => sub {
    run_case( 'my %h; %h{"k"} = 1; delete %h{"k"}; if (exists %h{"k"}) { return 1; } return 0;', 0,
        'the deleted key no longer exists' );
    run_case( 'my %h; %h{"a"} = 1; %h{"b"} = 2; %h{"c"} = 3; delete %h{"b"}; return %h{"a"} + %h{"c"};', 4,
        'the other keys survive' );
    run_case( 'my %h; %h{"a"} = 1; %h{"b"} = 2; delete %h{"a"}; if (exists %h{"a"}) { return 1; } if (!exists %h{"b"}) { return 2; } return 3;', 3,
        'the deleted key is gone while its neighbour remains' );
};

# A missing key deletes nothing and returns undef.
subtest 'delete of a missing key returns undef' => sub {
    run_case( 'my %h; my Any $v = delete %h{"x"}; if (defined $v) { return 1; } return 0;', 0,
        'a missing key yields an undefined box' );
    run_case( 'my %h; if (delete %h{"x"}) { return 1; } return 0;', 0, 'a missing key is false' );
};

# A delete leaves a tombstone, so a probe that walks past it still reaches a later key in the same cluster.
subtest 'a tombstone does not hide a later key' => sub {
    run_case( 'my %h; %h{"a"} = 1; %h{"b"} = 2; %h{"c"} = 3; %h{"d"} = 4; delete %h{"b"}; if (exists %h{"b"}) { return 1; } return %h{"a"} + %h{"c"} + %h{"d"};', 8,
        'the keys after the deleted one are still found' );
    run_case( 'my %h; %h{"k"} = 1; delete %h{"k"}; %h{"k"} = 9; return %h{"k"};', 9,
        'a deleted key can be reinserted' );
    run_case( 'my %h; my i64 $i = 0; while ($i < 16) { %h{$i} = $i; $i = $i + 1; } delete %h{3}; delete %h{7}; return %h{0} + %h{15};', 15,
        'delete survives a table that grew past its first capacity' );
};

# A discarded delete statement releases the box it removed; it must not fault before the next statement runs.
subtest 'a discarded delete statement is safe' => sub {
    run_case( 'my %h; %h{"k"} = 1; delete %h{"k"}; return 0;', 0, 'delete as a statement' );
    run_case( 'my %h; %h{"k"} = 1; delete %h{"k"}; if (exists %h{"k"}) { return 1; } return 0;', 0,
        'exists of the just-deleted key is false, not a fault' );
};

# `delete` is only meaningful on a hash element.
subtest 'delete rejects a non-hash-element argument' => sub {
    my $brocken = Brocken->new();
    my $err = do { local $@; eval { $brocken->compile('my i64 $x = 1; delete $x;'); 1 } ? '' : $@ };
    like( $err, qr/delete expects a hash element/, 'delete of a scalar is a compile error' );
};

done_testing;
