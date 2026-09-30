use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
use Test2::Tools::Brocken qw(temp_path);
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $host          = Brocken::Katsuro::Platform::parse();
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $wasm_platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

# Integer operands have to meet at a common width before an arithmetic or
# comparison instruction. `lower_binop` only widened when one side was
# `dynamic`, so two native integers of different widths reached the backend
# unmixed. `$g == -1`, with `$g` an i32 local and the literal an i64, produced
# an `icmp i32, i64`; the backend then compared them at the width it took from
# the left operand, so the guard came out false and the branch was never taken.
#
# Two fixes meet here. `lower_binop` promotes the narrower operand, and
# `maybe_convert_type` now truncates on the way *down* as well as sign/zero
# extending on the way up. The narrowing matters for the same reason from the
# other side: a literal carries no type of its own, so `my i32 $g = -1` reached
# the 4-byte slot as an 8-byte value. Native tolerated that; the Wasm validator
# rejected the module outright ("expected i32, found i64").
# Each program returns a small value so it is also readable as a native exit
# code, and the return value is the thing under test.
my @cases = (
    {   name => 'an i32 local compares equal to a negative literal',
        src  => "my i32 \$g = -1;\nif (\$g == -1) { return 11; }\nreturn 13;\n",
        want => 11,
    },
    {   name => 'an i32 local is not unequal to a negative literal',
        src  => "my i32 \$g = -1;\nif (\$g != -1) { return 11; }\nreturn 13;\n",
        want => 13,
    },
    {   name => 'an i64 local compares equal to a negative literal',
        src  => "my i64 \$g = -1;\nif (\$g == -1) { return 11; }\nreturn 13;\n",
        want => 11,
    },
    {   name => 'a narrow local compares equal to a negative literal',
        src  => "my i8 \$g = -1;\nif (\$g == -1) { return 11; }\nreturn 13;\n",
        want => 11,
    },
    {   name => 'an i32 and an i64 of the same value compare equal',
        src  => "my i32 \$a = 5;\nmy i64 \$b = 5;\nif (\$a == \$b) { return 11; }\nreturn 13;\n",
        want => 11,
    },
    { name => 'mixed widths order correctly', src => "my i32 \$a = 3;\nmy i64 \$b = 5;\nif (\$a < \$b) { return 11; }\nreturn 13;\n",   want => 11, },
    { name => 'a wide literal is truncated into a narrow slot', src => "my u8 \$g = 300;\nif (\$g == 44) { return 11; }\nreturn 13;\n", want => 11, },
    {   name => 'an i32 keeps the low half of a too-wide literal',
        src  => "my i32 \$g = 8589934591;\nif (\$g == -1) { return 11; }\nreturn 13;\n",
        want => 11,
    },
);

# Wasm
sub run_wasm {
    my ( $src, $name ) = @_;
    my $module  = Brocken::Compiler->new->compile($src);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $wasm_platform );
    my $out     = temp_path($name) . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $codegen->emit_functions( $module->functions ), $wasm_platform );
    my $r = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$out" 1024 2>&1];
    $r =~ s/^warning: using .*$//mg;
    $r =~ s/^\s+|\s+$//g;
    unlink $out;
    return $r;
}
for my $case (@cases) {
SKIP: {
        skip 'wasmtime not available', 1 unless $wasmtime_path && -f $wasmtime_path;
        is( run_wasm( $case->{src}, 'type_promotion_wasm' ), $case->{want}, "wasm: $case->{name}" );
    }
}

# Native
{
    my $brocken = Brocken->new();
SKIP: {
        skip 'Not native', scalar @cases unless $brocken->platform->is_native;
        for my $case (@cases) {
            my $module = Brocken::Compiler->new->compile( $case->{src} );
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $file   = $brocken->tmpdir . '/type_promotion' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            system $file;
            is( $? >> 8, $case->{want}, "native: $case->{name}" );
        }
    }
}
done_testing;
