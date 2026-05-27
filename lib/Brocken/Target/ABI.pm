use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::ABI {

    method cc ( $arch, $name ) {
        return { eq => 0, ne => 1, lt => 0xB, le => 0xD, gt => 0xC, ge => 0xA, z => 0, nz => 1 }->{$name} if $arch eq 'arm64' || $arch eq 'riscv64';
        return { eq => 4, ne => 5, lt => 0xC, le => 0xE, gt => 0xF, ge => 0xD, z => 4, nz => 5 }->{$name};
    }

    method available_registers ($arch) {
        if ( $arch eq 'x64' ) {

            # rax, rcx, rdx, rbx, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15
            # Excluding rsp, rbp for now
            return qw(rax rcx rdx rbx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15);
        }
        elsif ( $arch eq 'arm64' ) {

            # x0-x28
            return map {"x$_"} 0 .. 28;
        }
        elsif ( $arch eq 'riscv64' ) {

            # a0-a7, s1-s11, t0-t6
            return ( map {"a$_"} 0 .. 7 ), ( map {"s$_"} 1 .. 11 ), ( map {"t$_"} 0 .. 6 );
        }
        return ();
    }

    method caller_saved_registers ($arch) {
        if ( $arch eq 'x64' ) {
            return qw(rax rcx rdx rsi rdi r8 r9 r10 r11);
        }
        elsif ( $arch eq 'arm64' ) {
            return map {"x$_"} 0 .. 15;
        }
        elsif ( $arch eq 'riscv64' ) {
            return ( map {"a$_"} 0 .. 7 ), ( map {"t$_"} 0 .. 6 );
        }
        return ();
    }

    method callee_saved_registers ($arch) {
        if ( $arch eq 'x64' ) {
            return qw(rbx r12 r13 r14 r15);
        }
        elsif ( $arch eq 'arm64' ) {
            return map {"x$_"} 19 .. 28;
        }
        elsif ( $arch eq 'riscv64' ) {
            return map {"s$_"} 1 .. 11;
        }
        return ();
    }
}
#
1;
