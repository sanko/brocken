use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[run_exec cross_available temp_path];
use Brocken;
use Brocken::Katsuro::Platform;
no warnings qw[experimental::class experimental::builtin];
use feature qw[class];

# F17: a dynamic alloca inside a while loop used to grow the stack on every iteration until the epilogue, because
# alloca_dyn only ever moved rsp/sp down.  Each in-progress block scope now frames its dynamic arrays in a
# stack_save/stack_restore pair, and last/next restore the loop body's outermost save, so the stack stays bounded.
my @TARGETS = (
    [ 'x86_64-pc-windows-msvc',    'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'x86_64-unknown-linux-gnu',  'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'aarch64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::ARM64' ],
    [ 'riscv64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::RISCV64' ],
);

# A loop body with a runtime-sized array.  The per-iteration save/restore is what keeps the stack from growing.
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

sub block_has( $ops, $needle ) {
    return scalar grep { $_ eq $needle } @$ops;
}

subtest 'a dynamic array in a loop body is framed by stack_save/stack_restore' => sub {
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        my ( $entry_ops, $blocks ) = lower_entry_ops( $triple, $class, src_loop( 64, 4 ) );
        my ($body) = grep { block_has( $_, 'alloca_dyn' ) && block_has( $_, 'stack_restore' ) } @$blocks;
        ok( $body, "$triple: the loop body block has alloca_dyn and stack_restore" );
        next unless $body;
        my $save_idx;
        for my $i ( 0 .. $#$body ) {
            if ( $body->[$i] eq 'stack_save' ) { $save_idx = $i; last }
        }
        my @ops_after_save = @$body[ $save_idx + 1 .. $#$body ] if defined $save_idx;
        ok( defined $save_idx, "$triple: stack_save precedes the per-iteration alloca_dyn" )
            and ok( scalar( grep { $_ eq 'alloca_dyn' } @ops_after_save ) == 1, "$triple: the save is followed by the dynamic alloca" );
        my $restore_idx = $#$body;
        $restore_idx-- while $restore_idx >= 0 && $body->[$restore_idx] ne 'stack_restore';
        ok( $restore_idx >= 0 && ( $restore_idx > $save_idx // -1 ), "$triple: stack_restore closes the loop body after the alloca" );
    }
};

subtest 'a function-scope dynamic array frames each loop scope and is still freed at exit' => sub {
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
        my ($body) = grep { block_has( $_, 'stack_save' ) && block_has( $_, 'alloca_dyn' ) } @$blocks;
        ok( $body, "$triple: the function body captures a dynamic region" );
        next unless $body;
        my $first_save = 0;
        $first_save++ while $first_save < @$body && $body->[$first_save] ne 'stack_save';
        my $first_dyn = $first_save;
        $first_dyn++ while $first_dyn < @$body && $body->[$first_dyn] ne 'alloca_dyn';
        ok( $first_save < @$body && $first_save < $first_dyn, "$triple: entry captures the dynamic region before the first alloca" );
    }
};

# The loop below concatenates the two behaviors the fix must keep correct at once on the host: a loop-scope array is
# re-carved and freed every iteration, a next from inside an if-scope still returns to the header with a bounded
# stack, and the loop actually terminates with the right answer.
subtest 'bounded loop stack on the host' => sub {
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
    run_exec( $out, expected_exit => 109, platform => $host, name => 'bounded loop-vla stack on host' );
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