use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Returning a dynamic (boxed) value hands ownership to the caller, so the box has
# to survive the decref of the function's own locals. The exit path increfs the
# return value before running that cleanup, but the incref was gated on a type
# kind of `any` while the IR spells it `dynamic`, so it never ran: the exit decref
# dropped the box's refcount to zero and pushed it onto the free list, and the
# caller received a pointer whose payload slot had already been overwritten with
# the free-list link. Every case below returned 0 before the fix.
sub run_case {
    my ( $src, $want, $name ) = @_;
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile($src);
        my $file   = $brocken->tmpdir . '/boxed_return_' . ( $name =~ s/\W+/_/gr ) . $brocken->ext;
        $brocken->linker->write_executable( $file, $brocken->codegen->emit_functions( $module->functions ), $host );
        system $file;
        is( $? >> 8, $want, $name );
        unlink $file;
    }
}
subtest 'a returned box survives the callee exit decref' => sub {
    run_case( <<'BROCKEN', 8, 'return a local, add in the caller' );
sub mk() -> Any { my $u = 7; return $u; }
my $a = mk();
return $a + 1;
BROCKEN
    run_case( <<'BROCKEN', 10, 'the returned box holds a computed value' );
sub mk() -> Any { my $u = 7; my $v = 9; return $u + $v; }
my $a = mk();
return $a - 6;
BROCKEN
};
subtest 'a box passed through a parameter comes back alive' => sub {
    run_case( <<'BROCKEN', 5, 'identity through an Any parameter' );
sub id(Any $v) -> Any { return $v; }
my $x = 5;
return id($x);
BROCKEN
    run_case( <<'BROCKEN', 11, 'a returned box passed through identity' );
sub id(Any $v) -> Any { return $v; }
sub mk() -> Any { my $u = 11; return $u; }
return id(mk());
BROCKEN
};
subtest 'two calls do not free each others boxes' => sub {
    run_case( <<'BROCKEN', 6, 'two independent Any returns' );
sub mk() -> Any { my $u = 3; return $u; }
my $a = mk();
my $b = mk();
return $a + $b;
BROCKEN
};
done_testing;
