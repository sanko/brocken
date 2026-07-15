use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'memory_limit=0 means unlimited' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# memory_limit is 0 (default from _init) — unlimited
my i64 $limit = Brocken::load_i64(Brocken::ptr_add($hb, 88));
if ($limit != 0) { return 1; }
# Allocate several Any values — should never fail
my $a = 1;
my $b = 2;
my $c = 3;
# Check err_code is still 0
my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72));
if ($err != 0) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_mem_unlim' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'memory_limit=0 allows unlimited allocation' );
        unlink $file;
    }
};
subtest 'setting memory_limit via store_i64' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Set memory_limit to 100 bytes
Brocken::store_i64(Brocken::ptr_add($hb, 88), 100);
my i64 $limit = Brocken::load_i64(Brocken::ptr_add($hb, 88));
if ($limit != 100) { return 1; }
# Set memory_used to 0 to start fresh
Brocken::store_i64(Brocken::ptr_add($hb, 96), 0);
# Allocate one Any (16 bytes) — should succeed since 16 < 100
my $x = 42;
my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72));
if ($err != 0) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_mem_set' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'memory_limit set and small allocation succeeds' );
        unlink $file;
    }
};
subtest 'allocation exceeding memory_limit triggers OOM' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Reset err_code and memory_used to 0
Brocken::store_i64(Brocken::ptr_add($hb, 72), 0);
Brocken::store_i64(Brocken::ptr_add($hb, 96), 0);
# Set memory_limit to 20 bytes (less than one Any = 16 bytes after partial use)
Brocken::store_i64(Brocken::ptr_add($hb, 88), 20);
# Allocate one Any successfully (16 bytes fits: 0 + 16 <= 20)
my $a = 1;
my i64 $used = Brocken::load_i64(Brocken::ptr_add($hb, 96));
# Now set limit so next alloc fails: limit = used (already consumed)
Brocken::store_i64(Brocken::ptr_add($hb, 88), $used);
# Reset err_code
Brocken::store_i64(Brocken::ptr_add($hb, 72), 0);
# Call bump_alloc directly — returns 0 on OOM without crashing
my ptr $result = Brocken::Runtime::bump_alloc($hb, 16);
# err_code should be 1 (OOM)
my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72));
if ($err != 1) { return 1; }
# result should be 0 (null pointer from OOM)
if (Brocken::ptr_cmp_eq($result, 0) == 0) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_mem_oom' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'exceeding memory_limit sets err_code=1 (OOM)' );
        unlink $file;
    }
};
subtest 'memory_used increments on allocation' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Reset memory_used and memory_limit
Brocken::store_i64(Brocken::ptr_add($hb, 96), 0);
Brocken::store_i64(Brocken::ptr_add($hb, 88), 0);
# Allocate 3 Any values: each is 16 bytes (box header + payload)
my $a = 10;
my $b = 20;
my $c = 30;
my i64 $used = Brocken::load_i64(Brocken::ptr_add($hb, 96));
# Each Any allocation goes through bump_alloc and increments memory_used
# The bump_alloc memory_used increments happen per bump_alloc call,
# but the free16 hot-path does NOT increment memory_used.
# After 3 fresh allocations (no free16 recycling), memory_used should be >= 48
if ($used < 48) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_mem_used' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'memory_used increments by alloc size' );
        unlink $file;
    }
};
subtest 'OOM on block boundary when memory_limit crossed' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Reset state
Brocken::store_i64(Brocken::ptr_add($hb, 72), 0);
Brocken::store_i64(Brocken::ptr_add($hb, 96), 0);
Brocken::store_i64(Brocken::ptr_add($hb, 88), 0);
# Allocate two Any values to consume some memory
my $a = 1;
my $b = 2;
# Read current memory_used
my i64 $used_before = Brocken::load_i64(Brocken::ptr_add($hb, 96));
# Set limit to current_used + 8 bytes (less than one Any = 16 bytes)
my i64 $tight_limit = Brocken::i64_add($used_before, 8);
Brocken::store_i64(Brocken::ptr_add($hb, 88), $tight_limit);
# Reset err_code
Brocken::store_i64(Brocken::ptr_add($hb, 72), 0);
# Call bump_alloc directly — returns 0 on OOM without crashing
my ptr $result = Brocken::Runtime::bump_alloc($hb, 16);
# err_code should be 1 (OOM)
my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72));
if ($err != 1) { return 1; }
# result should be null
if (Brocken::ptr_cmp_eq($result, 0) == 0) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_mem_boundary' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'tight limit triggers OOM on next allocation' );
        unlink $file;
    }
};
done_testing;
