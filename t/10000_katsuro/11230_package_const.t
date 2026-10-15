use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `__PACKAGE__` (spec 7, pseudo-constants) evaluates to the package in effect where it is written, as a string. It is
# resolved at parse time -- the parser already stamps `$current_package` onto the nodes it builds -- and folds to an
# ordinary string constant, so it lowers to a NUL-terminated rodata blob like any other string literal. At the top
# level, where no `package` is in effect, it is `main` (the module's name). Wasm is excluded because string literals
# need rodata, which the Wasm backend does not emit yet.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

subtest '__PACKAGE__ is the in-effect package' => sub {
    check( 'return __PACKAGE__ eq "main" ? 1 : 0;',                          1, 'the top level is main' );
    check( 'package P; return __PACKAGE__ eq "P" ? 1 : 0;',                  1, 'a package declaration' );
    check( 'package A::B; return __PACKAGE__ eq "A::B" ? 1 : 0;',            1, 'a nested package name' );
    check( 'package P; return __PACKAGE__ ne "main" ? 1 : 0;',               1, 'a package is not main' );
};

subtest '__PACKAGE__ follows a package block scope' => sub {
    check( 'package Scoped { return __PACKAGE__ eq "Scoped" ? 1 : 0; }',     1, 'inside the block' );
    check( 'package Scoped { } return __PACKAGE__ eq "main" ? 1 : 0;',       1, 'the block package does not leak' );
};

subtest '__PACKAGE__ is a usable string value' => sub {
    check( 'my String $p = __PACKAGE__; return $p eq "main" ? 1 : 0;',       1, 'bound to a String local' );
    check( 'return (__PACKAGE__ . "!") eq "main!" ? 1 : 0;',                 1, 'used in a concatenation' );
};

done_testing;
