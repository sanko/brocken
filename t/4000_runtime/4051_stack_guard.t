use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'stack guard fires before the OS guard page' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 6 unless $host->is_native;
        my $run_case = sub ( $name, $source, $expect ) {
            my $module = eval { $brocken->compile($source) };
            if ( my $e = $@ ) {
                ok( 0, "$name compiles" );
                diag("compile failed: $e");
                return;
            }
            my $funcs = eval { $brocken->codegen->emit_functions( $module->functions ) };
            if ( my $e = $@ ) {
                ok( 0, "$name codegens" );
                diag("codegen failed: $e");
                return;
            }
            my $file = $brocken->tmpdir . "/r_stk_$name" . $brocken->ext;
            eval { $brocken->linker->write_executable( $file, $funcs, $host ) };
            if ( my $e = $@ ) {
                ok( 0, "$name links" );
                diag("link failed: $e");
                return;
            }
            ok( 1, "$name links" );
            run_exec( $file, expected_exit => $expect, name => "$name exit $expect", platform => $host );
            unlink $file;
        };

        my $driver = sub {
            my $f = shift;
            return <<"BROCKEN";
use feature 'brocken_native_types';
sub f(i64 \$n) -> i64 {
    my i64 \$x = 0;
    if (\$n > 0) { \$x = f(\$n - 1); }
    return \$x + 1;
}
$f
BROCKEN
        };

        # Guard fires on deep recursion and unwinds gracefully; the program then
        # reports ICB.err_code (ERR_STACK = 6) instead of overrunning the stack.
        $run_case->(
            'deep',
            $driver->('my i64 $r = f(100000); my ptr $hb = Brocken::heap_base(); my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72)); return $err;'),
            6
        );

        # A shallow recursion stays under the line and returns normally.  f(n) = n+1,
        # so f(3000) = 3001, which the OS truncates to a one-byte exit status (185).
        $run_case->( 'shallow', $driver->('my i64 $r = f(3000); return $r;'), 185 );

        # The guard must not disturb programs that ignore err_code: deep recursion
        # hits the guard, every over-limit frame returns 0, and main exits cleanly.
        $run_case->( 'deep_clean', $driver->('my i64 $r = f(100000); return 0;'), 0 );

        # With a live try/catch handler the guard longjmps to it exactly like throw.
        $run_case->(
            'catch_deep',
            $driver->(<<'BROCKEN')
sub main() -> i64 {
    my i64 $caught = -1;
    try {
        my i64 $r = f(200000);
        $caught = 0;
    } catch ($e) {
        $caught = 42;
    }
    return $caught;
}
return main();
BROCKEN
            ,
            42
        );

        # Control: the setjmp/longjmp machinery behind the guard still handles an
        # ordinary throw with no stack pressure involved.
        $run_case->(
            'throw_control',
            $driver->(<<'BROCKEN')
sub main() -> i64 {
    my i64 $caught = -1;
    try {
        throw 7;
        $caught = 0;
    } catch ($e) {
        $caught = 3;
    }
    return $caught;
}
return main();
BROCKEN
            ,
            3
        );
    }
};
done_testing;