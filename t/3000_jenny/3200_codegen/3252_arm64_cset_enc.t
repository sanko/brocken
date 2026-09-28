use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# The ARM64 `cset_*` family is how every comparison reaches the hardware, but as
# of this writing it encodes an unallocated instruction word.
#
# CSET Rd, cond is defined as CSINC Rd, ZR, ZR, invert(cond):
#
#     sf | 0x1A800400 | cond<<12 | Rn<<5 | Rd      with Rn = 31 (ZR)
#
# Codegen/ARM64.pm instead packs CSINC => 0x9A9F07E0 and ORs in (31 << 16),
# (cond << 12) and (31 << 5). That constant already has bit 20 and the Rm field
# baked in, so the result lands in the reserved space between the CSEL and
# CSINC groups rather than in CSINC at all. Concretely, for `cset_lt` into
# register 10 the encoder produces 0x9A9FA7EA where the architectural word is
# 0x1A80B7EA (32-bit) or 0x9A80B7EA (64-bit).
#
# Four independent defects, all in the one pack() at Codegen/ARM64.pm:854:
#
#   1. the CSINC base constant sets bit 20, which must be 0 for the group;
#   2. (31 << 16) forces Rm = 31, so both CSINC inputs are the same register
#      and the "invert via Xm + 1" trick collapses to a no-op;
#   3. cond is forwarded un-inverted, where CSET requires cond ^ 1;
#   4. no SF bit, so a 64-bit comparison yields a 32-bit result -- the two
#      widths emit the identical word.
#
# Nothing catches this because no test asserts these encodings. `sltu` in the
# same file shares all four defects, and roughly sixty `cset_*` sites across
# Lowerer/ARM64.pm depend on it: every ICmp predicate, the i128 div/icmp/min-max
# expansions and the float compare paths. That is the most likely reason all
# four aarch64 CI legs are red.
#
# The byte-exact assertion below is wrapped in `todo` on purpose. It fails today
# and the failure output records the emitted word, so the defect is pinned in the
# suite without turning the currently-green legs red. Fixing the encoder turns
# these into unexpected successes, at which point the `todo` markers come off.

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

# ICmp predicate -> architectural NZCV condition code.
my %nzcv = (
    eq  => 0x0,
    ne  => 0x1,
    slt => 0xA,
    sgt => 0xD,
    sle => 0xC,
    sge => 0xB,
    ult => 0x2,
    ugt => 0x3,
    ule => 0x8,
    uge => 0x9,
);

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
        skip 'ARM64 lowerer/codegen unavailable', 1
            unless eval "require Brocken::Jenny::Lowerer::ARM64; require Brocken::Jenny::Codegen::ARM64; 1";

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
                    my $res = $builder->build_icmp(
                        $pred, $sum, Brocken::Lindsay::IR::Constant->new( type => $type, value => 3 ) );
                    $builder->build_ret($res);

                    my $mf = eval {
                        Brocken::Jenny::Lowerer::ARM64->new( platform => $platform )->lower($func);
                    };
                    ok( $mf, 'lower survived' ) or do { diag $@; return };

                    my @cset = grep { $_->opcode eq $cset_for{$pred} }
                        $mf->blocks->[0]->instructions->@*;
                    is( scalar @cset, 1, "lowered to exactly one $cset_for{$pred}" ) or return;

                    my $bytes = eval { $codegen->emit_function($func) };
                    ok( defined $bytes && length $bytes, 'emit_function produced bytes' ) or do {
                        diag $@;
                        return;
                    };

                    my @found = grep { ( ( $_ >> 21 ) & 0xFF ) == $CSEL_SIG } unpack 'V*', $bytes;
                    is( scalar @found, 1, 'exactly one CSEL-family word in the stream' ) or return;

                    my $sf   = $width == 64 ? 0x80000000 : 0x00000000;
                    my $want = $sf | 0x1A800400 | ( ( $nzcv{$pred} ^ 1 ) << 12 ) | ( 31 << 5 );

                    todo 'CSINC base constant sets bit 20 and Rm; cond is not inverted; SF is missing' => sub {
                        is( $found[0] & ~$RD_MASK, $want,
                            "cset word is CSET Rd, " . ( $nzcv{$pred} ^ 1 ) );
                    };
                };
            }
        }
    }
};

done_testing;
