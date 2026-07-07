use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

subtest 'Float literal return truncates to i64' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile('return 42.7;');
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/float_ret_42' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'return 42.7 -> 42' );
        unlink $file;
    }
};

subtest 'Float arithmetic with fptosi return' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my f64 $x = 10.5;
my f64 $y = 20.5;
my f64 $z = $x + $y;
return $z;
BROCKEN
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/float_add' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 31, '10.5 + 20.5 = 31.0 -> 31' );
        unlink $file;
    }
};

subtest 'Float constant folding returns int via maybe_convert_type' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile('return 99.0;');
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/float_ret_99' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 99, 'return 99.0 -> 99' );
        unlink $file;
    }
};

done_testing;
