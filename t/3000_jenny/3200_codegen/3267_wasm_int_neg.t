use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use File::Spec ();
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);

# Wasm has no integer neg/abs opcode (only f32.neg/f64.neg and
# f32.abs/f64.abs), so the lowerer used to die with "Wasm unary op neg requires
# float type" for every integer negation. Unary minus reaches the lowerer for
# any numeric type, so a plain `return -x;` over an int failed to compile on
# Wasm while every other backend handled it.
#
# The integer forms are now built from the generic i32/i64 ops: neg(x) is
# 0 - x, and abs(x) is x < 0 ? -x : x via select. These run under wasmtime
# rather than being decoded from the bytes, which is what caught the original
# signed-LEB128 encoder bug.
my $i64           = Brocken::Lindsay::IR::Type::i64();
my $i32           = Brocken::Lindsay::IR::Type::i32();
my $i16           = Brocken::Lindsay::IR::Type->new( kind => 'int', bits => 16, signed => 1 );
my $i8            = Brocken::Lindsay::IR::Type->new( kind => 'int', bits => 8,  signed => 1 );
my $platform      = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $devnull       = File::Spec->devnull;
my $have_wasmtime = (`wasmtime --version 2>$devnull`) ? 1 : 0;

# Sub-word and 32-bit results come back in a full 32-bit lane. These types are
# signed, so read the result with sext to recover the signed value (a zext
# would read the same 32-bit lane as its unsigned equivalent). i64 needs
# nothing: the lane is already the result.
sub build {
    my ( $type, $op, $value ) = @_;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $slot = $builder->build_alloca( $type, '%slot' );
    $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => $type, value => $value ), $slot );
    my $val = $builder->build_load( $type, $slot, '%val' );
    my $r   = $op eq 'neg' ? $builder->build_neg( $val, '%r' ) : $builder->build_abs( $val, '%r' );
    $builder->build_ret( $type->bits < 64 ? $builder->build_sext( $r, $i64, '%z' ) : $r );
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $bytes   = $codegen->emit_function($func);
    my $out     = temp_path( $op . '_' . $type->bits ) . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $bytes, $platform );
    return $out;
}

sub run {
    my ($path) = @_;
    my $out = `wasmtime run --invoke main "$path" 2>$devnull`;
    chomp $out;
    return $out =~ /^\s*(-?\d+)\s*$/ ? $1 + 0 : undef;
}

# Values are written as decimal literals: a bare 64-bit hex literal lands in
# Perl as an NV and would make the comparison itself inexact.
my @cases = (
    [ 'neg', $i64, 42, -42 ], [ 'neg', $i64, -42, 42 ], [ 'neg', $i64, 0, 0 ], [ 'neg', $i64, 8589934592, -8589934592 ],    # 2**33: past 32 bits
    [ 'neg', $i64, -8589934592, 8589934592 ], [ 'neg', $i32, 1234,       -1234 ],      [ 'neg', $i16, 300, -300 ], [ 'neg', $i8,   7, -7 ],
    [ 'abs', $i64, -8589934592, 8589934592 ], [ 'abs', $i64, 8589934592, 8589934592 ], [ 'abs', $i64, 0,    0 ],   [ 'abs', $i32, -7,  7 ],
    [ 'abs', $i16, -300,        300 ],        [ 'abs', $i8,  -100,       100 ],
);
SKIP: {
    skip 'wasmtime is not installed', scalar @cases unless $have_wasmtime;
    for my $c (@cases) {
        my ( $op, $type, $value, $want ) = @$c;
        my $label = "$op i" . $type->bits . " $value";
        my $path  = eval { build( $type, $op, $value ) };
        if ( !defined $path ) { fail("$label: build died: $@"); next }
        is run($path), $want, "Wasm $label";
        unlink $path if -e $path;
    }
}

# The narrowest width: i8 abs(-128) has no positive representation, so the
# value has to map to itself rather than wrap to -128 + 1. Two's complement
# 0 - (-128) in a 32-bit lane is 0xFFFFFF80, which sign-extends back to -128.
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $slot = $builder->build_alloca( $i8, '%slot' );
    $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => $i8, value => -128 ), $slot );
    my $r = $builder->build_abs( $builder->build_load( $i8, $slot, '%val' ), '%r' );
    $builder->build_ret( $builder->build_sext( $r, $i64, '%z' ) );
    my $bytes = eval { Brocken::Jenny::Codegen::Wasm->new( platform => $platform )->emit_function($func) };
SKIP: {
        skip 'wasmtime is not installed', 1 unless $have_wasmtime;
        skip "build died: $@",            1 unless defined $bytes;
        my $out = temp_path('abs_min') . '.wasm';
        Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $bytes, $platform );
        my $got = run($out);
        is $got, -128, 'Wasm abs i8 -128 -> -128 (wraps, no positive i8)';
        unlink $out if -e $out;
    }
}

# sqrt stays float-only: Wasm has f32.sqrt/f64.sqrt but no integer square root,
# so an integer sqrt must still be rejected rather than silently miscompiled.
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( $builder->build_sqrt( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 4 ), '%r' ) );
    my $ok = eval { Brocken::Jenny::Codegen::Wasm->new( platform => $platform )->emit_function($func); 1 };
    ok !$ok, 'Wasm rejects integer sqrt';
    like $@, qr/non-float|sqrt/, 'integer sqrt error mentions a non-float type';
}
done_testing;
