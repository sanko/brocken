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
    my $exe       = 'loop_test' . $test_counter . $host_os->exe_ext;
    $format->write_bin( $exe, $text, $data, $arch, $os );
    my $output = ( $^O eq 'MSWin32' ) ? `.\\$exe 2>&1` : `./$exe 2>&1`;
    my $exit   = $? >> 8;
    unlink $exe;
    return ( $output, $exit );
}
subtest 'while loop executes body multiple times' => sub {
    my $source = <<'END';
my $x = 0;
while ($x < 3) {
    print "a";
    $x = $x + 1;
}
END
    my ( $out, $exit ) = compile_and_run($source);
    is $out, 'aaa', 'while loop executes body 3 times';
};
subtest 'while loop with zero iterations' => sub {
    my ( $out, $exit ) = compile_and_run('while (0) { print "a"; }');
    is $out, '', 'while false skips body';
};
subtest 'for loop basic' => sub {
    my $source = <<'END';
my $i;
for ($i = 0; $i < 3; $i = $i + 1) {
    print "a";
}
END
    my ( $out, $exit ) = compile_and_run($source);
    is $out, 'aaa', 'for loop executes body 3 times';
};
subtest 'last exits loop early' => sub {
    my $source = <<'END';
my $x = 0;
while ($x < 10) {
    print "a";
    if ($x == 1) { last; }
    $x = $x + 1;
}
END
    my ( $out, $exit ) = compile_and_run($source);
    is $out, 'aa', 'last exits after 2 iterations';
};
subtest 'next skips to next iteration' => sub {
    my $source = <<'END';
my $x = 0;
while ($x < 3) {
    $x = $x + 1;
    if ($x == 2) { next; }
    print "a";
}
END
    my ( $out, $exit ) = compile_and_run($source);
    is $out, 'aa', 'next skips iteration 2';
};
subtest 'while with variable condition' => sub {
    my $source = <<'END';
my $count = 0;
my $limit = 2;
while ($count < $limit) {
    print "a";
    $count = $count + 1;
}
END
    my ( $out, $exit ) = compile_and_run($source);
    is $out, 'aa', 'while with var condition';
};
done_testing;
