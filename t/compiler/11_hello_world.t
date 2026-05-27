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

# Detect host platform dynamically
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

# Load arch emitter
my $emitter = do {
    if    ( $arch eq 'arm64' )   { require Brocken::Target::Architecture::ARM64;   Brocken::Target::Architecture::ARM64->new() }
    elsif ( $arch eq 'riscv64' ) { require Brocken::Target::Architecture::RISCV64; Brocken::Target::Architecture::RISCV64->new() }
    else                         { require Brocken::Target::Architecture::X64;     Brocken::Target::Architecture::X64->new() }
};

# Load format based on OS
my $format = do {
    if    ( $os eq 'win64' ) { require Brocken::Target::Format::PE;    Brocken::Target::Format::PE->new() }
    elsif ( $os eq 'macos' ) { require Brocken::Target::Format::MachO; Brocken::Target::Format::MachO->new() }
    else                     { require Brocken::Target::Format::ELF;   Brocken::Target::Format::ELF->new() }
};
my $abi     = Brocken::Target::ABI->new();
my $lowerer = Brocken::Compiler::Lowerer->new();
subtest 'Hello World Generation' => sub {
    my $source    = 'print "Hello, World!";';
    my $lexer     = Brocken::Lexer->new( source => $source );
    my $parser    = Brocken::Parser->new( lexer => $lexer );
    my $ast       = $parser->parse();
    my $cfg       = $lowerer->lower($ast);
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping   = $allocator->allocate($cfg);
    my $selector  = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => $emitter, os => $host_os );
    my $text      = $selector->select($cfg);
    my $data      = "Hello, World!\0";
    my $exe       = 'hello' . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    ok -e $exe, 'Executable generated';

    # Run if on the current platform
    if ( $^O eq 'MSWin32' ) {
        my $output = `.\\$exe`;
        is $output, "Hello, World!", 'Executable printed correct output';
    }
    else {
        my $output = `./$exe`;
        is $output, "Hello, World!", 'Executable printed correct output';
    }
    unlink $exe;
};
done_testing;
