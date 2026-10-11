use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[run_exec cross_available temp_path];
use Brocken;
use Brocken::Katsuro::Platform;
no warnings qw[experimental::class experimental::builtin];
use feature qw[class];

# Heap promotion for dynamic array sizes: dynamic-sized arrays (and static arrays whose element count exceeds 4 KiB of
# stack) are allocated on the Immix heap via Brocken::Runtime::alloc_array instead of the dynamic stack alloca. The
# declaration becomes a pointer slot holding the tag-9 array header, so alloc_array no longer appears in MIR as
# `alloca_dyn` and there is no dynamic frame adjustment. Loops that re-declare the array each iteration free it at the
# back edge and reuse the same slab, bounding heap growth (see 3309).
my @TARGETS = (
    [ 'x86_64-pc-windows-msvc',    'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'x86_64-unknown-linux-gnu',  'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'aarch64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::ARM64' ],
    [ 'riscv64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::RISCV64' ],
);

sub src_dyn_small($n) {
    my $N = $n + 0;
    return <<"BROCKEN";
my i64 \$n = $N;
my [i64; \$n] \@arr;
\@arr[0] = 1;
\@arr[$N - 1] = $N;
return \@arr[0] + \@arr[$N - 1];
BROCKEN
}

sub src_dyn_large() {
    return <<'BROCKEN';
my i64 $n = 1000;
my [i64; $n] @arr;
@arr[0] = 25;
@arr[999] = 5000;
return @arr[0] + @arr[999];
BROCKEN
}

sub find_alloc_array_call($src) {
    my $module = Brocken->new->compile($src);
    my ($entry) = grep { $_->name eq '_BROCKEN_ENTRY' } $module->functions->@*;
    my $alloc;
    for my $bb ( $entry->blocks->@* ) {
        for my $inst ( $bb->instructions->@* ) {
            if ( $inst->isa('Brocken::Lindsay::IR::Instruction::Call') && $inst->callee && $inst->callee->name eq 'Brocken::Runtime::alloc_array' ) {
                $alloc = $inst;
            }
        }
    }
    return ( $module, $alloc );
}

sub has_alloca_dyn( $lower_class, $src ) {
    my $platform = Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu');
    my ($module) = find_alloc_array_call($src);
    my ($func)   = grep { $_->name eq '_BROCKEN_ENTRY' } $module->functions->@*;
    my $mf       = $lower_class->new( platform => $platform )->lower($func);
    for my $bb ( $mf->blocks->@* ) {
        for my $inst ( $bb->instructions->@* ) {
            if ( $inst->opcode eq 'alloca_dyn' ) {
                return 1;
            }
        }
    }
    return 0;
}

subtest 'dynamic array sizes are heap-promoted, not dynamically stacked' => sub {
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        my ( undef, $alloc ) = find_alloc_array_call( src_dyn_small(3) );
        ok( $alloc,                                                               "$triple emits Brocken::Runtime::alloc_array for dynamic count" );
        ok( !has_alloca_dyn( $class, src_dyn_small(3) ),                          "$triple no longer uses alloca_dyn for dynamic count" );
    }
};

subtest 'constant small arrays stay on the stack; large statics promote' => sub {
    my $src_const = <<'BROCKEN';
my i64 $x;
my [i64; 4] @arr;
@arr[0] = 1;
@arr[3] = 4;
$x = @arr[0] + @arr[3];
return $x;
BROCKEN
    my $src_big = <<'BROCKEN';
my [i64; 600] @arr;
@arr[0] = 1;
@arr[599] = 2;
return @arr[0] + @arr[599];
BROCKEN
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        my ( undef, $small_alloc ) = find_alloc_array_call($src_const);
        my ( undef, $big_alloc )   = find_alloc_array_call($src_big);
        ok( !$small_alloc, "$triple constant small array stays a stack alloca" );
        ok( !has_alloca_dyn( $class, $src_const ), "$triple constant small array uses no alloca_dyn" );
        ok( $big_alloc,   "$triple static array over 4 KiB promotes to alloc_array" );
    }
};

subtest 'small dynamic arrays return correct value (masked to 8 bits)' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
    my $src     = src_dyn_small(6);
    my $module  = Brocken->new->compile($src);
    my $funcs   = $brocken->codegen->emit_functions( $module->functions );
    my $out     = $brocken->tmpdir . '/dyn_small' . $brocken->ext;
    $brocken->linker->write_executable( $out, $funcs, $host );
    ok -e $out, 'executable created';
    run_exec( $out, expected_exit => 7, platform => $host, name => 'dyn small on host' );
};

subtest 'large dynamic arrays still land correct values through the heap (masked to 8 bits)' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
    my $src     = src_dyn_large();
    my $module  = Brocken->new->compile($src);
    my $funcs   = $brocken->codegen->emit_functions( $module->functions );
    my $out     = $brocken->tmpdir . '/dyn_large' . $brocken->ext;
    $brocken->linker->write_executable( $out, $funcs, $host );
    ok -e $out, 'executable created';
    run_exec( $out, expected_exit => 161, platform => $host, name => 'dyn large on host' );
};

subtest 'an untyped size is unboxed to i64 before alloc_array' => sub {
    my $src = <<'BROCKEN';
my $n = 6;
my [i64; $n] @arr;
@arr[0] = 5;
return @arr[0];
BROCKEN
    my ( undef, $alloc ) = find_alloc_array_call($src);
    ok( $alloc, 'the alloc_array call is present' );
    ok( $alloc
            && $alloc->operands->@* >= 3
            && $alloc->operands->[1]->type
            && $alloc->operands->[1]->type->kind eq 'int'
            && $alloc->operands->[1]->type->bits == 64,
        'the count is an i64, not the box pointer of the untyped size' );

    # The boxed (`my $n`) size used to reach the dynamic alloca as a raw box pointer, and the allocator carved that
    # many bytes off the stack.  Now the size feeds alloc_array - it has to run and answer 5.
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
    my $module  = Brocken->new->compile($src);
    my $funcs   = $brocken->codegen->emit_functions( $module->functions );
    my $out     = $brocken->tmpdir . '/dyn_untyped' . $brocken->ext;
    $brocken->linker->write_executable( $out, $funcs, $host );
    run_exec( $out, expected_exit => 5, platform => $host, name => 'untyped array size on host' );
};

subtest 'IR render survives a dynamic count' => sub {
    my $src = <<'BROCKEN';
my i64 $n = 6;
my [i64; $n] @arr;
@arr[0] = 5;
return @arr[0];
BROCKEN
    my ( $module, $alloc ) = find_alloc_array_call($src);
    ok( $alloc, 'the alloc_array call is present' );
    my $text = eval { $alloc->render };
    is( $@, '',             'render does not call ->value on an instruction count' );
    like( $text // '', qr/alloc_array/, 'render names the alloc_array callee' );
};

subtest 'foreign targets handle dynamic arrays' => sub {
    for my $target (@TARGETS) {
        my ($triple) = @$target;
        my $platform = Brocken::Katsuro::Platform::parse($triple);
    SKIP: {
            skip "$triple not executable here", 2 unless cross_available($platform);
            my $brocken = Brocken->new( platform => $platform );
            my $module  = Brocken->new->compile( src_dyn_small(4) );
            my $funcs   = $brocken->codegen->emit_functions( $module->functions );
            my $out     = temp_path( 'dyn_small_' . $platform->arch . $brocken->ext );
            $brocken->linker->write_executable( $out, $funcs, $platform );
            run_exec( $out, expected_exit => 5, platform => $platform, name => "dyn small on $platform->friendly" );
            $brocken = Brocken->new( platform => $platform );
            $module  = Brocken->new->compile( src_dyn_large() );
            $funcs   = $brocken->codegen->emit_functions( $module->functions );
            $out     = temp_path( 'dyn_large_' . $platform->arch . $brocken->ext );
            $brocken->linker->write_executable( $out, $funcs, $platform );
            run_exec( $out, expected_exit => 161, platform => $platform, name => "dyn large on $platform->friendly" );
        }
    }
};
done_testing;