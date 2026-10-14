use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# `%h{...}` is lowered to the runtime open-addressing table (src/runtime/core.brocken). Keys are NUL-terminated strings;
# values are owned dynamic boxes, so these snippets pin down the observable behaviour: last-write-wins, a missing key
# reading as undef (0 when unboxed), growth rehashing without losing entries, and integer keys being stringified. Wasm is
# excluded because string-literal keys need rodata, which the Wasm backend does not emit yet.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub check {
    my ( $source, $want, $label ) = @_;
    answers( $source, $want, $label, targets => [@native_targets] );
}

subtest 'set then get round-trips a value' => sub {
    check( 'my %h; %h{"a"} = 42; return %h{"a"};', 42, 'one key reads back' );
};

subtest 'a missing key reads as undef (0 unboxed)' => sub {
    check( 'my %h; %h{"a"} = 7; return %h{"absent"};', 0, 'missing key is undef -> 0' );
};

subtest 'two keys keep independent values' => sub {
    check( 'my %h; %h{"a"} = 1; %h{"b"} = 2; return %h{"a"};', 1, 'first key unchanged' );
    check( 'my %h; %h{"a"} = 1; %h{"b"} = 2; return %h{"b"};', 2, 'second key stored separately' );
};

subtest 'a repeated key overwrites in place' => sub {
    check( 'my %h; %h{"x"} = 10; %h{"x"} = 30; return %h{"x"};', 30, 'last write wins' );
    check( 'my %h; %h{"x"} = 10; %h{"y"} = 20; %h{"x"} = 30; return %h{"y"};', 20, 'the other key is untouched' );
};

subtest 'growth past the initial capacity keeps every entry' => sub {
    check(
        'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; %h{"d"}=4; %h{"e"}=5; %h{"f"}=6; %h{"g"}=7; %h{"h"}=8; %h{"i"}=9; return %h{"a"};',
        1, 'the first key survives two rehashes'
    );
    check(
        'my %h; %h{"a"}=1; %h{"b"}=2; %h{"c"}=3; %h{"d"}=4; %h{"e"}=5; %h{"f"}=6; %h{"g"}=7; %h{"h"}=8; %h{"i"}=9; return %h{"i"};',
        9, 'the newest key survives'
    );
};

subtest 'many keys all remain addressable' => sub {
    my $src = 'my %h;';
    my $n   = 64;
    for my $i ( 0 .. $n - 1 ) {
        $src .= qq{ %h{"key$i"} = $i;};
    }
    # Each key holds its index; sum the first 64 natural numbers mod 256 to fold the whole table into one exit status.
    my $sum = 0;
    $sum = ( $sum + $_ ) % 256 for 0 .. $n - 1;
    check( $src . ' my i64 $t = 0;' . join( '', map {" \$t = \$t + %h{\"key$_\"};"} 0 .. $n - 1 ) . ' return $t;',
        $sum, "all $n keys accumulate to $sum mod 256" );
};

subtest 'integer keys are stringified' => sub {
    check( 'my %h; %h{1} = 5; return %h{1};', 5, 'integer key round-trips' );
    check( 'my %h; %h{7} = 3; %h{8} = 4; return %h{7};', 3, 'two integer keys stay distinct' );
};

subtest 'values are read back as dynamic and usable in arithmetic' => sub {
    check( 'my %h; %h{"k"} = 5; return %h{"k"} + 37;', 42, 'a stored value adds' );
};

subtest 'reading a key whose value was overwritten releases the old box' => sub {
    # A 24-key table forces the table through several rehashes while every value is replaced once; a dangling or
    # double-freed box would show up as a wrong sum or a crash.
    check(
        'my %h;' . join( '', map {qq{ %h{"k$_"} = $_;}} 0 .. 23 ) . join( '', map {qq{ %h{"k$_"} = $_ + 100;}} 0 .. 23 )
            . ' return %h{"k23"};',
        123, 'the last replaced value reads back' );
};

done_testing;
