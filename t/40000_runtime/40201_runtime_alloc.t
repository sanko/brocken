use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# These tests exercise the runtime allocator indirectly through the Brocken source compiler. Classes allocate instances
# via bump_alloc.
subtest 'Class instance allocation via new' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
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
        my $module = Brocken->new->compile(<<'BROCKEN');
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
        my $module = Brocken->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
    method double() :returns(i64) { return $x * 2; }
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
        my $module = Brocken->new->compile(<<'BROCKEN');
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
subtest 'Field :accessor provides reader and writer' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Accessor {
    field i64 $value :param :accessor;
}
my ptr $a = Accessor->new(value => 11);
$a->set_value(29);
return $a->value();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_accessor' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 29, ':accessor generates both a reader and a writer' );
        unlink $file;
    }
};
subtest ':writer methods chain by returning $self' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Pair {
    field i64 $a :param :writer;
    field i64 $b :param :writer;
}
my ptr $p = Pair->new(a => 1, b => 2);
$p->set_a(5)->set_b(7);
return $p->a + $p->b;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_chain' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 12, 'chained writer calls all apply' );
        unlink $file;
    }
};
subtest 'Field ||= default applies when the supplied value is false' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Counter {
    field i64 $count :param :reader ||= 3;
}
my ptr $zero = Counter->new(count => 0);
my ptr $nine = Counter->new(count => 9);
return $zero->count()*10 + $nine->count();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_or_default' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 39, 'falsy 0 is replaced by the default; 9 is kept' );
        unlink $file;
    }
};
subtest 'Field ||= default on a float, read back through several comparisons' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Reading {
    field f64 $v :param :reader ||= 2.5;
}
my ptr $zero = Reading->new(v => 0.0);
my ptr $nine = Reading->new(v => 9.5);
if ($zero->v() > 2.4 && $zero->v() < 2.6 && $nine->v() > 9.4 && $nine->v() < 9.6) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_float_or_default' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 1, 'falsy 0.0 takes the default; 9.5 is kept; four float compares hold' );
        unlink $file;
    }
};
subtest 'Multiple ADJUST blocks run in declaration order' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
class Counter {
    field i64 $count :param :reader;
    ADJUST { if ($count < 1) { $count = 1; } }
    ADJUST { if ($count > 100) { $count = 100; } }
}
my ptr $lo = Counter->new(count => 0);
my ptr $hi = Counter->new(count => 500);
return $lo->count()*10 + $hi->count();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_class_multi_adjust' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 110, 'both ADJUST clamps applied (lower bound then upper bound)' );
        unlink $file;
    }
};
done_testing;
