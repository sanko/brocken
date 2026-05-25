use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
use Brocken::Compiler::Lowerer;

my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new(mode => 'modern');
my $lowerer = Brocken::Compiler::Lowerer->new();

my $source = 'my $x = 10 + 2;';
my $ast    = $parser->parse($scanner->scan($source));
my $cfg     = $lowerer->lower($ast);
my $entry   = $cfg->entry_block;
my @instr   = $entry->instructions;

# Expected IR in entry block:
# v0 = 10
# v1 = 2
# v2 = v0 + v1
# store $x = v2
is(scalar @instr, 4, "Should have 4 instructions in entry block");
is($instr[3]->to_string, 'store $x = v2', "Last instruction is store");
is($entry->terminator->isa('Brocken::IR::Return'), 1, "Terminator is a return");

done_testing;
