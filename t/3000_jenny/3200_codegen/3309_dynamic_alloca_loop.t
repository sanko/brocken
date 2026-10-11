use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[run_exec cross_available temp_path];
use Brocken;
use Brocken::Katsuro::Platform;
no warnings qw[experimental::class experimental::builtin];
use feature qw[class];

# F17: a dynamic array inside a while loop used to grow the stack on every iteration until the epilogue.  Dynamic-sized
# arrays are now heap-promoted to Brocken::Runtime::alloc_array: each declaration allocates a tag-9 array on the Immix
# heap, the loop's back-edge cleanup refcounts it back to the segregated free_big list, and the next iteration reuses
# the same slab - so the stack has no dynamic frame at all and the heap stays bounded regardless of iteration count.
my @TARGETS = (
    [ 'x86_64-pc-windows-msvc',    'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'x86_64-unknown-linux-gnu',  'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'aarch64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::ARM64' ],
    [ 'riscv64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::RISCV64' ],
);

sub src_loop($N, $ITERS) {
    return <<"BROCKEN";
my i64 \$n = $N;
my i64 \$i = 0;
my i64 \$sum = 0;
while (\$i < $ITERS) {
    my [i64; \$n] \@buf;
    \@buf[0] = \$i;
    \@buf[$N - 1] = 7;
    \$sum = \$sum + \@buf[0] + \@buf[$N - 1];
    \$i = \$i + 1;
}
return \$sum % 251;
BROCKEN
}

# Reads the lowering of `_BROCKEN_ENTRY` and returns [entry_body_ops, all_block_op_lists] as opcode arrays.
sub lower_entry_ops( $triple, $lower_class, $src ) {
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $module   = Brocken->new->compile($src);
    my ($func)   = grep { $_->name eq '_BROCKEN_ENTRY' } $module->functions->@*;
    my $mf       = $lower_class->new( platform => $platform )->lower($func);
    my @block_ops;
    for my $bb ( $mf->blocks->@* ) {
        push @block_ops, [ map { $_->opcode } $bb->instructions->@* ];
    }
    return ( $block_ops[0] // [], \@block_ops );
}

sub count_op( $ops, $needle ) {
    return scalar grep { $_ eq $needle } @$ops;
}

subtest 'a dynamic array in a loop body is heap-allocated, not dynamically stacked' => sub {
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        my ( $entry_ops, $blocks ) = lower_entry_ops( $triple, $class, src_loop( 64, 4 ) );
        my $alloca_dyn = 0;
        my $stack_save = 0;
        my $alloc      = 0;
        for my $ops ( $entry_ops, @$blocks ) {
            $alloca_dyn += count_op( $ops, 'alloca_dyn' );
            $stack_save += count_op( $ops, 'stack_save' ) + count_op( $ops, 'stack_restore' );
            $alloc      += count_op( $ops, 'call_func' );
        }
        is( $alloca_dyn, 0, "$triple: no alloca_dyn anywhere in a promoted array loop" );
        is( $stack_save, 0, "$triple: no stack_save/stack_restore anywhere in a promoted array loop" );
        ok( $alloc > 0,  "$triple: the loop body still emits runtime calls (alloc_array) for the array" );
    }
};

subtest 'a function-scope dynamic array alongside a loop-scope array stays heap-based' => sub {
    my $src = <<'BROCKEN';
my i64 $n = 64;
my [i64; $n] @big;
my i64 $i = 0;
while ($i < 3) {
    my [i64; $n] @buf;
    @buf[0] = 2;
    $i = $i + 1;
}
@big[0] = 5;
return @big[0] + $i;
BROCKEN
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        my ( $entry_ops, $blocks ) = lower_entry_ops( $triple, $class, $src );
        my $alloca_dyn = 0;
        my $stack_save = 0;
        for my $ops ( $entry_ops, @$blocks ) {
            $alloca_dyn += count_op( $ops, 'alloca_dyn' );
            $stack_save += count_op( $ops, 'stack_save' );
        }
        is( $alloca_dyn, 0, "$triple: function-scope and loop-scope arrays are both heap-promoted" );
        is( $stack_save, 0, "$triple: no stack_save is emitted for either" );
    }
};

# The loop below concatenates the behaviors the heap replacement must keep correct on the host: a loop-scope array is
# re-allocated and freed every iteration, a next from inside an if-scope still returns to the header with a bounded
# heap, and the loop actually terminates with the right answer.
subtest 'bounded loop heap on the host' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
    my $src     = <<'BROCKEN';
my i64 $n = 50000;
my i64 $i = 0;
my i64 $sum = 0;
while ($i < 200) {
    $i = $i + 1;
    my [i64; $n] @buf;
    @buf[0] = $i;
    if (@buf[0] % 2 == 0) {
        my [i64; $n] @scratch;
        @scratch[0] = 3;
        $sum = $sum + @scratch[0];
        next;
    }
    $sum = $sum + @buf[0] + 1;
}
return $sum % 251;
BROCKEN
    my $module = Brocken->new->compile($src);
    my $out    = $brocken->tmpdir . '/dyn_loop' . $brocken->ext;
    $brocken->linker->write_executable( $out, $brocken->codegen->emit_functions( $module->functions ), $host );
    ok -e $out, 'executable created';

    # evens: 100 x @scratch[0] = 300; odds: sum(1..199) + 1 each = 10000 + 100 = 10100.  total 10400, 10400 % 251 = 109.
    run_exec( $out, expected_exit => 109, platform => $host, name => 'bounded loop-vla heap on host' );
};

subtest 'heap cursor stays bounded across a re-allocation loop on the host' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
    my $src     = <<'BROCKEN';
my i64 $n = 50000;
my i64 $i = 0;
while ($i < 300) {
    my [i64; $n] @buf;
    @buf[1] = 7;
    $i = $i + 1;
}
my ptr $hb = Brocken::heap_base();
my ptr $hc = Brocken::Runtime::heap_cursor($hb);
my i64 $used = Brocken::ptr_sub($hc, $hb);
if (Brocken::ptr_cmp_gt($used, 2000000)) { return 2; }
return 0;
BROCKEN
    my $module = Brocken->new->compile($src);
    my $out    = $brocken->tmpdir . '/dyn_bounded' . $brocken->ext;
    $brocken->linker->write_executable( $out, $brocken->codegen->emit_functions( $module->functions ), $host );
    ok -e $out, 'executable created';

    # 300 iterations of a 400KB array would want 120MB; free_big reuse must keep the cursor inside 2MB.
    run_exec( $out, expected_exit => 0, platform => $host, name => 'heap cursor bounded after 300 re-allocations' );
};

subtest 'a function-scope array outlives the loop on the host' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
    my $src     = <<'BROCKEN';
my i64 $n = 4096;
my i64 $seed = 2;
my [i64; $n] @sink;
my i64 $i = 0;
my i64 $mark = 0;
while ($i < 40) {
    $seed = $seed + 1;
    my [i64; $n] @buf;
    @buf[0] = $seed;
    if (@buf[0] % 3 == 0) {
        my [i64; $n] @tb;
        @tb[0] = $seed + 1;
        $mark = @tb[0];
        last;
    }
    $i = $i + 1;
}
@sink[0] = $seed;
@sink[1] = $i;
@sink[2] = $mark;
return @sink[0] + @sink[1] + @sink[2];
BROCKEN
    my $module = Brocken->new->compile($src);
    my $out    = $brocken->tmpdir . '/dyn_guard' . $brocken->ext;
    $brocken->linker->write_executable( $out, $brocken->codegen->emit_functions( $module->functions ), $host );
    ok -e $out, 'executable created';

    # First %3==0 seed is 3 (loop-carried, i stays 0), mark = 4, sink = 3 + 0 + 4 = 7.
    run_exec( $out, expected_exit => 7, platform => $host, name => 'function-scope array lives across the loop' );
};

done_testing;