use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[run_exec];
use Brocken::Katsuro::Lexer;
subtest 'Katsuro Lexer: Tokenizer and gradual typing' => sub {
    my $source = <<'BROCKEN';
    use feature 'brocken_native_types';

    sub allocate_raw( i64 $size ) : NativeReturn(ptr) {
        # Bump allocator
        my ptr $cursor = $Brocken::Runtime::heap_cursor;
        my ptr $next   = Brocken::ptr_add($cursor, $size);

        if (Brocken::ptr_cmp_gt($next, $Brocken::Runtime::heap_limit)) {
            return gc_alloc_slow($size);
        }

        $Brocken::Runtime::heap_cursor = $next;
        return $cursor;
    }
BROCKEN
    my $lexer  = Brocken::Katsuro::Lexer->new( source => $source );
    my $tokens = $lexer->lex();
    is( ref $tokens, 'ARRAY', 'lex returned array ref' );

    # Let's inspect some crucial tokens for self-hosting standard library constructs
    my @idents   = grep { $_->{type} eq 'IDENT' } @$tokens;
    my @keywords = grep { $_->{type} eq 'KEYWORD' } @$tokens;
    my @vars     = grep { $_->{type} eq 'VAR' } @$tokens;

    # Exposes native types as keywords
    ok( ( grep { $_->{value} eq 'i64' } @keywords ), 'Recognizes native unboxed type i64' );
    ok( ( grep { $_->{value} eq 'ptr' } @keywords ), 'Recognizes native pointer type ptr' );

    # Lexes standard Perl sigils cleanly
    ok( ( grep { $_->{value} eq '$size' } @vars ), 'Lexes standard variable $size' );

    # Lexes dynamic memory intrinsics using the package qualified pseudo-namespace
    ok( ( grep { $_->{value} eq 'Brocken::ptr_add' } @idents ), 'Lexes package-qualified builtin Brocken::ptr_add as IDENT' );
    ok( ( grep { $_->{value} eq '$Brocken::Runtime::heap_cursor' } @vars ),
        'Lexes package-qualified global variable $Brocken::Runtime::heap_cursor' );

    # Check that EOF token exists
    is( $tokens->[-1]{type}, 'EOF', 'Token stream ends with EOF sentinel' );
};
subtest 'Lexer error includes filename' => sub {
    my $lexer = Brocken::Katsuro::Lexer->new( source => "my i64 \$x = \x80;", filename => 'test.br' );
    my $err   = eval { $lexer->lex(); undef } // $@;
    ok( $err, 'lex error thrown' );
    like( $err, qr/test\.br/, 'error mentions filename' );
    like( $err, qr/line 1/,   'error mentions line' );
    like( $err, qr/col 13/,   'error mentions col' );
};
subtest 'Lexer error default filename' => sub {
    my $lexer = Brocken::Katsuro::Lexer->new( source => "\x80" );
    my $err   = eval { $lexer->lex(); undef } // $@;
    like( $err, qr/\(eval\)/, 'default filename is (eval)' );
};
subtest 'FLOAT token for float literals' => sub {
    my $lexer  = Brocken::Katsuro::Lexer->new( source => '42.5 + 3.0' );
    my $tokens = $lexer->lex();
    my @floats = grep { $_->{type} eq 'FLOAT' } @$tokens;
    my @nums   = grep { $_->{type} eq 'NUM' } @$tokens;
    is( scalar @floats,      2,    'two FLOAT tokens found' );
    is( $floats[0]->{value}, 42.5, 'first FLOAT value is 42.5' );
    is( $floats[1]->{value}, 3.0,  'second FLOAT value is 3.0' );
    is( scalar @nums,        0,    'no NUM tokens from float literals' );
};
subtest 'FLOAT/NUM disambiguation: integer after float' => sub {
    my $lexer  = Brocken::Katsuro::Lexer->new( source => '3.14 99' );
    my $tokens = $lexer->lex();
    my @floats = grep { $_->{type} eq 'FLOAT' } @$tokens;
    my @nums   = grep { $_->{type} eq 'NUM' } @$tokens;
    is( scalar @floats,      1,    'one FLOAT token' );
    is( $floats[0]->{value}, 3.14, 'FLOAT value is 3.14' );
    is( scalar @nums,        1,    'one NUM token' );
    is( $nums[0]->{value},   99,   'NUM value is 99' );
};
subtest 'STRING token decodes backslash escapes' => sub {
    my $lexer  = Brocken::Katsuro::Lexer->new( source => q{"line\nnext\tend\\slash\"quote"} );
    my $tokens = $lexer->lex();
    my ($str)  = grep { $_->{type} eq 'STRING' } @$tokens;
    is( $str->{value}, "line\nnext\tend\\slash\"quote", 'escapes are decoded, not left literal' );
    my $lexer2 = Brocken::Katsuro::Lexer->new( source => q{'single\ttab'} );
    my ($str2) = grep { $_->{type} eq 'STRING' } @{ $lexer2->lex() };
    is( $str2->{value}, "single\ttab", 'single-quoted escapes decoded too' );
};
subtest 'FLOAT token for exponent and leading-dot notation' => sub {
    my $lexer  = Brocken::Katsuro::Lexer->new( source => '1e-5 2.5E10 .5 3.0e2' );
    my $tokens = $lexer->lex();
    my @floats = grep { $_->{type} eq 'FLOAT' } @$tokens;
    my @nums   = grep { $_->{type} eq 'NUM' } @$tokens;
    is( scalar @floats,      4,      'all four literals are FLOAT' );
    is( $floats[0]->{value}, 1e-5,   '1e-5' );
    is( $floats[1]->{value}, 2.5e10, '2.5E10' );
    is( $floats[2]->{value}, 0.5,    '.5' );
    is( $floats[3]->{value}, 300,    '3.0e2' );
    is( scalar @nums,        0,      'no NUM tokens' );
};
done_testing;
