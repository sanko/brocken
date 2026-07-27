use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'try without catch/finally is a parse error' => sub {
    my $c = Brocken::Compiler->new;
    like( dies { $c->compile('try { return 1; }') }, qr/catch.*finally/, 'try with neither catch nor finally croaks', );
};
subtest 'try/catch with no throw - normal flow' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $x = 10;
try {
    $x = 42;
} catch ($e) {
    $x = 0;
}
return $x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_try_no_throw' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'try without throw executes try body' );
        unlink $file;
    }
};
subtest 'throw and catch' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $result = 0;
try {
    $result = 1;
    throw 99;
    $result = 2;
} catch ($e) {
    $result = 3;
}
return $result;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_throw_catch' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 3, 'throw skips remaining try body, catch sets result=3' );
        unlink $file;
    }
};
subtest 'try/finally without catch' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $x = 0;
try {
    $x = 10;
} finally {
    $x = $x + 32;
}
return $x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_try_finally' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'try/finally: finally block runs after try' );
        unlink $file;
    }
};
subtest 'try/catch/finally - finally runs after catch' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $x = 0;
try {
    throw 1;
} catch ($e) {
    $x = 10;
} finally {
    $x = $x + 32;
}
return $x;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_try_catch_finally' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'catch sets x=10, finally adds 32 -> 42' );
        unlink $file;
    }
};
subtest 'unhandled throw sets err_code' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
throw 42;
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/e2e_unhandled_throw' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'unhandled throw returns 0 (fallback)' );
        unlink $file;
    }
};
done_testing;
