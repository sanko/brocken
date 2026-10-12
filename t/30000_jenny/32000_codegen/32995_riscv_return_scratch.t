use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Lindsay;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Codegen::RISCV64;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# The caller-save stores run *after* the lowerer has placed the outgoing arguments in a0-a7, and the caller-restore
# loads run *before* the caller copies the result out of a0/a1.  Those fixed values are physical registers the
# allocator never assigns, so they are absent from %assignment and the address-scratch picker used to hand one back --
# destroying the argument / return value the moment a spill slot sat past the 12-bit signed displacement range.  The
# picker now keeps a0-a7 out of the scratch while these instructions are encoded, which forces the scratch into t0-t6.
my %rid = (
    a0 => 10,
    a1 => 11,
    a2 => 12,
    a3 => 13,
    a4 => 14,
    a5 => 15,
    a6 => 16,
    a7 => 17,
    t0 => 5,
    t1 => 6,
    t2 => 7,
    t3 => 28,
    t4 => 29,
    t5 => 30,
    t6 => 31,
    sp => 2,
    s0 => 8
);
my $I64   = Brocken::Lindsay::IR::Type::i64();
my $STORE = 0x23;
my $LOAD  = 0x03;
sub word   { return unpack( 'V', substr( $_[0], $_[1] * 4, 4 ) ) }
sub op_of  { $_[0] & 0x7F }
sub rd_of  { ( $_[0] >> 7 ) & 0x1F }
sub rs1_of { ( $_[0] >> 15 ) & 0x1F }
sub rs2_of { ( $_[0] >> 20 ) & 0x1F }

# Encodes one body instruction inside a whole machine function (prologue, body, epilogue, ret) as raw words.
sub encode_body {
    my (@insts)  = @_;
    my $platform = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');
    my $mf       = Brocken::Jenny::MIR::MachineFunction->new( name => 'f', frame_size => 0 );
    my $bb       = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
    $mf->add_block($bb);
    $bb->add_instruction($_) for @insts;
    $bb->add_instruction( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [], comment => 'ret' ) );
    my $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform );
    my ($bytes) = $codegen->_encode( $mf, {}, [], undef, undef, [] );
    return map { word( $bytes, $_ ) } 0 .. length($bytes) / 4 - 1;
}
sub phys { Brocken::Jenny::MIR::MachineOperand->new( kind => 'phys_reg', value => $_[0] ) }
sub mem { Brocken::Jenny::MIR::MachineOperand->new( kind => 'mem', value => { base => 'sp', disp => 3000 }, type => $I64 ) }
subtest 'a caller-restore reload past the 12-bit range scratches t0, not the return register' => sub {
    my @words = encode_body(
        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'load', operands => [ phys('a1'), mem() ], comment => 'caller-restore a1' ) );
    my ($reload) = grep { op_of($_) == $LOAD && rd_of($_) == $rid{a1} } @words;
    ok defined $reload, 'the reload of a1 was emitted';
    is rs1_of($reload),                           $rid{t0}, 'its address scratch is t0';
    is [ grep { rd_of($_) == $rid{a0} } @words ], [],       'nothing is written into the return register';
};
subtest 'a caller-save store past the 12-bit range scratches t0, not an argument register' => sub {
    my @words = encode_body(
        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'store', operands => [ mem(), phys('a5') ], comment => 'caller-save a5' ) );
    my ($save) = grep { op_of($_) == $STORE && rs2_of($_) == $rid{a5} } @words;
    ok defined $save, 'the save of a5 was emitted';
    is rs1_of($save),                             $rid{t0}, 'its address scratch is t0';
    is [ grep { rd_of($_) == $rid{a0} } @words ], [],       'nothing is written into the argument registers';
};
subtest 'a caller-save of the scratch register itself picks the next free t register' => sub {
    my @words = encode_body(
        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'store', operands => [ mem(), phys('t0') ], comment => 'caller-save t0' ) );
    my ($save) = grep { op_of($_) == $STORE && rs2_of($_) == $rid{t0} } @words;
    ok defined $save, 'the save of t0 was emitted';
    is rs1_of($save),                             $rid{t1}, 'its address scratch is t1, never an argument register';
    is [ grep { rd_of($_) == $rid{a0} } @words ], [],       'and a0 is still untouched';
};
subtest 'an ordinary access still scratches from the caller set, minus the return pair' => sub {
    my @words
        = encode_body( Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'load', operands => [ phys('a1'), mem() ], comment => 'plain load' ) );
    my ($reload) = grep { op_of($_) == $LOAD && rd_of($_) == $rid{a1} } @words;
    ok defined $reload, 'the load of a1 was emitted';
    is rs1_of($reload), $rid{t0}, 'its address scratch is t0: a0 is the return register and a1 is the high half, so both stay reserved';
};
done_testing;
