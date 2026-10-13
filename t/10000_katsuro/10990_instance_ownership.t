use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers executable_targets];

# The instance-ownership contract is exercised on the native targets, where the heap can be introspected.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
my %native         = ( targets => [@native_targets] );

# A class with a DESTROY that records the fact it ran by writing into a live Probe instance. The writer goes through
# a raw i64 store at the Probe's first field (offset 8, past the 8-byte header) because `ptr`-typed fields carry no
# static class to dispatch a method on.
my $probe_and_victim = <<'BROCKEN';
class Probe { field i64 $hit :accessor = 0; }
class Victim {
    field ptr $probe :param :reader = 0;
    DESTROY {
        my ptr $slot = Brocken::ptr_add($probe, 8);
        Brocken::store_i64($slot, Brocken::i64_add(Brocken::load_i64($slot), 1));
    }
}
BROCKEN

subtest 'an owned instance is finalized and reclaimed at scope exit' => sub {

    # `$v` is declared and never handed anywhere, so the local owns the sole reference: leaving the block drops it,
    # the refcount reaches zero, DESTROY runs, and the storage is returned to the free list.
    answers(
        $probe_and_victim . <<'BROCKEN',
my ptr $p = Probe->new();
my ptr $hb = Brocken::heap_base();
my i64 $before = Brocken::Runtime::free16_count($hb);
{
    my ptr $v = Victim->new(probe => $p);
}
my i64 $after = Brocken::Runtime::free16_count($hb);
if ($p->hit() != 1) { return 1; }
if ($after <= $before) { return 2; }
return 0;
BROCKEN
        0, 'DESTROY ran exactly once and the instance was reclaimed', %native
    );
};

subtest 'an escaped instance keeps its reference' => sub {

    # `peek($v)` hands the pointer to a callee that may retain it -- and a `ptr` store does not incref -- so the
    # compiler leaves the local owned instead of reclaiming it. DESTROY must therefore not have run.
    answers(
        $probe_and_victim . <<'BROCKEN',
sub peek(ptr $v) :returns(i64) { return $v->probe(); }
my ptr $p = Probe->new();
{
    my ptr $v = Victim->new(probe => $p);
    peek($v);
}
if ($p->hit() != 0) { return 1; }
return 0;
BROCKEN
        0, 'the escaped instance was not finalized while still reachable', %native
    );
};

subtest 'destructor releases the managed fields the instance owns' => sub {

    # The `Any` field takes ownership of its box on store (F9). Reclaiming the instance must release that box too,
    # so the free-list count rises by the field's box and the instance.
    answers(
        <<'BROCKEN',
class Holder { field Any $box :param :reader = 0; }
my ptr $hb = Brocken::heap_base();
my i64 $before = Brocken::Runtime::free16_count($hb);
{
    my ptr $h = Holder->new(box => 7);
}
my i64 $after = Brocken::Runtime::free16_count($hb);
if ($after <= $before) { return 1; }
return 0;
BROCKEN
        0, 'the owned dynamic field is released with the instance', %native
    );
};

subtest 'a class with no DESTROY still reclaims its fields' => sub {

    # A class that never says `DESTROY` still gets a reclaim thunk; it skips the (absent) user hook and releases
    # the managed fields.
    answers(
        <<'BROCKEN',
class Plain { field Any $a :param :reader = 0; field Any $b :param :reader = 0; }
my ptr $hb = Brocken::heap_base();
my i64 $before = Brocken::Runtime::free16_count($hb);
{
    my ptr $o = Plain->new(a => 1, b => 2);
}
my i64 $after = Brocken::Runtime::free16_count($hb);
if ($after <= $before) { return 1; }
return 0;
BROCKEN
        0, 'plain class teardown releases its dynamic fields', %native
    );
};

done_testing;
