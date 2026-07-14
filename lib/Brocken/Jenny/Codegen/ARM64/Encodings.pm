package Brocken::Jenny::Codegen::ARM64::Encodings {
    use v5.42;
    use Exporter 'import';
    our %EXPORT_TAGS = (
        all => [
            qw[
                X0 X1 X2 X3 X4 X5 X6 X7 X8 X9 X10 X11 X12 X13 X14 X15
                X16 X17 X18 X19 X20 X21 X22 X23 X24 X25 X26 X27 X28 X29 X30
                FP LR SP
                B CBZ CBNZ BL BLR BR RET ADR ADRP
                ADD_W SUB_W AND_W ORR_W EOR_W MUL_W
                ADD_X ADD_X_EXT SUB_X ADCS_X SBCS_X
                AND_X ORR_X EOR_X MUL_X UMULH_X
                SDIV_X SDIV_W UDIV_X UDIV_W
                ADD_IMM ADD_IMM_64 SUB_IMM SUB_IMM_64
                CMP_IMM CMP_IMM_64
                UBFM UBFM_W SBFM SBFM_W
                MOVZ_32 MOVZ_64 MOVK_32 MOVK_64
                MOV_X MOV_W MOV_SP SUB_SP ADD_SP
                LDRB LDRSB LDRH LDRSH LDR_32 LDR_64
                STRB STRH STR_32 STR_64
                LDRB_REG LDRSB_REG LDRH_REG LDRSH_REG
                LDR_32_REG LDR_64_REG
                STRB_REG STRH_REG STR_32_REG STR_64_REG
                LDR_LIT LDR_LIT_64
                STP_PRE STP_POST LDP_PRE LDP_POST
                FLDR_32 FLDR_64 FSTR_32 FSTR_64
                FLDR_32_REG FLDR_64_REG FSTR_32_REG FSTR_64_REG
                CMP_REG CSINC
                FABS_32 FNEG_32 FSQRT_32 FMOV_32
                FMOV_GP2F_32 FMOV_GP2F_64
                FCMP_32 FCMP_64 FP_SZ
                FADD FSUB FMUL FDIV FMIN FMAX
                SCVTF_D_X FCVTZS_X_D
                SF UXTX_OPT UXTB
                BRK SVC
                FCB_RESUME_OFF
            ]
        ]
    );
    our @EXPORT_OK = @{ $EXPORT_TAGS{all} };
    our @EXPORT    = @{ $EXPORT_TAGS{all} };

    # ARM64 Register Aliases
    use constant {
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

        # Control flow
        B    => 0x14000000,    # Unconditional branch:           00 0101 1 imm26
        BL   => 0x94000000,    # Branch and link:                10 0101 1 imm26
        BLR  => 0xD63F0000,    # Branch and link to register:    1101011 0001 11111 000000 Rn 00000
        BR   => 0xD61F0000,    # Branch to register:             1101011 0000 11111 000000 Rn 00000
        RET  => 0xD65F03C0,    # Return:                         1101011 0010 11111 000000 11111 00000
        ADR  => 0x10000000,    # ADR:                            immlo(2) 10000 immhi(19) Rd
        ADRP => 0x90000000,    # ADRP (page-granular):           immlo(2) 10000 immhi(19) Rd
        CBZ  => 0xB4000000,    # Compare and branch if zero:     sf 011010 0 imm19 Rt (sf=0 W, sf=1 X)
        CBNZ => 0xB5000000,    # Compare and branch if not zero: sf 011010 1 imm19 Rt (sf=0 W, sf=1 X)

        # Data Processing - Register (W = 32-bit)
        ADD_W => 0x0B000000,    # ADD W:  000 01011 00 Rm imm6 000000 Rn Rd
        SUB_W => 0x4B000000,    # SUB W:  010 01011 00 Rm imm6 000000 Rn Rd
        AND_W => 0x0A000000,    # AND W:  000 01010 00 Rm imm6 000000 Rn Rd
        ORR_W => 0x2A000000,    # ORR W:  010 01010 00 Rm imm6 000000 Rn Rd
        EOR_W => 0x4A000000,    # EOR W:  100 01010 00 Rm imm6 000000 Rn Rd
        MUL_W => 0x1B007C00,    # MUL W:  000 01111 01 Rm 11111 000000 Rn Rd

        # Data Processing - Register (X = 64-bit)
        ADD_X     => 0x8B000000,    # ADD X:  100 01011 00 Rm imm6 000000 Rn Rd
        ADD_X_EXT => 0x8B200000,    # ADD X (extended): 100 01011 001 Rm opt S 0000 Rn Rd
        UXTX_OPT  => 0b011,         # UXTX opt field (LSL = 3)
        SUB_X     => 0xCB000000,    # SUB X:  110 01011 00 Rm imm6 000000 Rn Rd
        ADCS_X    => 0x9A000000,    # ADC X:  100 11010 00 Rm 000000 Rn Rd (Alias name kept for compatibility)
        SBCS_X    => 0xDA000000,    # SBC X:  110 11010 00 Rm 000000 Rn Rd (Alias name kept for compatibility)
        AND_X     => 0x8A000000,    # AND X:  100 01010 00 Rm imm6 000000 Rn Rd
        ORR_X     => 0xAA000000,    # ORR X:  101 01010 00 Rm imm6 000000 Rn Rd
        EOR_X     => 0xCA000000,    # EOR X:  110 01010 00 Rm imm6 000000 Rn Rd
        MUL_X     => 0x9B007C00,    # MUL X:  100 01111 01 Rm 11111 000000 Rn Rd
        UMULH_X   => 0x9BC07C00,    # UMULH X: 101 01111 10 Rm 11111 000000 Rn Rd
        SDIV_X    => 0x9AC00C00,    # SDIV X: 100 01101 0110 Rm 000011 Rn Rd
        SDIV_W    => 0x1AC00C00,    # SDIV W: 000 01101 0110 Rm 000011 Rn Rd
        UDIV_X    => 0x9AC00800,    # UDIV X: 100 01101 0110 Rm 000000 Rn Rd
        UDIV_W    => 0x1AC00800,    # UDIV W: 000 01101 0110 Rm 000000 Rn Rd

        # Data Processing - Immediate: ADD / SUB / CMP
        ADD_IMM    => 0x11000000,    # ADD IMM (dynamic SF): sf 100010 shift(1) imm12 Rn Rd
        ADD_IMM_64 => 0x91000000,    # ADD IMM 64-bit: 10 0100010 shift(1) imm12 Rn Rd
        SUB_IMM    => 0x51000000,    # SUB IMM (dynamic SF): sf 110010 shift(1) imm12 Rn Rd
        SUB_IMM_64 => 0xD1000000,    # SUB IMM 64-bit: 11 0100010 shift(1) imm12 Rn Rd
        CMP_IMM    => 0x7100001F,    # CMP IMM (dynamic SF): sf 1110101 shift(1) imm12 Rn 11111
        CMP_IMM_64 => 0xF100001F,    # CMP IMM 64-bit: 11 1100010 shift(1) imm12 Rn 11111
        CMP_REG    => 0x6B00001F,    # CMP REG: sf 01011110 Rm 0 Rn 11111

        # Data Processing - Immediate: Bitfield (shift / extract)
        UBFM   => 0xD3400000,        # UBFM 64-bit: 11 0100110 1 Rn immr imms Rd
        UBFM_W => 0x53400000,        # UBFM 32-bit: 01 0100110 0 Rn immr imms Rd
        SBFM   => 0x93400000,        # SBFM 64-bit: 10 0100110 1 Rn immr imms Rd
        SBFM_W => 0x13400000,        # SBFM 32-bit: 00 0100110 0 Rn immr imms Rd

        # Data Processing - Immediate: Move
        MOVZ_32 => 0x52800000,       # MOVZ 32-bit: 01 0100101 hw(2) imm16 Rd
        MOVZ_64 => 0xD2800000,       # MOVZ 64-bit: 11 0100101 hw(2) imm16 Rd
        MOVK_32 => 0x72800000,       # MOVK 32-bit: 01 1100101 hw(2) imm16 Rd
        MOVK_64 => 0xF2800000,       # MOVK 64-bit: 11 1100101 hw(2) imm16 Rd
        MOV_X   => 0xAA0003E0,       # MOV X: (ORR Xd, XZR, Xm): 10 101010000 Rm 000000 11111 Rd
        MOV_W   => 0x2A0003E0,       # MOV W: (ORR Wd, WZR, Wm): 00 101010000 Rm 000000 11111 Rd

        # Data Processing - SP Register (stack pointer operations)
        SUB_SP => 0xD10003FF,        # SUB SP: 11 0100010 shift imm12 Rn=11111 Rd=11111
        ADD_SP => 0x910003FF,        # ADD SP: 10 0100010 shift imm12 Rn=11111 Rd=11111
        MOV_SP => 0x910003E0,        # MOV SP (ADD Xd, SP, #0): 10 0100010 shift(0) 000000 Rn=11111 Rd

        # Load/Store - Unsigned Offset (byte/half/word/double)
        LDRB   => 0x39400000,        # LDRB:  11 111 0 01 01 imm12 Rn Rt
        LDRSB  => 0x39800000,        # LDRSB: sf 11 111 0 01 11 imm12 Rn Rt (S=1 sign-ext to 64)
        LDRH   => 0x79400000,        # LDRH:  11 111 0 01 01 imm12 Rn Rt (size=10b)
        LDRSH  => 0x79800000,        # LDRSH: sf 11 111 0 01 11 imm12 Rn Rt (size=10b, S=1)
        LDR_32 => 0xB9400000,        # LDR 32: 10 111 0 01 01 imm12 Rn Rt
        LDR_64 => 0xF9400000,        # LDR 64: 11 111 0 01 01 imm12 Rn Rt
        STRB   => 0x39000000,        # STRB:  11 111 0 00 00 imm12 Rn Rt
        STRH   => 0x79000000,        # STRH:  11 111 0 00 00 imm12 Rn Rt (size=10b)
        STR_32 => 0xB9000000,        # STR 32: 10 111 0 00 00 imm12 Rn Rt
        STR_64 => 0xF9000000,        # STR 64: 11 111 0 00 00 imm12 Rn Rt

        # Load/Store - Register Offset
        LDRB_REG   => 0x38408000,    # LDRB_REG:  11 111 0 00 01 1 S 10 Rm 0 Rn Rt
        LDRSB_REG  => 0x38C08000,    # LDRSB_REG: 11 111 0 00 01 1 S 10 Rm 01 Rn Rt
        LDRH_REG   => 0x78408000,    # LDRH_REG:  11 111 0 00 01 1 S 10 Rm 0 Rn Rt  (size=10b)
        LDRSH_REG  => 0x78C08000,    # LDRSH_REG: 11 111 0 00 01 1 S 10 Rm 01 Rn Rt  (size=10b)
        LDR_32_REG => 0xB8408000,    # LDR 32 REG: 10 111 0 00 01 1 0 10 Rm 0 Rn Rt
        LDR_64_REG => 0xF8408000,    # LDR 64 REG: 11 111 0 00 01 1 0 10 Rm 0 Rn Rt
        STRB_REG   => 0x38208000,    # STRB_REG:  11 111 0 00 00 1 0 10 Rm 0 Rn Rt
        STRH_REG   => 0x78208000,    # STRH_REG:  11 111 0 00 00 1 0 10 Rm 0 Rn Rt  (size=10b)
        STR_32_REG => 0xB8208000,    # STR 32 REG: 10 111 0 00 00 1 0 10 Rm 0 Rn Rt
        STR_64_REG => 0xF8208000,    # STR 64 REG: 11 111 0 00 00 1 0 10 Rm 0 Rn Rt

        # Load/Store - Pair (pre/post-index)
        STP_PRE  => 0xA9800000,      # STP pre-index:  10 101 0 01 10 imm7 Rt2 Rn Rt
        STP_POST => 0xA8800000,      # STP post-index: 10 101 0 00 10 imm7 Rt2 Rn Rt
        LDP_PRE  => 0xA8E00000,      # LDP pre-index:  10 101 0 11 11 imm7 Rt2 Rn Rt
        LDP_POST => 0xA8C00000,      # LDP post-index: 10 101 0 10 11 imm7 Rt2 Rn Rt

        # Load/Store - Literal (PC-relative)
        LDR_LIT    => 0x18000000,    # LDR literal 32: 00 011 0 0 imm19 Rt
        LDR_LIT_64 => 0x58000000,    # LDR literal 64: 01 011 0 0 imm19 Rt

        # Float - Load/Store (unsigned offset)
        FLDR_32 => 0xBD400000,       # FLDR 32: 10 111 1 01 01 imm13 Rn Rt
        FLDR_64 => 0xFD400000,       # FLDR 64: 11 111 1 01 01 imm13 Rn Rt
        FSTR_32 => 0xBD000000,       # FSTR 32: 10 111 1 00 01 imm13 Rn Rt
        FSTR_64 => 0xFD000000,       # FSTR 64: 11 111 1 00 01 imm13 Rn Rt

        # Float - Load/Store (register offset)
        FLDR_32_REG => 0xBC408000,    # FLDR 32 REG: 10 111 1 00 11 Rm 10 10 Rn Rt
        FLDR_64_REG => 0xFC408000,    # FLDR 64 REG: 11 111 1 00 11 Rm 10 10 Rn Rt
        FSTR_32_REG => 0xBC208000,    # FSTR 32 REG: 10 111 1 00 11 Rm 00 10 Rn Rt
        FSTR_64_REG => 0xFC208000,    # FSTR 64 REG: 11 111 1 00 11 Rm 00 10 Rn Rt

        # Float - Data Processing (single-precision f32)
        FMOV_32      => 0x1E204000,    # FMOV 32:  000 11110 00 10 0000 010000 Rn Rd
        FMOV_GP2F_32 => 0x1E270000,    # FMOV GP->FP (32): 000 11110 01 0 10001 0 Rm 00000 Rd
        FMOV_GP2F_64 => 0x9E670000,    # FMOV GP->FP (64): 100 11110 01 0 10001 0 Rm 00000 Rd
        FABS_32      => 0x1E20C000,    # FABS:  000 11110 00 10 0000 110000 Rn Rd
        FNEG_32      => 0x1E214000,    # FNEG:  000 11110 00 10 0001 010000 Rn Rd
        FSQRT_32     => 0x1E21C000,    # FSQRT: 000 11110 00 10 0011 110000 Rn Rd
        FCMP_32      => 0x1E202000,    # FCMP 32:  000 11110 00 10 0000 0010 00 Rn 00000
        FCMP_64      => 0x1E602000,    # FCMP 64:  000 11110 01 10 0000 0010 00 Rn 00000
        FP_SZ        => 0x00400000,    # Float size bit (f64 vs f32): bit 22
        FADD         => 0x1E202800,    # FADD:  000 11110 00 (10) (00) Rm 10000 Rn Rd
        FSUB         => 0x1E203800,    # FSUB:  000 11110 00 (10) (01) Rm 10000 Rn Rd
        FMUL         => 0x1E200800,    # FMUL:  000 11110 00 (10) (00) Rm 10000 Rn Rd
        FDIV         => 0x1E201800,    # FDIV:  000 11110 00 (10) (01) Rm 10000 Rn Rd
        FMIN         => 0x1E205800,    # FMIN:  000 11110 00 (10) (10) Rm 10000 Rn Rd
        FMAX         => 0x1E204800,    # FMAX:  000 11110 00 (10) (10) Rm 10000 Rn Rd

        # Float - Int conversion (type-aware, these are 64-bit variants)
        SCVTF_D_X   => 0x9E244000,     # unused (type-aware now)
        FCVTTZS_X_D => 0x9EE80000,     # unused (type-aware now)

        # Condition - CSINC (for cset / csetm patterns)
        CSINC => 0x9A9F07E0,           # CSINC Xd, XZR, XZR, ~cond: 100 11010100 11111 0 cond 1 11111 Xd

        # Immediate/Flag bits
        SF             => 0x80000000,    # SF bit - OR'd into ADD/SUB when operating on 64-bit X regs
        FCB_RESUME_OFF => 112,           # FCB resume offset (function call boundary stack delta)

        # Exception generation
        BRK  => 0xD4200000,              # BRK #imm16: 11010100 001 imm16 00000 00000
        SVC  => 0xD4000001,              # SVC #imm16: 11010100 000 imm16 00000 00001
        UXTB => 0x53001C00               # UXTB Wd, Wn: 01 011010 110 000 000 000 Rn Rd
    };
};
1;
