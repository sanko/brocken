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

my $format = do {
    if    ( $os eq 'win64' ) { require Brocken::Target::Format::PE;    Brocken::Target::Format::PE->new() }
    elsif ( $os eq 'macos' ) { require Brocken::Target::Format::MachO; Brocken::Target::Format::MachO->new() }
    else                     { require Brocken::Target::Format::ELF;   Brocken::Target::Format::ELF->new() }
};

my $abi     = Brocken::Target::ABI->new();
my $lowerer = Brocken::Compiler::Lowerer->new();

sub make_emitter {
    if    ( $arch eq 'arm64' )   { require Brocken::Target::Architecture::ARM64;   return Brocken::Target::Architecture::ARM64->new(os_name => $os) }
    elsif ( $arch eq 'riscv64' ) { require Brocken::Target::Architecture::RISCV64; return Brocken::Target::Architecture::RISCV64->new() }
    else                         { require Brocken::Target::Architecture::X64;     return Brocken::Target::Architecture::X64->new() }
}

my $test_counter = 0;
sub compile_and_run {
    my ($source) = @_;
    $test_counter++;
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $parser = Brocken::Parser->new( lexer => $lexer );
    my $ast    = $parser->parse();
    my $cfg    = $lowerer->lower($ast);
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping   = $allocator->allocate($cfg);
    my $selector  = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => make_emitter(), os => $host_os );
    my $text      = $selector->select($cfg);
    my $data      = $selector->data_segment();
    my $exe       = 'ps_test' . $test_counter . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    my $output = ( $^O eq 'MSWin32' ) ? `.\\$exe 2>&1` : `./$exe 2>&1`;
    my $exit   = $? >> 8;
    unlink $exe;
    return ( $output, $exit );
}

subtest 'print outputs without newline' => sub {
    my ($out, $exit) = compile_and_run('print "hello";');
    is $out, 'hello', 'print outputs string without newline';
};

subtest 'say outputs with newline' => sub {
    my ($out, $exit) = compile_and_run('say "hello";');
    is $out, "hello\n", 'say outputs string with newline';
};

subtest 'print single string literal' => sub {
    my ($out, $exit) = compile_and_run('print "abc";');
    is $out, 'abc', 'single string literal print works';
};

subtest 'say with no arguments' => sub {
    my ($out, $exit) = compile_and_run('say;');
    is $out, "\n", 'say without args outputs just newline';
};

subtest 'print empty string' => sub {
    my ($out, $exit) = compile_and_run('print "";');
    is $out, '',   'print empty string outputs nothing';
};

subtest 'print variable string' => sub {
    my ($out, $exit) = compile_and_run('my $x = "hello"; print $x;');
    is $out, 'hello', 'print with variable string works';
};

subtest 'say variable string' => sub {
    my ($out, $exit) = compile_and_run('my $x = "world"; say $x;');
    is $out, "world\n", 'say with variable string works';
};

subtest 'print reassigned variable' => sub {
    my ($out, $exit) = compile_and_run('my $x = "first"; $x = "second"; print $x;');
    is $out, 'second', 'print with reassigned variable works';
};

# Known limitation: print with multiple args only prints the first arg
# These are documented missing features for future implementation.

done_testing;
