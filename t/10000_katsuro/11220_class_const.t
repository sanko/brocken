use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `__CLASS__` (spec 7, pseudo-constants) evaluates to the current class's name as a string. It used to lower to a `ptr`
# *constant* whose value was the class name, but a constant's value is numified by the encoder, so the string `C` became
# the address 0 -- a null pointer that could be mentioned without croaking but was not a usable class handle. It now
# lowers exactly like a string literal: a NUL-terminated rodata blob holding the qualified class name, which is the
# value `perlclass` gives and what `say(__CLASS__)` prints. Wasm is excluded because string literals need rodata, which
# the Wasm backend does not emit yet.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

subtest '__CLASS__ is the class name string' => sub {
    check( <<'BROCKEN', 1, 'the name compares equal to its spelling' );
class C {
    method is_named() :returns(bool) { return __CLASS__ eq "C"; }
}
my ptr $c = C->new();
return $c->is_named() ? 1 : 0;
BROCKEN
    check( <<'BROCKEN', 1, 'the name is a usable string in a concatenation' );
class C {
    method is_named() :returns(bool) { return (__CLASS__ . "!") eq "C!"; }
}
my ptr $c = C->new();
return $c->is_named() ? 1 : 0;
BROCKEN
    check( <<'BROCKEN', 1, 'the name is a usable value in a variable' );
class C {
    method is_named() :returns(bool) {
        my String $name = __CLASS__;
        return $name eq "C";
    }
}
my ptr $c = C->new();
return $c->is_named() ? 1 : 0;
BROCKEN
};

subtest '__CLASS__ is qualified by the enclosing package' => sub {
    check( <<'BROCKEN', 1, 'the name carries the package prefix' );
package P;
class C {
    method is_named() :returns(bool) { return __CLASS__ eq "P::C"; }
}
my ptr $c = C->new();
return $c->is_named() ? 1 : 0;
BROCKEN
    check( <<'BROCKEN', 0, 'the bare class name does not match the qualified one' );
package P;
class C {
    method is_named() :returns(bool) { return __CLASS__ eq "C"; }
}
my ptr $c = C->new();
return $c->is_named() ? 1 : 0;
BROCKEN
};

subtest '__CLASS__ is usable from a field initializer' => sub {
    check( <<'BROCKEN', 1, 'a field default captures the class name' );
class C {
    field ptr $tag :reader = __CLASS__;
}
my ptr $c = C->new();
return $c->tag() eq "C" ? 1 : 0;
BROCKEN
};

subtest '__CLASS__ used outside a class is still a compile error' => sub {
    my $ok = eval { Brocken->new->compile('return __CLASS__ eq "x" ? 1 : 0;'); 1 };
    ok( !$ok, 'a bare __CLASS__ does not compile' );
    like( $@, qr/__CLASS__ used outside of a class/, 'the error names __CLASS__' );
};

done_testing;
