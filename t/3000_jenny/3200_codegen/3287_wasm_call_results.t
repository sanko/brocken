use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
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

# Two calls to the same function inside one expression were miscompiled twice
# over, and neither bug was visible without running the module.
#
# The frontend named every call result after the callee, so two calls to `g`
# both produced `%g_res`. The IR is supposed to be SSA, but the second
# definition shadowed the first, and the add read the same name twice:
#
#   %g_res   = call i64 @g(i64 20)
#   %g_res   = call i64 @g(i64 1)
#   %1 = add i64 %g_res, %g_res
#
# Every backend maps values to registers or locals by name, so the two
# different values collapsed into one. `g(20) + g(1)` computed 2 + 2 and
# answered 4 instead of 42.
#
# The Wasm linker then compounded it. A `call` placeholder is five bytes and
# the LEB128 index that replaces it is one or two, so each substitution
# shortened the buffer, but the fixup offsets recorded by the encoder assumed
# nothing had been rewritten yet. The second call in a function therefore
# overwrote the wrong bytes and left four continuation bytes in front of its
# index, which the validator read as the five-byte index 0x30000000 and
# rejected as out of function range.
subtest 'distinct names for repeated call results' => sub {
    my $mod = Brocken::Compiler->new->compile(<<'BROCKEN');
sub g(i64 $x) -> i64 { return $x * 2; }
return g(20) + g(1);
BROCKEN
    my ($entry) = grep { $_->name eq '_BROCKEN_ENTRY' } $mod->functions->@*;
    ok( $entry, 'entry function found' );
    my @results = grep { $_->opcode eq 'call' && $_->callee->name eq 'g' } map { $_->instructions->@* } $entry->blocks->@*;
    is( scalar @results, 2, 'both calls to g are in the IR' );
    my %names = map { ( $_->name // '<unnamed>' ) => 1 } @results;
    is( scalar keys %names, 2, 'the two call results have different names' );
    ok( !exists $names{''}, 'no call result is unnamed' );
};
subtest 'repeated calls in one expression' => sub {
    my @cases = (
        { name => 'two calls', src => <<'BROCKEN', want => 42 },
sub g(i64 $x) -> i64 { return $x * 2; }
return g(20) + g(1);
BROCKEN
        { name => 'nested calls', src => <<'BROCKEN', want => 42 },
sub g(i64 $x) -> i64 { return $x + 1; }
sub f(i64 $a) -> i64 { return g($a) + g($a); }
return f(20);
BROCKEN
        { name => 'three calls', src => <<'BROCKEN', want => 57 },
sub g(i64 $x) -> i64 { return $x + 14; }
return g(1) + g(2) + g(12);
BROCKEN
    );
    for my $case (@cases) {
    SKIP: {
            skip 'wasmtime not available', 1 and next unless $wasmtime_path && -f $wasmtime_path;
            my $platform    = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
            my $module      = Brocken::Compiler->new->compile( $case->{src} );
            my $codegen     = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
            my $funcs       = $codegen->emit_functions( $module->functions );
            my $safe        = $case->{name} =~ s/\W+/_/gr;
            my $output_file = temp_path("wasm_calls_$safe") . '.wasm';
            Brocken::Jenny::Linker::Wasm->new->write_executable( $output_file, $funcs, $platform );
            my $output = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$output_file" 1024 2>&1];
            $output =~ s/^warning: using .*$//mg;
            $output =~ s/^\s+|\s+$//g;
            is( $output, $case->{want}, "$case->{name}: returns $case->{want}" );
            unlink $output_file;
        }
    }
};
done_testing;
