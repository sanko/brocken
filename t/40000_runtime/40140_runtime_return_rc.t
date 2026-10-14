use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;

# A dynamic (`Any`) return hands the caller a reference, but only one. The callee already increfs the value before its
# exit cleanup drops its own locals, so the caller must consume that reference rather than take a second one (F13).
# Before the fix a stored call result carried RC 2 and the callee-exit cleanup only brought it back to 1, so the box
# outlived its scope. A function whose every dynamic return is a bare borrowed parameter is different: it hands back
# the caller's own box with no reference change, so the caller increfs (F3). Each case measures the Immix free list
# across a block that holds one stored return value; the box must be released exactly once.
sub run_case {
    my ( $src, $want, $name ) = @_;
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile($src);
        my $file   = $brocken->tmpdir . '/return_rc_' . ( $name =~ s/\W+/_/gr ) . $brocken->ext;
        $brocken->linker->write_executable( $file, $brocken->codegen->emit_functions( $module->functions ), $host );
        system $file;
        is( $? >> 8, $want, $name );
        unlink $file;
    }
}

# Count boxes freed across `$body` (which must leave exactly `$want` releases behind) and report 9 on a mismatch.
sub wrap {
    my ( $defs, $body, $want ) = @_;
    return $defs . "\n"
        . "my ptr \$hb = Brocken::heap_base();\n"
        . "my i64 \$before = Brocken::Runtime::free16_count(\$hb);\n"
        . $body . "\n"
        . "my i64 \$after = Brocken::Runtime::free16_count(\$hb);\n"
        . "my i64 \$diff = Brocken::i64_sub(\$after, \$before);\n"
        . "if (\$diff != $want) { return 9; }\n"
        . "return 0;\n";
}

subtest 'a returned local is owned once by the caller' => sub {
    run_case(
        wrap( 'sub mk() :returns(Any) { my $u = 7; return $u; }', '{ my Any $a = mk(); }', 1 ),
        0, 'the stored box is released once when its scope ends'
    );
};

subtest 'a forwarded call result is not incref again' => sub {
    run_case(
        wrap(
            'sub mk() :returns(Any) { my $u = 7; return $u; } sub fwd() :returns(Any) { return mk(); }',
            '{ my Any $a = fwd(); }', 1
        ),
        0, 'fwd forwards mk with no second reference'
    );
};

subtest 'a borrowed return leaves the caller owning its box' => sub {
    run_case(
        wrap(
            'sub ident(Any $v) :returns(Any) { return $v; }',
            '{ my Any $x = 5; my Any $y = ident($x); }', 1
        ),
        0, 'both names release one reference to the caller box'
    );
};

subtest 'a discarded borrowed return does not leak' => sub {
    run_case(
        wrap(
            'sub ident(Any $v) :returns(Any) { return $v; }',
            '{ my Any $x = 5; ident($x); }', 1
        ),
        0, 'a borrowed-returning call used for effect adds no reference'
    );
};

subtest '//= with an owned call result on a borrowed parameter balances' => sub {
    run_case(
        wrap(
            'sub mk() :returns(Any) { my $u = 42; return $u; }'
                . ' sub fill(Any $x) :returns(i64) { $x //= mk(); my i64 $v = $x; return $v; }',
            'my Any $z; my i64 $r = fill($z); if ($r != 42) { return 8; }', 1
        ),
        0, 'the stored call result is released once at callee exit'
    );
};

subtest 'a discarded owned return is released' => sub {
    run_case(
        wrap( 'sub mk() :returns(Any) { my $u = 7; return $u; }', '{ mk(); }', 1 ),
        0, 'a call result used only for effect is released'
    );
};

subtest 'an unboxed owned return is released' => sub {
    run_case(
        wrap( 'sub mk() :returns(Any) { my $u = 7; return $u; }', '{ my i64 $n = mk(); }', 1 ),
        0, 'the box is released once its payload is copied into an i64'
    );
    run_case(
        wrap( 'sub mk() :returns(Any) { my $u = 7; return $u; }', '{ my i64 $n = 0; $n = mk(); }', 1 ),
        0, 'the box is released once its payload is copied by an assignment'
    );
};

done_testing;
