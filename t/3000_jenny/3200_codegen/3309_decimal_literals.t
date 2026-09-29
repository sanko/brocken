use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Compiler;
use Brocken::Jenny;
use Test2::Tools::Brocken qw[temp_path];
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

# Decimal float literals.
#
# `my f64 $t = 3.0;` did not parse at all. The lexer matched the digits and
# stopped at the '.', so the parser saw the integer 3, a '.', and a 0 -- the
# whole class of float literals a reader reaches for first was unavailable, and
# the integer spelling that did work is the one carrying a different bug. That
# it went unnoticed is the other half of it: nothing in the suite used a decimal
# literal, so there was no test that could have failed.
#
# The lexer is the only place that can tell an integer from a float, because by
# the time a point or an exponent has been consumed there is nothing left to
# tell them apart, so the token carries the answer and the parser tags the
# constant. A literal is f64, and a narrower slot re-tags the constant rather
# than storing eight bytes into four.
#
# These run under wasmtime as well as natively, which is how the f32 cases were
# found: a width mismatch is silent on the native backends and a validator
# error on Wasm, so only one of the two would have caught it.
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;

# Each case is [name, source, expected exit]. The program returns 0 when it
# agrees with itself, so the exit code is the assertion.
my @CASES = (

    # The literal that did not parse.
    { name => 'decimal into f64', src => 'my f64 $t = 3.0; my i64 $i = $t; if ($i != 3) { return 1; } return 0;' },

    # A fractional part has to survive as a fraction. 1.5 + 2.5 is 4, and a
    # constant packed with its integer bits instead would be nowhere near it.
    { name => 'fractional arithmetic', src => 'my f64 $a = 1.5; my f64 $b = 2.5; my f64 $c = $a + $b; my i64 $i = $c; if ($i != 4) { return 1; } return 0;' },

    # Small magnitudes truncate to zero, and a value that did not survive as a
    # fraction would not.
    { name => 'sub-one truncates', src => 'my f64 $a = 0.5; my i64 $i = $a; if ($i != 0) { return 1; } return 0;' },

    # A negative literal, which is unary minus applied to a float rather than a
    # folded negative integer.
    { name => 'negative decimal', src => 'my f64 $a = -1.5; my i64 $i = $a; if ($i != -1) { return 1; } return 0;' },

    # f32 has a 24-bit significand and f64 a 53-bit one, so this value is
    # representable in the first and not the second. Stored at the wrong width
    # it comes back as the other number, which is the whole difference between
    # re-tagging the constant and ignoring the slot's type.
    { name => 'f32 rounds past 2^24', src => 'my f32 $a = 16777217.0; my i64 $i = $a; if ($i != 16777216) { return 1; } return 0;' },
    { name => 'f64 keeps past 2^24',  src => 'my f64 $a = 16777217.0; my i64 $i = $a; if ($i != 16777217) { return 1; } return 0;' },

    # Comparing a float against a decimal literal, which is a float against an
    # f64. This is the f32 half of the width problem: the stored value is f32
    # and the literal is f64, and they reached the instruction as they were.
    { name => 'f32 compared to literal', src => 'my f32 $a = 1.5; if ($a == 1.5) { return 0; } return 1;' },
    { name => 'f64 compared to literal', src => 'my f64 $a = 1.5; if ($a == 1.5) { return 0; } return 1;' },
    { name => 'f32 ordering',            src => 'my f32 $a = 1.5; if ($a < 2.0) { return 0; } return 1;' },

    # An f32 returned from a function and compared by the caller, so the
    # mismatch is across a call rather than inside one block.
    { name => 'f32 through a call', src => 'sub w() -> f32 { my f32 $a = 1.5; return $a; } if (w() == 1.5) { return 0; } return 1;' },

    # Exponents, which are a float for the same reason a decimal point is and
    # which the lexer has to recognise on their own -- `1e9` has no point in it.
    { name => 'exponent',         src => 'my f64 $a = 1e3; my i64 $i = $a; if ($i != 1000) { return 1; } return 0;' },
    { name => 'exponent negative',src => 'my f64 $a = 1e-2; my i64 $i = $a; if ($i != 0) { return 1; } return 0;' },
    { name => 'point and exponent', src => 'my f64 $a = 1.5e1; my i64 $i = $a; if ($i != 15) { return 1; } return 0;' },
    { name => 'large exponent',   src => 'my f64 $a = 1e15; my i64 $i = $a; if ($i != 1000000000000000) { return 1; } return 0;' },

    # An integer literal must still be an integer. 2**53+1 is not
    # representable as a float, so if the lexer had started tagging every
    # numeric token as a float this would round.
    { name => 'integer stays exact', src => 'my i64 $a = 9007199254740993; if ($a != 9007199254740993) { return 1; } return 0;' },
    { name => 'integer still compares', src => 'my i64 $a = 3; if ($a != 3) { return 1; } return 0;' },
);

my $brocken = Brocken->new;
SKIP: {
    skip 'Not native', scalar @CASES unless $brocken->platform->is_native;
    for my $case (@CASES) {
        is( run_native( $case->{src} ), 0, "native: $case->{name}" );
    }
}

# The same programs on Wasm, because a float width mismatch is not a wrong
# answer there -- it is a module the validator rejects, and it is caught by
# neither a native test nor a look at the source.
SKIP: {
    my @wasm = grep { $_->{src} =~ /f32/ || $_->{name} =~ /exponent|decimal|fractional/ } @CASES;
    skip 'wasmtime not available', scalar @wasm unless $wasmtime;
    for my $case (@wasm) {
        my $file = wasm_build( $case->{src}, $case->{name} );
        unless ($file) {
            fail("wasm: $case->{name} (module did not build)");
            next;
        }
        my $null = $host->is_windows ? 'NUL' : '/dev/null';
        qx["$wasmtime" run $file 2>$null];
        is( $? >> 8, 0, "wasm: $case->{name}" );
        unlink $file if -e $file;
    }
}
done_testing;

sub run_native {
    my ($src)  = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . '/declit' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    system $file;
    return $? >> 8;
}

# Compiling and linking through the Wasm path directly. Brocken->new refuses a
# Wasm platform, so the codegen and linker are driven by hand, the way the
# other Wasm tests do it.
sub wasm_build {
    my ( $src, $name ) = @_;
    my $module = eval { Brocken::Compiler->new->compile($src) };
    if ($@) {
        diag "wasm: $name did not compile: $@";
        return undef;
    }
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $funcs   = $codegen->emit_functions( $module->functions );
    my $stem    = $name;
    $stem =~ s/[^A-Za-z0-9]+/_/g;
    my $file = temp_path("declit_$stem") . '.wasm';
    eval { Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $funcs, $platform ) };
    if ($@) {
        diag "wasm: $name did not link: $@";
        return undef;
    }
    return $file;
}
