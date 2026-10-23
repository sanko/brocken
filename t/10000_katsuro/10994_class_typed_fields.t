use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# A class-typed field (`field Node $succ`) holds an instance pointer directly rather than an `Any` box, so the object
# graph the collector walks is made of class instances. These run wherever the heap can be introspected: the host and
# any cross target, but not Wasm.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
my %native         = ( targets => [@native_targets] );

sub find_function {
    my ( $mod, $name ) = @_;
    for my $f ( $mod->functions->@* ) {
        return $f if $f->name eq $name;
    }
    return undef;
}

# A Probe counts DESTROY runs through a raw i64 store at offset 8; a Node links to another Node through the
# class-typed field and bumps the Probe when it is finalized.
my $probe_and_node = <<'BROCKEN';
class Probe { field i64 $hits :accessor = 0; }
class Node {
    field Node $succ;
    field ptr  $probe :param;
    field i64  $id    :param;
    method tie() { $self->succ = $self; }
    DESTROY {
        my ptr $slot = Brocken::ptr_add($probe, 8);
        Brocken::store_i64($slot, Brocken::i64_add(Brocken::load_i64($slot), 1));
    }
}
BROCKEN
subtest 'a class-typed field is a scanned, owned pointer' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Node {
    field Node $succ;
    field i64  $id :param;
}
class Plain {
    field i64 $n :param;
}
my ptr $n = Node->new(id => 1);
my ptr $p = Plain->new(n => 2);
return $p->n;
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;

    # The field slot is an instance pointer, so scan/restore walk it with the object collector's hooks rather than the
    # boxed-value ones.
    my $nscan = find_function( $mod, 'Node::__scan' )->as_string;
    like( $nscan, qr/succ\.scan/,                    'scan addresses the class-typed field' );
    like( $nscan, qr/load ptr/,                      'the field is loaded as an instance pointer' );
    like( $nscan, qr/\@Brocken::Runtime::gc_decref/, 'scan drops a reference to the field' );
    my $nrestore = find_function( $mod, 'Node::__restore' )->as_string;
    like( $nrestore, qr/succ\.restore/,                        'restore addresses the class-typed field' );
    like( $nrestore, qr/\@Brocken::Runtime::gc_restore_black/, 'restore takes the reference back' );

    # The reclaim thunk releases the field through the child's own destructor, not a bare decref.
    my $destroy = find_function( $mod, 'Node::__destroy' )->as_string;
    like( $destroy, qr/succ\.daddr/,                    'destructor addresses the class-typed field' );
    like( $destroy, qr/\@Brocken::Runtime::decref_obj/, 'destructor releases the child through its destructor' );

    # A class-typed field keeps both classes out of the Leaf state: it is an owned reference the collector must walk.
    my $entry        = find_function( $mod, '_BROCKEN_ENTRY' )->as_string;
    my $node_header  = 1 | ( 0 << 16 ) | ( 4 << 24 ) | ( 1 << 32 );
    my $plain_header = 1 | ( 4 << 16 ) | ( 4 << 24 ) | ( 2 << 32 );
    like( $entry, qr/store\s+i64\s+\Q$node_header\E/,  'Node header: has an owned field, not Leaf' );
    like( $entry, qr/store\s+i64\s+\Q$plain_header\E/, 'Plain header: no owned field, Leaf' );
};
subtest 'the writer takes an owning reference to the stored instance' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Node {
    field Node $succ :accessor;
    field i64  $id   :param;
}
my ptr $a = Node->new(id => 1);
return $a->id;
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;
    my $writer = find_function( $mod, 'Node::set_succ' )->as_string;
    like( $writer, qr/incref ptr/,                     'writer takes a reference to the new instance' );
    like( $writer, qr/\@Brocken::Runtime::decref_obj/, 'writer releases the displaced instance' );
};
subtest 'a self-cycle is reclaimed and finalized once' => sub {
    answers(
        $probe_and_node . <<'BROCKEN',
my ptr $hb = Brocken::heap_base();
my ptr $p  = Probe->new();
{
    my ptr $a = Node->new(probe => $p, id => 1);
    $a->tie();
}
Brocken::Runtime::gc_drain($hb);
return $p->hits();
BROCKEN
        1, 'the self-cycle was collected and DESTROY ran exactly once', %native
    );
};
subtest 'a two-node cycle is reclaimed and both are finalized' => sub {
    answers(
        $probe_and_node . <<'BROCKEN',
my ptr $hb = Brocken::heap_base();
my ptr $p  = Probe->new();
{
    my ptr $a = Node->new(probe => $p, id => 1);
    my ptr $b = Node->new(probe => $p, id => 2);
    $a->succ = $b;
    $b->succ = $a;
}
Brocken::Runtime::gc_drain($hb);
return $p->hits();
BROCKEN
        2, 'both cycle members were collected and finalized', %native
    );
};
subtest 'a still-reachable cycle survives gc_drain' => sub {
    answers(
        $probe_and_node . <<'BROCKEN',
my ptr $hb = Brocken::heap_base();
my ptr $p  = Probe->new();
my ptr $a  = Node->new(probe => $p, id => 1);
$a->tie();
Brocken::Runtime::push_suspect_buffer($a, $hb);
Brocken::Runtime::gc_drain($hb);
return $p->hits();
BROCKEN
        0, 'the live reference kept the cycle alive through the sweep', %native
    );
};
subtest 'an escaped instance keeps its reference' => sub {

    # `keep($a)` hands the pointer to a callee that may retain it, so the escape scan keeps the local's reference
    # instead of reclaiming it. `keep` returns the raw pointer without dereferencing, so it needs no static class.
    answers(
        $probe_and_node . <<'BROCKEN',
sub keep(ptr $v) :returns(ptr) { return $v; }
my ptr $hb = Brocken::heap_base();
my ptr $p  = Probe->new();
{
    my ptr $a = Node->new(probe => $p, id => 1);
    $a->tie();
    my ptr $k = keep($a);
}
Brocken::Runtime::gc_drain($hb);
return $p->hits();
BROCKEN
        0, 'the escaped instance was not finalized while still reachable', %native
    );
};
subtest 'a class-typed field reads back and dispatches to its class' => sub {
    answers(
        <<'BROCKEN',
class Node {
    field Node $succ;
    field i64  $id :param;
    method show() : returns(i64) { return $id; }
}
my ptr $a = Node->new(id => 1);
my ptr $b = Node->new(id => 2);
$a->succ = $b;
if ($a->succ->id != 2) { return 91; }
if ($a->succ->show() != 2) { return 92; }
my ptr $s = $a->succ;
if ($s->show() != 2) { return 93; }
return 0;
BROCKEN
        0, 'field read, chained method call, and borrowed local all resolve the class', %native
    );
};
done_testing;
