use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
use Brocken::Parser;
use Brocken::Compiler::Lowerer;

my $lowerer = Brocken::Compiler::Lowerer->new();

my $source = 'my $x = 10 + 2;';
my $lexer  = Brocken::Lexer->new(source => $source);
my $parser = Brocken::Parser->new(lexer => $lexer);
my $ast    = $parser->parse();
my $cfg     = $lowerer->lower($ast);
my $entry   = $cfg->entry_block;
my @instr   = $entry->instructions;

is(scalar @instr, 4, "Should have 4 instructions in entry block");
is($instr[3]->to_string, 'store $x = v2', "Last instruction is store");
is($entry->terminator->isa('Brocken::IR::Return'), 1, "Terminator is a return");

done_testing;
