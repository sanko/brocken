use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# try/catch lowers to setjmp/longjmp, which the Wasm backend does not implement, so the runtime checks run on every
# executable target except Wasm.
my @targets = grep { $_->[0] !~ /wasm/ } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@targets] );
}

# The parser records `catch ($e)` with its sigil, but the lowerer's symbol table is keyed by the bare name; the catch
# binding used to be stored under `$e` and read back as `e`, so any use of the catch variable was an "Undefined
# variable" error. The binding is now stored under the bare name and given a unique alloca, and the previous binding is
# saved and restored rather than deleted, so a nested try/catch that reuses the name neither aliases the outer slot nor
# leaves the outer name unbound.
subtest 'the catch variable carries the thrown value' => sub {
    check( <<'BROCKEN', 5, 'a handler that reads the value' );
my i64 $r = 0;
try { throw 5; } catch ($e) { $r = $e; }
return $r;
BROCKEN
    check( <<'BROCKEN', 42, 'a handler that computes with the value' );
my i64 $r = 0;
try { throw 40; } catch ($e) { $r = $e + 2; }
return $r;
BROCKEN
};

subtest 'a nested catch reusing the name does not clobber the outer binding' => sub {
    check( <<'BROCKEN', 51, 'the outer catch variable survives the inner block' );
my i64 $r = 0;
try {
    throw 5;
} catch ($e) {
    try {
        throw 1;
    } catch ($e) {
        $r = $r + $e;
    }
    $r = $r + $e * 10;
}
return $r;
BROCKEN
};

subtest 'distinct catch variables are independent' => sub {
    check( <<'BROCKEN', 51, 'inner and outer names differ' );
my i64 $r = 0;
try {
    throw 5;
} catch ($outer) {
    try { throw 1; } catch ($inner) { $r = $r + $inner; }
    $r = $r + $outer * 10;
}
return $r;
BROCKEN
};

subtest 'the catch variable is scoped to the catch block' => sub {
    my $ok = eval { Brocken->new->compile('try { throw 1; } catch ($e) { } return $e;'); 1 };
    ok( !$ok, 'using the catch variable after the block is an error' );
    like( $@, qr/Undefined variable 'e'/, 'the error names the variable' );
};

done_testing;
