use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../lib', '../lib';
use Brocken::Fuzz;
no warnings qw[experimental::class];
my $fuzz       = Brocken::Fuzz->new( seed => 20260705 );
my $iterations = $ENV{FUZZ_ITERATIONS} // 20;
my %summary;

for my $i ( 1 .. $iterations ) {
    my $program = $fuzz->generate_program( 10, 4 );
    my $result  = $fuzz->test_program($program);
    $summary{ $result->{status} }++;
    ok $result->{status} eq 'pass', "Fuzz #$i" or
        diag "Seed: $result->{seed}, Case: $result->{case_num}, Reason: $result->{reason}\nSource:\n$result->{source}";
}
diag "Summary: " . ( join ', ', map {"$_=$summary{$_}"} sort keys %summary );
done_testing;
