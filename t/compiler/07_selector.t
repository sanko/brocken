use Test2::V0;
use lib 'lib';
use Brocken::Target::ABI;
use Brocken::Target::Architecture::X64;
use Brocken::Target::OS;
use Brocken::Compiler::RegisterAllocator;
use Brocken::Compiler::InstructionSelector;
use Brocken::IR;

my $abi = Brocken::Target::ABI->new();
my $emitter = Brocken::Target::Architecture::X64->new();
my $os = Brocken::Target::OS->new(name => 'linux');

subtest 'X64 Instruction Selection' => sub {
    my $allocator = Brocken::Compiler::RegisterAllocator->new(abi => $abi, arch => 'x64');
    
    my $cfg = Brocken::IR::CFG->new();
    my $entry = Brocken::IR::BasicBlock->new(name => 'entry');
    $entry->add_instruction(Brocken::IR::Assign->new(dest => 'v0', lhs => '10', op => '', rhs => ''));
    $entry->add_instruction(Brocken::IR::Load->new(dest => 'v1', var => '$x'));
    $entry->add_instruction(Brocken::IR::Store->new(var => '$y', src => 'v0'));
    $entry->add_instruction(Brocken::IR::Call->new(dest => 'v2', func => 'myfunc', args => ['v0']));
    $entry->set_terminator(Brocken::IR::Return->new(val => 'v2'));
    $cfg->add_block($entry);
    
    my $mapping = $allocator->allocate($cfg);
    my $selector = Brocken::Compiler::InstructionSelector->new(arch => 'x64', mapping => $mapping, emitter => $emitter, os => $os);
    
    my $code = $selector->select($cfg);
    ok length($code) > 0, 'Generated code for Load/Store/Call';
};

done_testing;
