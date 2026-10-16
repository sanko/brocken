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

# F4: a non-local jump out of a `try` body -- `return`, `last`, `next` -- leaves the ICB exception handler stack
# pointing at that try's handler, whose jmp_buf belongs to a frame the jump abandons. A later `throw` then longjmps
# into the stale handler. The lowerer now pops the handlers a jump abandons: `return` pops every try body it is
# inside, and `last`/`next` pop the ones opened inside the loop they target. The pop is the same `head = *head`
# sequence try/catch emits on its normal and exceptional exits.
subtest 'a return from a try body pops the handler before returning' => sub {
    my $mod = Brocken->new->compile(<<'BROCKEN');
sub f() :returns(i64) {
    try {
        return 7;
    } catch ($e) {
        return 0;
    }
    return 2;
}
return f();
BROCKEN
    my ($f) = grep { $_->name eq 'f' } $mod->functions->@*;
    ok( $f, 'found function f' );
    like(
        $f->as_string,
        qr/load ptr, ptr %\S+\n\s+%\d+ = add ptr %\d+, i64 \d+\n\s+%\d+ = load i64, ptr %\d+\n\s+%\d+ = load i64, i64 %\d+\n\s+store i64 %\d+, ptr %\d+\n\s+ret i64 7/,
        'the try body drops the handler before it returns 7',
    );
};

# A `next` inside the loop's try leaves the handler pushed. Only the stale-handler path returning 99 can terminate the
# buggy program, so the test is shaped to expose the leak without looping: the outer catch returns 7 when the throw
# reaches it and the inner catch returns 99 if the throw instead lands on the abandoned handler.
subtest 'next out of a try inside a loop pops the handler' => sub {
    check( <<'BROCKEN', 7, 'a later throw reaches the outer catch, not the abandoned inner one' );
sub g() :returns(i64) {
    my i64 $sum = 0;
    try {
        for my $i (0, 1, 2, 3, 4) {
            try {
                if ($i == 2) { next; }
                $sum = $sum + $i;
            } catch ($e) {
                return 99;
            }
        }
        throw 9;
    } catch ($e) {
        return 7;
    }
    return 0;
}
return g();
BROCKEN
};

subtest 'last out of a try inside a loop pops the handler' => sub {
    check( <<'BROCKEN', 7, 'a later throw reaches the outer catch, not the abandoned inner one' );
sub g() :returns(i64) {
    my i64 $sum = 0;
    try {
        for my $i (0, 1, 2, 3, 4, 5) {
            try {
                if ($i == 5) { last; }
                $sum = $sum + $i;
            } catch ($e) {
                return 99;
            }
        }
        throw 9;
    } catch ($e) {
        return 7;
    }
    return 0;
}
return g();
BROCKEN
};

done_testing;
