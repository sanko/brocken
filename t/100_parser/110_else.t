use Test2::V0;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
use Brocken::Compiler::Lowerer;

my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );
my $lowerer = Brocken::Compiler::Lowerer->new();

my $source = q{
    if (1) {
        my $x = 1;
    } elsif (2) {
        my $x = 2;
    } else {
        my $x = 3;
    }
};

my $tokens = $scanner->scan($source);
my $ast    = $parser->parse($tokens);

is scalar @$ast, 1, 'Should have 1 statement (the if chain)';
like $ast->[0]->to_string, qr/if \(1\) \{ \(ASSIGN \$x= 1\) \} else \{ if \(2\) \{ \(ASSIGN \$x= 2\) \} else \{ \(ASSIGN \$x= 3\) \} \}/, 'AST string representation is correct';

my $cfg = $lowerer->lower($ast);
my @all_instrs;
for my $block ( $cfg->blocks ) {
    push @all_instrs, $block->instructions;
    push @all_instrs, $block->terminator if $block->terminator;
}

ok( (grep { $_->isa('Brocken::IR::Branch') } @all_instrs) >= 2, 'Should have at least 2 branches for if/elsif');
ok( (grep { $_->isa('Brocken::IR::Jump') } @all_instrs) >= 2, 'Should have at least 2 jumps for if/elsif/else completion');

done_testing;
