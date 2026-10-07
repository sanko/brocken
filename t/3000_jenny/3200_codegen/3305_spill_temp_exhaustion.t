use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

package Brocken::Test::RegAlloc::ExhaustedPlatform {
    sub new {
        my ( $class, %regs ) = @_;
        return bless { %regs }, $class;
    }
    sub registers    ( $self, $cat ) { return $self->{"gp_$cat"} // [] }
    sub fp_registers ( $self, $cat ) { return $self->{"fp_$cat"} // [] }
    sub return_register    ($self) { 'x0' }
    sub fp_return_register ($self) { 'v0' }
    sub fiber_reg          ($self) { 'x1' }
}

subtest 'spill temp falls back to a callee register under exhaustion' => sub {
    my $platform = Brocken::Test::RegAlloc::ExhaustedPlatform->new( gp_caller => [], gp_callee => [qw(x8 x9)] );
    my $alloc    = Brocken::Jenny::RegAlloc::LinearScan->new();
    my @intervals = (
        Brocken::Jenny::RegAlloc::LiveInterval->new( name => '%a', start => 0,  end => 5 ),
        Brocken::Jenny::RegAlloc::LiveInterval->new( name => '%b', start => 6,  end => 10 ),
    );
    my $res = $alloc->_linear_scan( undef, \@intervals, $platform, 0, 0 );
    is $res->{spill_temp}, 'x9', 'spill temp drawn from the callee pool';
    is $res->{used_callee}, [qw(x8 x9)], 'fallback spill temp marked callee-saved';
};

subtest 'both register pools empty croaks' => sub {
    my $platform = Brocken::Test::RegAlloc::ExhaustedPlatform->new( gp_caller => [], gp_callee => [] );
    my $alloc    = Brocken::Jenny::RegAlloc::LinearScan->new();
    my @intervals = ();
    my $err = dies { $alloc->_linear_scan( undef, \@intervals, $platform, 0, 0 ) };
    like $err, qr/no register available for the spill temp/, 'no spill temp anywhere dies loudly';
};

done_testing;