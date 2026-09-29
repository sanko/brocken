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

# Floating-point parameters, and the value that comes back from a call.
#
# Three separate faults, all of which only show up once a float is in a
# register the encoding had not been exercised for.
#
# 1. `fmov` between two registers emitted its REX byte *before* the F2 or F3
#    that selects single or double precision. A REX byte is only a REX byte as
#    the last prefix before the opcode, so one in front of a legacy prefix is
#    discarded -- and REX.R is the only thing that reaches xmm8-xmm15 at all.
#    Every move involving one of those read or wrote a register below it. The
#    same inversion was in `fload`, `fstore` and the scalar float arithmetic
#    group, so the fault was not confined to one opcode. Four f64 parameters
#    were enough to stay clear of it; the fifth is the first that spills into
#    the high registers, which is why an arity sweep is the only thing that
#    finds it.
#
# 2. The move that puts a returned f64 in the return register took its width
#    from its destination, and the destination was built without a type, so it
#    defaulted to 32 bits. The callee emitted `movss` and the caller received
#    four bytes of the value over the top of whatever xmm0 held. Nothing about
#    the callee looked wrong: the value only ever appeared in the return
#    register, so every test that checked the callee on its own passed while
#    the comparison on the caller's side was made against a denormal.
#
# 3. The entry shuffle scheduled only `mov`. A capture of a float parameter is
#    an `fmov`, so the run of captures stopped at the first one and the
#    floating-point parameters were left in whatever order the allocator
#    numbered them -- a capture that wrote a register could land before one
#    that read it. A capture the scheduler parks (one that cannot clobber
#    anything) also has to survive the rebuild of the entry block: it is
#    emitted unchanged, and dropping it would take a parameter with it.
#
# The last group is here because it is the same test at a different arity, and
# because the fix for it lives in the same place as the others.

my $brocken = Brocken->new;

SKIP: {
    skip 'Not native', 1 unless $brocken->platform->is_native;

    my $fp_args = scalar $brocken->platform->abi->fp_param_registers->@*;

    # Enough float parameters to reach the registers the REX bits name. Each is
    # used in a sum that is compared as a float, so a value that arrived in the
    # wrong register still has to produce the right total to pass.
    for my $n ( 1 .. $fp_args ) {
        my @params = map { "f64 \$v$_" } 0 .. $n - 1;
        my @args   = map { $_ + 1 } 0 .. $n - 1;
        my $sum    = join( ' + ', map { "\$v$_" } 0 .. $n - 1 );
        my $total  = 0;
        $total += $_ for @args;

        my $src = <<"BROCKEN";
sub g( @{[ join ', ', @params ]} ) -> i64 { if ($sum == $total) { return 42; } return 1; }
return g( @{[ join ', ', @args ]} );
BROCKEN
        is( run($src), 42, "native: f64 parameter(s) in registers, $n of $fp_args" );
    }

    # A float that arrived in a register, compared against a literal. The
    # operand is the result of a call in every case, so this is the read side
    # of fault 2 rather than the write side.
    #
    # Each operator gets an operand that makes it true and one that makes it
    # false, and both directions are checked. A comparison that is simply
    # inverted therefore cannot pass by agreeing with the false case, and one
    # that always returns the same answer cannot pass either -- which is worth
    # the extra case here, since the ordered predicates are built from `setnp`
    # and a second `setCC`, and a mis-selected condition code is invisible in
    # any one of them.
    my @comparisons = (
        [ '==' => 3, 4 ], [ '!=' => 4, 3 ],
        [ '<'  => 4, 2 ], [ '<=' => 3, 2 ],
        [ '>'  => 2, 3 ], [ '>=' => 3, 4 ],
    );
    for my $c (@comparisons) {
        my ( $op, $holds, $fails ) = $c->@*;

        my $yes = <<"BROCKEN";
sub f() -> f64 { return 3; }
if ( f() $op $holds ) { return 42; }
return 1;
BROCKEN
        is( run($yes), 42, "native: call result $op $holds is true" );

        my $no = <<"BROCKEN";
sub f() -> f64 { return 3; }
if ( f() $op $fails ) { return 1; }
return 42;
BROCKEN
        is( run($no), 42, "native: call result $op $fails is false" );
    }

    # A parameter the body never reads. Its capture cannot clobber a source,
    # so the scheduler parks it, and a parked capture still has to be emitted:
    # the entry block is rebuilt from the plan, and leaving one out would drop
    # the instruction. The callee answers 7 whatever it is handed, so what is
    # being tested is that the function runs at all.
    my $unused = <<'BROCKEN';
sub g(f64 $a) -> i64 { return 7; }
if ( g(1) == 7 ) { return 42; }
return 1;
BROCKEN
    is( run($unused), 42, 'native: unused float parameter is still captured' );

    # The same parameter read back, so the capture is not merely present but
    # correct, and a single-precision one beside it to keep the narrower path
    # in the same test.
    my $mixed_width = <<'BROCKEN';
sub g(f32 $a, f64 $b) -> i64 { if ($a == 1 && $b == 2) { return 42; } return 1; }
return g(1, 2);
BROCKEN
    is( run($mixed_width), 42, 'native: single- and double-precision parameters together' );

    # Float parameters interleaved with integer ones, so the two register
    # classes are captured in one entry block and the shuffle has to schedule
    # them apart rather than as one sequence.
    my $interleaved = <<'BROCKEN';
sub g(f64 $a, i64 $b, f64 $c, i64 $d) -> i64 {
    if ($a == 1 && $b == 2 && $c == 3 && $d == 4) { return 42; }
    return 1;
}
return g(1, 2, 3, 4);
BROCKEN
    is( run($interleaved), 42, 'native: float and integer parameters interleaved' );

    # An f64 live across a call. The caller-save sequence stores and reloads it
    # through the stack, and both moves take their width from the operand, so
    # an untyped one would move four bytes of eight.
    my $across = <<'BROCKEN';
sub h() -> i64 { return 9; }
sub g(f64 $a) -> i64 { if ($a == 7) { return 42; } return 1; }
my f64 $t = 7;
my i64 $n = h();
return g($t) + $n - $n;
BROCKEN
    is( run($across), 42, 'native: f64 live across a call' );

    # A float literal as an argument, with nothing to load it from but the
    # immediate in the instruction.
    my $literal = <<'BROCKEN';
sub g(f64 $a) -> i64 { if ($a == 3) { return 42; } return 1; }
return g(3);
BROCKEN
    is( run($literal), 42, 'native: float literal passed as a call argument' );

    # The parked capture is worth a case of its own, and it cannot be written
    # as an answer: the capture it drops is the one that saves the entry
    # stub's parameter count into a register the body never reads, so a
    # missing one costs nothing that any program can observe. It is still a
    # real fault, because the entry block is rebuilt from the plan and a
    # parked capture was being pushed as itself rather than wrapped for the
    # renderer. The renderer found no `cap` in it, so it fell through to the
    # branch that builds a fresh instruction -- with no opcode, because a raw
    # capture carries no `opcode` either. What reached the encoder was a hole,
    # and the encoder warned once per field it read while deciding what the
    # instruction was. So this asserts on the warnings rather than the exit
    # status, which stays 42 either way.
    my $clean = <<'BROCKEN';
sub g(f64 $a, i64 $b) -> i64 { if ($a == 1 && $b == 2) { return 42; } return 1; }
return g(1, 2);
BROCKEN
    my $noise = run( $clean, 1 );
    is( $noise, '', 'native: codegen is silent for a function with a parked entry capture' );
}

done_testing;

sub run {
    my ( $src, $quiet ) = @_;

    # The second argument asks for the compiler's own chatter rather than the
    # program's answer, so a test can assert that there was none. The back end
    # warns on the process's error stream, so that is what gets redirected --
    # there is no handle to point anywhere else.
    if ($quiet) {
        my $log = $brocken->tmpdir . '/fparam_stderr';
        open my $saved, '>&', \*STDERR or die "cannot dup STDERR: $!";
        open STDERR, '>', $log          or die "cannot redirect STDERR: $!";
        my $answer = build($src);
        open STDERR, '>&', $saved        or die "cannot restore STDERR: $!";
        close $saved;

        my @warnings = grep { m/uninitialized value|Unknown opcode|unhandled opcode/ }
          split /\n/, do { local ( @ARGV, $/ ) = ($log); <> };
        return join( "\n", @warnings );
    }

    return build($src);
}

sub build {
    my ($src) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/fparam' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}
