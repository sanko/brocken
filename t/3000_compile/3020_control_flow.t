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
    if    ( $arch eq 'arm64' )   { require Brocken::Target::Architecture::ARM64; return Brocken::Target::Architecture::ARM64->new( os_name => $os ) }
    elsif ( $arch eq 'riscv64' ) { require Brocken::Target::Architecture::RISCV64; return Brocken::Target::Architecture::RISCV64->new() }
    else                         { require Brocken::Target::Architecture::X64;     return Brocken::Target::Architecture::X64->new() }
}
my $test_counter = 0;

sub compile_and_run {
    my ($source) = @_;
    $test_counter++;
    my $lexer     = Brocken::Lexer->new( source => $source );
    my $parser    = Brocken::Parser->new( lexer => $lexer );
    my $ast       = $parser->parse();
    my $cfg       = $lowerer->lower($ast);
    my $allocator = Brocken::Compiler::RegisterAllocator->new( abi => $abi, arch => $arch );
    my $mapping   = $allocator->allocate($cfg);
    my $selector  = Brocken::Compiler::InstructionSelector->new( arch => $arch, mapping => $mapping, emitter => make_emitter(), os => $host_os );
    my $text      = $selector->select($cfg);
    my $data      = $selector->data_segment();
    my $exe       = 'cf_test' . $test_counter . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    my $output = ( $^O eq 'MSWin32' ) ? `.\\$exe 2>&1` : `./$exe 2>&1`;
    my $exit   = $? >> 8;
    unlink $exe;
    return ( $output, $exit );
}
subtest 'if-true executes then-block' => sub {
    my ( $out, $exit ) = compile_and_run('if (1) { print "yes"; }');
    is $out, 'yes', 'if-true prints then-block';
};
subtest 'if-false skips then-block' => sub {
    my ( $out, $exit ) = compile_and_run('if (0) { print "yes"; }');
    is $out, '', 'if-false prints nothing';
};
subtest 'if-else executes correct branch (true)' => sub {
    my ( $out, $exit ) = compile_and_run('if (1) { print "a"; } else { print "b"; }');
    is $out, 'a', 'if-else true prints then-branch';
};
subtest 'if-else executes correct branch (false)' => sub {
    my ( $out, $exit ) = compile_and_run('if (0) { print "a"; } else { print "b"; }');
    is $out, 'b', 'if-else false prints else-branch';
};
subtest 'unless condition' => sub {
    my ( $out, $exit ) = compile_and_run('unless (0) { print "yes"; }');
    is $out, 'yes', 'unless-false executes block';
};
subtest 'elsif chain' => sub {
    my ( $out, $exit ) = compile_and_run(<<'END');
if (0) { print "a"; }
elsif (1) { print "b"; }
else { print "c"; }
END
    is $out, 'b', 'elsif true executes its block';
};
subtest 'elsif falls through to else' => sub {
    my ( $out, $exit ) = compile_and_run(<<'END');
if (0) { print "a"; }
elsif (0) { print "b"; }
else { print "c"; }
END
    is $out, 'c', 'elsif false falls through to else';
};
subtest 'nested if statements' => sub {
    my ( $out, $exit ) = compile_and_run(<<'END');
if (1) {
    if (1) { print "a"; }
}
END
    is $out, 'a', 'nested if both true executes body';
};
done_testing;
