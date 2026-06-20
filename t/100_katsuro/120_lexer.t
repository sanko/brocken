use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
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
done_testing;
