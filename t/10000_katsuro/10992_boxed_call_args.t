use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# Strings and class objects are raw memory/rodata, which the Wasm backend does not model, so run on native targets.
my @native = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub answers_native {
    my ( $src, $want, $name ) = @_;
    answers( $src, $want, $name, targets => [@native] );
}

# A user parameter whose Brocken type maps to `ptr` (`String`, a class, a raw `ptr`) is a pointer to the payload, but a
# dynamic argument is the *box* pointer (the runtime helpers read the header through it). The call site therefore has to
# unbox a dynamic argument for such a parameter and leave an `Any` parameter's box alone. Before this, only assignment
# and return sites unboxed, so `sub f(String $s)` called with `$any` read the box header (`length` answered 1).
subtest 'an Any argument to a String parameter reads the wrapped string' => sub {
    answers_native(
        'sub slen(String $s) :returns(i64) { return length($s); } my $any = "hello"; return slen($any);',
        5, 'length() sees the payload, not the box header'
    );
    answers_native(
        'sub slen(String $s) :returns(i64) { return length($s); }'
            . ' sub mk() :returns(Any) { my $u = "hello!"; return $u; } return slen(mk());',
        6, 'an Any returned from a function is unboxed at the call it is passed to'
    );
};

subtest 'an Any argument to a raw ptr parameter is unboxed' => sub {
    answers_native(
        'sub slen(ptr $p) :returns(i64) { return length($p); } my $any = "hello"; return slen($any);',
        5, 'a ptr parameter takes the payload the same way a String parameter does'
    );
};

subtest 'an Any argument to a method parameter is converted too' => sub {
    answers_native(
        'class C { method slen(String $s) :returns(i64) { return length($s); } }'
            . ' my ptr $c = C->new(); my $any = "hello!"; return $c->slen($any);',
        6, 'a method user argument is unboxed the same way as a plain call argument'
    );
};

subtest 'a trailing default bound to an Any value is unboxed' => sub {
    answers_native(
        'sub f(Any $a, String $s = $a) :returns(i64) { return length($s); } my $any = "hey"; return f($any);',
        3, 'the omitted String parameter takes the payload of the bound Any argument'
    );
};

subtest 'an Any argument to an Any parameter keeps its box' => sub {
    answers_native(
        'sub id(Any $v) :returns(Any) { return $v; } my $x = 5; return id($x);',
        5, 'a dynamic parameter leaves the box in place'
    );
};

subtest 'a String value is not unboxed again' => sub {
    answers_native(
        'sub slen(String $s) :returns(i64) { return length($s); } my String $s = "abcd"; return slen($s);',
        4, 'a value already in a String slot is passed straight through'
    );
};

done_testing;
