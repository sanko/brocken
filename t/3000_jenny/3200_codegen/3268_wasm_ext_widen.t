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

# zext/sext emitted their i64_extend_i32_u / i64_extend_i32_s widening
# whenever the destination was wider than 32 bits, without checking the source
# width. Those opcodes consume an i32, so a 64-bit source left an i64 on the
# stack underneath and the validator rejected the module outright:
#
#   type mismatch: expected i32, found i64
#
# The widening is only meaningful when the value is still in a 32-bit lane, so
# it is now gated on the source being at most 32 bits. An i64->i64 extension
# is a no-op, and emitting nothing leaves the i64 alone, which is what the
# caller wanted.
#
# Run under wasmtime: the failure mode here is a module that will not compile,
# and a byte-level check would not have caught it.
my $i64           = Brocken::Lindsay::IR::Type::i64();
my $i32           = Brocken::Lindsay::IR::Type::i32();
my $platform      = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $devnull       = File::Spec->devnull;
my $have_wasmtime = (`wasmtime --version 2>$devnull`) ? 1 : 0;

sub build {
    my ( $kind, $src_type, $dst_type, $value ) = @_;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $slot = $builder->build_alloca( $src_type, '%slot' );
    $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => $src_type, value => $value ), $slot );
    my $ld = $builder->build_load( $src_type, $slot, '%ld' );
    my $r  = $kind eq 'zext' ? $builder->build_zext( $ld, $dst_type, '%r' ) : $builder->build_sext( $ld, $dst_type, '%r' );
    $builder->build_ret($r);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $bytes   = $codegen->emit_function($func);
    my $out     = temp_path( $kind . '_' . $src_type->bits . '_' . $dst_type->bits ) . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $bytes, $platform );
    return $out;
}

sub run {
    my ($path) = @_;
    my $out = `wasmtime run --invoke main "$path" 2>$devnull`;
    chomp $out;
    return $out =~ /^\s*(-?\d+)\s*$/ ? $1 + 0 : undef;
}

# Decimal literals only: a bare 64-bit hex literal lands in Perl as an NV and
# would make the comparison itself inexact.
my @cases = (

    # 64-bit source: the case that used to emit a widening opcode over an i64.
    [ 'zext', $i64, $i64, 7, 7 ], [ 'sext', $i64, $i64, -7, -7 ], [ 'zext', $i64, $i64, 3000000000, 3000000000 ],
    [ 'sext', $i64, $i64, 3000000000, 3000000000 ], [ 'sext', $i64, $i64, -3000000000, -3000000000 ],

    # 32-bit source: the widening is real and must be kept.
    [ 'zext', $i32, $i64, 7, 7 ], [ 'sext', $i32, $i64, -7, -7 ], [ 'zext', $i32, $i64, 2000000000, 2000000000 ],
    [ 'sext', $i32, $i64, 2000000000, 2000000000 ],
);
SKIP: {
    skip 'wasmtime is not installed', scalar @cases unless $have_wasmtime;
    for my $c (@cases) {
        my ( $kind, $src, $dst, $value, $want ) = @$c;
        my $label = "$kind i" . $src->bits . "->i" . $dst->bits . " $value";
        my $path  = eval { build( $kind, $src, $dst, $value ) };
        if ( !defined $path ) { fail("$label: build died: $@"); next }
        is run($path), $want, "Wasm $label";
        unlink $path if -e $path;
    }
}
done_testing;
