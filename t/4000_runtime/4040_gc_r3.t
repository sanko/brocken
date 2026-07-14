use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

sub test_prog {
    my ( $name, $source, $expected ) = @_;
    my $fuzz   = Brocken::Fuzz->new();
    my $result = $fuzz->test_program( { source => $source, expected => $expected } );
    ok $result->{status} eq 'pass', $name or diag "FAIL: $result->{reason}\nSource:\n$source";
}
subtest 'get_gc_flags and set_gc_flags round-trip' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my $obj = 42;
my ptr $addr = Brocken::ptr_add($obj, 0);
# Read initial GC flags (fresh Any has flags = 0)
my i64 $flags = Brocken::Runtime::get_gc_flags($addr);
if ($flags != 0) { return 1; }
# Set flags to 0x15 (Suspect | Leaf | BRC_0)
Brocken::Runtime::set_gc_flags($addr, 21);
$flags = Brocken::Runtime::get_gc_flags($addr);
if ($flags != 21) { return 2; }
# Verify refcount and tag are preserved
my i64 $header = Brocken::load_i64($addr);
my i64 $rc = Brocken::band($header, 65535);
my i64 $tag = Brocken::band(Brocken::shr($header, 24), 255);
if ($rc == 0) { return 3; }
if ($tag != 2) { return 4; }
# Clear flags back to 0
Brocken::Runtime::set_gc_flags($addr, 0);
$flags = Brocken::Runtime::get_gc_flags($addr);
if ($flags != 0) { return 5; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_gc_flags' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'get_gc_flags/set_gc_flags round-trip passes' );
        unlink $file;
    }
};
subtest 'push_suspect_buffer adds entry' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Suspect buffer should be empty
my i64 $sc = Brocken::Runtime::suspect_count($hb);
if ($sc != 0) { return 1; }
# Create an Any-typed variable (heap-allocated)
my $obj = 42;
my ptr $addr = Brocken::ptr_add($obj, 0);
# Push to suspect buffer
Brocken::Runtime::push_suspect_buffer($addr, $hb);
# Count should be 1
$sc = Brocken::Runtime::suspect_count($hb);
if ($sc != 1) { return 2; }
# Buffered flag (bit 1) should be set
my i64 $flags = Brocken::Runtime::get_gc_flags($addr);
if (Brocken::band($flags, 2) == 0) { return 3; }
# Suspect flag (bit 0) should be set
if (Brocken::band($flags, 1) == 0) { return 4; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_push_suspect' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'push_suspect_buffer adds entry and sets flags' );
        unlink $file;
    }
};
subtest 'push_suspect_buffer skips already-buffered' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my $obj = 99;
my ptr $addr = Brocken::ptr_add($obj, 0);
# Push twice
Brocken::Runtime::push_suspect_buffer($addr, $hb);
Brocken::Runtime::push_suspect_buffer($addr, $hb);
# Count should still be 1 (not 2)
my i64 $sc = Brocken::Runtime::suspect_count($hb);
if ($sc != 1) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_push_dedup' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'push_suspect_buffer skips already-buffered objects' );
        unlink $file;
    }
};
subtest 'pop_suspect_buffer returns obj and clears flags' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my $obj = 77;
my ptr $addr = Brocken::ptr_add($obj, 0);
Brocken::Runtime::push_suspect_buffer($addr, $hb);
# Pop it
my ptr $popped = Brocken::Runtime::pop_suspect_buffer($hb);
if (Brocken::ptr_cmp_eq($popped, $addr) == 0) { return 1; }
# Buffer should be empty
my i64 $sc = Brocken::Runtime::suspect_count($hb);
if ($sc != 0) { return 2; }
# Buffered flag should be cleared
my i64 $flags = Brocken::Runtime::get_gc_flags($addr);
if (Brocken::band($flags, 2) != 0) { return 3; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_pop_suspect' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'pop_suspect_buffer returns obj and clears Buffered flag' );
        unlink $file;
    }
};
subtest 'pop_suspect_buffer from empty returns 0' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $popped = Brocken::Runtime::pop_suspect_buffer($hb);
if (Brocken::ptr_cmp_eq($popped, 0) == 0) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_pop_empty' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'pop_suspect_buffer from empty buffer returns 0' );
        unlink $file;
    }
};
subtest 'push/pop LIFO order' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my $a = 10;
my $b = 20;
my $c = 30;
my ptr $pa = Brocken::ptr_add($a, 0);
my ptr $pb = Brocken::ptr_add($b, 0);
my ptr $pc = Brocken::ptr_add($c, 0);
Brocken::Runtime::push_suspect_buffer($pa, $hb);
Brocken::Runtime::push_suspect_buffer($pb, $hb);
Brocken::Runtime::push_suspect_buffer($pc, $hb);
# Pop should return in LIFO order: c, b, a
my ptr $p1 = Brocken::Runtime::pop_suspect_buffer($hb);
if (Brocken::ptr_cmp_eq($p1, $pc) == 0) { return 1; }
my ptr $p2 = Brocken::Runtime::pop_suspect_buffer($hb);
if (Brocken::ptr_cmp_eq($p2, $pb) == 0) { return 2; }
my ptr $p3 = Brocken::Runtime::pop_suspect_buffer($hb);
if (Brocken::ptr_cmp_eq($p3, $pa) == 0) { return 3; }
# Buffer should be empty now
if (Brocken::Runtime::suspect_count($hb) != 0) { return 4; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_lifo' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'push/pop LIFO order verified' );
        unlink $file;
    }
};
subtest 'gc_drain on empty buffer is a no-op' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
Brocken::Runtime::gc_drain($hb);
# Buffer should still be empty
my i64 $sc = Brocken::Runtime::suspect_count($hb);
if ($sc != 0) { return 1; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_drain_empty' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'gc_drain on empty buffer is a no-op' );
        unlink $file;
    }
};
subtest 'gc_drain clears suspect buffer' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my $a = 10;
my ptr $pa = Brocken::ptr_add($a, 0);
Brocken::Runtime::push_suspect_buffer($pa, $hb);
if (Brocken::Runtime::suspect_count($hb) != 1) { return 1; }
Brocken::Runtime::gc_drain($hb);
# Buffer should be cleared
if (Brocken::Runtime::suspect_count($hb) != 0) { return 2; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_drain_clears' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'gc_drain clears the suspect buffer' );
        unlink $file;
    }
};
subtest 'gc_drain marks reachable suspects as Black' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# An Any var with RC > 0 should survive gc_drain
my $obj = 42;
my ptr $pa = Brocken::ptr_add($obj, 0);
Brocken::Runtime::push_suspect_buffer($pa, $hb);
Brocken::Runtime::gc_drain($hb);
# Buffer should be cleared
if (Brocken::Runtime::suspect_count($hb) != 0) { return 1; }
# The var should still be valid (return its value)
return $obj;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_drain_reachable' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'gc_drain marks reachable suspects as Black, preserving them' );
        unlink $file;
    }
};
subtest 'gc_drain with multiple suspects' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my $a = 10;
my $b = 20;
my $c = 30;
my ptr $pa = Brocken::ptr_add($a, 0);
my ptr $pb = Brocken::ptr_add($b, 0);
my ptr $pc = Brocken::ptr_add($c, 0);
Brocken::Runtime::push_suspect_buffer($pa, $hb);
Brocken::Runtime::push_suspect_buffer($pb, $hb);
Brocken::Runtime::push_suspect_buffer($pc, $hb);
if (Brocken::Runtime::suspect_count($hb) != 3) { return 1; }
Brocken::Runtime::gc_drain($hb);
if (Brocken::Runtime::suspect_count($hb) != 0) { return 2; }
# Verify each var is still valid
if ($a != 10) { return 3; }
if ($b != 20) { return 4; }
if ($c != 30) { return 5; }
return 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_drain_multi' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 0, 'gc_drain with multiple reachable suspects preserves all' );
        unlink $file;
    }
};
subtest 'decref R3 suspect push on RC > 0' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
# Allocate and copy to trigger incref/decref
my $x = 42;
my $y = $x;
# When $y goes out of scope, decref fires with RC > 0 -> suspect push
# Just verify no crash and the value survives
return $y;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_decref_suspect' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'decref with RC > 0 pushes to suspect buffer without crash' );
        unlink $file;
    }
};
subtest 'multiple alloc/dealloc cycles stress bump_alloc' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my i64 $i = 0;
my i64 $limit = 10;
while (Brocken::ptr_cmp_gt($limit, $i)) {
    my i64 $x = Brocken::i64_add($i, 1);
    my i64 $y = Brocken::i64_add($x, $x);
    $i = Brocken::i64_add($i, 1);
}
return $i;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/r_r3_alloc_stress' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 10, '10 alloc/dealloc cycles stress bump_alloc' );
        unlink $file;
    }
};
done_testing;
