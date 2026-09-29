use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# The ARM64 `cset_*` family is how every scalar comparison reaches the hardware.
# Straightforward to get wrong on paper, so its encoding is pinned here,
# byte-exact, against the independently derived architectural formula:
#
#     sf | 0x1A800400 | csinc_cond<<12 | (31<<16) | (31<<5) | Rd
#
# CSET Rd, cond is defined as CSINC Rd, ZR, ZR, invert(cond). Both source fields
# read ZR (31): CSINC selects Xm + 1 when its cond is false, so the cond CSET
# evaluates is the inverse of what the CSINC field holds. Verified against
# ground truth disassembly: `cset w0, eq` = 0x1A9F17E0, i.e. this formula with
# Rd = 0, csinc_cond = NE and both source fields 31.
#
# The codegen's %arm_cond map already carries the inverted codes (cset_lt -> GE,
# cset_eq -> NE, ...) and is emitted as-is, so each row below is the inverse of
# the predicate's true condition. These are the same codes Lowerer/ARM64.pm
# relies on, pinned here so a swap in either file fails loudly.
#
# SF is fixed on: the result is a 0/1 boolean, so the 64-bit form is valid for
# every operand width and leaves the upper half zeroed for 64-bit consumers.
# The icmp result value itself carries no width (it is i1), so both the i32 and
# i64 comparisons below must produce the same word; the SF bit always set is
# the encoder's contract.
#
# `sltu` (dst = dst < src unsigned, i.e. cset dst, lo after CMP) shares the
# same CSINC base with cond 2 = hs, the inverse of the lo it wants; its word
# is pinned here via the `ult` row.
my $i32 = Brocken::Lindsay::IR::Type::i32();
my $i64 = Brocken::Lindsay::IR::Type::i64();

# ICmp predicate -> the cset_* opcode the lowerer picks for it.
my %cset_for = (
    eq  => 'cset_eq',
    ne  => 'cset_ne',
    slt => 'cset_lt',
    sgt => 'cset_gt',
    sle => 'cset_le',
    sge => 'cset_ge',
    ult => 'cset_cc',
    ugt => 'cset_hi',
    ule => 'cset_ls',
    uge => 'cset_cs',
);

# ICmp predicate -> the cond field the CSET must emit. CSET Rd, pred is
# CSINC Rd, ZR, ZR, invert(pred), so these are the *inverted* TRUE conditions:
# eq -> ne(0x1), slt -> ge(0xA), ugt -> ls(0x9), uge -> lo(0x3), ... They are
# the same codes Lowerer/ARM64.pm expects the codegen to produce, pinned here
# so a swap in either file fails loudly.
my %nzcv = ( eq => 0x1, ne => 0x0, slt => 0xA, sgt => 0xD, sle => 0xC, sge => 0xB, ult => 0x2, ugt => 0x9, ule => 0x8, uge => 0x3, );

# CSEL/CSINC/ CSET all share bits[28:21] == 0b11010_100, which survives the
# repair, so the instruction stays identifiable once the encoding is fixed.
# Filtering on that rather than on the current broken bits keeps this locator
# valid on both sides of the fix.
my $CSEL_SIG = 0xD4;

# Rd is chosen by the register allocator, not the encoder, so it is masked off;
# every other bit is compared exactly.
my $RD_MASK = 0x1F;
subtest 'ARM64: cset_* encodes CSET Rd, cond' => sub {
SKIP: {
        skip 'ARM64 lowerer/codegen unavailable', 1 unless eval "require Brocken::Jenny::Lowerer::ARM64; require Brocken::Jenny::Codegen::ARM64; 1";
        my $platform = Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu');
        my $codegen  = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
        for my $width ( 32, 64 ) {
            my $type = $width == 64 ? $i64 : $i32;
            for my $pred ( sort keys %cset_for ) {
                subtest "$width-bit $pred" => sub {
                    my $func    = Brocken::Lindsay::IR::Function->new( name => 'ic', return_type => $type );
                    my $builder = Brocken::Lindsay::IR::Builder->new();
                    $builder->position_at_end( $func->append_block('entry') );

                    # Keep both operands in registers so the lowering is a plain
                    # cmp + cset with no constant folding in the way.
                    my $sum = $builder->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => $type, value => 5 ),
                        Brocken::Lindsay::IR::Constant->new( type => $type, value => 1 ),
                        '%a'
                    );
                    my $res = $builder->build_icmp( $pred, $sum, Brocken::Lindsay::IR::Constant->new( type => $type, value => 3 ) );
                    $builder->build_ret($res);
                    my $mf = eval { Brocken::Jenny::Lowerer::ARM64->new( platform => $platform )->lower($func); };
                    ok( $mf, 'lower survived' ) or do { diag $@; return };
                    my @cset = grep { $_->opcode eq $cset_for{$pred} } $mf->blocks->[0]->instructions->@*;
                    is( scalar @cset, 1, "lowered to exactly one $cset_for{$pred}" ) or return;
                    my $bytes = eval { $codegen->emit_function($func) };
                    ok( defined $bytes && length $bytes, 'emit_function produced bytes' ) or do {
                        diag $@;
                        return;
                    };
                    my @found = grep { ( ( $_ >> 21 ) & 0xFF ) == $CSEL_SIG } unpack 'V*', $bytes;
                    is( scalar @found, 1, 'exactly one CSEL-family word in the stream' ) or return;

                    # Both widths must produce the same word (SF always on); the
                    # boolean result is 0/1, so a 64-bit cset is correct for an
                    # i32 comparison too. Pinning the identical word for both is
                    # the encoder's contract.
                    my $want = 0x80000000 | 0x1A800400 | ( $nzcv{$pred} << 12 ) | ( 31 << 16 )    # Rm = ZR
                        | ( 31 << 5 );                                                            # Rn = ZR
                    is( $found[0] & ~$RD_MASK, $want, "cset word is CSET Rd, $pred" );
                };
            }
        }
    }
};
done_testing;
