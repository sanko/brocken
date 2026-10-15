use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `__LINE__` and `__FILE__` (spec 7, pseudo-constants) fold at parse time to the line and filename of the token where
# they appear: the lexer already stamps `line`/`col` on every token and carries the `filename` the compiler was opened
# with. `__LINE__` folds to an ordinary `Int` constant and `__FILE__` to a `String` constant, so both lower through the
# normal constant path -- no new lowering is involved. (`__FILE__` reports whatever name the unit was compiled under;
# with modules still pending that is the caller-supplied name, `(eval)` by default.) Wasm is excluded from the runtime
# checks because `__FILE__` is a string literal, which needs rodata the Wasm backend does not emit yet; the parse-level
# checks run everywhere.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

sub return_expr {
    my ($source) = @_;
    my $prog = Brocken->new->parse( $source, @_[ 1 .. $#_ ] );
    return $prog->statements->[0]->expr;
}

subtest '__LINE__ folds to the token line' => sub {
    is( return_expr('return __LINE__;')->value,    1, 'the first line is line 1' );
    is( return_expr("\nreturn __LINE__;")->value,  2, 'a leading newline shifts the count' );
    is( return_expr("\n\nreturn __LINE__;")->value, 3, 'two leading newlines' );
    my $prog = Brocken->new->parse("return 0;\nreturn __LINE__;");
    is( $prog->statements->[1]->expr->value, 2, 'the second statement is on line 2' );
};

subtest '__FILE__ folds to the compilation unit name' => sub {
    is( return_expr( 'return __FILE__;' )->value,                '(eval)',      'the default filename' );
    is( return_expr( 'return __FILE__;', 'src/thing.bk' )->value, 'src/thing.bk', 'a caller-supplied filename' );
};

subtest '__PACKAGE__ also parses to a string constant' => sub {
    my $prog = Brocken->new->parse('package P; return __PACKAGE__;');
    is( $prog->statements->[1]->expr->value, 'P', 'the enclosing package' );
};

subtest '__LINE__ and __FILE__ run' => sub {
    check( 'return __LINE__;',                        1, 'a line number is returned as an integer' );
    check( "\nreturn __LINE__;",                      2, 'the shifted line number' );
    check( 'return __FILE__ eq "(eval)" ? 1 : 0;',    1, 'the filename is the compilation unit name' );
    check( 'return (__FILE__ . ":" . __LINE__) eq "(eval):1" ? 1 : 0;', 1, 'both in one expression' );
};

done_testing;
