use Test2::V0;
use lib 'lib';
use Brocken::Target::ABI;
use Brocken::Compiler::RegisterAllocator;
use Brocken::IR;
my $abi = Brocken::Target::ABI->new();
subtest 'X64 Register Allocation' => sub {
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => 'x64' );

    # Manually construct a CFG
    my $cfg   = Brocken::IR::CFG->new();
    my $entry = Brocken::IR::BasicBlock->new( name => 'entry' );
    $entry->add_instruction( Brocken::IR::Assign->new( dest => 'v0', lhs => '10', op => '',  rhs => '' ) );
    $entry->add_instruction( Brocken::IR::Assign->new( dest => 'v1', lhs => '20', op => '',  rhs => '' ) );
    $entry->add_instruction( Brocken::IR::Assign->new( dest => 'v2', lhs => 'v0', op => '+', rhs => 'v1' ) );
    $entry->set_terminator( Brocken::IR::Return->new( val => 'v2' ) );
    $cfg->add_block($entry);
    my $mapping = $allocator->allocate($cfg);
    ok exists $mapping->{v0}, 'v0 mapped';
    ok exists $mapping->{v1}, 'v1 mapped';
    ok exists $mapping->{v2}, 'v2 mapped';

    # Check that they use physical registers
    like $mapping->{v0}, qr/^[a-z0-9]+$/, 'v0 uses physical register';

    # diag explain $mapping;
};
subtest 'ARM64 Register Allocation' => sub {
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => 'arm64' );
    my $cfg       = Brocken::IR::CFG->new();
    my $entry     = Brocken::IR::BasicBlock->new( name => 'entry' );
    $entry->add_instruction( Brocken::IR::Assign->new( dest => 'v0', lhs => '10', op => '', rhs => '' ) );
    $entry->set_terminator( Brocken::IR::Return->new( val => 'v0' ) );
    $cfg->add_block($entry);
    my $mapping = $allocator->allocate($cfg);
    like $mapping->{v0}, qr/^x\d+$/, 'v0 uses ARM64 x-register';
};
done_testing;
