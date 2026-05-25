use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
use Brocken::Compiler::Lowerer;

my $lowerer = Brocken::Compiler::Lowerer->new();

subtest 'While Loop Lowering' => sub {
    my $source = 'while (1) { my $x = 10; }';
    my $lexer  = Brocken::Lexer->new(source => $source);
    my $parser = Brocken::Parser->new(lexer => $lexer);
    my $ast    = $parser->parse();
    my $cfg    = $lowerer->lower($ast);
    my @blocks = $cfg->blocks;

    # Expected CFG:
    # entry:
    #   jmp L0
    # L0: (cond)
    #   v0 = 1
    #   jz L2, v0
    # L1: (body)
    #   v1 = 10
    #   store $x = v1
    #   jmp L0
    # L2: (end)
    #   ret undef
    is(scalar @blocks, 4, "Should have 4 blocks");
    is($blocks[0]->terminator->to_string, 'jmp L0', "Entry block jumps to condition");
    is($blocks[1]->name, 'L0', "Second block is condition block");
    is($blocks[2]->name, 'L1', "Third block is body block");
};

done_testing;
