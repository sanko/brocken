use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'signed div by zero sets err_code=4 and returns 0' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
use feature 'brocken_native_types';
my i64 $x = 10;
my i64 $y = 0;
my i64 $r = $x / $y;
return $r;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_div_zero_s' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $exit = $? >> 8;
        is( $exit, 0, 'signed div-by-zero returns 0 (not SIGFPE)' );
        unlink $file;
    }
};
subtest 'signed div by zero sets err_code=4' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
use feature 'brocken_native_types';
sub do_div() -> i64 {
    my i64 $x = 42;
    my i64 $y = 0;
    my i64 $r = $x / $y;
    return $r;
}
my ptr $hb = Brocken::heap_base();
my i64 $_r = do_div();
my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72));
return $err;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_div_zero_err' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $exit = $? >> 8;
        is( $exit, 4, 'signed div-by-zero sets err_code=4' );
        unlink $file;
    }
};
subtest 'unsigned div by zero returns 0' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
use feature 'brocken_native_types';
my u64 $x = 10;
my u64 $y = 0;
my u64 $r = $x / $y;
return $r;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_div_zero_u' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $exit = $? >> 8;
        is( $exit, 0, 'unsigned div-by-zero returns 0 (not SIGFPE)' );
        unlink $file;
    }
};
subtest 'signed rem by zero returns 0' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
use feature 'brocken_native_types';
my i64 $x = 10;
my i64 $y = 0;
my i64 $r = $x % $y;
return $r;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_rem_zero_s' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $exit = $? >> 8;
        is( $exit, 0, 'signed rem-by-zero returns 0 (not SIGFPE)' );
        unlink $file;
    }
};
subtest 'div by non-zero works normally' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
use feature 'brocken_native_types';
my i64 $x = 42;
my i64 $y = 7;
my i64 $r = $x / $y;
return $r;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_div_norm' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $exit = $? >> 8;
        is( $exit, 42 / 7, 'normal division still works' );
        unlink $file;
    }
};
subtest 'div with constant zero divisor' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
use feature 'brocken_native_types';
my i64 $x = 10;
my i64 $r = $x / 0;
return $r;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_div_const0' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $exit = $? >> 8;
        is( $exit, 0, 'constant zero divisor handled safely' );
        unlink $file;
    }
};
done_testing;
