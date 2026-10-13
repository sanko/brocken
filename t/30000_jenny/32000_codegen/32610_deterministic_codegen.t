use v5.42;
use Test2::V0 '!subtest';
use blib;
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Register allocation must be a pure function of the input module.  Perl randomizes hash iteration order per process,
# so an unsorted walk over a liveness or spill set changes which register a value lands in and emits a different
# object on the next run.  That is the "Nondeterministic Codegen" item in TODO section 1; the RISC-V 128-bit divide
# sequence (the largest, spill-heaviest expansion in the backend) was the case that exposed it, so it is the probe.
#
# The hash seed is fixed when a process starts, so the emission has to be repeated in child processes under different
# seeds and compared.  The emitter is written to a file rather than re-exec'ing this test so no Test2 output can leak
# into the captured digest.

my $emitter = <<'PERL';
use v5.42;
use Brocken;
use Brocken::Lindsay;
use Digest::SHA ();
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

my $brocken = Brocken->new( platform => Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu') );
my $codegen = $brocken->codegen;
my $acc     = '';
for my $spec ( [ 'udiv', 100, 7 ], [ 'sdiv', -42, 2 ] ) {
    my ( $op, $a, $b ) = @$spec;
    my $func = Brocken::Lindsay::IR::Function->new( name => 'f_' . $op, return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $lhs = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $a );
    my $rhs = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $b );
    my $div = $op eq 'udiv' ? $builder->build_udiv( $lhs, $rhs, '%r' ) : $builder->build_div( $lhs, $rhs, '%r' );
    $builder->build_ret($div);
    $acc .= $codegen->emit_function($func);
}
print Digest::SHA::sha256_hex($acc), "\n";
PERL

my $tmp     = Brocken->new()->tmpdir;
my $emitter_file = "$tmp/determinism_emitter.pl";
open my $efh, '>', $emitter_file or die "$emitter_file: $!";
print {$efh} $emitter;
close $efh;

sub emit_under_seed {
    my ($seed) = @_;
    local $ENV{PERL_HASH_SEED}    = $seed;
    local $ENV{PERL_PERTURB_KEYS} = 1;
    open my $fh, '-|', $^X, '-Mblib', $emitter_file or die "fork: $!";
    my $out    = do { local $/; <$fh> };
    my $status = close $fh;
    die "emitter failed (status $status)" unless $status;
    chomp $out;
    return $out;
}

my $digest_a = emit_under_seed(0);
my $digest_b = emit_under_seed(1);

like( $digest_a, qr/\A[0-9a-f]{64}\z/, 'the emitter produced a sha256 digest' );
is( $digest_b, $digest_a, 'i128 codegen is byte-identical under different Perl hash seeds' );

unlink $emitter_file;
done_testing;
