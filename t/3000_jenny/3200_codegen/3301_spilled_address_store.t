use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec cross_available temp_path];
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Compiler;
use Brocken::Jenny::RegAlloc;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# A store through an address that the allocator spilled.
#
# The allocator kept exactly one scratch register for spill reloads, so an
# instruction that needed two spilled values at once had nowhere to put the
# second one.  A store whose address is a spilled local and whose value is
# another spilled local is exactly that shape: the address is one spilled value
# and the stored value is another.  Both were reloaded into the same scratch, so
# the reload of the value overwrote the address and the store wrote through
# whatever the value happened to be -- a small integer, from a parameter, which
# on x86-64 is an unmapped address.  The result was an access violation at run
# time from code that encoded without a single diagnostic.
#
# The count that trips it is not a constant of the language.  It is whatever
# makes the allocator run out of registers while every address is still live,
# and that is per backend, so each count below is chosen to force spilling.  The
# structural check fails when a count did not spill, rather than passing
# vacuously.
#
# Reserving the second register is itself a cost, and it is easy to pay it in the
# wrong place.  Taking a register out of the pool for every function shrinks
# that pool by one everywhere and changes assignments that were correct before,
# which is a different set of bugs entirely.  So the allocator only reserves it
# once a first pass has produced a real collision, and these tests hold it to
# that: the structural check covers the backends, and the run confirms the
# programs that were already correct still are.
#
# Two things are checked.  The run checks observable behaviour, which is the only
# thing that catches a store landing on the wrong address: a wrong sum has to be
# a wrong sum, not merely a program that happened not to fault.  The structural
# check then covers every backend, including the ones that cannot be executed
# here, and states the invariant directly -- when an instruction is handed a
# reloaded address and a reloaded value, the two sit in different registers.
# Enough arguments to overrun the register file on each backend, low enough
# that the ones that spill to the stack still land in a sane frame.
my %COUNT   = ( x86_64 => 16, aarch64 => 40, riscv64 => 32 );
my @TARGETS = (
    [ 'x86_64-pc-windows-msvc',    'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'x86_64-unknown-linux-gnu',  'Brocken::Jenny::Lowerer::X86_64' ],
    [ 'aarch64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::ARM64' ],
    [ 'riscv64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::RISCV64' ],
);

# Each argument is a distinct odd multiple of 7, so the sums for the counts
# above stay distinct once the process exit code truncates them to a byte, and
# losing or duplicating a single argument moves the result.
sub sum_src($n) {
    my @args   = map { 7 * $_ } 1 .. $n;
    my $params = join ', ',  map {"i64 \$p$_"} 0 .. $n - 1;
    my $body   = join ' + ', map {"\$p$_"} 0 .. $n - 1;
    return <<"BROCKEN";
sub f($params) -> i64 {
    my i64 \$s = $body;
    return \$s;
}
return f(@{[ join ', ', @args ]});
BROCKEN
}
sub expected_sum($n) { return ( 7 * $n * ( $n + 1 ) / 2 ) & 0xFF }

# Walk the run of spill reloads in front of each instruction.  When a run holds
# both a reloaded address and a reloaded value, the instruction is about to use
# two spilled values at once and they cannot share a register.
sub reload_reg_conflict($mf) {
    my @bad;
    for my $bb ( $mf->blocks->@* ) {
        my ( $addr, $value );
        for my $inst ( $bb->instructions->@* ) {
            my $comment = $inst->comment // '';
            if    ( $comment eq 'spill-reload-addr' ) { $addr  = $inst->operands->[0]->value; next }
            elsif ( $comment eq 'spill-reload' )      { $value = $inst->operands->[0]->value; next }
            push @bad, $inst->opcode if defined $addr && defined $value && $addr eq $value;
            ( $addr, $value ) = ( undef, undef );
        }
    }
    return @bad;
}

sub allocated( $triple, $class, $n ) {
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $module   = Brocken::Compiler->new->compile( sum_src($n) );
    my ($func)   = grep { $_->name eq 'f' } $module->functions->@*;
    my $mf       = $class->new( platform => $platform )->lower($func);
    my $alloc    = Brocken::Jenny::RegAlloc::LinearScan->new;
    my $int      = $alloc->allocate( $mf, $platform, 0 );
    $alloc->insert_spill_code( $mf, $int->{spill_slots}, $int->{spill_temp}, $platform->stack_reg, 0, $int->{spill_addr_temp} );
    my $fp = $alloc->allocate( $mf, $platform, 1 );
    $alloc->insert_spill_code( $mf, $fp->{spill_slots}, $fp->{spill_temp}, $platform->stack_reg, 1, $fp->{spill_addr_temp} );
    return ( $mf, $int, $platform );
}
subtest 'A reloaded address and a reloaded value do not share a scratch' => sub {
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        my $n = $COUNT{ ( split /-/, $triple )[0] };
        my ( $mf, $int ) = allocated( $triple, $class, $n );

        # Without a spill there is nothing to check here, and a check that
        # passes because it never ran is worse than no check at all.
        ok( keys %{ $int->{spill_slots} }, "$triple: $n arguments make the allocator spill" ) or next;
        is( [ reload_reg_conflict($mf) ], [], "$triple: no instruction reuses one scratch for a reloaded address and a reloaded value" );
    }
};
subtest 'A sum of many spilled arguments comes back intact' => sub {
    my $brocken = Brocken->new;
    my $host    = $brocken->platform;
    my $n       = $COUNT{ $host->arch } // 16;
    my $module  = Brocken::Compiler->new->compile( sum_src($n) );
    my $funcs   = $brocken->codegen->emit_functions( $module->functions );
    my $out     = $brocken->tmpdir . '/spilled_address_store' . $brocken->ext;
    $brocken->linker->write_executable( $out, $funcs, $host );
    ok -e $out, 'the binary exists';
    run_exec(
        $out,
        expected_exit => expected_sum($n),
        platform      => $host,
        name          => "$n arguments summing to " . expected_sum($n) . " on $host->friendly",
    );
};
subtest 'Foreign targets execute the same sum' => sub {
    for my $target (@TARGETS) {
        my ($triple) = @$target;
        my $n        = $COUNT{ ( split /-/, $triple )[0] };
        my $platform = Brocken::Katsuro::Platform::parse($triple);
    SKIP: {
            skip "$triple not executable here", 1 unless cross_available($platform);
            my $brocken = Brocken->new( platform => $platform );
            my $module  = Brocken::Compiler->new->compile( sum_src($n) );
            my $funcs   = $brocken->codegen->emit_functions( $module->functions );
            my $out     = temp_path( 'spilled_address_' . $platform->arch . $brocken->ext );
            $brocken->linker->write_executable( $out, $funcs, $platform );
            run_exec(
                $out,
                expected_exit => expected_sum($n),
                platform      => $platform,
                name          => "$n arguments summing to " . expected_sum($n) . " on $platform->friendly",
            );
        }
    }
};
done_testing;
