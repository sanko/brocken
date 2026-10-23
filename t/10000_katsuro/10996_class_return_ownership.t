use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# The ownership contract is exercised on the native targets, where the heap can be introspected.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
my %native         = ( targets => [@native_targets] );

sub find_function {
    my ( $mod, $name ) = @_;
    for my $f ( $mod->functions->@* ) {
        return $f if $f->name eq $name;
    }
    return undef;
}

# A class with a DESTROY that records the fact it ran by writing into a live Probe instance. The writer goes through
# a raw i64 store at the Probe's first field (offset 8, past the 8-byte header) because `ptr`-typed fields carry no
# static class to dispatch a method on.
my $setup = <<'BROCKEN';
class Probe { field i64 $hit :accessor = 0; }
class Node {
    field ptr $probe :param :reader = 0;
    DESTROY {
        my ptr $slot = Brocken::ptr_add($probe, 8);
        Brocken::store_i64($slot, Brocken::i64_add(Brocken::load_i64($slot), 1));
    }
    method me() :returns(Node) { return $self; }
}
sub make(ptr $pr) :returns(Node) { return Node->new(probe => $pr); }
sub make_local(ptr $pr) :returns(Node) { my ptr $n = Node->new(probe => $pr); return $n; }
sub make_checked(ptr $pr) :returns(Node) {
    if (1) { my ptr $n = Node->new(probe => $pr); return $n; }
    return 0;
}
sub wrap(ptr $pr) :returns(Node) { return make($pr); }
sub ident(ptr $n) :returns(Node) { return $n; }
sub consume(ptr $n) :returns(i64) { return 0; }
BROCKEN

# Count how many DESTROY bodies ran by the time the entry point returns. Every program below ends in `return $p->hit();`
# so the exit status *is* the count.
subtest 'a fresh construction returned by value is owned by the caller' => sub {
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
my ptr $hb = Brocken::heap_base();
my i64 $before = Brocken::Runtime::free16_count($hb);
{ my ptr $n = make($p); }
my i64 $after = Brocken::Runtime::free16_count($hb);
if ($p->hit() != 1) { return 1; }
if ($after <= $before) { return 2; }
return 0;
BROCKEN
        0, 'DESTROY ran once and the instance was reclaimed', %native
    );
};
subtest 'a returned local is not released by the callee' => sub {

    # The exit cleanup must not free `$n` before handing it over: the caller still releases it exactly once, so a
    # premature release would be a double free and the DESTROY count would not come out at one.
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
{ my ptr $n = make_local($p); }
if ($p->hit() != 1) { return 1; }
return 0;
BROCKEN
        0, 'returning a local transfers it without a premature release', %native
    );
};
subtest 'ownership forwards through a returned owned call' => sub {
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
{ my ptr $n = wrap($p); }
if ($p->hit() != 1) { return 1; }
return 0;
BROCKEN
        0, 'a call chain that ends in a fresh construction is owned end to end', %native
    );
};
subtest 'a null return fallback does not disqualify ownership' => sub {
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
{ my ptr $n = make_checked($p); }
if ($p->hit() != 1) { return 1; }
return 0;
BROCKEN
        0, 'a conditional fresh return beside `return 0` is still owned', %native
    );
};
subtest 'a borrowed `$self` return is not released by the caller' => sub {
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
{ my ptr $n = Node->new(probe => $p); my ptr $m = $n->me(); }
if ($p->hit() != 1) { return 1; }
return 0;
BROCKEN
        0, 'the borrowed receiver is released once, when its owner leaves scope', %native
    );
};
subtest 'a borrowed pointer parameter return is not released by the caller' => sub {

    # `$n` escapes into `ident`, so the caller keeps its reference (a leak, never a dangling free). Nothing releases
    # the borrowed `$m` either: a wrong release would drop the count to zero and the program would report one.
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
{ my ptr $n = Node->new(probe => $p); my ptr $m = ident($n); }
if ($p->hit() != 0) { return 1; }
return 0;
BROCKEN
        0, 'a borrowed parameter return triggers no release on either side', %native
    );
};
subtest 'assignment takes ownership of an owned call result' => sub {
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
{ my ptr $n = 0; $n = make($p); }
if ($p->hit() != 1) { return 1; }
return 0;
BROCKEN
        0, 'a null slot that receives an owned instance releases it at scope exit', %native
    );
};
subtest 'reassignment releases the displaced instance' => sub {
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
{ my ptr $n = Node->new(probe => $p); $n = make($p); }
if ($p->hit() != 2) { return 1; }
return 0;
BROCKEN
        0, 'the old and the new instance are each released once', %native
    );
};
subtest 'assignment to an escaped local stays borrowed' => sub {
    answers(
        $setup . <<'BROCKEN',
my ptr $p = Probe->new();
{ my ptr $n = 0; consume($n); $n = make($p); }
if ($p->hit() != 0) { return 1; }
return 0;
BROCKEN
        0, 'an escaped slot never takes ownership, so nothing is released', %native
    );
};
subtest 'the callee transfers and the caller finalizes' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Node { field i64 $x :accessor = 0; }
sub make_local() :returns(Node) { my ptr $n = Node->new(); return $n; }
sub drive() :returns(i64) { my ptr $n = make_local(); return 0; }
return drive();
BROCKEN
    ok( !$@, 'compiled the callee/caller pair' ) or diag $@;

    # The callee never runs the destructor: the instance's reference is transferred, not dropped.
    my $callee = find_function( $mod, 'make_local' )->as_string;
    unlike( $callee, qr/decref|__destroy/, 'the callee does not release the instance it returns' );

    # The caller owns the returned instance and releases it through the statically-known destructor.
    my $caller = find_function( $mod, 'drive' )->as_string;
    like( $caller, qr/\@Node::__destroy/, 'the caller finalizes the owned instance' );
};
done_testing;
