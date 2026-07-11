# ARM64 sweep_block diagnostic test
# Encodes diagnostic info in exit code:
#   0   = PASS (sweep_block returned 0 on zeroed block)
#   1-99 = sweep_block return value (what it returned instead of 0)
#   100  = word0 non-zero after _init
#   101  = word1 non-zero after _init
#   200+ = other failures

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
# Step 1: Check word0 and word1 directly
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 80);
my i64 $word0 = Brocken::load_i64($block);
if ($word0 != 0) { return 100; }
my i64 $word1 = Brocken::load_i64(Brocken::ptr_add($block, 8));
if ($word1 != 0) { return 101; }
# Step 2: Run sweep_block and return its value (should be 0)
my i64 $s0 = Brocken::Runtime::sweep_block($block);
return $s0;  # returns what sweep_block gave us
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/sweep_diag' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        my $rc = $? >> 8;
        unlink $file;
        $rc;
    };
    ok( $rc == 0, "$name exit code $rc" ) or diag("sweep_block returned $rc on ARM64");
}

done_testing;
