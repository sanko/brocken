use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[run_exec cross_available temp_path];
use Brocken;
use Brocken::Katsuro::Platform;
no warnings qw[experimental::class experimental::builtin];
use feature qw[class];

# Regression for dynamic frame adjustment.

my @TARGETS = (
    [ 'x86_64-pc-windows-msvc',   'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'x86_64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'aarch64-unknown-linux-gnu','Brocken::Jenny::Lowerer::ARM64'  ],
    [ 'riscv64-unknown-linux-gnu','Brocken::Jenny::Lowerer::RISCV64'],
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

sub has_alloca_dyn($triple, $lower_class, $src) {
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $module   = Brocken->new->compile($src);
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

sub find_array_alloca($src) {
    my $module = Brocken->new->compile($src);
    my ($func) = grep { $_->name eq '_BROCKEN_ENTRY' } $module->functions->@*;
    for my $bb ( $func->blocks->@* ) {
        for my $inst ( $bb->instructions->@* ) {
            next unless $inst->isa('Brocken::Lindsay::IR::Instruction::Alloca');
            return $inst if $inst->count;
        }
    }
    return undef;
}

subtest 'alloca_dyn is used for dynamic array sizes' => sub {
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        ok( has_alloca_dyn( $triple, $class, src_dyn_small(3) ), "$triple uses alloca_dyn for dynamic count" );
    }
};

subtest 'alloca_dyn is not used when array size is constant' => sub {
    my $src_const = <<'BROCKEN';
my i64 $x;
my [i64; 4] @arr;
@arr[0] = 1;
@arr[3] = 4;
$x = @arr[0] + @arr[3];
return $x;
BROCKEN
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        ok( !has_alloca_dyn( $triple, $class, $src_const ), "$triple does not use alloca_dyn for constant size" );
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

subtest 'large dynamic arrays cross out-of-range displacements (masked to 8 bits)' => sub {
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

subtest 'an untyped size is unboxed before the alloca' => sub {
    my $src = <<'BROCKEN';
my $n = 6;
my [i64; $n] @arr;
@arr[0] = 5;
return @arr[0];
BROCKEN
    my $alloca = find_array_alloca($src);
    ok( $alloca, 'the array alloca is present' );
    ok( $alloca && $alloca->count && $alloca->count->type && $alloca->count->type->kind eq 'int' && $alloca->count->type->bits == 64,
        'the count is an i64, not the box pointer of the untyped size' );

    # The boxed (`my $n`) size used to reach the dynamic alloca as a raw box pointer, and the allocator carved that
    # many bytes off the stack.  It has to run and answer 5.
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
    my $alloca = find_array_alloca($src);
    ok( $alloca, 'the array alloca is present' );
    ok( $alloca && $alloca->count && !$alloca->count->isa('Brocken::Lindsay::IR::Constant'),
        'the count is an instruction' );
    my $text = eval { $alloca->render };
    is( $@, '', 'render does not call ->value on an instruction count' );
    like( $text // '', qr/alloca i64, i64 %/, 'render spells the count as its SSA name' );
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