use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Immix block ownership. A freed object must be charged to the block it was allocated in, not to whichever block happens
# to be current at free time. block_of() does that by masking the address against the block grid anchored at the first
# block (heap_base + ICB::SIZE). A bare `addr & ~(BLOCK_SIZE-1)` mask is wrong because heap_base is only 16-byte aligned
# and block 0 sits ICB::SIZE bytes off any heap_base-anchored grid, which is exactly what made block 0 overlap block 1.
subtest 'block_of maps an allocation to its owning block on one grid' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block0 = Brocken::ptr_add($hb, 160);
# Raw 16-byte cell in block 0 with RC=1, tag=0.
my ptr $a = Brocken::Runtime::bump_alloc($hb, 16);
Brocken::store_i64($a, 1);
if (Brocken::ptr_cmp_eq(Brocken::Runtime::block_of($hb, $a), $block0) == 0) { return 1; }
# Force block 0 to look full, then allocate: the runtime must carve a fresh block.
my ptr $block_end = Brocken::ptr_add($block0, 32752);
my ptr $fake_end = Brocken::ptr_sub($block_end, 16);
Brocken::store_i64(Brocken::ptr_add($hb, 24), $fake_end);
Brocken::store_i64(Brocken::ptr_add($hb, 32), $fake_end);
my i64 $i = 0;
while (Brocken::ptr_cmp_gt(128, $i)) {
    Brocken::Runtime::mark_line($block0, $i);
    $i = Brocken::i64_add($i, 1);
}
my ptr $b = Brocken::Runtime::bump_alloc($hb, 16);
Brocken::store_i64($b, 1);
my ptr $block1 = Brocken::load_i64(Brocken::ptr_add($hb, 80));
if (Brocken::ptr_cmp_eq($block1, $block0)) { return 2; }
# Blocks tile one grid: block 1 begins exactly where block 0 ends (no ICB-sized overlap).
if (Brocken::ptr_cmp_eq(Brocken::ptr_sub($block1, $block0), Brocken::Runtime::block_size()) == 0) { return 3; }
if (Brocken::ptr_cmp_ge($block1, Brocken::ptr_add($block0, Brocken::Runtime::block_size())) == 0) { return 4; }
if (Brocken::ptr_cmp_eq(Brocken::Runtime::block_of($hb, $a), $block0) == 0) { return 5; }
if (Brocken::ptr_cmp_eq(Brocken::Runtime::block_of($hb, $b), $block1) == 0) { return 6; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_block_owner_of' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'block_of maps objects to their owning block' );
        unlink $file;
    }
};
subtest 'decref charges the owning block while another block is current' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block0 = Brocken::ptr_add($hb, 160);
my ptr $a = Brocken::Runtime::bump_alloc($hb, 16);
Brocken::store_i64($a, 1);
# Force a second block so that block 1, not block 0, is current.
my ptr $block_end = Brocken::ptr_add($block0, 32752);
my ptr $fake_end = Brocken::ptr_sub($block_end, 16);
Brocken::store_i64(Brocken::ptr_add($hb, 24), $fake_end);
Brocken::store_i64(Brocken::ptr_add($hb, 32), $fake_end);
my i64 $i = 0;
while (Brocken::ptr_cmp_gt(128, $i)) {
    Brocken::Runtime::mark_line($block0, $i);
    $i = Brocken::i64_add($i, 1);
}
my ptr $b = Brocken::Runtime::bump_alloc($hb, 16);
Brocken::store_i64($b, 1);
my ptr $block1 = Brocken::load_i64(Brocken::ptr_add($hb, 80));
if (Brocken::ptr_cmp_eq($block1, $block0)) { return 1; }
my i64 $lc0_before = Brocken::load_i64(Brocken::ptr_add($block0, 32752));
my i64 $lc1_before = Brocken::load_i64(Brocken::ptr_add($block1, 32752));
if ($lc0_before != 1) { return 2; }
if ($lc1_before != 1) { return 3; }
# block 1 is current; freeing the block-0 object must charge block 0.
Brocken::Runtime::decref($a, $hb);
my i64 $lc0_after = Brocken::load_i64(Brocken::ptr_add($block0, 32752));
my i64 $lc1_after = Brocken::load_i64(Brocken::ptr_add($block1, 32752));
if ($lc0_after != 0) { return 4; }
if ($lc1_after != $lc1_before) { return 5; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_block_owner_decref' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'decref charges the owning block' );
        unlink $file;
    }
};
subtest 'gc_decref charges the owning block while another block is current' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block0 = Brocken::ptr_add($hb, 160);
my ptr $a = Brocken::Runtime::bump_alloc($hb, 16);
Brocken::store_i64($a, 2);
my ptr $block_end = Brocken::ptr_add($block0, 32752);
my ptr $fake_end = Brocken::ptr_sub($block_end, 16);
Brocken::store_i64(Brocken::ptr_add($hb, 24), $fake_end);
Brocken::store_i64(Brocken::ptr_add($hb, 32), $fake_end);
my i64 $i = 0;
while (Brocken::ptr_cmp_gt(128, $i)) {
    Brocken::Runtime::mark_line($block0, $i);
    $i = Brocken::i64_add($i, 1);
}
my ptr $b = Brocken::Runtime::bump_alloc($hb, 16);
Brocken::store_i64($b, 2);
my ptr $block1 = Brocken::load_i64(Brocken::ptr_add($hb, 80));
if (Brocken::ptr_cmp_eq($block1, $block0)) { return 1; }
my i64 $lc1_before = Brocken::load_i64(Brocken::ptr_add($block1, 32752));
# RC 2 -> 1: node survives and stays out of block bookkeeping only in the RC==0 path.
Brocken::Runtime::gc_decref($a, $hb);
if (Brocken::load_i64(Brocken::ptr_add($block0, 32752)) != 1) { return 2; }
if (Brocken::load_i64(Brocken::ptr_add($block1, 32752)) != $lc1_before) { return 3; }
# RC 1 -> 0: now block 0 must be charged, not the current block 1.
Brocken::Runtime::gc_decref($a, $hb);
if (Brocken::load_i64(Brocken::ptr_add($block0, 32752)) != 0) { return 4; }
if (Brocken::load_i64(Brocken::ptr_add($block1, 32752)) != $lc1_before) { return 5; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_block_owner_gc_decref' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'gc_decref charges the owning block' );
        unlink $file;
    }
};
done_testing;
