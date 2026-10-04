use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# x86-64's ALU and compare opcodes take at most a 32-bit immediate and the
# 64-bit forms sign-extend it, so `cmp r64, imm32` reads any constant outside
# signed 32 bits as a different number, and there is no 64-bit immediate form
# for `add`/`sub`/`and`/`or`/`xor`/`mul` at all.  Such a constant has to go
# through a register.  These tests execute a compiled binary, because the
# fault is in the emitted encoding and cannot be seen in the IR or MIR.
sub compiles_to ( $src, $want, $name ) {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    return diag("not native") unless $host->is_native;
    my $module = eval { Brocken->new->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return }
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    my $file  = $brocken->tmpdir . '/imm64' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $host );
    system $file;
    is( $? >> 8, $want, $name );
    unlink $file;
    return;
}
subtest 'comparison against an out-of-range literal' => sub {

    # The boundary: signed 32 bits reaches 2147483647 and no further.
    compiles_to( 'my i64 $x = 2147483647; return $x == 2147483647 ? 1 : 0;', 1, 'imm within signed 32 bits still compares' );
    compiles_to( 'my i64 $x = 2147483648; return $x == 2147483648 ? 1 : 0;', 1, 'imm at 2^31 compares' );
    compiles_to( 'my i64 $x = 4294967296; return $x == 4294967296 ? 1 : 0;', 1, 'imm at 2^32 compares' );
    compiles_to( 'my i64 $x = 5; return $x == 4294967296 ? 1 : 0;',          0, 'a small value does not equal 2^32' );
};
subtest 'arithmetic with an out-of-range literal' => sub {

    # `$x >> 32` keeps the answer under 2^31 so the check is the arithmetic,
    # not another large-immediate compare.
    compiles_to( 'my i64 $x = 1; $x = $x + 4294967296; return $x >> 32;',    1, 'add of 2^32 keeps its value' );
    compiles_to( 'my i64 $x = 4294967297; $x = $x - 4294967296; return $x;', 1, 'sub of 2^32 keeps its value' );
    compiles_to( 'my i64 $x = 3; $x = $x * 4294967296; return $x >> 32;',    3, 'mul by 2^32 keeps its value' );

    # A 64-bit AND mask whose low 32 bits are zero is sign-extended to all ones
    # by the imm32 form, which would clear every bit instead of the low ones.
    compiles_to( 'my i64 $x = 4294967297; $x = $x & 4294967296; return $x >> 32;', 1, 'and with a 2^32 mask keeps the high bit' );

    # Negative values outside signed 32 bits take the same path.
    compiles_to( 'my i64 $x = 0; $x = $x - 4294967296; return $x == -4294967296 ? 1 : 0;', 1, 'negative out-of-range imm compares' );
};
done_testing;
