use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
use Brocken::Compiler::Lowerer;
my $lowerer = Brocken::Compiler::Lowerer->new();
subtest 'Control Flow Lowering' => sub {
    my $source = 'if (1) { my $x = 10; }';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    my $cfg    = $lowerer->lower($ast);
    my @blocks = $cfg->blocks;

    # Expected CFG:
    # entry:
    #   v0 = 1
    #   jz L1, v0
    # L0:
    #   v1 = 10
    #   store $x = v1
    #   jmp L2
    # L1:
    #   jmp L2
    # L2:
    #   ret undef
    is( scalar @blocks,                    4,           "Should have 4 blocks" );
    is( $blocks[0]->terminator->to_string, 'jz L1, v0', "Entry block ends with conditional branch" );
    is( $blocks[1]->name,                  'L0',        "Second block is then block" );
    is( $blocks[2]->name,                  'L1',        "Third block is else block" );
};
done_testing;
