use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# Compile a snippet and assert its exit status on every native target that can run here (the host, plus any cross
# target with an emulator and sysroot). The exercising paths -- boxing a bool through `sext i1`, boxing a string
# literal through `lea_rodata` -- are backend-specific, so restricting this to the host left the ARM64 copies of two
# x86-64 fixes uncovered. Wasm is left out: its code generator has no rodata/data-segment support, so a string literal
# cannot be boxed there regardless of this test.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub chk ( $source, $want, $label ) {
    answers( $source, $want, $label, targets => [@native_targets] );
}
subtest 'reftype folds a static scalar to its class-name string' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
sub f() :returns(i64) {
    my i64 $n = 1;
    my String $t = builtin::reftype($n);
    return length($t);
}
return f();
BROCKEN
    ok( !$@, 'compiled reftype program' ) or diag $@;
    my %rodata = %{ $mod->rodata };
    ok( scalar( grep { $_ eq "SCALAR\0" } values %rodata ), 'the SCALAR class-name string is interned in rodata' );
};
subtest 'builtin::true/false versus is_bool' => sub {

    # A `bool` is an i1; boxing it into an `Any` sign- extends the constant, which the encoder had no immediate form
    # for.  `is_bool` answers from the box tag: a narrow-int tag is a bool, a wide-int tag is not.
    chk( 'sub f() :returns(i64) { my bool $b = 1; return builtin::is_bool($b); } return f();',              1, 'static bool is a bool' );
    chk( 'sub f() :returns(i64) { my i64 $n = 1; return builtin::is_bool($n); } return f();',               0, 'a wide int is not a bool' );
    chk( 'sub f() :returns(i64) { my Any $b = builtin::true(); return builtin::is_bool($b); } return f();', 1, 'a boxed true is a bool' );
    chk( 'sub f() :returns(i64) { my Any $n = 5; return builtin::is_bool($n); } return f();',               0, 'a boxed wide int is not a bool' );
};
subtest 'created_as_number and created_as_string' => sub {
    chk( 'sub f() :returns(i64) { my i64 $n = 5; return builtin::created_as_number($n); } return f();', 1, 'an int was created as a number' );
    chk( 'sub f() :returns(i64) { my String $s = "hi"; return builtin::created_as_number($s); } return f();',
        0, 'a string was not created as a number' );
    chk( 'sub f() :returns(i64) { my String $s = "hi"; return builtin::created_as_string($s); } return f();', 1, 'a string was created as a string' );
    chk( 'sub f() :returns(i64) { my i64 $n = 5; return builtin::created_as_string($n); } return f();', 0, 'an int was not created as a string' );
    chk( 'sub f() :returns(i64) { my Any $n = 5; return builtin::created_as_number($n); } return f();', 1, 'a boxed int was created as a number' );
    chk( 'sub f() :returns(i64) { my Any $s = "hi"; return builtin::created_as_string($s); } return f();',
        1, 'a boxed string was created as a string' );
};
subtest 'refaddr answers a non-zero address for a boxed value' => sub {
    chk( 'sub f() :returns(i64) { my Any $n = 5; my u64 $a = builtin::refaddr($n); if ($a > 1000) { return 1; } return 0; } return f();',
        1, 'a boxed value has an address' );
    chk( 'sub f() :returns(i64) { my i64 $n = 5; return builtin::refaddr($n); } return f();', 0, 'a non-reference has no address' );
};
subtest 'stringify renders a value to a string' => sub {
    chk( 'sub f() :returns(i64) { my i64 $n = 12345; my String $s = builtin::stringify($n); return length($s); } return f();',
        5, 'an int stringifies to its digits' );
    chk( 'sub f() :returns(i64) { my Any $n = 12345; my String $s = builtin::stringify($n); return length($s); } return f();',
        5, 'a boxed int stringifies to its digits' );
    chk( 'sub f() :returns(i64) { my String $s = "hi"; my String $t = builtin::stringify($s); return length($t); } return f();',
        2, 'a String is already a string' );

    # Boxing a string literal into an `Any` has to load its address with `lea_rodata`; it used to store an unnamed
    # register and the boxed pointer was garbage.
    chk( 'sub f() :returns(i64) { my Any $s = "hi"; my String $t = builtin::stringify($s); return length($t); } return f();',
        2, 'a boxed string stringifies to its own characters' );
};
subtest 'numify converts a value to a number' => sub {
    chk( 'sub f() :returns(i64) { my i64 $n = 42; return builtin::numify($n); } return f();',       42, 'an int numifies to itself' );
    chk( 'sub f() :returns(i64) { my String $s = "42"; return builtin::numify($s); } return f();',  42, 'a numeric string numifies to its value' );
    chk( 'sub f() :returns(i64) { my String $s = "abc"; return builtin::numify($s); } return f();', 0,  'a non-numeric string numifies to zero' );
    chk( 'sub f() :returns(i64) { my Any $n = 42; return builtin::numify($n); } return f();',       42, 'a boxed int numifies' );

    # Both select arms run, so the string parse must never dereference a non-string payload.
    chk( 'sub f() :returns(i64) { my Any $s = "42"; return builtin::numify($s); } return f();', 42, 'a boxed string numifies' );
};
subtest 'reftype and blessed report an object' => sub {
    my $class = "class Point { field i64 \$x :accessor; }\n";
    chk( $class . 'sub f() :returns(i64) { my ptr $p = Point->new(); my String $t = builtin::reftype($p); return length($t); } return f();',
        6, 'a class instance reftypes as OBJECT' );
    chk( $class . 'sub f() :returns(i64) { my ptr $p = Point->new(); my String $t = builtin::blessed($p); return length($t); } return f();',
        5, 'blessed names the static class' );

    # A box carries only the tag, not the instance's class id, so a class instance boxed into an `Any` reftypes as a
    # plain scalar -- the same tag-4 limitation as a boxed String.
    chk( $class . 'sub f() :returns(i64) { my Any $p = Point->new(); my String $t = builtin::reftype($p); return length($t); } return f();',
        6, 'a boxed class instance reftypes as SCALAR' );
    chk( 'sub f() :returns(i64) { my i64 $n = 1; if (builtin::blessed($n)) { return 1; } return 0; } return f();',
        0, 'blessed of a non-object is undef' );
};
done_testing;
