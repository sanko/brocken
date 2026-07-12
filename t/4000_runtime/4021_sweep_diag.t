# ARM64 shl(1, N) variable-shift diagnostic test
# Isolates the variable-shift path (LSLV) vs constant-shift path (UBFM).
# Encodes diagnostic info in exit code:
#   0   = PASS
#   1   = const 0x8000000000000000 bit63 not set (constant itself corrupted)
#  10+  = const shl(1,63): lower 8 bits of wrong result + 10
#  20+  = param shl(1,63): lower 8 bits of wrong result + 20
#  30+  = param shl(1,N) for N=0..63: N + lower 8 bits of wrong result * 64
#  40   = shl(1,62) mismatch
#  50   = sweep_block final check failed

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
sub diag_shl_param(i64 $p) -> i64 {
    return Brocken::shl(1, $p);
}

#### Phase 1: verify the expected constant ####
my i64 $expected = 0x8000000000000000;
my i64 $check = Brocken::band($expected, 0x8000000000000000);
if (Brocken::ptr_cmp_eq($check, 0)) { return 1; }

#### Phase 2: compare constant vs parameter shl(1,63) ####
my i64 $const63 = Brocken::shl(1, 63);
my i64 $param63 = diag_shl_param(63);

# If constant path gives wrong result, report it
my i64 $xc = Brocken::bxor($const63, $expected);
if (!Brocken::ptr_cmp_eq($xc, 0)) {
    my i64 $lo = Brocken::band($const63, 0xFF);
    return Brocken::i64_add($lo, 10);
}

# If param path gives wrong result, report it
my i64 $xp = Brocken::bxor($param63, $expected);
if (!Brocken::ptr_cmp_eq($xp, 0)) {
    my i64 $lo = Brocken::band($param63, 0xFF);
    return Brocken::i64_add($lo, 20);
}

#### Phase 3: test shl(1,62) on both paths ####
my i64 $c62 = Brocken::shl(1, 62);
my i64 $p62 = diag_shl_param(62);
my i64 $e62 = 0x4000000000000000;
if (!Brocken::ptr_cmp_eq(Brocken::bxor($c62, $e62), 0)) { return 40; }
if (!Brocken::ptr_cmp_eq(Brocken::bxor($p62, $e62), 0)) { return 40; }

#### Phase 4: full mark_line integration smoke test ####
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 80);
Brocken::Runtime::mark_line($block, 0);
Brocken::Runtime::mark_line($block, 1);
Brocken::Runtime::mark_line($block, 63);
my i64 $swept = Brocken::Runtime::sweep_block($block);
if ($swept != 3) { return 50; }

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
