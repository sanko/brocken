use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::ABI;

class Brocken::Katsuro::Platform::ABI::AArch64 : isa(Brocken::Katsuro::Platform::ABI) {

    # ARM64 Procedure Call Standard (AAPCS64)
    # SCRATCH: x0-x15
    # PRESERVED: x19-x28, sp, x29 (fp), x30 (lr)
    method registers( $category = 'available' ) {
        my %data = (
            available => [qw[x0 x1 x2 x3 x4 x5 x6 x7 x9 x10 x11 x12 x13 x14 x15 x20 x21 x22 x23 x24 x25 x26 x27 x28]],
            caller    => [qw[x0 x1 x2 x3 x4 x5 x6 x7 x9 x10 x11 x12 x13 x14 x15]],
            callee    => [qw[x20 x21 x22 x23 x24 x25 x26 x27 x28]]
        );
        return $data{$category} // [];
    }
    method frame_reg()          {'x29'}
    method stack_reg()          {'sp'}
    method param_registers()    { [qw(x0 x1 x2 x3 x4 x5 x6 x7)] }
    method return_register()    {'x0'}
    method fp_return_register() {'v0'}

    # ARM64 FP/SIMD registers (AAPCS64 calling convention)
    # Note: v0-v7 are caller-saved, v8-v15 are callee-saved (only the lower 64 bits)
    method fp_registers( $category = 'available' ) {
        my %data = (
            available => [qw[v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15]],
            caller    => [qw[v0 v1 v2 v3 v4 v5 v6 v7]],
            callee    => [qw[v8 v9 v10 v11 v12 v13 v14 v15]]
        );
        return $data{$category} // [];
    }

    # ARM64 standard DWARF mappings: x0-x30 map to 0-30, sp maps to 31
    method dwarf_reg_num($name) {
        return 31 if $name eq 'sp';
        return $1 if $name =~ /^x(\d+)$/;
        return $1 if $name =~ /^v(\d+)$/;
        return undef;
    }
}
1;
