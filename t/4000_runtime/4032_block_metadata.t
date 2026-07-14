use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# R2.2 Block Metadata Tests — find_free_line, clear_block_bitmap,
# next_free hint, bump_alloc line marking, sweep-driven reclamation
subtest 'clear_block_bitmap zeros both words' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
# Block has Line 0 marked from _init
Brocken::Runtime::clear_block_bitmap($block);
my i64 $w0 = Brocken::load_i64($block);
my i64 $w1 = Brocken::load_i64(Brocken::ptr_add($block, 8));
if ($w0 != 0) { return 1; }
if ($w1 != 0) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_clear_bitmap' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'clear_block_bitmap zeros both words' );
        unlink $file;
    }
};
subtest 'find_free_line returns first unmarked line' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
# Clear bitmap (Line 0 was marked by _init)
Brocken::Runtime::clear_block_bitmap($block);
# Empty bitmap: find_free_line should return 0
my i64 $f0 = Brocken::Runtime::find_free_line($block, 0);
if ($f0 != 0) { return 1; }
# Mark line 0, find from 0
Brocken::Runtime::mark_line($block, 0);
my i64 $f1 = Brocken::Runtime::find_free_line($block, 0);
if ($f1 != 1) { return 2; }
# Mark lines 1-5, find from 0
my i64 $i = 1;
while (Brocken::ptr_cmp_gt(6, $i)) {
    Brocken::Runtime::mark_line($block, $i);
    $i = Brocken::i64_add($i, 1);
}
my i64 $f2 = Brocken::Runtime::find_free_line($block, 0);
if ($f2 != 6) { return 3; }
# Mark line 63, find from 60
Brocken::Runtime::mark_line($block, 63);
my i64 $f3 = Brocken::Runtime::find_free_line($block, 60);
if ($f3 != 60) { return 4; }
# Mark lines 60-62 too, find from 60 should jump to 64
Brocken::Runtime::mark_line($block, 60);
Brocken::Runtime::mark_line($block, 61);
Brocken::Runtime::mark_line($block, 62);
my i64 $f4 = Brocken::Runtime::find_free_line($block, 60);
if ($f4 != 64) { return 5; }
# Mark line 64, find from 64 should return 65
Brocken::Runtime::mark_line($block, 64);
my i64 $f5 = Brocken::Runtime::find_free_line($block, 64);
if ($f5 != 65) { return 6; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_find_free_line' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'find_free_line returns first unmarked line' );
        unlink $file;
    }
};
subtest 'find_free_line returns -1 when all lines marked' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
# Mark all 128 lines
my i64 $i = 0;
while (Brocken::ptr_cmp_gt(128, $i)) {
    Brocken::Runtime::mark_line($block, $i);
    $i = Brocken::i64_add($i, 1);
}
# find_free_line should return -1
my i64 $f = Brocken::Runtime::find_free_line($block, 0);
if ($f != -1) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_find_full' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'find_free_line returns -1 when all 128 lines marked' );
        unlink $file;
    }
};
subtest 'find_free_line with start_idx skips ahead' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
Brocken::Runtime::clear_block_bitmap($block);
# Mark lines 0-9
my i64 $i = 0;
while (Brocken::ptr_cmp_gt(10, $i)) {
    Brocken::Runtime::mark_line($block, $i);
    $i = Brocken::i64_add($i, 1);
}
# Start from 5: should return 10 (skipping marked 5-9)
my i64 $f0 = Brocken::Runtime::find_free_line($block, 5);
if ($f0 != 10) { return 1; }
# Start from 10: should return 10 (line 10 is free)
my i64 $f1 = Brocken::Runtime::find_free_line($block, 10);
if ($f1 != 10) { return 2; }
# Start from 100: all free, returns 100
my i64 $f2 = Brocken::Runtime::find_free_line($block, 100);
if ($f2 != 100) { return 3; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_find_start_idx' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'find_free_line respects start_idx' );
        unlink $file;
    }
};
subtest 'get_next_free and set_next_free' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
# _init sets next_free to 0
my i64 $nf0 = Brocken::Runtime::get_next_free($block);
if ($nf0 != 0) { return 1; }
# Set to 42
Brocken::Runtime::set_next_free($block, 42);
my i64 $nf1 = Brocken::Runtime::get_next_free($block);
if ($nf1 != 42) { return 2; }
# Set to 127
Brocken::Runtime::set_next_free($block, 127);
my i64 $nf2 = Brocken::Runtime::get_next_free($block);
if ($nf2 != 127) { return 3; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_next_free' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'get_next_free and set_next_free work correctly' );
        unlink $file;
    }
};
subtest '_init marks Line 0 in bitmap' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
# Check that Line 0 is marked in the bitmap after _init
my i64 $w0 = Brocken::load_i64($block);
my i64 $bit0 = Brocken::band($w0, 1);
if ($bit0 != 1) { return 1; }
# Check that sweep_block returns 1 (only Line 0 marked)
my i64 $s = Brocken::Runtime::sweep_block($block);
if ($s != 1) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_init_mark' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, '_init marks Line 0 in bitmap' );
        unlink $file;
    }
};
subtest 'bump_alloc marks lines when advancing' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block0 = Brocken::ptr_add($hb, 88);
# Allocate many times to ensure we cross at least one line boundary
my $a = 10; my $b = 20; my $c = 30; my $d = 40;
my $e = 50; my $f = 60; my $g = 70; my $h = 80;
my $i = 90; my $j = 100; my $k = 110; my $l = 120;
my $m = 130; my $n = 140; my $o = 150; my $p = 160;
my $q = 170; my $r = 180; my $s = 190; my $t = 200;
# Check live_count to confirm allocations happened
my i64 $lc = Brocken::load_i64(Brocken::ptr_add($block0, 32752));
if ($lc < 1) { return 1; }
# Check cursor position
my ptr $cursor = Brocken::load_i64(Brocken::ptr_add($hb, 24));
my i64 $offset = Brocken::ptr_sub($cursor, $block0);
# offset should be >= 256 (we've moved to Line 1+)
if (Brocken::ptr_cmp_gt(256, $offset)) { return 2; }
# Check that multiple lines are marked in bitmap
my i64 $w0 = Brocken::load_i64($block0);
# At least Line 0 and Line 1 should be marked
my i64 $bit0 = Brocken::band($w0, 1);
if ($bit0 != 1) { return 3; }
my i64 $bit1 = Brocken::band($w0, 2);
if ($bit1 == 0) { return 4; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_alloc_mark' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'bump_alloc marks lines when advancing' );
        unlink $file;
    }
};
subtest 'bump_alloc reuses free line via find_free_line' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
# Force cursor to near end of Line 127 to trigger block-full path
my ptr $block_end = Brocken::ptr_add($block, 32752);
my ptr $fake_end = Brocken::ptr_sub($block_end, 16);
Brocken::store_i64(Brocken::ptr_add($hb, 24), $fake_end);
Brocken::store_i64(Brocken::ptr_add($hb, 32), $fake_end);
# Clear bitmap so there are free lines available
Brocken::Runtime::clear_block_bitmap($block);
# Set next_free to 0 so it starts scanning from beginning
Brocken::Runtime::set_next_free($block, 0);
# Allocate — should reuse a free line instead of allocating new block
my $x = 42;
my ptr $after_cb = Brocken::load_i64(Brocken::ptr_add($hb, 80));
# current_block should NOT have changed — free line was reused
if (Brocken::ptr_cmp_eq($after_cb, $block) == 0) { return 1; }
# The allocation should be somewhere in the block (not block0's original cursor area)
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_reuse_line' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'bump_alloc reuses free line via find_free_line' );
        unlink $file;
    }
};
subtest 'bump_alloc falls back to legacy heap when bitmap full' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block0 = Brocken::ptr_add($hb, 88);
my ptr $cb = Brocken::load_i64(Brocken::ptr_add($hb, 80));
if (Brocken::ptr_cmp_eq($cb, $block0) == 0) { return 1; }
# Mark ALL 128 lines so find_free_line returns -1
my i64 $i = 0;
while (Brocken::ptr_cmp_gt(128, $i)) {
    Brocken::Runtime::mark_line($block0, $i);
    $i = Brocken::i64_add($i, 1);
}
# Force cursor near end
my ptr $block_end = Brocken::ptr_add($block0, 32752);
my ptr $fake_end = Brocken::ptr_sub($block_end, 16);
Brocken::store_i64(Brocken::ptr_add($hb, 24), $fake_end);
Brocken::store_i64(Brocken::ptr_add($hb, 32), $fake_end);
# Allocate — must go to legacy heap
my $x = 42;
my ptr $after_cb = Brocken::load_i64(Brocken::ptr_add($hb, 80));
# current_block should have changed
if (Brocken::ptr_cmp_eq($after_cb, $block0)) { return 2; }
# New block live_count = 1
my i64 $lc = Brocken::load_i64(Brocken::ptr_add($after_cb, 32752));
if ($lc != 1) { return 3; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_legacy_fallback' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'bump_alloc falls back to legacy heap when bitmap full' );
        unlink $file;
    }
};
subtest 'recycle_block clears bitmap and resets next_free' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block = Brocken::ptr_add($hb, 88);
# Mark several lines
Brocken::Runtime::mark_line($block, 0);
Brocken::Runtime::mark_line($block, 1);
Brocken::Runtime::mark_line($block, 63);
Brocken::Runtime::mark_line($block, 64);
Brocken::Runtime::mark_line($block, 127);
# Set next_free to non-zero
Brocken::Runtime::set_next_free($block, 50);
# Recycle the block
Brocken::Runtime::recycle_block($hb, $block);
# Verify bitmap is cleared
my i64 $w0 = Brocken::load_i64($block);
my i64 $w1 = Brocken::load_i64(Brocken::ptr_add($block, 8));
if ($w0 != 0) { return 1; }
if ($w1 != 0) { return 2; }
# Verify next_free is reset to 0
my i64 $nf = Brocken::Runtime::get_next_free($block);
if ($nf != 0) { return 3; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_recycle' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'recycle_block clears bitmap and resets next_free' );
        unlink $file;
    }
};
subtest 'full sweep-reclaim cycle through bump_alloc' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block0 = Brocken::ptr_add($hb, 88);
{
    # Allocate in a block scope — freed on exit
    my $a = 10;
    my $b = 20;
}
# After block scope, decref should have recycled the block
# (live_count went to 0)
my i64 $fb = Brocken::Runtime::free_blocks_count($hb);
if ($fb == 0) { return 1; }
# The recycled block should have a clear bitmap
my ptr $recycled = Brocken::load_i64(Brocken::ptr_add($hb, 40));
# free_blocks list head should be the recycled block
if (Brocken::ptr_cmp_eq($recycled, 0)) { return 2; }
# Check the bitmap of the recycled block
my i64 $w0 = Brocken::load_i64($recycled);
my i64 $w1 = Brocken::load_i64(Brocken::ptr_add($recycled, 8));
if ($w0 != 0) { return 3; }
if ($w1 != 0) { return 4; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_sweep_reclaim' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'full sweep-reclaim cycle produces clean recycled block' );
        unlink $file;
    }
};
subtest 'live_count tracks allocations across line advances' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block0 = Brocken::ptr_add($hb, 88);
# Many allocations to span multiple lines
my $a = 1; my $b = 2; my $c = 3; my $d = 4;
my $e = 5; my $f = 6; my $g = 7; my $h = 8;
my $i = 9; my $j = 10; my $k = 11; my $l = 12;
my $m = 13; my $n = 14; my $o = 15; my $p = 16;
# live_count should be 16
my i64 $lc = Brocken::load_i64(Brocken::ptr_add($block0, 32752));
if ($lc != 16) { return 1; }
# Bitmap should have multiple lines marked
my i64 $w0 = Brocken::load_i64($block0);
# At least lines 0 and 1 should be marked
if (Brocken::band($w0, 1) == 0) { return 2; }
if (Brocken::band($w0, 2) == 0) { return 3; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_lc_multiline' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'live_count tracks allocations across line advances' );
        unlink $file;
    }
};
subtest 'next_free advances as bump_alloc marks lines' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $block0 = Brocken::ptr_add($hb, 88);
# Initially next_free = 0
my i64 $nf0 = Brocken::Runtime::get_next_free($block0);
if ($nf0 != 0) { return 1; }
# Force cursor to near end to trigger line advance
my ptr $block_end = Brocken::ptr_add($block0, 32752);
my ptr $fake_end = Brocken::ptr_sub($block_end, 16);
Brocken::store_i64(Brocken::ptr_add($hb, 24), $fake_end);
Brocken::store_i64(Brocken::ptr_add($hb, 32), $fake_end);
# Clear bitmap so find_free_line can find free lines
Brocken::Runtime::clear_block_bitmap($block0);
Brocken::Runtime::set_next_free($block0, 0);
# Allocate — should find a free line and update next_free
my $x = 42;
my i64 $nf1 = Brocken::Runtime::get_next_free($block0);
# cursor was at line 127, find_free_line returns 127, next_free = 128
if ($nf1 != 128) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r22_nf_advance' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'next_free advances when bump_alloc reuses a free line' );
        unlink $file;
    }
};
done_testing;
