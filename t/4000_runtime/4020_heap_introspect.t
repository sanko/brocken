use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'Initial ICB cursor state after _init' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $hc = Brocken::Runtime::heap_cursor($hb);
my ptr $ic = Brocken::Runtime::immix_cursor($hb);
my ptr $il = Brocken::Runtime::immix_limit($hb);
my i64 $lr = Brocken::Runtime::line_remaining($hb);
my i64 $br = Brocken::Runtime::block_remaining($hb);
my i64 $f16 = Brocken::Runtime::free16_count($hb);
my i64 $fb = Brocken::Runtime::free_blocks_count($hb);

# Expected: heap_cursor == immix_cursor == hb + 80 (block at hb+64, Line 0 data at block+16)
my ptr $base = Brocken::ptr_add($hb, 64);
my ptr $line0 = Brocken::ptr_add($base, 16);
# hc should be line0
if (Brocken::ptr_cmp_eq($hc, $line0) == 0) { return 1; }
# ic should also be line0
if (Brocken::ptr_cmp_eq($ic, $line0) == 0) { return 2; }
# il should be base + 256
if (Brocken::ptr_cmp_eq($il, Brocken::ptr_add($base, 256)) == 0) { return 3; }
# line_remaining = 256 - 16 = 240
if ($lr != 240) { return 4; }
# block_remaining = 32768 - 16 = 32752
if ($br != 32752) { return 5; }
# free16_count == 0
if ($f16 != 0) { return 6; }
# free_blocks_count == 0
if ($fb != 0) { return 7; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_intro_init' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'all 7 initial-state checks pass' );
        unlink $file;
    }
};
subtest 'Cursor advances after Any allocation' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $before = Brocken::Runtime::immix_cursor($hb);
my i64 $before_lr = Brocken::Runtime::line_remaining($hb);
# Allocate an Any (boxes 16 bytes)
my $x = 42;
my ptr $after = Brocken::Runtime::immix_cursor($hb);
my i64 $after_lr = Brocken::Runtime::line_remaining($hb);
my ptr $expected_after = Brocken::ptr_add($before, 16);
# cursor advanced by 16
if (Brocken::ptr_cmp_eq($after, $expected_after) == 0) { return 1; }
# line_remaining decreased by 16
my i64 $expected_lr = Brocken::i64_sub($before_lr, 16);
if ($after_lr != $expected_lr) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_intro_alloc1' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'cursor and line_remaining after single Any allocation' );
        unlink $file;
    }
};
subtest 'Multiple Any allocations advance cursor' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $before = Brocken::Runtime::immix_cursor($hb);
# Allocate three Any variables: 3 * 16 = 48 bytes
my $x = 10;
my $y = 20;
my $z = 30;
my ptr $after = Brocken::Runtime::immix_cursor($hb);
my ptr $expected = Brocken::ptr_add($before, 48);
if (Brocken::ptr_cmp_eq($after, $expected) == 0) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_intro_alloc3' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'cursor advances 48 after three Any allocations' );
        unlink $file;
    }
};
subtest 'heap_cursor and immix_cursor start equal' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $hc = Brocken::Runtime::heap_cursor($hb);
my ptr $ic = Brocken::Runtime::immix_cursor($hb);
# heap_cursor (legacy) should equal immix_cursor initially
if (Brocken::ptr_cmp_eq($hc, $ic) == 0) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_intro_equal' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'heap_cursor == immix_cursor initially' );
        unlink $file;
    }
};
subtest 'block_remaining starts at max and decreases' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my i64 $br1 = Brocken::Runtime::block_remaining($hb);
# After first allocation, cursor moved 16, so block_remaining decreases by 16
my $x = 42;
my i64 $br2 = Brocken::Runtime::block_remaining($hb);
my i64 $expected_br2 = Brocken::i64_sub($br1, 16);
if ($br2 != $expected_br2) { return 1; }
# After second allocation, decreases by another 16
my $y = 99;
my i64 $br3 = Brocken::Runtime::block_remaining($hb);
my i64 $expected_br3 = Brocken::i64_sub($expected_br2, 16);
if ($br3 != $expected_br3) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_intro_blockrem' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'block_remaining decreases by 16 per allocation' );
        unlink $file;
    }
};
subtest 'free16_count and free_blocks_count remain zero after allocation' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my $x = 42;
my $y = 99;
my $z = 100;
# No objects have been freed yet
my i64 $f16 = Brocken::Runtime::free16_count($hb);
my i64 $fb = Brocken::Runtime::free_blocks_count($hb);
if ($f16 != 0) { return 1; }
if ($fb != 0) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_intro_counts' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'free counts zero after allocations (no decref yet)' );
        unlink $file;
    }
};
subtest 'mem_status initial state is all zeros' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my i64 $s = Brocken::Runtime::mem_status($hb);
# Expected: all bits 0 (line not full, block not full, no free objects/blocks)
if ($s != 0) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_gc_mem_status_init' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'mem_status: initial state all zeros' );
        unlink $file;
    }
};
subtest 'mem_status sets bit 0 when line is full' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Fill line 0: 240 bytes / 16 = 15 Any allocations
my $a1=1;my $a2=2;my $a3=3;my $a4=4;my $a5=5;
my $a6=6;my $a7=7;my $a8=8;my $a9=9;my $a10=10;
my $a11=11;my $a12=12;my $a13=13;my $a14=14;my $a15=15;
my i64 $s = Brocken::Runtime::mem_status($hb);
# bit 0 (value 1) should be set
my i64 $expected = 1;
if ($s != $expected) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_gc_mem_status_line_full' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'mem_status: bit 0 set when line is full' );
        unlink $file;
    }
};
subtest 'Block-scoped decref via bare block' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my i64 $before = Brocken::Runtime::free16_count($hb);
# Declare Any in a bare block — block-scoped RC decref cleans it up at block exit
{
    my $x = 42;
}
my i64 $after = Brocken::Runtime::free16_count($hb);
# free16_count should increase by 1 (the box(42) was freed)
my i64 $diff = Brocken::i64_sub($after, $before);
if ($diff != 1) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_gc_block_decref' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'block-scoped decref frees block-local Any' );
        unlink $file;
    }
};
subtest 'mem_status sets bit 2 after decref (free16 nonempty)' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Reassign to an existing Any variable to trigger decref of old value
my $x = 10;
$x = 99;
# After reassignment, the old value (10) was decref'd and pushed to free16_head
my i64 $s = Brocken::Runtime::mem_status($hb);
# bit 2 (value 4) should be set
if (Brocken::band($s, 4) == 0) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_gc_mem_status_free16' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'mem_status: bit 2 set after Any reassignment' );
        unlink $file;
    }
};
subtest 'line_waste initial and after allocations' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my i64 $w0 = Brocken::Runtime::line_waste($hb);
# Initially: line 0 starts at block+16, limit at block+256 → waste = 240
if ($w0 != 240) { return 1; }
my $x = 42;
my i64 $w1 = Brocken::Runtime::line_waste($hb);
# After 1 alloc (16 bytes): waste = 240 - 16 = 224
if ($w1 != 224) { return 2; }
# Fill the rest of line 0 (14 more allocs: 15 total = 240 bytes)
my $a1=1;my $a2=2;my $a3=3;my $a4=4;my $a5=5;
my $a6=6;my $a7=7;my $a8=8;my $a9=9;my $a10=10;
my $a11=11;my $a12=12;my $a13=13;my $a14=14;
my i64 $w15 = Brocken::Runtime::line_waste($hb);
# After 15 allocs: waste = 0 (line exhausted)
if ($w15 != 0) { return 3; }
# The next alloc advances to line 1
my $a16 = 16;
my i64 $w16 = Brocken::Runtime::line_waste($hb);
# Line 1 has full 256 bytes, waste = 256 - 16 = 240
if ($w16 != 240) { return 4; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_gc_line_waste' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'line_waste: initial 240, 224 after 1 alloc, 0 at line fill, 240 on new line' );
        unlink $file;
    }
};
done_testing;
