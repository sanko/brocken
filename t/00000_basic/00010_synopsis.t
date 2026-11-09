use v5.42;
use lib '../../lib', 'lib';
use Brocken;
use Test2::V0;
use IPC::Open3;
use Symbol qw[gensym];

my $brocken = Brocken->new;

my $code = <<'BROCKEN';
sub fib( i64 $n ) :returns(i64) {
    say("Hi");
    if ( $n < 2 ) { return $n; }
    return fib( $n - 1 ) + fib( $n - 2 );
}

return fib( 4 );
BROCKEN

my $module = $brocken->compile($code);
my $funcs  = $brocken->codegen->emit_functions( $module->functions );
my $file   = $brocken->tmpdir . '/fib' . $brocken->ext;
$brocken->linker->write_executable( $file, $funcs, $brocken->platform );

ok( -x $file, 'compiled executable exists and is executable' );

my $err = gensym;
my $pid = open3( my $in, my $out, $err, $file );
close $in;
my $stdout = do { local $/; <$out> };
my $stderr = do { local $/; <$err> };
waitpid( $pid, 0 );
my $exit = $? >> 8;

is( $exit, 3, 'fib(4) returns 3' );
like( $stdout, qr/^(?:Hi\r?\n){9}\z/, 'prints "Hi" exactly 9 times' );

done_testing;
