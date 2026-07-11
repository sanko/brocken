use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# These tests exercise the runtime allocator indirectly through the
# Brocken source compiler. Classes allocate instances via bump_alloc.
subtest 'Class instance allocation via new' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param :reader;
}
my ptr $p = Point->new(x => 42);
return $p->x();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_alloc' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'class instance allocated and field returns param value' );
        unlink $file;
    }
};
subtest 'Class with ADJUST block' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param :reader;
    ADJUST {
        if ($x < 10) { $x = 10; }
    }
}
my ptr $p = Point->new(x => 3);
return $p->x();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_adjust' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 10, 'ADJUST clamps value to minimum 10' );
        unlink $file;
    }
};
subtest 'Class with custom method' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
    method double() -> i64 { return $x * 2; }
}
my ptr $p = Point->new(x => 21);
return $p->double();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_method' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'custom method returns doubled value' );
        unlink $file;
    }
};
subtest 'Direct field read and write' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Counter {
    field i64 $count :param :reader :writer;
}
my ptr $c = Counter->new(count => 10);
$c->set_count(32);
return $c->count();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_writer' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 32, 'class with writer method' );
        unlink $file;
    }
};
done_testing;
