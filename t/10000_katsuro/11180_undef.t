use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `undef` (spec 3.3) is the null value and a mutator: `$x = undef` resets a scalar to null, `undef $x` is that same
# assignment, and `undef @a` / `undef %h` empty a container in place. The value literal is a null box (Type Tag 0);
# `maybe_convert_type` turns it into a native zero or a null pointer so it works in any slot. Wasm is excluded because
# the string-literal cases need rodata, which the Wasm backend does not emit yet.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}
subtest 'undef is the undefined value' => sub {
    check( 'my Any $x = undef; return defined($x) ? 1 : 0;', 0, 'an Any initialised with undef is undefined' );
    check( 'return defined(undef) ? 1 : 0;',                 0, 'the undef literal is undefined' );
    check( 'if (undef) { return 1; } return 0;',             0, 'undef is false in a condition' );
};
subtest 'assigning undef clears a managed or native slot' => sub {
    check( 'my Any $x = 5; $x = undef; return defined($x) ? 1 : 0;',       0, 'an Any slot becomes undefined' );
    check( 'my i64 $x = 5; $x = undef; return $x;',                        0, 'a native slot resets to zero' );
    check( 'my f64 $x = 1.5; $x = undef; return $x + 0;',                  0, 'a float slot resets to zero' );
    check( 'my String $s = "hi"; $s = undef; return defined($s) ? 1 : 0;', 0, 'a String slot becomes null (not a wild read)' );
};
subtest 'undef as a call argument and a return value' => sub {
    check( 'sub d(Any $x) :returns(i64) { return defined($x) ? 1 : 0; } return d(undef);',         0, 'undef passes as an undefined argument' );
    check( 'sub d(Any $x) :returns(i64) { return defined($x) ? 1 : 0; } return d(3);',             1, 'a real argument is defined' );
    check( 'sub f() :returns(Any) { return undef; } my Any $y = f(); return defined($y) ? 1 : 0;', 0, 'a function can return undef' );
};
subtest 'undef($x) / undef $x reset a scalar in place' => sub {
    check( 'my Any $x = 9; undef($x); return defined($x) ? 1 : 0;',             0, 'the parenthesised mutator clears the slot' );
    check( 'my Any $x = 9; undef $x; return defined($x) ? 1 : 0;',              0, 'the bare mutator clears the slot' );
    check( 'my Any $x = 9; my Any $y = undef($x); return defined($y) ? 1 : 0;', 0, 'the mutator also yields the (undefined) value' );
    check( 'my Any $x = "hello"; undef($x); return 6;',                         6, 'clearing a string slot drops the old box without crashing' );
};
subtest 'undef interacts with //= and defined' => sub {
    check( 'my Any $x = undef; $x //= 4; return $x;',         4, '//= fires on an undef slot' );
    check( 'my Any $x = 1; $x = undef; $x //= 4; return $x;', 4, '//= fires after an undef reset' );
};
subtest 'undef empties an i64 array' => sub {
    check( 'my [i64] @a; push @a, 1; push @a, 2; push @a, 3; undef @a; my i64 $n = push @a, 9; return $n;',
        1, 'a growable array is empty after undef (the next push is element 0)' );
    check( 'my [i64] @a; push @a, 5; undef @a; return pop @a;',                                  0, 'popping an emptied growable array yields 0' );
    check( 'my [i64; 3] @a; @a[0]=1; @a[1]=2; @a[2]=3; undef @a; return @a[0] + @a[1] + @a[2];', 0, 'a fixed stack array has its elements zeroed' );
};
subtest 'undef empties an Any array' => sub {
    check( 'my [Any; 2] @a; @a[0]=7; @a[1]=8; undef @a; return defined(@a[0]) ? 1 : 0;', 0, 'a managed array drops its elements to undef' );
    check( 'my [Any; 2] @a; @a[0]=7; undef @a; @a[1]=9; return @a[1];',                  9, 'a managed array stays usable after undef' );

    # Each iteration boxes a fresh integer and stores it, then `undef @a` releases it. If the release were missing, the
    # Immix bump cursor would walk past a 4 KiB guard within the loop.
    check(
        'my ptr $hb = Brocken::heap_base(); my [Any; 1] @a;' .
            ' my ptr $before = Brocken::Runtime::immix_cursor($hb); my i64 $i = 0;' .
            ' while ($i < 1000) { @a[0] = $i; undef @a; $i = $i + 1; }' .
            ' my ptr $after = Brocken::Runtime::immix_cursor($hb);' .
            ' if (Brocken::ptr_cmp_gt($after, Brocken::ptr_add($before, 4096))) { return 1; }' .
            ' return 0;',
        0,
        'emptying a managed array releases the boxes it held'
    );
};
subtest 'undef empties a hash' => sub {
    check( 'my %h; %h{"a"}=1; %h{"b"}=2; undef %h; for my $k (keys %h) { return 1; } return 2;', 2, 'no key remains after undef' );
    check( 'my %h; %h{"a"}=1; undef %h; return defined(%h{"a"}) ? 1 : 0;',                       0, 'a cleared entry reads as undefined' );
    check( 'my %h; %h{"a"}=1; undef %h; %h{"b"}=5; return %h{"b"};',                             5, 'the hash stays usable after undef' );
    check( 'my %h; %h{"a"}="x"; %h{"b"}="y"; undef %h; return 3;', 3, 'clearing a hash with string values does not crash' );
};
subtest 'undef appears in a list' => sub {
    check( 'my (Any $a, Any $b) = (1, undef); return defined($b) ? 1 : 0;', 0, 'an undef list element stays undefined' );
    check( 'my (Any $a, Any $b) = (1, undef); return $a;',                  1, 'the defined element is untouched' );
};
subtest 'a bare undef statement is allowed' => sub {
    check( 'undef; return 7;',                    7, 'the bare literal statement is harmless' );
    check( 'my Any $x = 1; undef($x); return 7;', 7, 'the mutator statement is harmless' );
};
subtest 'undef parses as Expr::Undef / Expr::UndefOp' => sub {
    my $c    = Brocken->new;
    my $prog = $c->parse('sub foo() :returns(i64) { my Any $x = undef; return 0; }');
    my $decl = $prog->statements->[0]->body->statements->[0];
    isa_ok( $decl,       ['Brocken::Katsuro::AST::Stmt::VarDecl'] );
    isa_ok( $decl->init, ['Brocken::Katsuro::AST::Expr::Undef'] );
    my $prog2 = $c->parse('sub bar() :returns(i64) { my Any $x = 1; undef($x); return 0; }');
    my $stmt2 = $prog2->statements->[0]->body->statements->[1];
    isa_ok( $stmt2,       ['Brocken::Katsuro::AST::Expr::UndefOp'] );
    isa_ok( $stmt2->expr, ['Brocken::Katsuro::AST::Expr::Var'] );
    is( $stmt2->expr->sigil, '$', 'the operand keeps its sigil' );
    my $prog3 = $c->parse('sub baz() :returns(i64) { my [i64] @a; undef @a; return 0; }');
    my $stmt3 = $prog3->statements->[0]->body->statements->[1];
    isa_ok( $stmt3, ['Brocken::Katsuro::AST::Expr::UndefOp'] );
    is( $stmt3->expr->sigil, '@', 'an array operand keeps the @ sigil' );
};
subtest 'unsupported operands are rejected at compile time' => sub {
    my $c = Brocken->new;
    eval { $c->compile('sub f() :returns(i64) { undef(5); return 0; }') };
    like( $@, qr/Assignment target/, 'undef of a literal is rejected' );
    eval { $c->compile('sub g() :returns(i64) { undef($x); return 0; }') };
    like( $@, qr/Undefined variable/, 'undef of an undeclared variable is rejected' );
};
done_testing;
