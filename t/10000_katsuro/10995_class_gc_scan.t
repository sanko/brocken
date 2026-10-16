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

# Compile a class program, link it natively, run it, and hand back its exit code.
sub run_brocken {
    my ($source) = @_;
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    return undef unless $host->is_native;
    my $module = eval { $brocken->compile($source) };
    die $@ if $@;
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    my $file  = $brocken->tmpdir . '/r_class_gc_' . $$ . '.' . int( rand(1_000_000) ) . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $host );
    system $file;
    my $code = $? >> 8;
    unlink $file;
    return $code;
}

subtest 'per-class scan/restore mirror the owned dynamic fields' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Node {
    field Any $next;
    field i64 $tag :param;
}
class Plain {
    field i64 $n :param;
}
my ptr $n = Node->new(tag => 1);
my ptr $p = Plain->new(n => 2);
return $p->n;
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;

    for my $name (qw[Node::__scan Node::__restore Plain::__scan Plain::__restore]) {
        ok( find_function( $mod, $name ), "generated $name" );
    }

    # The dynamic field is walked; the i64 field is not.
    my $nscan = find_function( $mod, 'Node::__scan' )->as_string;
    like( $nscan, qr/getelementptr %Node/,                     'scan addresses the instance struct' );
    like( $nscan, qr/\@Brocken::Runtime::gc_decref/,            'scan drops a reference to the dynamic field' );
    unlike( $nscan, qr/load i64/,                              'scan does not touch the i64 field' );

    my $nrestore = find_function( $mod, 'Node::__restore' )->as_string;
    like( $nrestore, qr/\@Brocken::Runtime::gc_restore_black/, 'restore takes the reference back and repaints the child Black' );

    # A class with no owned dynamic field has empty hooks.
    like( find_function( $mod, 'Plain::__scan' )->as_string,    qr/entry:\s+ret void/, 'Plain::__scan is empty (Leaf)' );
    like( find_function( $mod, 'Plain::__restore' )->as_string, qr/entry:\s+ret void/, 'Plain::__restore is empty (Leaf)' );
};

subtest 'constructor header encodes the class id and the Leaf flag' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Node {
    field Any $next;
}
class Plain {
    field i64 $n :param;
}
my ptr $n = Node->new();
my ptr $p = Plain->new(n => 2);
return $p->n;
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;
    my $entry = find_function( $mod, '_BROCKEN_ENTRY' )->as_string;

    # Ids are assigned by sorted name, so Node is 1 and Plain is 2. Node owns a dynamic field, so it is not Leaf;
    # Plain has no managed field and is marked Leaf (flag bit 2) so the collector never buffers it.
    my $node_header  = 1 | ( 0 << 16 ) | ( 4 << 24 ) | ( 1 << 32 );
    my $plain_header = 1 | ( 4 << 16 ) | ( 4 << 24 ) | ( 2 << 32 );
    like( $entry, qr/store\s+i64\s+\Q$node_header\E/,  'Node header: tag 4, class id 1, no Leaf bit' );
    like( $entry, qr/store\s+i64\s+\Q$plain_header\E/, 'Plain header: tag 4, class id 2, Leaf bit set' );
};

subtest 'the runtime dispatch selects each class by id' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Node {
    field Any $next;
}
class Plain {
    field i64 $n;
}
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;

    my $scan = find_function( $mod, 'Brocken::Runtime::gc_scan_class' );
    ok( $scan, 'generated gc_scan_class' );
    my $scan_text = $scan->as_string;
    like( $scan_text, qr/lshr i64 \S+, 32/,   'reads the class id from the header' );
    like( $scan_text, qr/\@Node::__scan/,     'dispatches to Node::__scan' );
    like( $scan_text, qr/\@Plain::__scan/,    'dispatches to Plain::__scan' );

    my $restore = find_function( $mod, 'Brocken::Runtime::gc_restore_class' );
    ok( $restore, 'generated gc_restore_class' );
    my $restore_text = $restore->as_string;
    like( $restore_text, qr/\@Node::__restore/,  'dispatches to Node::__restore' );
    like( $restore_text, qr/\@Plain::__restore/, 'dispatches to Plain::__restore' );
};

subtest 'the runtime scan hooks classes, not boxed pointers' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Bag {
    field Any $payload;
    field i64 $n :param;
}
my ptr $bag = Bag->new(n => 1);
return $bag->n;
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;
    my $scan = find_function( $mod, 'Brocken::Runtime::gc_scan_obj' )->as_string;
    like( $scan, qr/icmp eq i64 \S+, 4/,                'gc_scan_obj tests the class tag (4)' );
    like( $scan, qr/\@Brocken::Runtime::gc_scan_class/,  'gc_scan_obj dispatches class instances' );

    my $restore = find_function( $mod, 'Brocken::Runtime::gc_restore_refs' )->as_string;
    like( $restore, qr/\@Brocken::Runtime::gc_restore_class/, 'gc_restore_refs dispatches class instances' );
};

subtest 'a reachable class instance survives gc_drain' => sub {
    my $code = run_brocken(<<'BROCKEN');
class Bag {
    field Any $payload;
    field i64 $n :param;
}
my ptr $hb  = Brocken::heap_base();
my ptr $bag = Bag->new(n => 55);
Brocken::Runtime::push_suspect_buffer($bag, $hb);
Brocken::Runtime::gc_drain($hb);
return $bag->n;
BROCKEN
    SKIP: {
        skip 'Not native', 1 unless defined $code;
        is( $code, 55, 'gc_drain scanned and restored the instance without corrupting it' );
    }
};

subtest 'gc_drain preserves a class instance with a live boxed field' => sub {
    my $code = run_brocken(<<'BROCKEN');
class Holder {
    field Any $val :accessor;
}
my ptr $hb     = Brocken::heap_base();
my ptr $holder = Holder->new();
my $keep = 77;
$holder->set_val($keep);
Brocken::Runtime::push_suspect_buffer($holder, $hb);
Brocken::Runtime::gc_drain($hb);
return $holder->val;
BROCKEN
    SKIP: {
        skip 'Not native', 1 unless defined $code;
        is( $code, 77, 'the owned dynamic field is decref\'d by scan and incref\'d back by restore' );
    }
};

done_testing;
