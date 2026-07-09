use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Fuzz;
use Brocken::Katsuro::Platform;
no warnings qw[experimental::class];
my $host = Brocken::Katsuro::Platform::parse();

if ( !$host->is_native ) {
    plan skip_all => 'Execution test requires native host';
}

sub test_prog {
    my ( $name, $source, $expected ) = @_;
    my $fuzz   = Brocken::Fuzz->new();
    my $result = $fuzz->test_program( { source => $source, expected => $expected } );
    ok $result->{status} eq 'pass', $name or diag "FAIL: $result->{reason}\nGot: $result->{got}\nSource:\n$source";
}

# This program was extracted from a fuzzer-generated test case
# that passes on x86_64 but fails on RISC-V.
# We progressively add more statements to isolate the failing step.
#
# Program:
#   my i8  $v1 = -31;
#   my i16 $v2 = 60;
#   my i32 $v3 = 41;
#   my i32 $v4 = 4;
#   $v2 = $v2 * $v2;     # 60*60 = 3600 (i16)
#   $v4 = $v2 ^ $v2;     # 3600^3600 = 0 (i32)
#   $v4 = -$v1;           # -(-31) = 31 (i32)
#   $v1 = $v4 | $v2;      # 31|3600 = 3615 -> i8: 3615&0xFF = 31
#   $v2 = $v1 << $v1;     # 31<<31 -> i16: 0
#   $v1 = $v1 / $v3;      # 31/41 = 0 (i8)
#   $v3 = $v3 << $v1;     # 41<<0 = 41 (i32)
#   return $v4;           # 31
#
# Expected exit codes (final & 0xFF):
#   1. init:        return v4=4   -> 4
#   2. after mul:   return v2=3600 -> 16
#   3. after xor:   return v4=0   -> 0
#   4. after neg:   return v4=31  -> 31
#   5. after or:    return v1=31  -> 31  (i8)
#   6. after shl:   return v2=0   -> 0   (i16)
#   7. after div:   return v1=0   -> 0   (i8)
#   8. after shl:   return v3=41  -> 41  (i32)
#   9. final:       return v4=31  -> 31
subtest 'step-by-step trace of fuzzer-generated program' => sub {
    test_prog( '1 init: return v4', <<'PROG', 4 );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
return $v4;
PROG
    test_prog( '2 mul: return v2', <<'PROG', 3600 & 0xFF );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
$v2 = $v2 * $v2;
return $v2;
PROG
    test_prog( '3 xor: return v4', <<'PROG', 0 );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
$v2 = $v2 * $v2;
$v4 = $v2 ^ $v2;
return $v4;
PROG
    test_prog( '4 neg: return v4', <<'PROG', 31 );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
$v2 = $v2 * $v2;
$v4 = $v2 ^ $v2;
$v4 = -$v1;
return $v4;
PROG
    test_prog( '5 or: return v1', <<'PROG', 31 );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
$v2 = $v2 * $v2;
$v4 = $v2 ^ $v2;
$v4 = -$v1;
$v1 = $v4 | $v2;
return $v1;
PROG
    test_prog( '6 shl: return v2', <<'PROG', 0 );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
$v2 = $v2 * $v2;
$v4 = $v2 ^ $v2;
$v4 = -$v1;
$v1 = $v4 | $v2;
$v2 = $v1 << $v1;
return $v2;
PROG
    test_prog( '7 div: return v1', <<'PROG', 0 );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
$v2 = $v2 * $v2;
$v4 = $v2 ^ $v2;
$v4 = -$v1;
$v1 = $v4 | $v2;
$v2 = $v1 << $v1;
$v1 = $v1 / $v3;
return $v1;
PROG
    test_prog( '8 shl: return v3', <<'PROG', 41 );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
$v2 = $v2 * $v2;
$v4 = $v2 ^ $v2;
$v4 = -$v1;
$v1 = $v4 | $v2;
$v2 = $v1 << $v1;
$v1 = $v1 / $v3;
$v3 = $v3 << $v1;
return $v3;
PROG
    test_prog( '9 final: return v4', <<'PROG', 31 );
my i8 $v1 = -31;
my i16 $v2 = 60;
my i32 $v3 = 41;
my i32 $v4 = 4;
$v2 = $v2 * $v2;
$v4 = $v2 ^ $v2;
$v4 = -$v1;
$v1 = $v4 | $v2;
$v2 = $v1 << $v1;
$v1 = $v1 / $v3;
$v3 = $v3 << $v1;
return $v4;
PROG
};
done_testing;
