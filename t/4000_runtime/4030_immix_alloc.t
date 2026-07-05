use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Test the Immix allocator via the Brocken source compiler.
# Class instances exercise bump_alloc internally.
# The free-list hot path is verified by allocation-after-free scenarios.
subtest 'Multiple class instances from same constructor' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param :reader;
}
my ptr $p1 = Point->new(10);
my ptr $p2 = Point->new(32);
return $p1->x() + $p2->x();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/i_multi_class' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'two class instances: sum of fields' );
        unlink $file;
    }
};
subtest 'Class instance written and read via writer' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Counter {
    field i64 $count :param :reader :writer;
}
my ptr $c = Counter->new(0);
$c->set_count(21);
return $c->count() * 2;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/i_writer' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'class with writer method: set and read' );
        unlink $file;
    }
};
subtest 'Many small allocations via class instances' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param :reader;
}
my i64 $s = 0;
my i64 $i = 0;
while ($i < 10) {
    my ptr $p = Point->new($i);
    $s = $s + $p->x();
    $i = $i + 1;
}
return $s;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/i_many_class' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 45, '10 class allocations in a loop (0+1+...+9 = 45)' );
        unlink $file;
    }
};
subtest 'Class with multiple param fields' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
class Point {
    field i64 $x :param :reader;
    field i64 $y :param :reader;
}
my ptr $p = Point->new(10, 32);
return $p->x() + $p->y();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/i_multi_field' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'class with two fields: sum' );
        unlink $file;
    }
};
done_testing;
