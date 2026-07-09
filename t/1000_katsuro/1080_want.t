use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
use Brocken::Katsuro::AST;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'want(i64) returns 1 when function returns i64' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile('return want(i64);');
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/want_type_match' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 1, 'want(i64) is 1 when return type is i64' );
        unlink $file;
    }
};
subtest 'want(f64) returns 0 when function returns i64' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile('return want(f64);');
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/want_type_mismatch' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'want(f64) is 0 when return type is i64' );
        unlink $file;
    }
};
subtest 'want("scalar") returns 1 in scalar context' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(q!return want("scalar");!);
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/want_scalar' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 1, 'want("scalar") is 1 at top level' );
        unlink $file;
    }
};
subtest 'want("list") returns 0 in scalar context' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(q!return want("list");!);
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/want_list' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'want("list") is 0 at top level' );
        unlink $file;
    }
};
subtest 'want("void") returns 0 in scalar context' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(q!return want("void");!);
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/want_void' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'want("void") is 0 at top level' );
        unlink $file;
    }
};
subtest 'want(TypeName) in user-defined function' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub is_i64() -> i64 {
    return want(i64);
}
return is_i64();
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/want_cross_func' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 1, 'want(i64) in function that returns i64' );
        unlink $file;
    }
};
subtest 'want(i64) IR shows constant folding (ret i64 1)' => sub {
    my $module = Brocken::Compiler->new->compile('return want(i64);');
    my $text   = $module->as_string;
    like( $text, qr/ret\s+i64\s+1/, 'want(i64) constant-folded to ret i64 1' );
    my $entry_fn   = ( grep { $_->name eq '_BROCKEN_ENTRY' } $module->functions->@* )[0];
    my $entry_text = $entry_fn->as_string;
    unlike( $entry_text, qr/call.*want_is/, 'no want_is runtime call in _BROCKEN_ENTRY' );
};
subtest 'want("scalar") IR shows runtime call' => sub {
    my $module = Brocken::Compiler->new->compile(q!return want("scalar");!);
    my $text   = $module->as_string;
    like( $text, qr/call\s+i64\s+\@Brocken::Runtime::want_is_scalar/, 'structural want emits runtime call' );
};
done_testing;
