package Brocken::Jenny::Codegen::ARM64::Inst;
use v5.42;
use strict;
use warnings;
use Exporter 'import';
our %EXPORT_TAGS = (
    all => [
        qw(
            X0 X1 X2 X3 X4 X5 X6 X7 X8 X9
            X10 X11 X12 X13 X14 X15 X16 X17 X18 X19
            X20 X21 X22 X23 X24 X25 X26 X27 X28 X29 X30
            SP LR FP
            ret stp_pre stp_post ldp_pre ldp_post
            str_64 ldr_64 str_32 ldr_32
            ldr_lit ldr_lit_64
            movz_64 movz_32 movk_64 movk_32 mov_64
            adr adrp blr bl b
            brk svc uxtb
            add_imm sub_imm
            cmp_imm
        )
    ]
);
our @EXPORT_OK = @{ $EXPORT_TAGS{all} };
our @EXPORT    = @{ $EXPORT_TAGS{all} };
use constant {

    # Register aliases (0-30)
    X0  => 0,
    X1  => 1,
    X2  => 2,
    X3  => 3,
    X4  => 4,
    X5  => 5,
    X6  => 6,
    X7  => 7,
    X8  => 8,
    X9  => 9,
    X10 => 10,
    X11 => 11,
    X12 => 12,
    X13 => 13,
    X14 => 14,
    X15 => 15,
    X16 => 16,
    X17 => 17,
    X18 => 18,
    X19 => 19,
    X20 => 20,
    X21 => 21,
    X22 => 22,
    X23 => 23,
    X24 => 24,
    X25 => 25,
    X26 => 26,
    X27 => 27,
    X28 => 28,
    X29 => 29,
    X30 => 30,
    FP  => 29,
    LR  => 30,
    SP  => 31,

    # Instruction base encodings
    # STP pre-index: 10 101 0 0 1 10 imm7 Rt2 Rn Rt
    _STP_PRE => 0xA9800000,

    # STP post-index: 10 101 0 0 0 10 imm7 Rt2 Rn Rt
    _STP_POST => 0xA8800000,

    # LDP pre-index: 10 101 0 1 1 11 imm7 Rt2 Rn Rt
    _LDP_PRE => 0xA8E00000,

    # LDP post-index: 10 101 0 1 0 11 imm7 Rt2 Rn Rt
    _LDP_POST => 0xA8C00000,

    # STR 64-bit unsigned offset: 10 101 0 0 1 00 imm12 Rn Rt
    _STR_64 => 0xF9000000,

    # LDR 64-bit unsigned offset: 10 101 0 1 1 01 imm12 Rn Rt
    _LDR_64 => 0xF9400000,

    # STR 32-bit unsigned offset
    _STR_32 => 0xB9000000,

    # LDR 32-bit unsigned offset
    _LDR_32 => 0xB9400000,

    # LDR literal 32-bit: 00 011 0 L 00 imm19 Rt
    _LDR_LIT => 0x18000000,

    # LDR literal 64-bit: 01 011 0 L 00 imm19 Rt
    _LDR_LIT_64 => 0x58000000,

    # MOVZ 64-bit: 10 100 101 hw imm16 rd
    _MOVZ_64 => 0xD2800000,

    # MOVZ 32-bit
    _MOVZ_32 => 0x52800000,

    # MOVK 64-bit
    _MOVK_64 => 0xF2800000,

    # MOVK 32-bit
    _MOVK_32 => 0x72800000,

    # MOV (ORR XZR, rm): 10 010 101 00 00000 000000 rm rd
    _MOV_64 => 0xAA0003E0,

    # ADR: 0 0 1 10000 imm19 rd
    _ADR => 0x10000000,

    # ADRP: 1 0 0 10000 imm19 rd
    _ADRP => 0x90000000,

    # BLR: 10 010 101 10 000 000000 00000 00000 rn 00000
    _BLR => 0xD63F0000,

    # BL: 10 010 11 imm26
    _BL => 0x94000000,

    # B: 00 010 11 imm26
    _B => 0x14000000,

    # BRK: 11 010 100 001 imm16 00000 00000
    _BRK => 0xD4200000,

    # SVC: 11 010 100 001 imm16 00000 001
    _SVC => 0xD4000001,

    # UXTB Wd, Wn: 01 011 010 110 000 000 000 rn rd
    _UXTB => 0x53001C00,

    # ADD immediate 64-bit: 10 010 001 shift imm12 rn rd
    _ADD_IMM => 0x91000000,

    # SUB immediate 64-bit: 11 010 001 shift imm12 rn rd
    _SUB_IMM => 0xD1000000,

    # CMP immediate 64-bit: 11 100 011 shift imm12 rn 11111
    _CMP_IMM => 0xF100001F,

    # RET: 11 010 101 10 000 000000 11111 00000 00000
    _RET => 0xD65F03C0,
};
sub ret () {_RET}

sub stp_pre {
    my ( $rt, $rt2, $rn, $imm ) = @_;
    my $imm7 = ( $imm >> 3 ) & 0x7F;
    _STP_PRE | ( $rt2 << 10 ) | ( $imm7 << 15 ) | ( $rn << 5 ) | $rt;
}

sub stp_post {
    my ( $rt, $rt2, $rn, $imm ) = @_;
    my $imm7 = ( $imm >> 3 ) & 0x7F;
    _STP_POST | ( $rt2 << 10 ) | ( $imm7 << 15 ) | ( $rn << 5 ) | $rt;
}

sub ldp_pre {
    my ( $rt, $rt2, $rn, $imm ) = @_;
    my $imm7 = ( $imm >> 3 ) & 0x7F;
    _LDP_PRE | ( $rt2 << 10 ) | ( $imm7 << 15 ) | ( $rn << 5 ) | $rt;
}

sub ldp_post {
    my ( $rt, $rt2, $rn, $imm ) = @_;
    my $imm7 = ( $imm >> 3 ) & 0x7F;
    _LDP_POST | ( $rt2 << 10 ) | ( $imm7 << 15 ) | ( $rn << 5 ) | $rt;
}

sub str_64 {
    my ( $rt, $rn, $imm ) = @_;
    _STR_64 | ( ( $imm >> 3 ) << 10 ) | ( $rn << 5 ) | $rt;
}

sub ldr_64 {
    my ( $rt, $rn, $imm ) = @_;
    _LDR_64 | ( ( $imm >> 3 ) << 10 ) | ( $rn << 5 ) | $rt;
}

sub str_32 {
    my ( $rt, $rn, $imm ) = @_;
    _STR_32 | ( ( $imm >> 2 ) << 10 ) | ( $rn << 5 ) | $rt;
}

sub ldr_32 {
    my ( $rt, $rn, $imm ) = @_;
    _LDR_32 | ( ( $imm >> 2 ) << 10 ) | ( $rn << 5 ) | $rt;
}

sub ldr_lit {
    my ( $rt, $offset ) = @_;
    my $imm19 = ( $offset >> 2 ) & 0x7FFFF;
    _LDR_LIT | ( $imm19 << 5 ) | $rt;
}

sub ldr_lit_64 {
    my ( $rt, $offset ) = @_;
    my $imm19 = ( $offset >> 2 ) & 0x7FFFF;
    _LDR_LIT_64 | ( $imm19 << 5 ) | $rt;
}

sub movz_64 {
    my ( $rd, $imm16, $hw ) = @_;
    $hw //= 0;
    _MOVZ_64 | ( ( $hw & 3 ) << 21 ) | ( ( $imm16 & 0xFFFF ) << 5 ) | $rd;
}

sub movz_32 {
    my ( $rd, $imm16, $hw ) = @_;
    $hw //= 0;
    _MOVZ_32 | ( ( $hw & 3 ) << 21 ) | ( ( $imm16 & 0xFFFF ) << 5 ) | $rd;
}

sub movk_64 {
    my ( $rd, $imm16, $hw ) = @_;
    $hw //= 0;
    _MOVK_64 | ( ( $hw & 3 ) << 21 ) | ( ( $imm16 & 0xFFFF ) << 5 ) | $rd;
}

sub movk_32 {
    my ( $rd, $imm16, $hw ) = @_;
    $hw //= 0;
    _MOVK_32 | ( ( $hw & 3 ) << 21 ) | ( ( $imm16 & 0xFFFF ) << 5 ) | $rd;
}

sub mov_64 {
    my ( $rd, $rm ) = @_;
    _MOV_64 | ( $rm << 16 ) | $rd;
}

sub adr {
    my ( $rd, $offset ) = @_;
    my $lo = $offset & 3;
    my $hi = ( $offset >> 2 ) & 0x7FFFF;
    _ADR | ( $lo << 29 ) | ( $hi << 5 ) | $rd;
}

sub adrp {
    my ( $rd, $target, $pc ) = @_;
    my $page_diff = ( ( $target >> 12 ) - ( $pc >> 12 ) ) & 0x1FFFFF;
    _ADRP | ( ( $page_diff & 3 ) << 29 ) | ( ( ( $page_diff >> 2 ) & 0x7FFFF ) << 5 ) | $rd;
}

sub blr {
    my ($rn) = @_;
    _BLR | ( $rn << 5 );
}

sub bl {
    my ($offset) = @_;
    my $imm26 = ( $offset >> 2 ) & 0x3FFFFFF;
    _BL | $imm26;
}

sub b {
    my ($offset) = @_;
    my $imm26 = ( $offset >> 2 ) & 0x3FFFFFF;
    _B | $imm26;
}

sub brk {
    my ($imm16) = @_;
    _BRK | ( ( $imm16 & 0xFFFF ) << 5 );
}

sub svc {
    my ($imm16) = @_;
    _SVC | ( ( $imm16 & 0xFFFF ) << 5 );
}

sub uxtb {
    my ( $rd, $rn ) = @_;
    _UXTB | ( $rn << 5 ) | $rd;
}

sub add_imm {
    my ( $rd, $rn, $imm12 ) = @_;
    _ADD_IMM | ( ( $imm12 & 0xFFF ) << 10 ) | ( $rn << 5 ) | $rd;
}

sub sub_imm {
    my ( $rd, $rn, $imm12 ) = @_;
    _SUB_IMM | ( ( $imm12 & 0xFFF ) << 10 ) | ( $rn << 5 ) | $rd;
}

sub cmp_imm {
    my ( $rn, $imm12 ) = @_;
    _CMP_IMM | ( ( $imm12 & 0xFFF ) << 10 ) | ( $rn << 5 );
}
1;
