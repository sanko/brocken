use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `keys %h` / `values %h` (spec 6.2) lower to the runtime open-addressing table (src/runtime/core.brocken). Both return a
# tag-7 list -- the same shape an `Expr::List` builds -- read in the order each key was first inserted. The table threads
# a doubly-linked list through its buckets for that order, so it survives overwrites, deletes, and rehashes. Wasm is
# excluded because string-literal keys need rodata, which the Wasm backend does not emit yet.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}
subtest 'keys yields the keys in insertion order' => sub {
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; my i64 $t=0; for my $k (keys %h) { $t = $t*10 + %h{$k}; } return $t;',
        123, 'the values read back through the keys follow insertion order' );

    # Inserting in the opposite order iterates in that order: b was inserted first, so it leads even though a sorts
    # before it.
    check( 'my %h; %h{"b"}=2; %h{"a"}=1; my i64 $t=0; for my $k (keys %h) { $t = $t*10 + %h{$k}; } return $t;',
        21, 'reversing the insertion order reverses the iteration order' );

    # The keys are the actual key bytes: "hi" starts with 'h' (104).
    check( 'my %h; %h{"hi"}=1; for my $k (keys %h) { return Brocken::load_i8( Brocken::Runtime::unbox_ptr($k) ); } return 0;',
        104, 'a key box holds the key string' );
};
subtest 'values yields the stored values in insertion order' => sub {
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; my i64 $t=0; for my $v (values %h) { $t = $t*10 + $v; } return $t;',
        123, 'values follow insertion order' );
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; %h{"a"}=9; my i64 $t=0; for my $v (values %h) { $t = $t*10 + $v; } return $t;',
        92, 'an overwrite keeps the key in place but reports the new value' );
};
subtest 're-assigning a key keeps its position' => sub {
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; %h{"b"}=9; my i64 $t=0; for my $k (keys %h) { $t = $t*10 + %h{$k}; } return $t;',
        193, 'the second key still iterates second' );
};
subtest 'deleting a key unlinks it from the order' => sub {
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; delete %h{"a"}; my i64 $t=0; for my $k (keys %h) { $t = $t*10 + %h{$k}; } return $t;',
        23, 'removing the head leaves the rest in order' );
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; delete %h{"b"}; my i64 $t=0; for my $k (keys %h) { $t = $t*10 + %h{$k}; } return $t;',
        13, 'removing an interior key links its neighbours' );
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; delete %h{"c"}; my i64 $t=0; for my $k (keys %h) { $t = $t*10 + %h{$k}; } return $t;',
        12, 'removing the tail moves the tail back' );
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; delete %h{"a"}; my i64 $n=0; for my $k (keys %h) { $n=$n+1; } return $n;',
        2, 'a deleted key is not counted' );
};
subtest 'a key inserted after a delete goes to the tail' => sub {
    check(
        'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; delete %h{"b"}; %h{"d"}=4;' .
            ' my i64 $t=0; for my $k (keys %h) { $t = $t*10 + %h{$k}; } return $t;',
        134,
        'the new key iterates last, after the surviving a and c'
    );
};
subtest 'an empty hash yields an empty list' => sub {
    check( 'my %h; my i64 $t=7; for my $k (keys %h) { $t=1; } return $t;',   7, 'keys of an empty hash never iterates' );
    check( 'my %h; my i64 $t=7; for my $v (values %h) { $t=1; } return $t;', 7, 'values of an empty hash never iterates' );
};
subtest 'insertion order survives a rehash' => sub {

    # 12 keys force the table through 8 and 16 buckets. The doubling checksum is order-sensitive, so a rehash that
    # scanned the bucket area instead of the order list would reshuffle the entries and change the result.
    my @names = 'a' .. 'l';
    my $src   = 'my %h;' . join( '', map { qq{ %h{"$names[$_]"}=} . ( $_ + 1 ) . ';' } 0 .. 11 );
    my $t     = 0;
    $t = ( $t * 2 + ( $_ + 1 ) ) % 256 for 0 .. 11;
    check( $src . ' my i64 $t=0; for my $k (keys %h) { $t = ($t*2 + %h{$k}) % 256; } return $t;', $t, "the order checksum is $t after two rehashes" );

    # Every entry is still present: the plain sum of the values 1..12 is 78.
    check( $src . ' my i64 $s=0; for my $v (values %h) { $s = $s + $v; } return $s;', 78, 'values still sum to 78 after growing' );
};
subtest 'a keys/values list destructures in order' => sub {
    check( 'my %h; %h{"a"}=10; %h{"b"}=20; my (Any $x, Any $y) = values %h; return $x*10 + $y;',
        120, 'values destructure into the declared slots in order' );
    check( 'my %h; %h{"hi"}=1; my (String $k) = keys %h; return Brocken::load_i8($k);', 104, 'a keys element destructures into a String slot' );
};
subtest 'values returns an owning snapshot of each stored box' => sub {

    # `values` takes a reference for the list it builds, so overwriting the table afterwards leaves the snapshot holding
    # the original box rather than a freed one.
    check( 'my %h; %h{"a"}=42; my (Any $v) = values %h; %h{"a"}=7; return $v;', 42, 'the captured value survives the table overwriting it' );
};
subtest 'a bare keys/values statement is allowed' => sub {
    check( 'my %h; %h{"a"}=1; keys %h; values %h; return 7;', 7, 'discarding the list is harmless' );
};
subtest 'keys/values parse as Expr::HashKeys over a hash variable' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(i64) { my %h; my Any $k = keys %h; return 0; }');
    my $body = $prog->statements->[0]->body->statements;
    my $decl = $body->[1];
    isa_ok( $decl,       ['Brocken::Katsuro::AST::Stmt::VarDecl'] );
    isa_ok( $decl->init, ['Brocken::Katsuro::AST::Expr::HashKeys'] );
    is( $decl->init->op, 'keys', 'the op is keys' );
    isa_ok( $decl->init->expr, ['Brocken::Katsuro::AST::Expr::Var'] );
    is( $decl->init->expr->sigil, '%', 'the operand keeps the % sigil' );
    my $prog2 = $c->parse('sub bar() :returns(i64) { my %h; my Any $v = values %h; return 0; }');
    my $body2 = $prog2->statements->[0]->body->statements;
    isa_ok( $body2->[1]->init, ['Brocken::Katsuro::AST::Expr::HashKeys'] );
    is( $body2->[1]->init->op, 'values', 'the op is values' );
};
subtest 'unsupported operands are rejected at compile time' => sub {
    my $c = Brocken->new;
    eval { $c->compile('my Any $z = keys $x;') };
    like( $@, qr/keys expects a hash variable/, 'keys of a scalar is rejected' );
    eval { $c->compile('my Any $z = values 5;') };
    like( $@, qr/values expects a hash variable/, 'values of a literal is rejected' );
    eval { $c->compile('my @a; my Any $z = keys @a;') };
    like( $@, qr/keys expects a hash variable/, 'keys of an array is rejected' );
    eval { $c->compile('my %h; my Any $z = keys %h{"a"};') };
    like( $@, qr/keys expects a hash variable/, 'keys of a hash element is rejected' );
};
done_testing;
