use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# These tests exercise the incref/decref runtime functions indirectly via
# Any variable assignment and function call boundaries.
subtest 'Runtime incref called on Any init' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my $x = 99;
return $x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_inc_init' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 99, 'incref on init does not corrupt value' );
        unlink $file;
    }
};
subtest 'Runtime decref called before function exit' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my $x = 42;
my $y = 0;
$y = $x;
return $y;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_inc_decref' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'incref/decref lifecycle produces correct result' );
        unlink $file;
    }
};
subtest 'Any var passed to helper function' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub double(i64 $n) -> i64 {
    return $n * 2;
}
my $x = 21;
return double($x);
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_inc_call' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'Any var passed to typed helper function' );
        unlink $file;
    }
};
subtest 'Any var returned from helper function' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub make_val(i64 $n) -> i64 {
    return $n;
}
my $x = make_val(42);
return $x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_inc_ret' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'Any var assigned from helper return' );
        unlink $file;
    }
};
subtest 'Return boxed Any survives decref cleanup' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;

        # Regression: lower_return used to decref ALL RC locals before build_ret,
        # which freed the returned object (RC 1 -> 0) and returned a dangling pointer.
        # The fix adds build_incref($val) before the decref loop.
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub wrap(i64 $n) -> i64 {
    my $inner = $n;
    return $inner;
}
my $x = wrap(77);
return $x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_inc_retbox' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 77, 'returned boxed Any value survives decref of locals' );
        unlink $file;
    }
};
subtest 'Reassign Any var — incref new + decref old' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my $a = 10;
my $b = 20;
$a = $b;
return $a;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_inc_reassign' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 20, 'reassign: incref new value, decref old value' );
        unlink $file;
    }
};
subtest 'Multiple Any vars survive scope cleanup' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my $a = 1;
my $b = 2;
my $c = 3;
my $d = 4;
return $a + $b + $c + $d;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_inc_multi' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 10, 'multiple RC vars — all decrefed without corruption' );
        unlink $file;
    }
};
subtest 'Call returning boxed Any — cross-function RC' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub make(i64 $n) -> i64 {
    return $n * 2;
}
sub chain(i64 $n) -> i64 {
    my $tmp = $n;
    return make($tmp);
}
my $x = chain(21);
return $x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_inc_cross' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'cross-function RC — boxed Any passed and returned' );
        unlink $file;
    }
};
done_testing;
