#!/usr/bin/env perl
use v5.42;
use warnings;
use feature qw[class];
no warnings qw[experimental::class];
use Getopt::Long   qw[GetOptions];
use Cwd            qw[abs_path];
use File::Basename qw[dirname];
use lib dirname( abs_path($0) ) . '/../lib';
use Brocken::Fuzz ();
$|++;
my $time_limit = 300;
my $seed;
my $max_ops  = 20;
my $max_vars = 5;
my $count;
my $case_id;
my $help;
GetOptions(
    'time-limit|t=i' => \$time_limit,
    'seed|s=i'       => \$seed,
    'max-ops|o=i'    => \$max_ops,
    'max-vars|v=i'   => \$max_vars,
    'count|c=i'      => \$count,
    'id|i=s'         => \$case_id,
    'help|h'         => \$help
    ) or
    die("Usage: $0 [options]\n");

if ($help) {
    print <<"USAGE";
Usage: $0 [options]

Run the Brocken fuzzer to find compiler bugs.

Options:
  -t, --time-limit SECS   Run for at most SECS seconds (default: 300)
  -s, --seed N            Use specific random seed (default: random)
  -o, --max-ops N         Maximum operations per program (default: 20)
  -v, --max-vars N        Maximum variables per program (default: 5)
  -c, --count N           Run exactly N iterations (instead of time-limited)
  -i, --id HEXID          Replay a specific fuzz case by its hex case_id
  -h, --help              Show this help
USAGE
    exit(0);
}

# Single-case replay mode
if ( defined $case_id ) {
    my $result = Brocken::Fuzz::run_case_id($case_id);
    if ( $result->{status} eq 'pass' ) {
        print "Case $case_id: PASS\n";
        exit(0);
    }
    else {
        print "Case $case_id: FAIL ($result->{reason})\n";
        print "Source:\n$result->{source}\n";
        exit(1);
    }
}
my $fuzz = Brocken::Fuzz->new( defined $seed ? ( seed => $seed ) : (), bail_on_fail => 1, );
if ( defined $count ) {
    my $results = $fuzz->fuzz( $count, $max_ops, $max_vars );
    my $pass    = grep { $_->{status} eq 'pass' } $results->@*;
    my $fail    = grep { $_->{status} ne 'pass' } $results->@*;
    print "Results: $pass pass, $fail fail\n";
    exit( $fail ? 1 : 0 );
}
else {
    eval { $fuzz->fuzz_until_time( $time_limit, $max_ops, $max_vars ); };
    if ( my $err = $@ ) {
        print STDERR "\nFuzzer aborted on failure:\n$err";
        exit(1);
    }
    exit(0);
}
