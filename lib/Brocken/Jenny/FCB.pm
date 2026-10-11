# Frame Control Block (FCB) layout.
#
# A fiber suspends by spilling the running context into its FCB and restoring the target's; the
# isolate trampolines and the main-fiber wrapper build the same structure by hand. The field map is
# therefore needed by lowerers, codegens and the shared StackGuard guards alike, and it is derived
# here once instead of being copied as bare offsets into each of them.
#
# The layout has two regions:
#
#   * the register region -- one 8-byte slot per register `ctx_swap` spills, in save order. The fiber
#     register is always in this list and its slot doubles as FCB.self.
#
#   * the named fields after it -- saved_sp, parent, resume_pc, os_thread, stack_limit and, on the
#     backends that route a transfer value through the FCB rather than the return register,
#     transfer_value.
#
# ARM64 and RISC-V list the stack pointer among the registers they spill, so FCB.saved_sp reuses that
# slot; x86-64 has no link register and saves rsp on its own, so saved_sp gets the first slot after
# the register region. Everything after that shifts with it.
#
# Adding a spilled register or a field is a change here and nowhere else: the lowerers, the codegens,
# StackGuard and the ctx_swap encoders all read these values.
package Brocken::Jenny::FCB;
use v5.42;
use Exporter 'import';
our @EXPORT_OK = qw[arch_layout fcb_layout];

# Registers `ctx_swap` spills, lowest offset first. Must match the save loop in each backend's
# ctx_swap encoder, which reads this list rather than repeating it.
my %SAVED = (
    aarch64 => [ ( map { "x$_" } 19 .. 28 ), 'x29', 'x30', 'sp' ],
    riscv64 => [qw[s0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 ra sp]],
    x86_64  => [qw[rbx rbp r12 r13 r14 r15]],
);

# The fiber register, whose slot in the region holds the FCB self-pointer.
my %FIBER_REG = (
    aarch64 => 'x28',
    riscv64 => 's11',
    x86_64  => 'r12',
);

# Backends that hand a fiber transfer/yield value to the resumed fiber through its FCB. x86-64 keeps
# the value in the return register (rax), which never collides with its first argument register, so it
# reserves no slot.
my %TRANSFER = ( aarch64 => 1, riscv64 => 1, x86_64 => 0 );

my %CACHE;

# Layout for an architecture name (e.g. 'aarch64'), with no platform in hand. Used by callers like the
# instruction-encoding tables that need a single field at compile time.
sub arch_layout ($arch) {
    return $CACHE{$arch} if $CACHE{$arch};

    my $saved = $SAVED{$arch}       // die "no FCB layout for architecture '$arch'";
    my $fiber = $FIBER_REG{$arch}   // die "no fiber register for architecture '$arch'";

    my $slot_of = sub ($reg) {
        for my $i ( 0 .. $#$saved ) {
            return $i if $saved->[$i] eq $reg;
        }
        return;
    };

    my $self_idx = $slot_of->($fiber);
    die "fiber register '$fiber' is not in the $arch FCB spill list" unless defined $self_idx;

    my %off = (
        saved => [ $saved->@* ],
        self  => $self_idx * 8,
        regs  => { map { $saved->[$_] => $_ * 8 } 0 .. $#$saved },
    );
    my $cursor = 8 * scalar $saved->@*;

    # The stack pointer keeps its place in the region when the backend spills it there; otherwise it
    # takes the first slot of the named region.
    my $sp_idx = $slot_of->('sp');
    if ( defined $sp_idx ) {
        $off{saved_sp} = $sp_idx * 8;
    }
    else {
        $off{saved_sp} = $cursor;
        $cursor += 8;
    }

    for my $field (qw[parent resume_pc os_thread stack_limit]) {
        $off{$field} = $cursor;
        $cursor += 8;
    }
    if ( $TRANSFER{$arch} ) {
        $off{transfer_value} = $cursor;
        $cursor += 8;
    }
    $off{size} = $cursor;

    return $CACHE{$arch} = \%off;
}

# Layout for a platform object.
sub fcb_layout ($platform) {
    return arch_layout( $platform->arch );
}

1;
