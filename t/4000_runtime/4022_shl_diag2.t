# ARM64 shl(1,N) diagnostic — tests each shift independently, no early return
# Exit codes:
#   0   = PASS (all shifts correct + memory round-trip OK)
#  10   = shl(1,0) returned 0
#  11   = shl(1,1) returned 0
#  31   = shl(1,31) returned 0
#  51   = shl(1,51) returned 0
#  61   = shl(1,61) returned 0
#  62   = shl(1,62) returned 0
#  63   = shl(1,63) returned 0
#  80   = memory round-trip failed for shl(1,63)
use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $name = 'shl(1,N) per-shift diagnostic: ';
SKIP: {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    skip 'Not ARM64', 1 unless $host->is_arm64 && $host->is_native;
    my $rc = do {
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $fail = 0;

# --- Phase 1: test each shift independently ---
my i64 $r0 = Brocken::shl(1, 0);
if (Brocken::ptr_cmp_eq($r0, 0)) { $fail = 10; }

my i64 $r1 = Brocken::shl(1, 1);
if (Brocken::ptr_cmp_eq($r1, 0)) { $fail = 11; }

my i64 $r31 = Brocken::shl(1, 31);
if (Brocken::ptr_cmp_eq($r31, 0)) { $fail = 31; }

my i64 $r51 = Brocken::shl(1, 51);
if (Brocken::ptr_cmp_eq($r51, 0)) { $fail = 51; }

my i64 $r61 = Brocken::shl(1, 61);
if (Brocken::ptr_cmp_eq($r61, 0)) { $fail = 61; }

my i64 $r62 = Brocken::shl(1, 62);
if (Brocken::ptr_cmp_eq($r62, 0)) { $fail = 62; }

my i64 $r63 = Brocken::shl(1, 63);
if (Brocken::ptr_cmp_eq($r63, 0)) { $fail = 63; }

# --- Phase 2: cross-check consistency ---
# shl(1, N) == shl(1, N-1) << 1 for all N we tested
# We already have the values, check: r31 must be non-zero and r63 must be non-zero
# If both r31 and r63 are non-zero, test that r31 shifted left by 32 gives r63.
# r31 << 32 = shl(r31, 32)
my i64 $r31_shl32 = Brocken::shl($r31, 32);
if (!Brocken::ptr_cmp_eq($r31_shl32, $r63)) { $fail = 70; }

# --- Phase 3: memory round-trip ---
my ptr $hb = Brocken::heap_base();
my ptr $slot = Brocken::ptr_add($hb, 256);
Brocken::store_i64($slot, $r63);
my i64 $readback = Brocken::load_i64($slot);
if (!Brocken::ptr_cmp_eq($readback, $r63)) { $fail = 80; }

return $fail;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/shl_diag2' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $rc = $? >> 8;
        unlink $file;
        $rc;
    };
    ok( $rc == 0, "$name exit code $rc" ) or diag("Diagnostic returned $rc on ARM64");
}
done_testing;
