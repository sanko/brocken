use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Codegen::ARM64;
use Brocken::Jenny::Codegen::RISCV64;
use Brocken::Jenny::Codegen::X86_64;

sub mf_instrs {
    my ($mf) = @_;
    my @instrs;
    for my $bb ( $mf->blocks->@* ) {
        push @instrs, $bb->instructions->@*;
    }
    return @instrs;
}

sub find_raw_mem_ops {
    my ( $mf, $raw ) = @_;
    my %seen_at;
    my $idx = 0;
    for my $inst ( mf_instrs($mf) ) {
        for my $op ( $inst->operands->@* ) {
            next unless $op->kind eq 'mem' && ( $op->value->{raw} // '' ) eq $raw;
            $seen_at{ $op->value->{disp} } = $idx;
        }
        $idx++;
    }
    return %seen_at;
}

sub call_indirect_idx {
    my ($mf) = @_;
    my $idx = 0;
    for my $inst ( mf_instrs($mf) ) {
        return $idx if $inst->opcode eq 'call_indirect';
        $idx++;
    }
    return -1;
}

# The gate trampoline forwards a4 (arg 6) and a5 (arg 7) from where its caller left them into the outgoing argument
# area, so the dispatched function reads them rather than the trampoline's own frame.  On ARM64/RISC-V those stack
# slots are measured at 8*index from the stack pointer (48 and 56); on x86-64 the lighter register count puts the
# first stack argument just above the return address (frame-relative) and the outgoing write under the shadow space on
# Windows.
subtest 'ARM64 forwards a4/a5 through the gate dispatch' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu');
    my $mf       = Brocken::Jenny::Codegen::ARM64->new( platform => $platform )->_build_gate_dispatch_mf;
    my %entry    = find_raw_mem_ops( $mf, 'entry' );
    my %outgoing = find_raw_mem_ops( $mf, 'stack' );
    is( [ sort keys %entry ],    [ 48, 56 ], 'reads a4/a5 from the entry stack at 8*6 and 8*7' );
    is( [ sort keys %outgoing ], [ 48, 56 ], 'writes a4/a5 to the outgoing area at 8*6 and 8*7' );
    ok( $entry{48} < $outgoing{48}             && $entry{56} < $outgoing{56},             'reads happen before the writes' );
    ok( $outgoing{48} < call_indirect_idx($mf) && $outgoing{56} < call_indirect_idx($mf), 'the outgoing writes precede the dispatch call' );
};
subtest 'RISCV64 forwards a4/a5 through the gate dispatch' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');
    my $mf       = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform )->_build_gate_dispatch_mf;
    my %entry    = find_raw_mem_ops( $mf, 'entry' );
    my %outgoing = find_raw_mem_ops( $mf, 'stack' );
    is( [ sort keys %entry ],    [ 48, 56 ], 'reads a4/a5 from the entry stack at 8*6 and 8*7' );
    is( [ sort keys %outgoing ], [ 48, 56 ], 'writes a4/a5 to the outgoing area at 8*6 and 8*7' );
    ok( $entry{48} < $outgoing{48}             && $entry{56} < $outgoing{56},             'reads happen before the writes' );
    ok( $outgoing{48} < call_indirect_idx($mf) && $outgoing{56} < call_indirect_idx($mf), 'the outgoing writes precede the dispatch call' );
};
subtest 'x86_64 SysV forwards a4/a5 through the gate dispatch' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
    my $mf       = Brocken::Jenny::Codegen::X86_64->new( platform => $platform )->_build_gate_dispatch_mf;
    my %entry    = find_raw_mem_ops( $mf, 'entry' );
    my %outgoing = find_raw_mem_ops( $mf, 'stack' );
    is( [ sort keys %entry ],    [ 16, 24 ], 'reads a4/a5 off the entry frame pointer (rbp+16, +24)' );
    is( [ sort keys %outgoing ], [ 0,  8 ],  'writes a4/a5 to the outgoing area at rsp+0, +8' );
    ok( $entry{16} < $outgoing{0}             && $entry{24} < $outgoing{8},             'reads happen before the writes' );
    ok( $outgoing{0} < call_indirect_idx($mf) && $outgoing{8} < call_indirect_idx($mf), 'the outgoing writes precede the dispatch call' );
};
subtest 'x86_64 Windows forwards a4/a5 through the gate dispatch' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');
    my $mf       = Brocken::Jenny::Codegen::X86_64->new( platform => $platform )->_build_gate_dispatch_mf;
    my %entry    = find_raw_mem_ops( $mf, 'entry' );
    my %outgoing = find_raw_mem_ops( $mf, 'stack' );
    is( [ sort keys %entry ],    [ 48, 56 ], 'reads a4/a5 off the entry frame pointer (48, 56)' );
    is( [ sort keys %outgoing ], [ 32, 40 ], 'writes a4/a5 under the shadow space at rsp+32, +40' );
    ok( $entry{48} < $outgoing{32}             && $entry{56} < $outgoing{40},             'reads happen before the writes' );
    ok( $outgoing{32} < call_indirect_idx($mf) && $outgoing{40} < call_indirect_idx($mf), 'the outgoing writes precede the dispatch call' );
};

# The outgoing writes must also reserve the argument area they land in, or the prologue will not leave room for them.
subtest 'the outgoing area is reserved for the forwarded arguments' => sub {
    for my $spec (
        [ 'aarch64-unknown-linux-gnu', 'sp',  64, 'arm64' ],
        [ 'riscv64-unknown-linux-gnu', 'sp',  64, 'riscv64' ],
        [ 'x86_64-pc-linux-gnu',       'rsp', 16, 'x86_64 sysv' ],
        [ 'x86_64-pc-windows-msvc',    'rsp', 48, 'x86_64 win' ],
    ) {
        my ( $plat, $stack_reg, $want, $name ) = @$spec;
        my $class    = platform_class( $plat =~ /^(x86_64)/ ? 'x86_64' : ( $plat =~ /^aarch64/ ? 'arm64' : 'riscv64' ) );
        my $platform = Brocken::Katsuro::Platform::parse($plat);
        my $codegen  = $class->new( platform => $platform );
        my $mf       = $codegen->_build_gate_dispatch_mf;
        is( $codegen->_compute_call_arg_frame( $mf, $stack_reg ), $want, "$name reserves $want bytes for a4/a5" );
    }
};

# The trampoline still encodes end to end, now that the copies and the reserve are in the MIR.
subtest 'the gate dispatch trampoline still encodes' => sub {
    for my $plat ( 'aarch64-unknown-linux-gnu', 'riscv64-unknown-linux-gnu', 'x86_64-pc-linux-gnu' ) {
        my $platform = Brocken::Katsuro::Platform::parse($plat);
        my $codegen  = platform_class( lc $platform->arch )->new( platform => $platform );
        my $mf       = $codegen->_build_gate_dispatch_mf;
        my $blob     = $codegen->_emit_single_mf($mf);
        ok( length( $blob->{bytes} ) > 0, "$plat emits a gate dispatch trampoline (" . length( $blob->{bytes} ) . ' bytes)' );
    }
};

sub platform_class {
    my ($arch) = @_;
    return 'Brocken::Jenny::Codegen::X86_64'  if $arch eq 'x86_64'  || $arch eq 'amd64';
    return 'Brocken::Jenny::Codegen::ARM64'   if $arch eq 'aarch64' || $arch eq 'arm64';
    return 'Brocken::Jenny::Codegen::RISCV64' if $arch eq 'riscv64';
    die "unknown arch $arch";
}
done_testing;
