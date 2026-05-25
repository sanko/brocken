use v5.40;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
use Time::HiRes qw(sleep);
my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );

# Fuzzer: Generates scope-aware code
my @declared_vars;

sub generate_expr {
    my $depth = shift // 0;
    return (qw(10 20 42))[ rand 3 ] if $depth > 2;

    # Use an existing variable if possible
    if ( @declared_vars && rand() < 0.5 ) {
        return $declared_vars[ rand @declared_vars ];
    }
    my $op = (qw(+ - * / << >> & | && || . .. ... ** -> => == != <= >=))[ rand 18 ];
    return "(" . generate_expr( $depth + 1 ) . " $op " . generate_expr( $depth + 1 ) . ")";
}

sub generate_code {
    my $choice = rand();

    # 40% chance to declare a new variable
    if ( $choice < 0.4 ) {
        my $var = '$var' . ( scalar @declared_vars );
        push @declared_vars, $var;
        return "my $var = " . generate_expr() . ";";
    }

    # 40% chance to assign to existing variable
    elsif ( $choice < 0.8 && @declared_vars ) {
        return $declared_vars[ rand @declared_vars ] . " = " . generate_expr() . ";";
    }

    # 20% chance for control flow
    else {
        return "if (1) { my \$x_local = " . generate_expr() . "; }";
    }
}
say "Starting continuous fuzzer. Press Ctrl+C to stop.";
while (1) {

    # Reset for a new fuzzed "file" to keep the AST manageable
    @declared_vars = ();
    my $source = "";
    for ( 1 .. 5 ) { $source .= generate_code() . " "; }
    eval {
        my $tokens = $scanner->scan($source);

        # We only want to test the scanner for now.
        # The parser will fail on many things we haven't implemented yet.
    };
    if ($@) {
        say "CRASH on Scanner: $source";
        say "Error: $@";
        exit 1;
    }
    sleep 0.1;
}
