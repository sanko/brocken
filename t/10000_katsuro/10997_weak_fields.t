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
    my $file  = $brocken->tmpdir . '/r_weak_' . $$ . '.' . int( rand(1_000_000) ) . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $host );
    system $file;
    my $code = $? >> 8;
    unlink $file;
    return $code;
}
subtest 'a weak field stores without taking a reference' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Node {
    field Any $tag  :accessor;
    field Any $link :accessor :weak;
}
my ptr $n = Node->new();
return 0;
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;

    # The generated writer for a strong field owns a reference; the weak writer just stores the pointer.
    my $set_tag = find_function( $mod, 'Node::set_tag' )->as_string;
    like( $set_tag, qr/incref dynamic/, 'strong writer takes a reference' );
    my $set_link = find_function( $mod, 'Node::set_link' )->as_string;
    unlike( $set_link, qr/incref|decref/, 'weak writer takes and releases nothing' );
    like( $set_link, qr/store dynamic/, 'weak writer is a plain store' );

    # Neither the destructor nor the cycle-scan hooks may release a field the class does not own.
    my $destroy = find_function( $mod, 'Node::__destroy' )->as_string;
    like( $destroy, qr/tag\.daddr/, 'destructor releases the owned field' );
    unlike( $destroy, qr/link\.daddr/, 'destructor leaves the weak field alone' );
    my $scan = find_function( $mod, 'Node::__scan' )->as_string;
    like( $scan, qr/tag\.scan/, 'scan walks the owned field' );
    unlike( $scan, qr/link\.scan/, 'scan skips the weak field' );
    my $restore = find_function( $mod, 'Node::__restore' )->as_string;
    like( $restore, qr/tag\.restore/, 'restore walks the owned field' );
    unlike( $restore, qr/link\.restore/, 'restore skips the weak field' );
};
subtest 'a class whose only dynamic field is weak is Leaf' => sub {
    my $c   = Brocken->new;
    my $mod = $c->compile(<<'BROCKEN');
class Leaf {
    field Any $link :weak;
}
class Strong {
    field Any $tag;
}
my ptr $l = Leaf->new();
my ptr $s = Strong->new();
return 0;
BROCKEN
    ok( !$@, 'compiled class program' ) or diag $@;
    my $entry = find_function( $mod, '_BROCKEN_ENTRY' )->as_string;

    # Ids are assigned by sorted name (Leaf = 1, Strong = 2). Only a non-weak dynamic field keeps a class out of
    # the Leaf state, so Leaf carries flag bit 2 and Strong does not.
    my $leaf_header   = 1 | ( 4 << 16 ) | ( 4 << 24 ) | ( 1 << 32 );
    my $strong_header = 1 | ( 0 << 16 ) | ( 4 << 24 ) | ( 2 << 32 );
    like( $entry, qr/store\s+i64\s+\Q$leaf_header\E/,   'Leaf header sets the Leaf flag' );
    like( $entry, qr/store\s+i64\s+\Q$strong_header\E/, 'Strong header clears the Leaf flag' );
};
subtest 'a weak store does not own the box it holds' => sub {

    # An owned (`Any`) field takes its own reference to the box it stores, so dropping the source local leaves the box
    # at RC 1 and its release is a suspect push. A `:weak` field stores the same box without a reference, so the same
    # release drops it to zero and the buffer stays empty. Counting the buffer shows the ownership difference without
    # ever reading memory the weak field may have let die.
    my $strong = run_brocken(<<'BROCKEN');
class Holder {
    field Any $v :accessor;
}
my ptr $hb = Brocken::heap_base();
my ptr $h  = Holder->new();
{
    my $tmp = 88;
    $h->set_v($tmp);
}
return Brocken::Runtime::suspect_count($hb);
BROCKEN
    my $weak = run_brocken(<<'BROCKEN');
class Holder {
    field Any $v :accessor :weak;
}
my ptr $hb = Brocken::heap_base();
my ptr $h  = Holder->new();
{
    my $tmp = 88;
    $h->set_v($tmp);
}
return Brocken::Runtime::suspect_count($hb);
BROCKEN
SKIP: {
        skip 'Not native', 2 unless defined $strong && defined $weak;
        is( $strong, 1, 'an owned field keeps the box alive, so releasing the source is buffered' );
        is( $weak,   0, 'a weak field holds no reference, so releasing the source frees the box' );
    }
};
subtest 'a weak field still reads back through its reader' => sub {
    my $code = run_brocken(<<'BROCKEN');
class Holder {
    field Any $weak :accessor :weak;
}
my ptr $hb     = Brocken::heap_base();
my ptr $holder = Holder->new();
my $keep = 41;
$holder->set_weak($keep);
return $holder->weak;
BROCKEN
SKIP: {
        skip 'Not native', 1 unless defined $code;
        is( $code, 41, 'the weakly stored box is readable while its owner is alive' );
    }
};
done_testing;
