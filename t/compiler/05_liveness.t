use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
use Brocken::Compiler::Lowerer;
use Brocken::Compiler::LivenessAnalyzer;

my $lowerer = Brocken::Compiler::Lowerer->new();
my $analyzer = Brocken::Compiler::LivenessAnalyzer->new();

subtest 'Simple Liveness' => sub {
    my $source = 'my Int $x = 10; my Int $y = $x + 5; print($y);';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    my $cfg    = $lowerer->lower($ast);
    
    $analyzer->analyze($cfg);
    
    my $entry = $cfg->entry_block;
    # diag $entry->to_string;
    
    # In a linear block:
    # v0 = 10
    # store $x = v0  <-- v0 dies here
    # v1 = load $x
    # v2 = 5
    # v3 = v1 + v2   <-- v1, v2 die here
    # store $y = v3  <-- v3 dies here
    # v4 = load $y
    # call print(v4) <-- v4 dies here
    
    # Actually, liveness analysis at block level:
    # LiveOut of entry is empty (nothing escapes the block)
    # LiveIn of entry is empty (no globals used)
    
    # To really test liveness, we need to check intermediate points or use-defs.
    # But since we only store block-level LiveIn/Out for now:
    my %li = $entry->live_in;
    my %lo = $entry->live_out;
    is scalar(keys %li), 0, 'Entry block LiveIn is empty';
    is scalar(keys %lo), 0, 'Entry block LiveOut is empty';
};

subtest 'Liveness across blocks (Real)' => sub {
    # We need to manually construct a CFG or use code that generates cross-block vregs.
    # Currently our lowerer loads variables into new vregs in each block.
    # To test cross-block liveness, we'd need something like:
    # entry:
    #   v0 = 10
    #   jmp L0
    # L0:
    #   call print(v0)
    
    my $cfg = Brocken::IR::CFG->new();
    my $entry = Brocken::IR::BasicBlock->new(name => 'entry');
    $entry->add_instruction(Brocken::IR::Assign->new(dest => 'v0', lhs => '10', op => '', rhs => ''));
    $entry->set_terminator(Brocken::IR::Jump->new(label => 'L0'));
    $cfg->add_block($entry);
    
    my $l0 = Brocken::IR::BasicBlock->new(name => 'L0');
    $l0->add_instruction(Brocken::IR::Call->new(dest => 'v1', func => 'print', args => ['v0']));
    $l0->set_terminator(Brocken::IR::Return->new(val => 'undef'));
    $cfg->add_block($l0);
    
    $analyzer->analyze($cfg);
    
    my %entry_lo = $entry->live_out;
    ok $entry_lo{v0}, 'v0 is live out of entry';
    
    my %l0_li = $l0->live_in;
    ok $l0_li{v0}, 'v0 is live in to L0';
};

done_testing;
