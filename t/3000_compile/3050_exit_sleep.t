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
    my $exe       = 'es_test' . $test_counter . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    my $output;
    my $exit;

    if ( $^O eq 'MSWin32' ) {
        $output = `.\\$exe 2>&1`;
        $exit   = $? >> 8;
    }
    else {
        $output = `./$exe 2>&1`;
        $exit   = $? >> 8;
    }
    if ( $test_counter != 1 ) { unlink $exe; }
    return ( $output, $exit );
}
subtest 'exit stops program execution' => sub {
    my ( $out, $exit ) = compile_and_run('print "before"; exit(0); print "after";');
    is $out, 'before', 'exit stops program (after not printed)';
    ok $out !~ /after/, 'after not in output';
};
subtest 'exit 42 no print' => sub {
    my ( $out, $exit ) = compile_and_run('exit(42);');
    is $exit, 42, 'exit(42) without print returns 42';
};
subtest 'exit 0 no print' => sub {
    my ( $out, $exit ) = compile_and_run('exit(0);');
    ok defined $out, 'exit(0) as sole instruction completes (no hang)';
    is $exit, 0, 'exit code 0 from sole exit(0)';
};
subtest 'exit with non-zero code and print' => sub {
    my ( $out, $exit ) = compile_and_run('print "x"; exit(42);');
    is $out,  'x', 'before exit output visible';
    is $exit, 42,  'exit code 42 is propagated';
};
subtest 'exit code 0 with print' => sub {
    my ( $out, $exit ) = compile_and_run('print "x"; exit(0);');
    is $exit, 0, 'exit code 0 is propagated';
};
subtest 'sleep returns after specified seconds' => sub {
    my $start = time;
    my ( $out, $exit ) = compile_and_run('print "s"; sleep(1); print "ok";');
    my $elapsed = time - $start;
    is $out, 'sok', 'sleep(1) then print works';
    ok $elapsed >= 1, "sleep took at least 1s (took ${elapsed}s)";
};
subtest 'sleep with variable argument' => sub {
    my $start = time;
    my ( $out, $exit ) = compile_and_run('my $t = 1; print "s"; sleep($t); print "ok";');
    my $elapsed = time - $start;
    is $out, 'sok', 'sleep with variable works';
    ok $elapsed >= 1, "sleep took at least 1s (took ${elapsed}s)";
};
done_testing;
