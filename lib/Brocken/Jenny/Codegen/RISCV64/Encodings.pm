package Brocken::Jenny::Codegen::RISCV64::Encodings {
    use v5.42;
    use Exporter 'import';
    our %EXPORT_TAGS = (
        all => [
            qw[
                JAL JALR
                SRAI_B FSGNJ FMINMAX FSQRT FMV_W_X FMV_D_X FCVT_D_L FCVT_L_D
                FP_FMT OP_IMM OP LOAD STORE FLOAD FSTORE FP_OP BCC LUI
                FCB_RESUME_OFF
            ]
        ]
    );
    our @EXPORT_OK = @{ $EXPORT_TAGS{all} };
    our @EXPORT    = @{ $EXPORT_TAGS{all} };
    use constant {

        # RISC-V Opcodes (bits [6:0]) & Control Flow
        JAL  => 0x0000006F,    # JAL:    imm[20|10:1|11|19:12] rd 1101111
        JALR => 0x00008067,    # JALR / RET: imm[11:0]=0 rs1=1(ra) 000 rd=0(zero) 1100111

        # Integer Register-Immediate (OP-IMM: 0010011)
        SRAI_B => 0x40000000,    # SRAI_B: base OP-IMM with funct7=0100000, funct3=101 (SRAI)
        OP_IMM => 0x13,          # OP_IMM: base for ADDI/ANDI/ORI/XORI/SLLI/SRLI/SRAI (0010011)

        # Integer Register-Register (OP: 0110011)
        OP => 0x33,              # OP: base for ADD/SUB/AND/OR/XOR/SLL/SRL/SRA/MUL/DIV/REM (0110011)

        # Load/Store (width encodings via funct3)
        LOAD  => 0x03,           # LOAD: base for LB/LH/LW/LD (0000011, funct3 selects width)
        STORE => 0x23,           # STORE: base for SB/SH/SW/SD (0100011, funct3 selects width)

        # Float Load/Store
        FLOAD  => 0x07,          # FLOAD: base for FLW/FLD (0000111)
        FSTORE => 0x27,          # FSTORE: base for FSW/FSD (0100111)

        # Float Operations (OP-FP: 1010011)
        FP_OP   => 0x53,          # FP_OP: base for FADD.S/FADD.D/FSUB/FMUL/FDIV etc. (1010011)
        FP_FMT  => 0x02000000,    # FP_FMT: single-precision format bit (funct7 base for f32 ops)
        FSGNJ   => 0x20000000,    # FSGNJ: FMV/FNEG/FABS via FSGNJ variants (funct7=0010000)
        FMINMAX => 0x28000000,    # FMINMAX: FMIN/FMAX (funct7=0010100)
        FSQRT   => 0x58000000,    # FSQRT: FSQRT.S/FSQRT.D (funct7=0101100)
        FMV_W_X => 0xF0000000,    # FMV.W.X: float <- int reg (funct7=1111000)
        FMV_D_X => 0xF2000000,    # FMV.D.X: float <- int reg (funct7=1111001)

        # Conversions
        FCVT_D_L => 0xD2201000,    # FCVT.D.L: int64 -> float64 (funct7=1101010, rs2=010)
        FCVT_L_D => 0xC2201000,    # FCVT.L.D: float64 -> int64 (funct7=1100010, rs2=010)

        # Branch & Upper Immediate
        BCC => 0x63,               # BCC: base for BEQ/BNE/BLT/BGE/BLTU/BGEU (1100011, funct3 selects cond)
        LUI => 0x37,               # LUI: load upper 20 bits into rd (0110111)

        # Misc
        FCB_RESUME_OFF => 120      # FCB resume offset (function call boundary stack delta)
    };
};
1;
