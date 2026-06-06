use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Config;
use Brocken;
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::IR;
use Brocken::Core::IRGenerator;
use Brocken::Target::Architecture::RISC64;
use Brocken::Target::Format::ELF;
use File::Temp;

# Helper to verify standard RISC-V 64 Linux architecture compatibility
sub is_host_riscv64_linux {
    return 0 if $^O ne 'linux';
    require POSIX;
    my ( $sysname, $nodename, $release, $version, $machine ) = POSIX::uname();
    return ( $machine =~ /riscv64/i ) ? 1 : 0;
}
subtest 'RISC64 Assembler Code Generation' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $risc64 = Brocken::Target::Architecture::RISC64->new();
    my $t      = Brocken::Target::Triple->new( raw_string => 'riscv64-linux-elf' );
    my $bin    = $risc64->assemble( $generator->blocks, $t );
    ok length($bin) > 0, 'successfully generated raw RISC64 machine code bytes';
    is substr( $bin, 0, 4 ), pack( 'V', 0xf8010113 ), 'emitted standard RISC-V addi stack allocation prologue';
    is substr( $bin, -4 ), pack( 'V', 0x00008067 ), 'emitted standard RISC-V ret epilogue';
};
subtest 'Cross-Platform RISC64 ELF File Generation' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $t           = Brocken::Target::Triple->new( raw_string => 'riscv64-linux-elf' );
    my $risc64      = Brocken::Target::Architecture::RISC64->new();
    my $bin         = $risc64->assemble( $generator->blocks, $t );
    my $elf         = Brocken::Target::Format::ELF->new();
    my $output_file = File::Temp->new( TEMPLATE => 'risc_elf_XXXXX', SUFFIX => '.elf' );
    $output_file->close();
    $elf->write_executable( $output_file->filename, $bin, $t, undef, undef );
    ok -e $output_file->filename, 'successfully generated RISC64 ELF binary file';
    open my $fh, '<', $output_file->filename or die $!;
    binmode $fh;
    seek $fh, 18, 0;
    read $fh, my $mach, 2;
    is unpack( 'S', $mach ), 243, 'file header contains correct EM_RISCV machine descriptor (243)';
    close $fh;

    if ( is_host_riscv64_linux() ) {
        my $cmd = './' . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 15, 'executed native RISC64 binary on Linux RISC-V and verified exit code matches calculation (15)';
    }
    else {
        skip_all 'Skipping native execution test on non-RISC64-Linux host';
    }
};
subtest 'End-to-End Native Execution (RISC64 Loops)' => sub {
    my $code = q{
        my $x = 5;
        my $y = 0;
        while ($x) {
            $y = $y + 10;
            $x = $x - 1;
        }
        $y;
    };
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $t           = Brocken::Target::Triple->new( raw_string => 'riscv64-linux-elf' );
    my $risc64      = Brocken::Target::Architecture::RISC64->new();
    my $bin         = $risc64->assemble( $generator->blocks, $t );
    my $elf         = Brocken::Target::Format::ELF->new();
    my $output_file = File::Temp->new( TEMPLATE => 'riscv_while_XXXXX', SUFFIX => '.elf' );
    $output_file->close();
    $elf->write_executable( $output_file->filename, $bin, $t );
    ok -e $output_file->filename, 'successfully generated RISC64 loop ELF binary file';

    if ( is_host_riscv64_linux() ) {
        my $cmd = './' . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 50, 'executed native loop binary on Linux RISC-V and verified exit code matches loop logic (50)';
    }
    else {
        skip_all 'Skipping native loop execution test on non-RISC64-Linux host';
    }
};
done_testing;
