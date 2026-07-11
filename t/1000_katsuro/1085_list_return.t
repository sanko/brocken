use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
use Brocken::Katsuro::AST;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'list return and unpack produces correct values' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub make_list() -> ptr {
    return (3, 4);
}
my ($a, $b) = make_list();
return $a + $b;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_return' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 7, 'list return + unpack gives 3+4=7' );
        unlink $file;
    }
};
subtest 'list return with three elements' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub make_list() -> ptr {
    return (10, 20, 30);
}
my ($x, $y, $z) = make_list();
return $x + $y + $z;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_return_3' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 60, 'three-element list return gives 10+20+30=60' );
        unlink $file;
    }
};
subtest 'list return with single element' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub make_one() -> ptr {
    return (42);
}
my ($v) = make_one();
return $v;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_one' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'single-element list return gives 42' );
        unlink $file;
    }
};
subtest 'list return with expression elements' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub make_list() -> ptr {
    my $x = 5;
    return ($x * 2, $x + 3);
}
my ($a, $b) = make_list();
return $a + $b;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_expr_elems' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 18, 'list with expression elements: (10, 8) sum = 18' );
        unlink $file;
    }
};
done_testing;
