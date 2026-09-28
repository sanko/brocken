use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
use Brocken::Compiler;
use Brocken::Katsuro;
use Brocken::Katsuro::Platform;
use Brocken::Jenny;
use Brocken::Jenny::Linker::Wasm;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# A frame is reserved up front from a single immediate, so an array has to
# scale its reservation by the element count.  X86_64 ignored the count, which
# reserved one element (8 bytes) for `my [i64; 5] @a;`; every element past the
# first then ran into the neighbouring slot, so a plain local allocated after
# the array was silently overwritten.
my $array_src = <<'BROCKEN';
my [i64; 5] @a;
my i64 $x = 123;
@a[0] = 11;
@a[1] = 22;
@a[2] = 33;
@a[3] = 44;
@a[4] = 55;
return $x;
BROCKEN

my %lowerer_class = (
    'X86_64'  => 'Brocken::Jenny::Lowerer::X86_64',
    'ARM64'   => 'Brocken::Jenny::Lowerer::ARM64',
    'RISCV64' => 'Brocken::Jenny::Lowerer::RISCV64',
    'Wasm'    => 'Brocken::Jenny::Lowerer::Wasm',
);
my %triple = (
    'X86_64'  => 'x86_64-unknown-linux-gnu',
    'ARM64'   => 'aarch64-unknown-linux-gnu',
    'RISCV64' => 'riscv64-unknown-linux-gnu',
);

sub lowerer_for {
    my ($arch) = @_;
    # The Wasm lowerer takes no platform; the native ones do.
    return $lowerer_class{$arch}->new() if $arch eq 'Wasm';
    return $lowerer_class{$arch}->new( platform => Brocken::Katsuro::Platform::parse( $triple{$arch} ) );
}

subtest 'Alloca reserves element-count * size on every backend' => sub {
    my $brocken = Brocken->new();
    my $module  = Brocken::Compiler->new->compile($array_src);
    for my $arch ( sort keys %lowerer_class ) {
        my @reserved;
        for my $func ( $module->functions->@* ) {
            next unless $func->name eq '_BROCKEN_ENTRY';
            my $mir = lowerer_for($arch)->lower($func);
            for my $block ( $mir->blocks->@* ) {
                for my $inst ( $block->instructions->@* ) {
                    # The native backends emit an `alloca` opcode commented
                    # "alloca N bytes"; Wasm lowers the bump inline with an
                    # "alloca: size N" comment and no alloca opcode at all.
                    next unless $inst->opcode eq 'alloca' || ( $inst->comment // '' ) =~ m{alloca:? size};
                    next unless ( $inst->comment // '' ) =~ m{alloca:? (?:size )?(\d+)};
                    push @reserved, $1;
                }
            }
        }
        ok( scalar @reserved, "$arch lowered the program" );
        # 5 elements * 8 bytes.  Reserving 8 here is the bug: $x legitimately
        # reserves 8 bytes too, so the array slot has to be told apart by size.
        is( scalar( grep { $_ == 40 } @reserved ), 1, "$arch reserved 40 bytes for a 5-element i64 array" );
    }
};

subtest 'Array writes do not clobber a neighbouring local (native)' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    SKIP: {
        skip 'needs a native host to run the executable', 3 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile($array_src);
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        my $file   = $brocken->tmpdir . '/alloca_count' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        ok( -e $file, 'executable written' );
        # 123 must survive the five array writes; before the fix @a[2] landed
        # in $x's slot and the program returned 33.
        run_exec( $file, expected_exit => 123, platform => $host,
            name => 'neighbouring local intact after array writes on ' . $host->friendly );
    }
};

subtest 'Non-constant element count is rejected clearly' => sub {
    my $brocken = Brocken->new();
    my $module  = Brocken::Compiler->new->compile(<<'BROCKEN');
my i64 $n = 5;
my [i64; $n] @a;
@a[0] = 1;
return @a[0];
BROCKEN
    for my $arch ( sort keys %lowerer_class ) {
        my $err = '';
        for my $func ( $module->functions->@* ) {
            next unless $func->name eq '_BROCKEN_ENTRY';
            eval { lowerer_for($arch)->lower($func); 1 } or $err = $@;
        }
        like( $err, qr/non-constant element count/, "$arch reports the non-constant count" );
    }
};

done_testing;
