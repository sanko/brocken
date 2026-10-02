use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# A float literal is lexed as f64. `my f32 $t = 1.5;` therefore has to be
# re-tagged on the way into the slot, because the backends take a float
# store/load/move width from an operand's type: without the re-tag the store
# is a double-width write into a four-byte slot, and the matching load reads
# the low half of the pattern, which for a small value is the zero mantissa.
#
# These assert the program's *answer*, not the shape of the IR. The existing
# float tests are all MIR-level, which is why this class of fault survived
# them: an MIR-level test passes while the emitted code computes 0.0f.
sub compiles_to ( $src, $want, $name ) {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    return diag("not native") unless $host->is_native;
    my $module = eval { Brocken->new->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return }
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    my $file  = $brocken->tmpdir . '/fw' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $host );
    system $file;
    is( $? >> 8, $want, $name );
    unlink $file;
    return;
}
subtest 'f32 slot round-trips through the register file' => sub {
    compiles_to( 'my f32 $t = 1.5; my f32 $u = $t + $t; return 3.0 == $u ? 1 : 0;', 1, 'f32 add of a literal is 3.0' );
    compiles_to( 'my f32 $t = 1.5; my f32 $u = 1.5; return $t == $u ? 1 : 0;',      1, 'two f32 locals holding 1.5 compare equal' );

    # 2^24 is exactly representable in f32, so this needs no rounding to be
    # correct; it fails outright if the store is a double-width write.
    compiles_to( 'my f32 $t = 16777216.0; my f32 $u = 16777216.0; return $t == $u ? 1 : 0;', 1, 'f32 holds 2^24 exactly' );
};
subtest 'f32 keeps its width when returned' => sub {
    compiles_to( 'my f32 $t = 2.5; return 2.5 == $t ? 1 : 0;', 1, 'f32 return compares equal' );
};
subtest 'a float of one width cannot be stored in a slot of the other' => sub {

    # There is no fptrunc or fpext in the IR, so this has to be refused
    # rather than silently reinterpreted: the value is loaded, so there is
    # nothing to re-tag.
    for my $case (
        [ 'my f64 $a = 1.5; my f32 $t = $a; return 0;', 'f64 loaded into an f32 slot' ],
        [ 'my f32 $a = 1.5; my f64 $t = $a; return 0;', 'f32 loaded into an f64 slot' ],
    ) {
        my ( $src, $name ) = @$case;
        my $module = eval { Brocken->new->compile($src) };
        ok( !$module && $@ =~ /float-to-float conversion/, "$name is refused" );
    }
};
done_testing;
