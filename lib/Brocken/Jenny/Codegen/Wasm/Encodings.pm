package Brocken::Jenny::Codegen::Wasm::Encodings {
    ;
    use v5.42;
    use Exporter 'import';
    our %EXPORT_TAGS = (
        all => [
            qw[
                UNREACHABLE BLOCK END_BLOCK BR BR_IF RETURN CALL LOCAL_GET LOCAL_SET
                I32_LOAD I64_LOAD F32_LOAD F64_LOAD
                I32_LOAD8_U I32_LOAD16_U
                I64_LOAD8_U I64_LOAD16_U I64_LOAD32_U
                I32_STORE I64_STORE F32_STORE F64_STORE
                I32_STORE8 I32_STORE16
                I64_STORE8 I64_STORE16 I64_STORE32
                I32_CONST I64_CONST F32_CONST F64_CONST
                I32_EQZ I32_EQ I32_NE I32_LT_S I32_LT_U I32_GT_S I32_GT_U
                I32_LE_S I32_LE_U I32_GE_S I32_GE_U
                I64_EQZ I64_EQ I64_NE I64_LT_S I64_LT_U I64_GT_S I64_GT_U
                I64_LE_S I64_LE_U I64_GE_S I64_GE_U
                F32_EQ F32_NE F32_LT F32_GT F32_LE F32_GE
                F64_EQ F64_NE F64_LT F64_GT F64_LE F64_GE
                I32_ADD I32_SUB I32_MUL I32_DIV_S I32_DIV_U I32_REM_S I32_REM_U
                I32_AND I32_OR I32_XOR I32_SHL I32_SHR_S I32_SHR_U
                I64_ADD I64_SUB I64_MUL I64_DIV_S I64_DIV_U I64_REM_S I64_REM_U
                I64_AND I64_OR I64_XOR I64_SHL I64_SHR_S I64_SHR_U
                F32_ADD F32_SUB F32_MUL F32_DIV F32_MIN F32_MAX
                F32_ABS F32_NEG F32_COPYSIGN F32_SQRT
                F64_ADD F64_SUB F64_MUL F64_DIV F64_MIN F64_MAX
                F64_ABS F64_NEG F64_COPYSIGN F64_SQRT
                I32_WRAP_I64 I64_EXTEND_I32_S I64_EXTEND_I32_U
                F64_CONVERT_I64_S I64_TRUNC_F64_S
                VALTYPE_I32 VALTYPE_I64 VALTYPE_F32 VALTYPE_F64
            ]
        ]
    );
    our @EXPORT_OK = @{ $EXPORT_TAGS{all} };
    our @EXPORT    = @{ $EXPORT_TAGS{all} };
    use constant {

        # Control
        UNREACHABLE => 0x00,    # unreachable
        BLOCK       => 0x02,    # block <valtype> <bt>
        END_BLOCK   => 0x0B,    # end
        BR          => 0x0C,    # br <labelidx>
        BR_IF       => 0x0D,    # br_if <labelidx>
        RETURN      => 0x0F,    # return
        CALL        => 0x10,    # call <funcidx>

        # Variable
        LOCAL_GET => 0x20,      # local.get <localidx>
        LOCAL_SET => 0x21,      # local.set <localidx>

        # Memory - Load
        I32_LOAD     => 0x28,    # i32.load <align> <offset>
        I64_LOAD     => 0x29,    # i64.load <align> <offset>
        F32_LOAD     => 0x2A,    # f32.load <align> <offset>
        F64_LOAD     => 0x2B,    # f64.load <align> <offset>
        I32_LOAD8_U  => 0x2D,    # i32.load8_u
        I32_LOAD16_U => 0x2F,    # i32.load16_u
        I64_LOAD8_U  => 0x31,    # i64.load8_u
        I64_LOAD16_U => 0x33,    # i64.load16_u
        I64_LOAD32_U => 0x35,    # i64.load32_u

        # Memory - Store
        I32_STORE   => 0x36,     # i32.store <align> <offset>
        I64_STORE   => 0x37,     # i64.store <align> <offset>
        F32_STORE   => 0x38,     # f32.store <align> <offset>
        F64_STORE   => 0x39,     # f64.store <align> <offset>
        I32_STORE8  => 0x3A,     # i32.store8 <align> <offset>
        I32_STORE16 => 0x3B,     # i32.store16 <align> <offset>
        I64_STORE8  => 0x3C,     # i64.store8 <align> <offset>
        I64_STORE16 => 0x3D,     # i64.store16 <align> <offset>
        I64_STORE32 => 0x3E,     # i64.store32 <align> <offset>

        # Constants
        I32_CONST => 0x41,       # i32.const <s32>
        I64_CONST => 0x42,       # i64.const <s64>
        F32_CONST => 0x43,       # f32.const <f32>
        F64_CONST => 0x44,       # f64.const <f64>

        # i32 Comparison
        I32_EQZ  => 0x45,        # i32.eqz
        I32_EQ   => 0x46,        # i32.eq
        I32_NE   => 0x47,        # i32.ne
        I32_LT_S => 0x48,        # i32.lt_s
        I32_LT_U => 0x49,        # i32.lt_u
        I32_GT_S => 0x4A,        # i32.gt_s
        I32_GT_U => 0x4B,        # i32.gt_u
        I32_LE_S => 0x4C,        # i32.le_s
        I32_LE_U => 0x4D,        # i32.le_u
        I32_GE_S => 0x4E,        # i32.ge_s
        I32_GE_U => 0x4F,        # i32.ge_u

        # i64 Comparison
        I64_EQZ  => 0x50,        # i64.eqz
        I64_EQ   => 0x51,        # i64.eq
        I64_NE   => 0x52,        # i64.ne
        I64_LT_S => 0x53,        # i64.lt_s
        I64_LT_U => 0x54,        # i64.lt_u
        I64_GT_S => 0x55,        # i64.gt_s
        I64_GT_U => 0x56,        # i64.gt_u
        I64_LE_S => 0x57,        # i64.le_s
        I64_LE_U => 0x58,        # i64.le_u
        I64_GE_S => 0x59,        # i64.ge_s
        I64_GE_U => 0x5A,        # i64.ge_u

        # f32 Comparison
        F32_EQ => 0x5B,          # f32.eq
        F32_NE => 0x5C,          # f32.ne
        F32_LT => 0x5D,          # f32.lt
        F32_GT => 0x5E,          # f32.gt
        F32_LE => 0x5F,          # f32.le
        F32_GE => 0x60,          # f32.ge

        # f64 Comparison
        F64_EQ => 0x61,          # f64.eq
        F64_NE => 0x62,          # f64.ne
        F64_LT => 0x63,          # f64.lt
        F64_GT => 0x64,          # f64.gt
        F64_LE => 0x65,          # f64.le
        F64_GE => 0x66,          # f64.ge

        # i32 Arithmetic
        I32_ADD   => 0x6A,       # i32.add
        I32_SUB   => 0x6B,       # i32.sub
        I32_MUL   => 0x6C,       # i32.mul
        I32_DIV_S => 0x6D,       # i32.div_s
        I32_DIV_U => 0x6E,       # i32.div_u
        I32_REM_S => 0x6F,       # i32.rem_s
        I32_REM_U => 0x70,       # i32.rem_u
        I32_AND   => 0x71,       # i32.and
        I32_OR    => 0x72,       # i32.or
        I32_XOR   => 0x73,       # i32.xor
        I32_SHL   => 0x74,       # i32.shl
        I32_SHR_S => 0x75,       # i32.shr_s
        I32_SHR_U => 0x76,       # i32.shr_u

        # i64 Arithmetic
        I64_ADD   => 0x7C,       # i64.add
        I64_SUB   => 0x7D,       # i64.sub
        I64_MUL   => 0x7E,       # i64.mul
        I64_DIV_S => 0x7F,       # i64.div_s
        I64_DIV_U => 0x80,       # i64.div_u
        I64_REM_S => 0x81,       # i64.rem_s
        I64_REM_U => 0x82,       # i64.rem_u
        I64_AND   => 0x83,       # i64.and
        I64_OR    => 0x84,       # i64.or
        I64_XOR   => 0x85,       # i64.xor
        I64_SHL   => 0x86,       # i64.shl
        I64_SHR_S => 0x87,       # i64.shr_s
        I64_SHR_U => 0x88,       # i64.shr_u

        # f32 Arithmetic
        F32_ABS      => 0x8B,    # f32.abs
        F32_NEG      => 0x8C,    # f32.neg
        F32_COPYSIGN => 0x8D,    # f32.copysign
        F32_SQRT     => 0x91,    # f32.sqrt
        F32_ADD      => 0x92,    # f32.add
        F32_SUB      => 0x93,    # f32.sub
        F32_MUL      => 0x94,    # f32.mul
        F32_DIV      => 0x95,    # f32.div
        F32_MIN      => 0x96,    # f32.min
        F32_MAX      => 0x97,    # f32.max

        # f64 Arithmetic
        F64_ABS      => 0x99,    # f64.abs
        F64_NEG      => 0x9A,    # f64.neg
        F64_COPYSIGN => 0x9B,    # f64.copysign
        F64_SQRT     => 0x9F,    # f64.sqrt
        F64_ADD      => 0xA0,    # f64.add
        F64_SUB      => 0xA1,    # f64.sub
        F64_MUL      => 0xA2,    # f64.mul
        F64_DIV      => 0xA3,    # f64.div
        F64_MIN      => 0xA4,    # f64.min
        F64_MAX      => 0xA5,    # f64.max

        # Conversions
        I32_WRAP_I64      => 0xA7,    # i32.wrap_i64
        I64_TRUNC_F64_S   => 0xA8,    # i64.trunc_f64_s
        I64_EXTEND_I32_S  => 0xAC,    # i64.extend_i32_s
        I64_EXTEND_I32_U  => 0xAD,    # i64.extend_i32_u
        F64_CONVERT_I64_S => 0xBB,    # f64.convert_i64_s

        # Value Types (for locals block encoding)
        VALTYPE_I32 => 0x7F,          # i32 type identifier
        VALTYPE_I64 => 0x7E,          # i64 type identifier
        VALTYPE_F32 => 0x7D,          # f32 type identifier
        VALTYPE_F64 => 0x7C           # f64 type identifier
    };
};
1;
