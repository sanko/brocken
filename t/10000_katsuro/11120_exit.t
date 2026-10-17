use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# `exit;` / `exit(CODE);` end the process immediately with the given status (0 when the status is omitted). The status
# is an i64 handed to libc `exit`, which flushes stdio first, so anything `say`/`print` had written still reaches the
# terminal. The call never returns, so code after it must not run -- including a `return` in the same function and the
# rest of an enclosing loop.
#
# `answers` compares the process status, which an `exit` case produces directly, so the cases read as the status they
# expect. Wasm has no `exit` import (its runner would need `proc_exit`) and the Wasm backend is already excluded from
# the string/throw suites, so these run native-only.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub native_case { answers( $_[0], $_[1], $_[2], targets => [@native_targets] ) }

subtest 'exit with an explicit status' => sub {
    native_case( 'exit(3);',  3,  'exit(3) exits 3' );
    native_case( 'exit(0);',  0,  'exit(0) exits 0' );
    native_case( 'exit(42);', 42, 'arbitrary status' );
};

subtest 'bare exit is status 0' => sub {
    native_case( 'exit;', 0, 'exit with no status exits 0' );
};

subtest 'exit does not fall through' => sub {
    native_case( 'my i64 $x = 0; exit(5); $x = 9; return $x;', 5, 'code after exit never runs' );
    native_case( 'exit(5); return 9;',                         5, 'a later return never runs' );
};

subtest 'exit from inside a function ends the process' => sub {
    native_case( 'sub f(i64 $x) : returns(i64) { exit($x); return 0; } return f(7) + 100;', 7, 'exit beats the surrounding return' );
    native_case( 'sub g() : returns(i64) { exit(6); } return g() + 1;',                     6, 'exit from a callee' );
};

subtest 'exit from inside a loop ends the process' => sub {
    native_case( 'my i64 $i = 0; while (true) { $i = $i + 1; if ($i == 3) { exit($i); } } return 99;', 3,
        'exit out of a loop' );
};

subtest 'exit in a branch' => sub {
    native_case( 'if (true) { exit(2); } return 8;',  2, 'a taken branch exits' );
    native_case( 'if (false) { exit(2); } return 8;', 8, 'an untaken branch falls through' );
};

subtest 'the status is an expression' => sub {
    native_case( 'my i64 $a = 4; exit($a + 3);', 7, 'computed status' );
    native_case( 'my Any $c = 5; exit($c);',     5, 'status unboxed from an Any' );
};

subtest 'exit takes a postfix modifier' => sub {
    native_case( 'exit(4) if true; return 9;',      4, 'exit(4) if true fires' );
    native_case( 'exit(4) if false; return 9;',     9, 'exit(4) if false is skipped' );
    native_case( 'exit(4) unless false; return 9;', 4, 'exit(4) unless false fires' );
};

subtest 'output written before exit is flushed' => sub {
    native_case( 'say("before"); exit(6); say("after");', 6, 'exit status wins and runs no later statement' );
};

done_testing;
