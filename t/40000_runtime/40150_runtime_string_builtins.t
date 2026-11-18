use v5.42;
use Test2::V0;
use blib;
use Brocken;

sub run_brocken ($src) {
    my $brocken = Brocken->new;
    my $module  = $brocken->compile($src);
    my $funcs   = $brocken->codegen->emit_functions( $module->functions );
    my $exe     = $brocken->tmpdir . '/test' . $brocken->ext;
    $brocken->linker->write_executable( $exe, $funcs, $brocken->platform );

    #~ system 'gdb', '--batch', '-ex', 'run',  '-ex', 'bt', '--args', $exe ;
    my $out = `$exe`;
    my $rc  = $? >> 8;

    #~ diag $rc;
    #~ diag $exe;
    #~ diag $out;
    return ( $rc, $out );
}
subtest 'core.brocken string helpers directly' => sub {
    my ( $rc, $out ) = run_brocken(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $s  = "Hello World";
say( Brocken::Runtime::str_len($s) );
say( Brocken::Runtime::str_substr_rest( $hb, $s, 6 ) );
say( Brocken::Runtime::str_substr( $hb, $s, 1, 4 ) );
say( Brocken::Runtime::str_substr( $hb, $s, 1, -1 ) );
say( Brocken::Runtime::str_index( $s, "lo", 0 ) );
say( Brocken::Runtime::str_rindex( $s, "l", 11 ) );
say( Brocken::Runtime::str_lc( $hb, $s ) );
say( Brocken::Runtime::str_uc( $hb, $s ) );
say( Brocken::Runtime::str_lcfirst( $hb, $s ) );
say( Brocken::Runtime::str_ucfirst( $hb, "hello" ) );
exit 0;
BROCKEN
    is $rc,  0,                                                                                  'exit 0';
    is $out, "11\nWorld\nello\nello Worl\n3\n9\nhello world\nHELLO WORLD\nhello World\nHello\n", 'direct runtime string helpers';
};
subtest 'user-facing string builtins (native, Any, edge cases)' => sub {
    my ( $rc, $out ) = run_brocken(<<'BROCKEN');
my $dyn = "Brocken";
say( length($dyn) );
say( length("") );
say( length(undef) );
say( substr( "abcdef", 2 ) );
say( substr( "abcdef", -2 ) );
say( substr( "abcdef", 1, 3 ) );
say( substr( "abcdef", 1, -2 ) );
say( substr( $dyn, 0, 4 ) );
say( index( "bananas", "na" ) );
say( index( "bananas", "na", 3 ) );
say( index( "bananas", "x" ) );
say( rindex( "bananas", "na" ) );
say( rindex( "bananas", "na", 3 ) );
say( rindex( "bananas", "a", -1 ) );
say( lc($dyn) );
say( uc($dyn) );
say( lcfirst($dyn) );
say( ucfirst("brocken") );
exit 0;
BROCKEN
    is $rc,  0,                                                                                             'exit 0';
    is $out, "7\n0\n0\ncdef\nef\nbcd\nbcd\nBroc\n2\n4\n-1\n4\n2\n-1\nbrocken\nBROCKEN\nbrocken\nBrocken\n", 'user-facing string builtins';
};
#
done_testing;
__END__
# perl t/40000_runtime/40150_runtime_string_builtins.t
