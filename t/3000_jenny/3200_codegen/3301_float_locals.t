use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

# Float locals, and the scratch slot the GP-to-XMM move has to use.
#
# Moving a float constant into an XMM register normally takes the bit pattern
# in a GPR and hands it over with MOVD or MOVQ. On AMD Zen 4 the register form
# of that instruction produces a wrong result when the source is one of R8 to
# R15, so the back end parks the GPR in memory and reads the XMM back from
# there instead.
#
# That workaround named its parking place as a literal `rsp+0x20`. A fixed
# displacement is only in dead space when the frame happens to be empty. The
# frame is laid out with the outgoing argument area at the bottom, then the
# locals, then the spill and caller-save area, so `rsp+0x20` is exactly where
# the second local is put. Storing a constant through it overwrote that local
# with the bit pattern being moved, and the local read back as whichever
# constant was moved last:
#
#     my f64 $a = 1; my f64 $b = 2; my f64 $c = 3;
#     if ($b == 2) { ... }        # false: $b holds 3.0
#
# Two locals stayed clear of it by luck, which is why the fault survived the
# suites that only ever declared a couple. The slot is now reserved at the top
# of the alloca area, above every local, so nothing is addressed out of it.
#
# The sweep runs from three locals up. Each program returns the index of the
# first local that does not hold the value it was given, or 42 when they all
# do, so a failure names the local rather than just reporting that one was
# wrong. The upper end also matters for the encoding: the reserved slot is
# placed past the locals, and a frame with that many locals in it pushes the
# slot beyond what a one-byte displacement can express, so the wide form of the
# addressing gets exercised too.

my $brocken = Brocken->new;

SKIP: {
    skip 'Not native', 3 unless $brocken->platform->is_native;

    for my $type (qw[f64 f32]) {
        for my $n ( 3 .. 12 ) {
            is( locals_ok( $type, $n ), 42, "native: $n $type local(s) each hold their own value" );
        }
    }

    # An integer local shares the alloca area with the float ones, so it is
    # just as exposed to a scratch slot landing in the middle of it.
    is( mixed_locals_ok(), 42, 'native: int and float locals in one frame all keep their values' );
}

done_testing;

# One program, $n locals, each holding the next integer.  The exit status is
# the 1-based index of the first local that lost its value, or 42 if none did.
sub locals_ok {
    my ( $type, $n ) = @_;

    my $decls = join ' ', map { "my $type \$v$_ = " . ( $_ + 1 ) . ';' } 0 .. $n - 1;
    my $checks = join "\n", map { "if (\$v$_ != " . ( $_ + 1 ) . ") { return $_ + 1; }" } 0 .. $n - 1;
    return build("$decls\n$checks\nreturn 42;\n");
}

# Alternating integer and float declarations, so the two kinds of local land
# next to each other in the alloca area rather than in separate runs.  The
# float values are whole numbers on purpose: a decimal literal is a separate
# gap of its own and would only hide what this is here to check.
sub mixed_locals_ok {
    my $decls = '';
    my $checks = '';
    for my $i ( 0 .. 9 ) {
        if ( $i % 2 ) {
            $decls .= "my f64 \$v$i = " . ( $i + 1 ) . ';';
            $checks .= "if (\$v$i != " . ( $i + 1 ) . ") { return " . ( $i + 1 ) . "; }\n";
        }
        else {
            $decls .= "my i64 \$v$i = " . ( $i + 100 ) . ';';
            $checks .= "if (\$v$i != " . ( $i + 100 ) . ") { return " . ( $i + 1 ) . "; }\n";
        }
    }
    return build("$decls\n$checks\nreturn 42;\n");
}

sub build {
    my ($src) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/flocal' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
