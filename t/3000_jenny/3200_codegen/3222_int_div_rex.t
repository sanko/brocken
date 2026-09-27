use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# The x86-64 udiv/umulh sequences move the dividend into RAX with
# "mov rax, <reg>". That puts the source register in the ModRM r/m field, so
# the high-register extension belongs in the REX B bit (0x01). The encoder used
# 0x04 (the SIB index bit) instead, so for operands allocated to r8-r15 the
# CPU executed "mov rax, rcx" and divided an uninitialised register. The
# operands here are deliberately shaped so the allocator picks r8/r9, and each
# binary is run repeatedly because the original failure was nondeterministic.

my @CASES = (
    { name => 'x / y',      src => 'my i64 $x = 12; my i64 $y = 3; return $x / $y;',  want => 4 },
    { name => 'y / x',      src => 'my i64 $x = 12; my i64 $y = 3; return $y / $x;',  want => 0 },
    { name => '100 / 7',    src => 'my i64 $x = 100; my i64 $y = 7; return $x / $y;', want => 14 },
    { name => '100 % 7',    src => 'my i64 $x = 100; my i64 $y = 7; return $x % $y;', want => 2 },
    { name => '84 / 5',     src => 'my i64 $x = 84; my i64 $y = 5; return $x / $y;',   want => 16 },
    { name => '84 / 7',     src => 'my i64 $x = 84; my i64 $y = 7; return $x / $y;',   want => 12 },
    { name => '1000000 / 100000', src => 'my i64 $x = 1000000; my i64 $y = 100000; return $x / $y;', want => 10 },
);

my $RUNS = 8;

for my $case (@CASES) {
    subtest $case->{name} => sub {
        my $brocken = Brocken->new();
        my $host    = $brocken->platform;
    SKIP: {
            skip 'Not native', $RUNS + 1 unless $host->is_native;
            my $module = Brocken::Compiler->new->compile( $case->{src} );
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $file   = $brocken->tmpdir . '/e2e_int_div_rex' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $host );
            ok( -x $file || $host->is_windows, 'executable written' );
            for my $n ( 1 .. $RUNS ) {
                system $file;
                is( $? >> 8, $case->{want}, "run $n returned $case->{want}" );
            }
            unlink $file;
        }
    };
}

done_testing;
