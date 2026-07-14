# ARM64 shl(1, N) variable-shift diagnostic test
# Isolates the variable-shift path (LSLV) vs constant-shift path.
# Encodes diagnostic info in exit code (avoids 64-bit hex constants entirely):
#   0   = PASS
#   1   = c63 != p63 (constant shl(1,63) != param shl(1,63))
#   2   = shl(1,63) returned 0 on both paths
#   3   = shl(1,62) mismatch (constant vs param)
#   4   = sweep_block returned wrong count
#  31   = shl(1,31) returned 0 (shift-63 specific, or all shifts broken)
#  32   = shl(1,31) worked but shl(1,63) = 0
use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $name = 'shl variable-shift ARM64 diagnostic: ';
SKIP: {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    skip 'Not ARM64', 1 unless $host->is_arm64 && $host->is_native;
    my $rc = do {
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub always_shl_63() -> i64 { return Brocken::shl(1, 63); }

sub diag_shl_param(i64 $p) -> i64 {
    return Brocken::shl(1, $p);
}

#### Phase 1: compare constant vs parameter shl(1,63) ####
my i64 $c63 = Brocken::shl(1, 63);
my i64 $f63 = always_shl_63();
my i64 $p63 = diag_shl_param(63);

# If const path differs from param path, report which
if (!Brocken::ptr_cmp_eq(Brocken::bxor($c63, $p63), 0)) { return 1; }
if (!Brocken::ptr_cmp_eq(Brocken::bxor($f63, $p63), 0)) { return 1; }

# If both paths give 0, something is fundamentally wrong
if (Brocken::ptr_cmp_eq($c63, 0)) { return 2; }

#### Phase 2: narrow down — is shl(1,31) also broken? ####
my i64 $c31 = Brocken::shl(1, 31);
if (Brocken::ptr_cmp_eq($c31, 0)) { return 31; }

# shl(1,31) worked — so LSLV is not fundamentally broken for all shifts.
# Check if shl(1,63) == 0 is specific to shift amount 63.
my i64 $c62 = Brocken::shl(1, 62);
if (Brocken::ptr_cmp_eq($c62, 0)) { return 32; }

#### Phase 3: test shl(1,62) param vs const match ####
my i64 $p62 = diag_shl_param(62);
if (!Brocken::ptr_cmp_eq(Brocken::bxor($c62, $p62), 0)) { return 3; }

#### Phase 4: full mark_line integration smoke test ####
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
Brocken::Runtime::mark_line($block, 0);
Brocken::Runtime::mark_line($block, 1);
Brocken::Runtime::mark_line($block, 63);
my i64 $swept = Brocken::Runtime::sweep_block($block);
if ($swept != 3) { return 4; }

return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/shl_diag' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $rc = $? >> 8;
        unlink $file;
        $rc;
    };
    ok( $rc == 0, "$name exit code $rc" ) or diag("Diagnostic returned $rc on ARM64");
}
done_testing;
