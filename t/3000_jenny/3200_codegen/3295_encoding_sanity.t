#!/usr/bin/env perl
use v5.42;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";

# Import ARM64 constants directly (no collision issues in this test)
use Brocken::Jenny::Codegen::ARM64::Encodings qw[:all];

# Preload other modules (we access their constants via fully-qualified calls)
require Brocken::Jenny::Codegen::X86_64::Encodings;
require Brocken::Jenny::Codegen::RISCV64::Encodings;
require Brocken::Jenny::Codegen::Wasm::Encodings;
sub e86  { no strict 'refs'; &{ 'Brocken::Jenny::Codegen::X86_64::Encodings::' . $_[0] }() }
sub er64 { no strict 'refs'; &{ 'Brocken::Jenny::Codegen::RISCV64::Encodings::' . $_[0] }() }
sub ew   { no strict 'refs'; &{ 'Brocken::Jenny::Codegen::Wasm::Encodings::' . $_[0] }() }
subtest 'ARM64 encodings sanity' => sub {
    is( SBFM,                              0x93400000, 'SBFM X base (N=1, sf=1)' );
    is( SBFM_W,                            0x13400000, 'SBFM W base (N=0, sf=0)' );
    is( SBFM | ( 0 << 16 ) | ( 7 << 10 ),  0x93401C00, 'SXTB X = SBFM immr=0 imms=7' );
    is( SBFM | ( 0 << 16 ) | ( 15 << 10 ), 0x93403C00, 'SXTH X = SBFM immr=0 imms=15' );
    is( UBFM,                              0xD3400000, 'UBFM X base (N=1, sf=1)' );
    is( UBFM_W,                            0x53400000, 'UBFM W base (N=0, sf=0)' );
    ok( ( ADD_W & 0x80000000 ) == 0, 'ADD_W sf=0' );
    ok( ( ADD_X & 0x80000000 ) != 0, 'ADD_X sf=1' );
    ok( ( SUB_W & 0x80000000 ) == 0, 'SUB_W sf=0' );
    ok( ( SUB_X & 0x80000000 ) != 0, 'SUB_X sf=1' );
    ok( ( MOV_W & 0x80000000 ) == 0, 'MOV_W sf=0' );
    ok( ( MOV_X & 0x80000000 ) != 0, 'MOV_X sf=1' );
    is( SP,    31,         'SP = 31' );
    is( FP,    29,         'FP = 29' );
    is( LR,    30,         'LR = 30' );
    is( RET,   0xD65F03C0, 'RET' );
    is( BLR,   0xD63F0000, 'BLR' );
    is( BL,    0x94000000, 'BL' );
    is( BRK,   0xD4200000, 'BRK' );
    is( SVC,   0xD4000001, 'SVC' );
    is( CSINC, 0x9A9F07E0, 'CSINC' );
};
subtest 'ARM64 Inst.pm convenience subs' => sub {
    require Brocken::Jenny::Codegen::ARM64::Inst;
    Brocken::Jenny::Codegen::ARM64::Inst->import(qw[:all]);
    my $inst = add_imm( 0, 31, 0 );
    is( $inst & 0xFFE00000, 0x91000000, 'add_imm base = ADD_IMM_64' );
};
subtest 'x86_64 encodings sanity' => sub {
    is( e86('REX_W'),       0x08, 'REX.W' );
    is( e86('RET_BYTE'),    0xC3, 'RET' );
    is( e86('MOV_EAX_IMM'), 0xB8, 'MOV EAX, imm' );
    is( e86('PUSH_BASE'),   0x50, 'PUSH reg base' );
    is( e86('POP_BASE'),    0x58, 'POP reg base' );
    is( e86('JMP_REL32'),   0xE9, 'JMP rel32' );
    is( e86('JE'),          0x84, 'JE' );
    is( e86('JNE'),         0x85, 'JNE' );
};
subtest 'RISCV64 encodings sanity' => sub {
    is( er64('JAL'),    0x0000006F, 'JAL' );
    is( er64('JALR'),   0x00008067, 'JALR' );
    is( er64('OP_IMM'), 0x13,       'OP-IMM' );
    is( er64('OP'),     0x33,       'OP' );
    is( er64('LOAD'),   0x03,       'LOAD' );
    is( er64('STORE'),  0x23,       'STORE' );
    is( er64('FP_OP'),  0x53,       'FP_OP' );
    is( er64('BCC'),    0x63,       'BCC' );
    is( er64('LUI'),    0x37,       'LUI' );
};
subtest 'Wasm encodings sanity' => sub {
    is( ew('BLOCK'),       0x02, 'BLOCK' );
    is( ew('END_BLOCK'),   0x0B, 'END_BLOCK' );
    is( ew('BR'),          0x0C, 'BR' );
    is( ew('BR_IF'),       0x0D, 'BR_IF' );
    is( ew('RETURN'),      0x0F, 'RETURN' );
    is( ew('CALL'),        0x10, 'CALL' );
    is( ew('I32_CONST'),   0x41, 'I32_CONST' );
    is( ew('I64_CONST'),   0x42, 'I64_CONST' );
    is( ew('F32_CONST'),   0x43, 'F32_CONST' );
    is( ew('F64_CONST'),   0x44, 'F64_CONST' );
    is( ew('LOCAL_GET'),   0x20, 'LOCAL_GET' );
    is( ew('LOCAL_SET'),   0x21, 'LOCAL_SET' );
    is( ew('I32_ADD'),     0x6A, 'I32_ADD' );
    is( ew('I64_ADD'),     0x7C, 'I64_ADD' );
    is( ew('I32_LOAD'),    0x28, 'I32_LOAD' );
    is( ew('I64_LOAD'),    0x29, 'I64_LOAD' );
    is( ew('I32_STORE'),   0x36, 'I32_STORE' );
    is( ew('I64_STORE'),   0x37, 'I64_STORE' );
    is( ew('VALTYPE_I32'), 0x7F, 'VALTYPE_I32' );
    is( ew('VALTYPE_I64'), 0x7E, 'VALTYPE_I64' );
};
done_testing;
