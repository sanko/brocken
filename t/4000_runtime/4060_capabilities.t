use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'default capabilities allow syscall' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Default caps should be ~0 (all bits set) from _BROCKEN_ENTRY prologue.
# CAP_FFI = 16, so bit 4 should be set.
my i64 $caps = Brocken::load_i64(Brocken::ptr_add($hb, 104));
my i64 $ffi_bit = Brocken::band($caps, 16);
if ($ffi_bit == 0) { return 1; }
# err_code should be 0 initially
my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72));
if ($err != 0) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_cap_default' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'default capabilities have CAP_FFI bit set' );
        unlink $file;
    }
};
subtest 'zero capabilities block syscall' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Set capabilities to 0 (no capabilities)
Brocken::store_i64(Brocken::ptr_add($hb, 104), 0);
# Reset err_code
Brocken::store_i64(Brocken::ptr_add($hb, 72), 0);
# Now attempt a syscall (exit with code 42)
# The cap check should intercept this and set err_code=3
my i64 $ret = Brocken::syscall(60, 42, 0, 0);
# We should never reach here — the cap violation branches to fuel_exit
# which returns 0, but the program continues because fuel_exit_block
# returns from _BROCKEN_ENTRY. The ret value from syscall should be 0
# (from the exit block), and err_code should be 3.
my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72));
if ($err != 3) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_cap_zero' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'zero capabilities set err_code=3 (SECURITY)' );
        unlink $file;
    }
};
subtest 'restoring CAP_FFI allows syscall again' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# First, block capabilities
Brocken::store_i64(Brocken::ptr_add($hb, 104), 0);
Brocken::store_i64(Brocken::ptr_add($hb, 72), 0);
# Attempt syscall — should be blocked
my i64 $ret1 = Brocken::syscall(60, 42, 0, 0);
my i64 $err1 = Brocken::load_i64(Brocken::ptr_add($hb, 72));
if ($err1 != 3) { return 1; }
# Now restore CAP_FFI (bit 4 = 16)
Brocken::store_i64(Brocken::ptr_add($hb, 104), 16);
# Reset err_code
Brocken::store_i64(Brocken::ptr_add($hb, 72), 0);
# Verify caps
my i64 $caps = Brocken::load_i64(Brocken::ptr_add($hb, 104));
if ($caps != 16) { return 2; }
my i64 $ffi_bit = Brocken::band($caps, 16);
if ($ffi_bit == 0) { return 3; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_cap_restore' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'restoring CAP_FFI unblocks syscall capability' );
        unlink $file;
    }
};
subtest 'wrong capability bit does not satisfy CAP_FFI check' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Set capabilities to CAP_FS_READ (1) only — missing CAP_FFI (16)
Brocken::store_i64(Brocken::ptr_add($hb, 104), 1);
Brocken::store_i64(Brocken::ptr_add($hb, 72), 0);
# Attempt syscall — should be blocked (CAP_FFI bit not set)
my i64 $ret = Brocken::syscall(60, 42, 0, 0);
my i64 $err = Brocken::load_i64(Brocken::ptr_add($hb, 72));
if ($err != 3) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_cap_wrong' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'wrong capability bit (CAP_FS_READ) does not allow syscall' );
        unlink $file;
    }
};
subtest 'err_code starts at 0 for clean isolate' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Verify all sandbox fields are clean from _init
my i64 $fuel    = Brocken::load_i64(Brocken::ptr_add($hb, 64));
my i64 $err     = Brocken::load_i64(Brocken::ptr_add($hb, 72));
my i64 $mem_lim = Brocken::load_i64(Brocken::ptr_add($hb, 88));
my i64 $mem_use = Brocken::load_i64(Brocken::ptr_add($hb, 96));
my i64 $caps    = Brocken::load_i64(Brocken::ptr_add($hb, 104));
# fuel should be the default (1000000), not 0
if ($fuel != 1000000) { return 1; }
# err_code should be 0
if ($err != 0) { return 2; }
# memory_limit should be 0 (unlimited)
if ($mem_lim != 0) { return 3; }
# memory_used should be 0
if ($mem_use != 0) { return 4; }
# capabilities should be ~0 (all bits set)
if ($caps == 0) { return 5; }
# Check a few specific cap bits
my i64 $fs_read = Brocken::band($caps, 1);
my i64 $fs_write = Brocken::band($caps, 2);
my i64 $net      = Brocken::band($caps, 4);
my i64 $system   = Brocken::band($caps, 8);
my i64 $ffi      = Brocken::band($caps, 16);
if ($fs_read == 0) { return 6; }
if ($fs_write == 0) { return 7; }
if ($net == 0) { return 8; }
if ($system == 0) { return 9; }
if ($ffi == 0) { return 10; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_cap_clean' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'clean isolate has all sandbox fields initialized correctly' );
        unlink $file;
    }
};
done_testing;
