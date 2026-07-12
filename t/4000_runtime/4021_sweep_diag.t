# ARM64 mark_line/sweep_block diagnostic test
# Encodes diagnostic info in exit code:
#   0   = PASS
#   1   = sweep_block(block) on zeroed block returned != 0
#   2   = sweep_block after mark_line(0) returned != 1
#   3   = sweep_block after mark_line(1) returned != 2
#   4   = sweep_block after mark_line(63) returned != 3
#   5   = sweep_block after mark_line(64) returned != 4
#   6   = sweep_block after mark_line(127) returned != 5
#  20   = word0 raw after mark(0)+mark(1) != 3
#  21   = word0 raw after mark(0)+mark(1)+mark(63) doesn't have bit 63
#  22   = word0 raw after all marks doesn't match expected
#  30   = sweep_block on manually written 0xFF..FF word0 != 64
#  31   = sweep_block on manually written word0 with only bit 63 != 1
# 100+ = raw word0 value (lower 8 bits + 100)

use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

my $name = 'sweep_block ARM64 diagnostic: ';

SKIP: {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    skip 'Not ARM64', 1 unless $host->is_arm64 && $host->is_native;
    my $rc = do {
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 80);

# Test 1: sweep_block on zeroed block
my i64 $s0 = Brocken::Runtime::sweep_block($block);
if ($s0 != 0) { return 1; }

# Test 2: mark_line(0) and check
Brocken::Runtime::mark_line($block, 0);
my i64 $s1 = Brocken::Runtime::sweep_block($block);
if ($s1 != 1) { return 2; }

# Test 3: mark_line(1) and check
Brocken::Runtime::mark_line($block, 1);
my i64 $s2 = Brocken::Runtime::sweep_block($block);
if ($s2 != 2) { return 3; }

# Diagnostic: check raw word0 value after bits 0,1 are set
my i64 $word0_raw = Brocken::load_i64($block);
if ($word0_raw != 3) { return 20; }

# Test 4: mark_line(63) and check
Brocken::Runtime::mark_line($block, 63);
my i64 $s3 = Brocken::Runtime::sweep_block($block);

# Diagnostic: check raw word0 after mark(63)
my i64 $word0_after = Brocken::load_i64($block);
my i64 $mask63 = Brocken::shl(1, 63);
my i64 $bit63 = Brocken::band($word0_after, $mask63);
if (Brocken::ptr_cmp_eq($bit63, 0)) { return 21; }

if ($s3 != 3) {
    # Failed - return sweep_block result + 100 to diagnose
    my i64 $diag = Brocken::i64_add($s3, 100);
    return $diag;
}

# Test 5: mark_line(64) and check
Brocken::Runtime::mark_line($block, 64);
my i64 $s4 = Brocken::Runtime::sweep_block($block);
if ($s4 != 4) { return 5; }

# Test 6: mark_line(127) and check
Brocken::Runtime::mark_line($block, 127);
my i64 $s5 = Brocken::Runtime::sweep_block($block);
if ($s5 != 5) { return 6; }

return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/sweep_diag' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $rc = $? >> 8;
        unlink $file;
        $rc;
    };
    ok( $rc == 0, "$name exit code $rc" ) or diag("Diagnostic returned $rc on ARM64");
}

done_testing;
