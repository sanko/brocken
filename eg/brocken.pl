#~ use blib;
use lib '../lib';
use Brocken;
my $brocken = Brocken->new;
my $module  = $brocken->compile(<<~'BROCKEN');
    say  ("Hi");
    say  ('Hello');
    say  (1.0);
    say  (4);
    exit (1);
    BROCKEN
my $funcs = $brocken->codegen->emit_functions( $module->functions );
my $file =    #$brocken->tmpdir .
    '.' . '/fib' . $brocken->ext;
$brocken->linker->write_executable( $file, $funcs, $brocken->platform );
warn system(

    #'gdb',
    $file
) >> 8;       # exits 55, which is fib(10)
