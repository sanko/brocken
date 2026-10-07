use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers];

# Array variables are keyed in the symbol table as '@name', but lower_assign looked the assignment target up as 'name',
# so `@dst = @src` died with "Undefined variable 'dst'" even though the array had been declared.
subtest 'assigning to an array variable resolves the @ sigil' => sub {
    answers( 'my [i64; 3] @src; my [i64; 3] @dst; @dst = @src; return @dst[0] ? 1 : 0;', 1,
        'array-to-array assignment compiles and the base pointer lands in slot 0' );
};
done_testing;