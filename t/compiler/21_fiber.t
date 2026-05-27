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
my $arch    = 'x64';

if ( $os eq 'win64' ) {
    $arch = ( ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) =~ /ARM64/i ) ? 'arm64' : 'x64';
}
else {
    my $m = `uname -m` // 'x86_64';
    $arch = 'arm64'   if $m =~ /aarch64|arm64|armv8/i;
    $arch = 'riscv64' if $m =~ /riscv64/i;
    use Config;
    $arch = 'arm64' if ( $Config{archname} // '' ) =~ /aarch64|arm64|apple-arm64/i;
}
my $emitter = do {
    if    ( $arch eq 'arm64' )   { require Brocken::Target::Architecture::ARM64;   Brocken::Target::Architecture::ARM64->new(os_name => $os) }
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
subtest 'Fiber keyword parsing' => sub {
    my $source = 'fiber { yield 1; };';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->isa('Brocken::AST::Stmt::Program'), 'parsed program';
    is scalar( @{ $ast->statements } ), 1, 'one statement';
    ok $ast->statements->[0]->isa('Brocken::AST::Async::FiberBlock'), 'statement is FiberBlock';
    my $fb = $ast->statements->[0];
    ok $fb->body->isa('Brocken::AST::Stmt::Block'), 'fiber body is Block';
    is scalar( @{ $fb->body->statements } ), 1, 'one statement in fiber body';
    ok $fb->body->statements->[0]->isa('Brocken::AST::Async::Yield'),           'body statement is Yield';
    ok defined $fb->body->statements->[0]->expr,                                'yield has expression';
    ok $fb->body->statements->[0]->expr->isa('Brocken::AST::Expr::IntLiteral'), 'yield expr is IntLiteral';
    is $fb->body->statements->[0]->expr->value, 1, 'yield value is 1';
};
subtest 'Fiber with print and yield' => sub {
    my $source = q{fiber { print "hello"; yield 99; };};
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->isa('Brocken::AST::Stmt::Program'), 'parsed program';
    my $cfg = $lowerer->lower($ast);
    ok $cfg->isa('Brocken::IR::CFG'), 'lowered to CFG';
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping   = $allocator->allocate($cfg);
    my $selector  = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => $emitter, os => $host_os );
    my $text      = $selector->select($cfg);
    my $data      = "hello\0";
    my $exe       = 'fiber_test' . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    ok -e $exe, 'Executable generated';

    if ( $^O eq 'MSWin32' ) {
        my $output = `.\\$exe`;
        is $output, "hello", 'Executable printed correct output';
    }
    else {
        my $output = `./$exe`;
        is $output, "hello", 'Executable printed correct output';
    }
    unlink $exe;
};
subtest 'Yield keyword parsing at statement level' => sub {
    my $source = 'yield 42;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->isa('Brocken::AST::Stmt::Program'), 'parsed program';
    is scalar( @{ $ast->statements } ), 1, 'one statement';
    ok $ast->statements->[0]->isa('Brocken::AST::Async::Yield'), 'statement is Yield';
    ok defined $ast->statements->[0]->expr,                      'yield has expression';
    is $ast->statements->[0]->expr->value, 42, 'yield value is 42';
};
subtest 'Yield without expression' => sub {
    my $source = 'yield;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    ok $ast->isa('Brocken::AST::Stmt::Program'),                 'parsed program';
    ok $ast->statements->[0]->isa('Brocken::AST::Async::Yield'), 'statement is Yield';
    ok !defined $ast->statements->[0]->expr,                     'yield has no expression';
};
done_testing;
