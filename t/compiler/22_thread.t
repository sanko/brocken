use Test2::V0;
use lib 'lib', '../../lib';
use Brocken::Target::ABI;
use Brocken::Target::OS;
use Brocken::Compiler::RegisterAllocator;
use Brocken::Compiler::InstructionSelector;
use Brocken::Compiler::Lowerer;
use Brocken::Lexer;
use Brocken::Parser;
use Brocken::IR;
use Brocken::AST;
my $host_os = Brocken::Target::OS->detect_host();
my $os      = $host_os->name;
my $arch    = Brocken::Target::OS->detect_arch();
my $emitter = do {
    if    ( $arch eq 'arm64' )   { require Brocken::Target::Architecture::ARM64;   Brocken::Target::Architecture::ARM64->new() }
    elsif ( $arch eq 'riscv64' ) { require Brocken::Target::Architecture::RISCV64; Brocken::Target::Architecture::RISCV64->new() }
    else                         { require Brocken::Target::Architecture::X64;     Brocken::Target::Architecture::X64->new() }
};
my $format = do {
    if    ( $os eq 'win64' ) { require Brocken::Target::Format::PE;    Brocken::Target::Format::PE->new() }
    elsif ( $os eq 'macos' ) { require Brocken::Target::Format::MachO; Brocken::Target::Format::MachO->new() }
    else                     { require Brocken::Target::Format::ELF;   Brocken::Target::Format::ELF->new() }
};
my $abi     = Brocken::Target::ABI->new();
my $lowerer = Brocken::Compiler::Lowerer->new();
subtest 'spawn_thread parsing' => sub {
    my $source = 'spawn_thread sub { print "hi\n"; };';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->isa('Brocken::AST::Stmt::Program'), 'parsed program';
    is scalar( @{ $ast->statements } ), 1, 'one statement';
    ok $ast->statements->[0]->isa('Brocken::AST::Expr::Call'), 'statement is Call';
    is $ast->statements->[0]->name,                'spawn_thread', 'call name is spawn_thread';
    is scalar( @{ $ast->statements->[0]->args } ), 1,              'one argument';
    ok $ast->statements->[0]->args->[0]->isa('Brocken::AST::OOP::AnonSub'), 'arg is AnonSub';
};
subtest 'spawn_thread compile and run' => sub {
    my $source = 'spawn_thread sub { print "ok\n"; };';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    my $cfg    = $lowerer->lower($ast);
    ok $cfg->isa('Brocken::IR::CFG'), 'lowered to CFG';
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping   = $allocator->allocate($cfg);
    my $selector  = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => $emitter, os => $host_os );
    my $text      = $selector->select($cfg);
    my $data      = "ok\n\0";
    my $exe       = 'thread_test' . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    ok -e $exe, 'Executable generated';
    my $prefix = ( $^O eq 'MSWin32' ) ? '.\\' : './';
    my $output = `$prefix$exe`;
    is $output, "ok\n", 'Output matches expected';
    unlink $exe;
};
done_testing;
