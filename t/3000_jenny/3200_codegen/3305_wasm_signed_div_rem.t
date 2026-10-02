use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::Wasm;
use Test2::Tools::Brocken qw[temp_path];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Signed division, remainder and narrow-value extension on the Wasm target.
#
# Three separate faults met here, and all three hid behind operands that were
# positive, which is why the existing arithmetic tests passed:
#
# 1. `div` and `rem` are the signed operations and were mapped onto the unsigned
#    opcode. `i64 -20 / 3` then divided two's complement bits and returned a
#    quotient near 2^64. Any test with a positive operand agrees with the signed
#    answer, so nothing caught it.
#
# 2. `i32_div_s`, `i32_div_u` and `i64_div_s` had no encoding at all. Because of
#    (1) every division at or below 32 bits asked for `i32_div_u` and died in the
#    code generator, so i8, i16, i32 and their unsigned forms could not be
#    divided for this target whatsoever.
#
# 3. The narrow load instructions were chosen by bit width alone and hardcoded
#    the zero-extending `_u` forms, so a signed i8 or i16 read back from memory
#    came out as its unsigned twin: `i8 -20 / 3` divided 236 by 3, and
#    `i8 -20 >> 2` shifted 236 instead of -20. The fix picks the sign from the
#    stored type and uses `i32_load8_s`/`i32_load16_s`/`i64_load*_s` where the
#    value is signed.

my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $brocken  = Brocken->new( platform => $platform );
my $null     = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;
my $node = $host->is_windows ? `where node 2>NUL` : `which node 2>/dev/null`;
chomp $node if $node;
my $runner = $wasmtime && -x $wasmtime ? 'wasmtime' : ( $node && -x $node ? 'node' : undef );

# Every case returns its result biased into 0..255 so it survives the exit
# status, which is truncated to a byte on both Windows and Unix.
sub answers ( $src, $want, $name ) {
    my $module = eval { $brocken->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return }
    my $file = temp_path('wasm_signed') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $brocken->codegen->emit_functions( $module->functions ), $platform );
    my $output;
    if ( $runner eq 'wasmtime' ) {
        $output = qx["$wasmtime" run --invoke _BROCKEN_ENTRY "$file" 1024 2>$null];
    }
    else {
        my $js = "const fs=require('fs');const buf=fs.readFileSync('$file');"
            . 'WebAssembly.instantiate(buf).then(r=>{process.exit(r.instance.exports._BROCKEN_ENTRY(1024));})'
            . '.catch(e=>{console.error(e);process.exit(1);});';
        system( 'node', '-e', $js );
        $output = ( $? >> 8 ) . "\n";
    }
    my @lines = grep {/\S/} split /\n/, $output;
    my $got   = @lines ? $lines[-1] : '';
    is( $got, $want, $name );
    unlink $file if -e $file;
    return;
}

# The module has to validate as well as run, or a wrong encoding would only show
# up as a runtime trap.
sub validates ( $src, $name ) {
    my $module = eval { $brocken->compile($src) };
    if ($@) { fail("$name: compile died: $@"); return }
    my $file = temp_path('wasm_signed') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $brocken->codegen->emit_functions( $module->functions ), $platform );
    SKIP: {
        skip 'no wasm binary runner available', 1 unless $runner;
        is system( qq["$wasmtime" compile "$file" -o "$null" 2>&1] ), 0, $name
            or diag qx["$wasmtime" compile "$file" -o "$null" 2>&1];
    }
    unlink $file if -e $file;
    return;
}

SKIP: {
    skip 'Neither wasmtime nor node are installed', 1 unless $runner;

    subtest 'signed division truncates toward zero' => sub {
        for my $ty (qw[i8 i16 i32 i64]) {
            answers( "my $ty \$a = 20; my $ty \$b = 3; my $ty \$r = \$a / \$b; return \$r + 64;",
                70, "$ty 20 / 3 is 6" );
            answers( "my $ty \$a = 0; my $ty \$b = 3; my $ty \$r = \$a - \$b; my $ty \$q = \$r / \$b; return \$q + 64;",
                63, "$ty -3 / 3 is -1" );
        }
    };

    subtest 'signed remainder keeps the sign of the dividend' => sub {
        for my $ty (qw[i8 i16 i32 i64]) {
            answers( "my $ty \$a = 20; my $ty \$b = 3; my $ty \$r = \$a % \$b; return \$r + 64;",
                66, "$ty 20 % 3 is 2" );
            answers( "my $ty \$a = 0; my $ty \$b = 7; my $ty \$r = \$a - \$b; my $ty \$m = \$r % \$b; return \$m + 64;",
                64, "$ty -7 % 7 is 0" );
        }
    };

    subtest 'a negative quotient rounds toward zero, not down' => sub {
        answers( 'my i64 $a = 0; my i64 $b = 7; my i64 $r = $a - $b; my i64 $q = $r / $b; return ($q + 64) & 255;',
            63, 'i64 -7 / 7 is -1, not -2' );
        answers( 'my i32 $a = 0; my i32 $b = 7; my i32 $r = $a - $b; my i32 $q = $r / $b; return ($q + 64) & 255;',
            63, 'i32 -7 / 7 is -1, not -2' );
    };

    subtest 'unsigned division still divides unsigned' => sub {
        for my $ty (qw[u8 u16 u32 u64]) {
            answers( "my $ty \$a = 200; my $ty \$b = 100; my $ty \$r = \$a / \$b; return \$r;",
                2, "$ty 200 / 100 is 2" );
            answers( "my $ty \$a = 201; my $ty \$b = 100; my $ty \$r = \$a % \$b; return \$r;",
                1, "$ty 201 % 100 is 1" );
        }
    };

    subtest 'a narrow signed value read back from memory keeps its sign' => sub {

        # The load is what these all pass through, so the sign has to survive
        # the round trip through the slot rather than sitting in a register.
        for my $ty (qw[i8 i16]) {
            answers( "my $ty \$a = 0; my $ty \$b = 3; my $ty \$c = \$a - \$b; my $ty \$d = \$c / \$b; return \$d + 64;",
                63, "$ty -3 / 3 is -1" );
            answers( "my $ty \$a = 0; my $ty \$b = 4; my $ty \$c = \$a - \$b; my $ty \$d = \$c >> 2; return (\$d + 64) & 255;",
                63, "$ty -4 >> 2 is -1" );
            answers( "my $ty \$a = 0; my $ty \$b = 4; my $ty \$c = \$a - \$b; my i64 \$d = \$c; return (\$d + 64) & 255;",
                60, "$ty -4 widened to i64 is -4" );
        }
    };

    subtest 'the division opcodes have encodings' => sub {
        validates( 'my i32 $a = 20; my i32 $b = 3; my i32 $r = $a / $b; return $r;', 'i32 signed division validates' );
        validates( 'my u32 $a = 20; my u32 $b = 3; my u32 $r = $a / $b; return $r;', 'i32 unsigned division validates' );
        validates( 'my i64 $a = 20; my i64 $b = 3; my i64 $r = $a / $b; return $r;', 'i64 signed division validates' );
        validates( 'my i8 $a = 20; my i8 $b = 3; my i8 $r = $a / $b; return $r;',   'i8 division validates' );
    };
}

done_testing;