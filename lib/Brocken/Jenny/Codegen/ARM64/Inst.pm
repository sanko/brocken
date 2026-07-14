package Brocken::Jenny::Codegen::ARM64::Inst;
use v5.42;
use strict;
use warnings;
use Exporter 'import';
use Brocken::Jenny::Codegen::ARM64::Encodings qw[:all];
our %EXPORT_TAGS = (
    all => [
        qw(
            X0 X1 X2 X3 X4 X5 X6 X7 X8 X9 X10 X11 X12 X13 X14 X15
            X16 X17 X18 X19 X20 X21 X22 X23 X24 X25 X26 X27 X28 X29 X30
            FP LR SP
            ret stp_pre stp_post ldp_pre ldp_post
            str_64 ldr_64 str_32 ldr_32
            ldr_lit ldr_lit_64
            movz_64 movz_32 movk_64 movk_32 mov_64
            adr adrp blr bl b
            brk svc uxtb
            add_imm sub_imm
            cmp_imm
        )
    ],
);
our @EXPORT_OK = @{ $EXPORT_TAGS{all} };
our @EXPORT    = @{ $EXPORT_TAGS{all} };
sub ret () {RET}

sub stp_pre {
    my ( $rt, $rt2, $rn, $imm ) = @_;
    my $imm7 = ( $imm >> 3 ) & 0x7F;
    STP_PRE | ( $rt2 << 10 ) | ( $imm7 << 15 ) | ( $rn << 5 ) | $rt;
}

sub stp_post {
    my ( $rt, $rt2, $rn, $imm ) = @_;
    my $imm7 = ( $imm >> 3 ) & 0x7F;
    STP_POST | ( $rt2 << 10 ) | ( $imm7 << 15 ) | ( $rn << 5 ) | $rt;
}

sub ldp_pre {
    my ( $rt, $rt2, $rn, $imm ) = @_;
    my $imm7 = ( $imm >> 3 ) & 0x7F;
    LDP_PRE | ( $rt2 << 10 ) | ( $imm7 << 15 ) | ( $rn << 5 ) | $rt;
}

sub ldp_post {
    my ( $rt, $rt2, $rn, $imm ) = @_;
    my $imm7 = ( $imm >> 3 ) & 0x7F;
    LDP_POST | ( $rt2 << 10 ) | ( $imm7 << 15 ) | ( $rn << 5 ) | $rt;
}

sub str_64 {
    my ( $rt, $rn, $imm ) = @_;
    STR_64 | ( ( $imm >> 3 ) << 10 ) | ( $rn << 5 ) | $rt;
}

sub ldr_64 {
    my ( $rt, $rn, $imm ) = @_;
    LDR_64 | ( ( $imm >> 3 ) << 10 ) | ( $rn << 5 ) | $rt;
}

sub str_32 {
    my ( $rt, $rn, $imm ) = @_;
    STR_32 | ( ( $imm >> 2 ) << 10 ) | ( $rn << 5 ) | $rt;
}

sub ldr_32 {
    my ( $rt, $rn, $imm ) = @_;
    LDR_32 | ( ( $imm >> 2 ) << 10 ) | ( $rn << 5 ) | $rt;
}

sub ldr_lit {
    my ( $rt, $offset ) = @_;
    my $imm19 = ( $offset >> 2 ) & 0x7FFFF;
    LDR_LIT | ( $imm19 << 5 ) | $rt;
}

sub ldr_lit_64 {
    my ( $rt, $offset ) = @_;
    my $imm19 = ( $offset >> 2 ) & 0x7FFFF;
    LDR_LIT_64 | ( $imm19 << 5 ) | $rt;
}

sub movz_64 {
    my ( $rd, $imm16, $hw ) = @_;
    $hw //= 0;
    MOVZ_64 | ( ( $hw & 3 ) << 21 ) | ( ( $imm16 & 0xFFFF ) << 5 ) | $rd;
}

sub movz_32 {
    my ( $rd, $imm16, $hw ) = @_;
    $hw //= 0;
    MOVZ_32 | ( ( $hw & 3 ) << 21 ) | ( ( $imm16 & 0xFFFF ) << 5 ) | $rd;
}

sub movk_64 {
    my ( $rd, $imm16, $hw ) = @_;
    $hw //= 0;
    MOVK_64 | ( ( $hw & 3 ) << 21 ) | ( ( $imm16 & 0xFFFF ) << 5 ) | $rd;
}

sub movk_32 {
    my ( $rd, $imm16, $hw ) = @_;
    $hw //= 0;
    MOVK_32 | ( ( $hw & 3 ) << 21 ) | ( ( $imm16 & 0xFFFF ) << 5 ) | $rd;
}

sub mov_64 {
    my ( $rd, $rm ) = @_;
    MOV_X | ( $rm << 16 ) | $rd;
}

sub adr {
    my ( $rd, $offset ) = @_;
    my $lo = $offset & 3;
    my $hi = ( $offset >> 2 ) & 0x7FFFF;
    ADR | ( $lo << 29 ) | ( $hi << 5 ) | $rd;
}

sub adrp {
    my ( $rd, $target, $pc ) = @_;
    my $page_diff = ( ( $target >> 12 ) - ( $pc >> 12 ) ) & 0x1FFFFF;
    ADRP | ( ( $page_diff & 3 ) << 29 ) | ( ( ( $page_diff >> 2 ) & 0x7FFFF ) << 5 ) | $rd;
}

sub blr {
    my ($rn) = @_;
    BLR | ( $rn << 5 );
}

sub bl {
    my ($offset) = @_;
    my $imm26 = ( $offset >> 2 ) & 0x3FFFFFF;
    BL | $imm26;
}

sub b {
    my ($offset) = @_;
    my $imm26 = ( $offset >> 2 ) & 0x3FFFFFF;
    B | $imm26;
}

sub brk {
    my ($imm16) = @_;
    BRK | ( ( $imm16 & 0xFFFF ) << 5 );
}

sub svc {
    my ($imm16) = @_;
    SVC | ( ( $imm16 & 0xFFFF ) << 5 );
}

sub uxtb {
    my ( $rd, $rn ) = @_;
    UXTB | ( $rn << 5 ) | $rd;
}

sub add_imm {
    my ( $rd, $rn, $imm12 ) = @_;
    ADD_IMM_64 | ( ( $imm12 & 0xFFF ) << 10 ) | ( $rn << 5 ) | $rd;
}

sub sub_imm {
    my ( $rd, $rn, $imm12 ) = @_;
    SUB_IMM_64 | ( ( $imm12 & 0xFFF ) << 10 ) | ( $rn << 5 ) | $rd;
}

sub cmp_imm {
    my ( $rn, $imm12 ) = @_;
    CMP_IMM_64 | ( ( $imm12 & 0xFFF ) << 10 ) | ( $rn << 5 );
}
1;
