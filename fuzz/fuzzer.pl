use v5.40;
use lib 'lib';
use Brocken::Scanner;
use Brocken::Parser;
use Time::HiRes qw[sleep time];
#
my $scanner = Brocken::Scanner->new();
my $parser  = Brocken::Parser->new( mode => 'modern' );
my @declared_vars;

sub generate_expr {
    my $depth = shift // 0;
    return (qw(10 20 42))[ rand 3 ] if $depth > 2;
    if ( @declared_vars && rand() < 0.5 ) {
        return $declared_vars[ rand @declared_vars ];
    }
    my $op = (qw(+ - * / << >> & | && ||))[ rand 10 ];
    return "(" . generate_expr( $depth + 1 ) . " $op " . generate_expr( $depth + 1 ) . ")";
}

sub generate_code {
    my $choice = rand();

    # 30% Declare variable with attributes
    if ( $choice < 0.3 ) {
        my $var = '$var' . ( scalar @declared_vars );
        push @declared_vars, $var;
        return "my $var :shared = " . generate_expr() . ";";
    }

    # 30% Assign to existing variable
    elsif ( $choice < 0.6 && @declared_vars ) {
        return $declared_vars[ rand @declared_vars ] . " = " . generate_expr() . ";";
    }

    # 20% Control flow (if/elsif/else)
    elsif ( $choice < 0.8 ) {
        my $case = rand();
        if ($case < 0.33) {
            return "if (1) { my \$x_local = " . generate_expr() . "; }";
        } elsif ($case < 0.66) {
            return "if (1) { my \$x_local = " . generate_expr() . "; } else { my \$y_local = " . generate_expr() . "; }";
        } else {
            return "if (1) { my \$x_local = " . generate_expr() . "; } elsif (2) { my \$z_local = " . generate_expr() . "; } else { my \$y_local = " . generate_expr() . "; }";
        }
    }

    # 20% Subroutine with attributes
    else {
        return "sub foo :lvalue { my \$x = " . generate_expr() . "; }";
    }
}
my $start_time = time();
my $timeout    = 60;
say "Starting continuous fuzzer for $timeout seconds. Press Ctrl+C to stop.";
while ( time() - $start_time < $timeout ) {
    @declared_vars = ();
    my $source = "";

    # Build a small module
    for ( 1 .. 10 ) { $source .= generate_code() . " "; }
    eval {
        my $tokens = $scanner->scan($source);
        $parser->parse($tokens);
    };
    if ($@) {
        say "CRASH on: $source";
        say "Error: $@";
        exit 1;
    }
    sleep 0.1;
}
say "Fuzzer finished after $timeout seconds.";
