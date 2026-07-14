package Brocken::Jenny::Codegen::X86_64::Encodings {
    use v5.42;
    use Exporter 'import';
    our %EXPORT_TAGS = (
        all => [
            qw[
                REX_W REX_B
                MOV_EAX_IMM MOV_RM_R MOV_R_RM MOV_IMM_RM
                ARITH_IMM CMP_IMM8 SHIFT_IMM IMUL_IMM
                JMP_REL32 JE JNE RET_BYTE
                POP_BASE PUSH_BASE
            ]
        ]
    );
    our @EXPORT_OK = @{ $EXPORT_TAGS{all} };
    our @EXPORT    = @{ $EXPORT_TAGS{all} };
    use constant {

        # REX Prefix Field Masks (OR'd with base 0x40)
        REX_W => 0x08,    # REX.W (Bit 3) - 64-bit operand size
        REX_B => 0x01,    # REX.B (Bit 0) - Extension of r/m field

        # MOV Variants
        MOV_EAX_IMM => 0xB8,    # MOV reg32/64, imm32/64 (Base value; OR with target reg ID)
        MOV_RM_R    => 0x89,    # MOV r/m, r (FIXED: changed from 0x8B to 0x89; transfers R to RM)
        MOV_R_RM    => 0x8B,    # MOV r, r/m (FIXED: changed from 0x89 to 0x8B; transfers RM to R)
        MOV_IMM_RM  => 0xC7,    # MOV r/m32, imm32 (Sign-extended)

        # Arithmetic & Shifts
        ARITH_IMM => 0x81,      # ALU r/m, imm32 (Used with ModRM for ADD/SUB/AND/OR/XOR/CMP)
        CMP_IMM8  => 0x83,      # CMP/ALU r/m, imm8 (Sign-extended 8-bit immediate)
        SHIFT_IMM => 0xC1,      # Shift r/m, imm8 (Used with ModRM for SHL/SHR/SAR)
        IMUL_IMM  => 0x69,      # IMUL r, r/m, imm32

        # Control flow
        JMP_REL32 => 0xE9,      # JMP rel32 (Near jump relative)
        JE        => 0x84,      # JE rel32 (Second byte of 2-byte opcode 0x0F 0x84; ZF=1)
        JNE       => 0x85,      # JNE rel32 (Second byte of 2-byte opcode 0x0F 0x85; ZF=0)

        # Function Prologue / Epilogue
        RET_BYTE  => 0xC3,      # RET near
        POP_BASE  => 0x58,      # POP r64 Base (OR with target register ID: 0x58 + reg)
        PUSH_BASE => 0x50       # PUSH r64 Base (OR with target register ID: 0x50 + reg)
    };
};
1;
