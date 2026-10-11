use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Jenny::RegAlloc;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Read-modify-write opcodes read their destination before overwriting it, so a spilled destination has to be reloaded
# before the instruction runs.  The table of such opcodes used the IR spellings `shr`/`sar` for the shift instructions
# instead of the MIR opcodes `lshr`/`ashr`, so a spilled logical or arithmetic shift destination was never reloaded:
# the shift read whatever stale value the reload scratch happened to hold.  `umulh` was absent from both the reload and
# the liveness tables, so its destination was neither reloaded nor kept live across a chain that first mentions it
# through a self-move.

sub vreg($n)          { Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => $n ) }
sub imm($v)           { Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm',      value => $v ) }
sub inst( $op, @ops ) { Brocken::Jenny::MIR::MachineInstruction->new( opcode => $op, operands => [@ops] ) }

my $platform = Brocken->new->platform;

subtest 'A read-modify-write destination is live-in' => sub {
    my $ra = Brocken::Jenny::RegAlloc::LinearScan->new;
    for my $op (qw[shl lshr ashr umulh]) {
        my ( $defd, $used ) = $ra->_scan_insts( [ inst( $op, vreg('%d'), vreg('%s') ) ], 0, $platform );
        ok $used->{'%d'}, "$op reads its destination";
        ok $used->{'%s'}, "$op reads its source";
        ok $defd->{'%d'}, "$op defines its destination";
    }
};

subtest 'A spilled read-modify-write destination is reloaded before and stored after' => sub {
    my $ra = Brocken::Jenny::RegAlloc::LinearScan->new;
    for my $op (qw[lshr ashr shl umulh]) {
        my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'rmw', frame_size => 0 );
        my $bb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
        $mf->add_block($bb);
        $bb->add_instruction( inst( $op, vreg('%d'), imm(3) ) );
        $bb->add_instruction( inst('ret') );
        $ra->insert_spill_code( $mf, { '%d' => 0 }, '%scratch', $platform->stack_reg, 0, undef );
        is [ map { $_->opcode } $bb->instructions->@* ], [ 'load', $op, 'store', 'ret' ],
            "$op reloads its spilled destination and stores it back";
    }
};

done_testing;
