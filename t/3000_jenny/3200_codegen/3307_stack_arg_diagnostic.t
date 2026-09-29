use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro::Platform;
use Test2::Tools::Brocken qw[run_cross cross_available];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# An argument past the last argument register used to be indexed off the end of
# the register list, which produced an undefined register name, and the encoder
# resolved that to register 0 -- so the program assembled, ran, and answered
# from the wrong register. reg_id now rejects an unknown name outright, and all
# three native backends have the machinery to pass the overflow on the stack.
#
# These run under qemu rather than checking encodings, because the failure being
# guarded against is a value read from the wrong place: a nine-argument call
# whose ninth argument lands at [sp+0] instead of a register can assemble
# perfectly and still return the wrong answer. x86-64 had the machinery already
# and is the control: if these passed only where the stack area is reserved, a
# diagnostic or a silent miscompile on the others would not show up as a
# difference.
my $ten = 'sub f(i64 $a, i64 $b, i64 $c, i64 $d, i64 $e, i64 $g, i64 $h, i64 $i, i64 $j, i64 $k) -> i64
             { return $a + $j; }
           if (f(1, 1, 1, 1, 1, 1, 1, 1, 41, 1) != 42) { return 1; } return 0;';
my $nine = 'sub f(i64 $a, i64 $b, i64 $c, i64 $d, i64 $e, i64 $g, i64 $h, i64 $i, i64 $j) -> i64
              { return $a + $j; }
            if (f(1, 1, 1, 1, 1, 1, 1, 1, 41) != 42) { return 1; } return 0;';

# A float argument overflows the same way, and against a different register
# file: eight of x0-x7 on AArch64 and RISCV64, and eight of v0-v7. The ninth
# float has to go to the stack while eight integer arguments still arrive in
# registers, so the two areas have to be sized independently.
my $float = 'sub f(f64 $a, f64 $b, f64 $c, f64 $d, f64 $e, f64 $g, f64 $h, f64 $i, f64 $j) -> f64
               { return $a + $j; }
             if (f(1, 1, 1, 1, 1, 1, 1, 1, 41) != 42) { return 1; } return 0;';

# Mixed: the ninth argument is an integer that overflows while a float sits in
# the middle of the list, so the two counters have to advance independently and
# an integer must not be charged to the floating-point register file.
my $mixed = 'sub f(i64 $a, f64 $b, i64 $c, i64 $d, i64 $e, i64 $g, i64 $h, i64 $i, i64 $j) -> i64
               { return $a + $j; }
             if (f(1, 1, 1, 1, 1, 1, 1, 1, 41) != 42) { return 1; } return 0;';

# A stack argument read in a callee that then makes its own call, so the
# outgoing argument area has to be reserved by a frame that already has one
# and the saved value has to survive the second call's register shuffles.
my $nested = 'sub g(i64 $x) -> i64 { return $x * 2; }
              sub f(i64 $a, i64 $b, i64 $c, i64 $d, i64 $e, i64 $gg, i64 $h, i64 $i, i64 $j) -> i64 { return g($j) + $a; }
              if (f(1, 1, 1, 1, 1, 1, 1, 1, 20) != 41) { return 1; } return 0;';
my @cases = (
    [ 'nine integer arguments',                 $nine ],
    [ 'ten integer arguments',                  $ten ],
    [ 'nine float arguments',                   $float ],
    [ 'a mixed overflow',                       $mixed ],
    [ 'a stack argument through a nested call', $nested ],
);
my $native = Brocken::Katsuro::Platform::parse( Brocken::Katsuro::Platform::gen_triple() );
for my $case (@cases) {
    my ( $name, $src ) = @$case;
    is( run_cross( $src, $native, name => "native: $name", expected_exit => 0 ), 0, "the host backend passes $name and gets the right answer" );
}
for my $target ( [ 'aarch64-unknown-linux-gnu', 'aarch64' ], [ 'riscv64-unknown-linux-gnu', 'riscv64' ] ) {
    my ( $triple, $label ) = @$target;
    my $plat = Brocken::Katsuro::Platform::parse($triple);
SKIP: {
        skip "$label: qemu or the cross libc is not available here", 2 * @cases unless cross_available($plat);
        for my $case (@cases) {
            my ( $name, $src ) = @$case;

            # The encoder-level fallback is gone for good: an unknown register
            # name has to be an error wherever it comes from.
            require Brocken;
            require Brocken::Compiler;
            my $brocken = Brocken->new( platform => $plat );
            my $module  = Brocken::Compiler->new->compile($src);
            my $err     = do {
                local $@;
                eval { $brocken->codegen->emit_functions( $module->functions ); 1 } ? '' : ( $@ // '' );
            };
            unlike( $err, qr/Unknown \w+ register/, "$label compiles $name without inventing a register" );
        }
        for my $case (@cases) {
            my ( $name, $src ) = @$case;
            is( run_cross( $src, $plat, name => "$label: $name", expected_exit => 0 ), 0, "$label passes $name and gets the right answer" );
        }
    }
}
done_testing;
