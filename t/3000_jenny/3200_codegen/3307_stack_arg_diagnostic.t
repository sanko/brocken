use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro::Platform;
use Test2::Tools::Brocken qw[run_cross cross_available];
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

# An argument past the last argument register has nowhere to go on the two
# backends without stack-argument support. It used to be indexed off the end of
# the register list, which produced an undefined register name, and the encoder
# resolved that to register 0 -- so the program assembled, ran, and answered
# from the wrong register. reg_id now rejects an unknown name outright, and the
# lowerer names the argument that ran out before it gets that far.
#
# x86-64 has the stack-argument machinery and is the control: it has to keep
# compiling and running these, since a diagnostic that fires everywhere would
# not be telling anyone anything. It uses the host platform rather than a
# spelled-out triple so the control runs on whatever this suite is running on.

my $ten = 'sub f(i64 $a, i64 $b, i64 $c, i64 $d, i64 $e, i64 $g, i64 $h, i64 $i, i64 $j, i64 $k) -> i64
             { return $a + $j; }
           if (f(1, 1, 1, 1, 1, 1, 1, 1, 41, 1) != 42) { return 1; } return 0;';

my $nine = 'sub f(i64 $a, i64 $b, i64 $c, i64 $d, i64 $e, i64 $g, i64 $h, i64 $i, i64 $j) -> i64
              { return $a + $j; }
            if (f(1, 1, 1, 1, 1, 1, 1, 1, 41) != 42) { return 1; } return 0;';

my $platform = Brocken::Katsuro::Platform::parse(Brocken::Katsuro::Platform::gen_triple());
is( run_cross( $ten, $platform, name => 'native: ten integer arguments', expected_exit => 0 ),
    0, 'the host backend passes ten integer arguments and gets the right answer' );
is( run_cross( $nine, $platform, name => 'native: nine integer arguments', expected_exit => 0 ),
    0, 'the host backend passes nine integer arguments and gets the right answer' );

for my $target ( [ 'aarch64-unknown-linux-gnu', 'aarch64' ], [ 'riscv64-unknown-linux-gnu', 'riscv64' ] ) {
    my ( $triple, $label ) = @$target;
    my $plat = Brocken::Katsuro::Platform::parse($triple);

    SKIP: {
        skip "$label: qemu or the cross libc is not available here", 1
            unless cross_available($plat);

        require Brocken;
        require Brocken::Compiler;
        my $brocken = Brocken->new( platform => $plat );
        my $module  = Brocken::Compiler->new->compile($ten);
        my $err     = do {
            local $@;
            eval { $brocken->codegen->emit_functions( $module->functions ); 1 } ? '' : ( $@ // '' );
        };
        unlike(
            $err,
            qr/Unknown \w+ register/,
            "$label names the missing register instead of resolving it to zero"
        );
        like(
            $err,
            qr/Argument 8 of \@f has no register on \w+; stack arguments are not implemented/,
            "$label reports the first argument past the register count"
        );
    }
}

done_testing;
