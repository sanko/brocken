use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# Perl makes the `;` optional on the last statement of a block: the statement right in front of a closing `}` (or the
# end of the file) needs no terminator, while a statement in the middle still does -- without a `;` the parser cannot
# tell where one statement ends and the next begins, so `my $x = 1 return $x` stays an error. This holds for every kind
# of block: a sub or method body, an `if`/`while`/`for` body, a bare block, a class body, and the top level.
#
# The behaviour cases use `exit(...)` so the entry point's value is an i64 with no string boxing, and run on the native
# targets only: a top-level `return` pulls in the `write`-based warning the Wasm backend cannot link (see
# `11260_implicit_return.t`).
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
sub native_case { answers( $_[0], $_[1], $_[2], targets => [@native_targets] ) }
subtest 'the final statement of a sub body may omit its semicolon' => sub {
    native_case( 'sub seven() :returns(i64) { return 7 } exit(seven());',                        7, 'a final return' );
    native_case( 'sub seven() :returns(i64) { 7 } exit(seven());',                               7, 'a final expression (implicit return)' );
    native_case( 'sub seven() :returns(i64) { my i64 $x = 7; $x } exit(seven());',               7, 'a final variable read' );
    native_case( 'sub seven() :returns(i64) { my i64 $x = 7; $x = 8; return 7 } exit(seven());', 7, 'an earlier statement still has its semicolon' );
};
subtest 'the final statement of a control-flow body may omit its semicolon' => sub {
    native_case( 'sub f() :returns(i64) { if (true) { return 1 } return 2; } exit(f());',                               1, 'an if body' );
    native_case( 'sub f() :returns(i64) { my i64 $i = 0; while ($i < 3) { $i = $i + 1 } return $i; } exit(f());',       3, 'a while body' );
    native_case( 'sub f() :returns(i64) { my i64 $n = 0; for my $x (1, 2, 3) { $n = $n + $x } return $n; } exit(f());', 6, 'a for body' );
};
subtest 'the final statement of a bare or try block may omit its semicolon' => sub {
    native_case( 'sub f() :returns(i64) { { return 3 } return 4; } exit(f());', 3, 'a bare block' );
    native_case( 'try { exit(6) } catch ($e) { exit(7) }',                      6, 'a try body' );
};
subtest 'the final statement at the top level may omit its semicolon' => sub {
    native_case( 'exit(5)',                     5, 'a final exit' );
    native_case( 'my i64 $x = 5; exit($x)',     5, 'a final exit after a terminated statement' );
    native_case( 'my i64 $x = 5; exit($x + 0)', 5, 'a final expression' );
};
subtest 'a final postfix modifier may omit the semicolon' => sub {
    native_case( 'sub f() :returns(i64) { return 1 if true } exit(f());',                      1, 'return ... if, no semicolon' );
    native_case( 'sub f() :returns(i64) { return if false; 9 } exit(f());',                    9, 'a bare return with a modifier' );
    native_case( 'sub f() :returns(i64) { my i64 $x = 9; return $x unless false } exit(f());', 9, 'unless modifier' );
};
subtest 'a class body final field may omit its semicolon' => sub {
    native_case( 'class C { field i64 $x = 9 } my $c = C->new(); exit($c->x);', 9, 'a final field declaration' );
    native_case( 'class C { field i64 $x = 9; method m() :returns(i64) { return $x } } my $c = C->new(); exit($c->m());',
        9, 'a terminated field before a method' );
};
subtest 'a missing semicolon between two statements is still an error' => sub {
    my $err = do {
        local $@;
        eval { Brocken->new->compile('sub f() :returns(i64) { my i64 $x = 1 my i64 $y = 2; return $x; }') };
        $@;
    };
    like( $err, qr/Expected ';'/, 'two variable declarations need a separator' );
    my $err2 = do {
        local $@;
        eval { Brocken->new->compile('sub f() :returns(i64) { return 1 return 2; }') };
        $@;
    };
    like( $err2, qr/Expected ';'/, 'two returns need a separator' );
    my $err3 = do {
        local $@;
        eval { Brocken->new->compile('class C { field i64 $x = 1 method m() { 1 } }') };
        $@;
    };
    like( $err3, qr/Expected ;/, 'a field before a method needs its separator' );
};

# The omitted semicolon must not change what a `say`/`print` prints: the final `say` still runs. Output goes to stdout,
# so it is checked on the host rather than through `answers`' exit code.
sub check_output ( $src, $want, $name ) {
    my $brocken = Brocken->new();
    plan skip_all => 'not a native host' unless $brocken->platform->is_native;
    my $module = $brocken->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    $brocken->linker->set_rodata( $module->rodata ) if $module->rodata && keys %{ $module->rodata };
    my $file = $brocken->tmpdir . '/optional_semicolons' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    chmod 0755, $file;
    my $out = `$file`;
    unlink $file;
    is( $out, $want, $name );
}
subtest 'a final say may omit its semicolon' => sub {
    check_output( q{sub f() { say "hi" } f(); return 0;}, "hi\n", 'a final say inside a sub body' );
    check_output( q{say "hi"},                            "hi\n", 'a final say at the top level' );
    check_output( q{sub render() { return 'blah' } say render; return 0;},
        "blah\n", 'the motivating string-returning sub without a trailing semicolon' );
    check_output(
        q{sub render() { return 'blah' } sub render2($name) { return 'Hi, ' . $name } say render, render, render2 'Alex'; return 0;},
        "blahblahHi, Alex\n",
        'the full motivating example'
    );
};
done_testing;
