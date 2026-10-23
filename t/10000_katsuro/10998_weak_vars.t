use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;

sub find_function {
    my ( $mod, $name ) = @_;
    for my $f ( $mod->functions->@* ) {
        return $f if $f->name eq $name;
    }
    return undef;
}

# Compile a program, link it natively, run it, and hand back its exit code (undef when not native).
sub run_brocken {
    my ($source) = @_;
    my $brocken  = Brocken->new();
    my $host     = $brocken->platform;
    return undef unless $host->is_native;
    my $module = eval { $brocken->compile($source) };
    die $@ if $@;
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    my $file  = $brocken->tmpdir . '/r_weakvar_' . $$ . '.' . int( rand(1_000_000) ) . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $host );
    system $file;
    my $code = $? >> 8;
    unlink $file;
    return $code;
}
subtest 'a :weak local stores without taking a reference' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
sub hold_strong() :returns(i64) {
    my Any $x = 7;
    return 0;
}
sub hold_weak() :returns(i64) {
    my Any $x :weak = 7;
    return 0;
}
return hold_strong() + hold_weak();
BROCKEN
    ok( !$@, 'compiled weak-local program' ) or diag $@;

    # An owned (`Any`) local takes a reference and releases it at scope exit; a `:weak` local does neither and is
    # just a plain store of the box pointer.
    my $strong = find_function( $mod, 'hold_strong' )->as_string;
    like( $strong, qr/incref dynamic/, 'owned local takes a reference' );
    like( $strong, qr/decref/,         'owned local releases at scope exit' );
    my $weak = find_function( $mod, 'hold_weak' )->as_string;
    unlike( $weak, qr/incref|decref/, 'weak local takes and releases nothing' );
    like( $weak, qr/store dynamic/, 'weak local is a plain store' );
};
subtest 'builtin::weaken drops the reference a local holds' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
sub drop() :returns(i64) {
    my Any $x = 7;
    builtin::weaken($x);
    return 0;
}
return drop();
BROCKEN
    ok( !$@, 'compiled builtin::weaken program' ) or diag $@;
    my $drop = find_function( $mod, 'drop' )->as_string;
    like( $drop, qr/decref/, 'weaken releases the reference the local held' );

    # `is_weak` observes the folded-out static state.
    my $c2   = Brocken->new;
    my $mod2 = $c2->compile(<<'BROCKEN');
sub isw() :returns(i64) {
    my Any $a = 1;
    my Any $b = 2;
    builtin::weaken($b);
    if (builtin::is_weak($b)) { $a = $a + 1; }
    if (builtin::is_weak($a)) { $a = $a + 10; }
    return $a;
}
return isw();
BROCKEN
    ok( !$@, 'compiled builtin::is_weak program' ) or diag $@;
};
subtest 'builtin::weaken releases an owned class instance' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Victim {
    field i64 $n :accessor;
    DESTROY { }
}
sub keepobj() :returns(i64) {
    my ptr $v = Victim->new();
    return 0;
}
sub dropobj() :returns(i64) {
    my ptr $v = Victim->new();
    builtin::weaken($v);
    return 0;
}
return keepobj() + dropobj();
BROCKEN
    ok( !$@, 'compiled class weaken program' ) or diag $@;

    # An owned instance is released through its destructor; weakening the local must drop that owned reference at the
    # call rather than leave the instance unreclaimed (the escape scan must not treat the builtin argument as a value
    # use).
    my $keep = find_function( $mod, 'keepobj' )->as_string;
    my $drop = find_function( $mod, 'dropobj' )->as_string;
    like( $keep, qr/__destroy|decref_obj/, 'an owned instance is released at scope exit' );
    like( $drop, qr/__destroy|decref_obj/, 'weaken releases the owned instance' );
};
subtest 'a :weak local does not keep the box it holds alive' => sub {

    # `my $tmp = 88` creates a box at RC 1. An owned `Any` local adds a reference, so dropping `$tmp` leaves the box
    # at RC 1 and its release is a suspect push. A `:weak` local adds no reference, so the same release drops the box
    # to zero and the buffer stays empty.
    my $strong = run_brocken(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
{
    my $tmp = 88;
    my Any $x = $tmp;
}
return Brocken::Runtime::suspect_count($hb);
BROCKEN
    my $weak = run_brocken(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
{
    my $tmp = 88;
    my Any $x :weak = $tmp;
}
return Brocken::Runtime::suspect_count($hb);
BROCKEN
SKIP: {
        skip 'Not native', 2 unless defined $strong && defined $weak;
        is( $strong, 1, 'an owned local keeps the box alive, so releasing the source is buffered' );
        is( $weak,   0, 'a weak local holds no reference, so releasing the source frees the box' );
    }
};
subtest 'builtin::weaken stops later assignments from owning' => sub {

    # Once weakened, `$x` stores plainly: assigning `$y` neither takes a reference to `$y`'s box nor releases the box
    # `$x` held (which weaken already freed). A strong local would take that reference, so dropping `$y` would leave
    # the box at RC 1 and buffer its release. The weak case leaves the buffer empty.
    my $strong = run_brocken(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
{
    my Any $x = 88;
    my Any $y = 99;
    $x = $y;
}
return Brocken::Runtime::suspect_count($hb);
BROCKEN
    my $weak = run_brocken(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
{
    my Any $x = 88;
    builtin::weaken($x);
    my Any $y = 99;
    $x = $y;
}
return Brocken::Runtime::suspect_count($hb);
BROCKEN
SKIP: {
        skip 'Not native', 2 unless defined $strong && defined $weak;
        is( $strong, 1, 'a strong local takes a reference to the newly assigned box' );
        is( $weak,   0, 'a weakened local stores without owning' );
    }
};
subtest 'builtin::unweaken re-takes a reference' => sub {

    # A `:weak` local holds nothing, so releasing the source frees the box and buffers nothing. After `unweaken`
    # the local owns a reference again, so the same release leaves the box at RC 1 and its release is a suspect push.
    my $still_weak = run_brocken(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
{
    my $tmp = 88;
    my Any $x :weak = $tmp;
}
return Brocken::Runtime::suspect_count($hb);
BROCKEN
    my $unweakened = run_brocken(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
{
    my $tmp = 88;
    my Any $x :weak = $tmp;
    builtin::unweaken($x);
}
return Brocken::Runtime::suspect_count($hb);
BROCKEN
SKIP: {
        skip 'Not native', 2 unless defined $still_weak && defined $unweakened;
        is( $still_weak, 0, 'a weak local leaves the buffer empty' );
        is( $unweakened, 1, 'unweaken takes a reference, so releasing the source is buffered' );
    }
};
subtest 'builtin::true and builtin::false are constants' => sub {
    my $code = run_brocken(<<'BROCKEN');
sub t() :returns(i64) { return builtin::true(); }
sub f() :returns(i64) { return builtin::false(); }
return t() * 10 + f();
BROCKEN
SKIP: {
        skip 'Not native', 1 unless defined $code;
        is( $code, 10, 'true is 1 and false is 0' );
    }
};
subtest 'builtin::is_weak folds to a compile-time boolean' => sub {
    my $code = run_brocken(<<'BROCKEN');
sub weak_bool() :returns(i64) {
    my Any $b :weak = 2;
    return builtin::is_weak($b);
}
sub strong_bool() :returns(i64) {
    my Any $s = 2;
    return builtin::is_weak($s);
}
return weak_bool() * 10 + strong_bool();
BROCKEN
SKIP: {
        skip 'Not native', 1 unless defined $code;
        is( $code, 10, 'a :weak local reports weak, an owned local does not' );
    }
};
subtest 'unknown builtins and variable attributes are rejected' => sub {
    my $c   = Brocken->new;
    my $ok1 = eval { $c->compile('return builtin::nope();'); 1 };
    ok( !$ok1, 'unknown builtin is a compile error' );
    like( $@, qr/Unknown builtin 'builtin::nope'/, 'the diagnostic names the builtin' );
    my $c2  = Brocken->new;
    my $ok2 = eval { $c2->compile('my Any $x :bogus = 1; return 0;'); 1 };
    ok( !$ok2, 'unknown variable attribute is a compile error' );
    like( $@, qr/Unknown variable attribute ':bogus'/, 'the diagnostic names the attribute' );
};
done_testing;
