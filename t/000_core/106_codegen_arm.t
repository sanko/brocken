use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Config;
use Brocken;
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::IR;
use Brocken::Core::IRGenerator;
use Brocken::Target::Architecture::ARM64;
use Brocken::Target::Format::ELF;
use Brocken::Target::Format::MachO;
use Brocken::Target::Format::PE;
use File::Temp qw[tempfile];

# Helper to verify standard Linux ARM64 architecture compatibility
sub is_host_arm64_linux {
    my $arch = $Config{archname} // '';
    if ( ( $ENV{PROCESSOR_ARCHITEW6432} // '' ) eq 'ARM64' || ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) eq 'ARM64' ) {
        $arch = 'arm64';
    }
    return ( $^O eq 'linux' && $arch =~ /arm64|aarch64/i ) ? 1 : 0;
}

# Helper to verify standard Windows ARM64 architecture compatibility
sub is_host_arm64_windows {
    my $arch = $Config{archname} // '';
    if ( ( $ENV{PROCESSOR_ARCHITEW6432} // '' ) eq 'ARM64' || ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) eq 'ARM64' ) {
        return 1 if $^O eq 'MSWin32' || $^O eq 'MSWin64';
    }
    return 0;
}

# Helper to verify standard macOS ARM64 (Apple Silicon) compatibility
sub is_host_arm64_macos {
    require POSIX;
    my ( $sysname, $nodename, $release, $version, $machine ) = POSIX::uname();
    if ( $sysname eq 'Darwin' && $machine eq 'arm64' ) {
        return 1;
    }
    my $arch = $Config{archname} // '';
    return ( $^O eq 'darwin' && $arch =~ /arm64|aarch64/i ) ? 1 : 0;
}
subtest 'ARM64 Assembler Code Generation' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $arm64 = Brocken::Target::Architecture::ARM64->new();
    my $t     = Brocken::Target::Triple->new( raw_string => 'arm64-linux-elf' );
    my $bin   = $arm64->assemble( $generator->blocks, $t );
    ok length($bin) > 0, 'successfully generated raw ARM64 machine code bytes';
    is substr( $bin, 0, 4 ), pack( 'V', 0xa9bf7bfd ), 'emitted standard AArch64 stp stack allocation prologue';
    is substr( $bin, -4 ), pack( 'V', 0xd65f03c0 ), 'emitted standard AArch64 ret epilogue';
};
subtest 'Cross-Platform ARM64 ELF File Generation' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $t           = Brocken::Target::Triple->new( raw_string => 'arm64-linux-elf' );
    my $arm64       = Brocken::Target::Architecture::ARM64->new();
    my $bin         = $arm64->assemble( $generator->blocks, $t );
    my $elf         = Brocken::Target::Format::ELF->new();
    my $output_file = File::Temp->new( TEMPLATE => 'crossXXXXX', SUFFIX => '.elf' );
    $output_file->close();
    $elf->write_executable( $output_file->filename, $bin, $t, undef, undef );
    ok -e $output_file->filename, 'successfully generated ARM64 ELF binary file';
    open my $fh, '<', $output_file->filename or die $!;
    binmode $fh;
    seek $fh, 18, 0;
    read $fh, my $mach, 2;
    is unpack( 'S', $mach ), 183, 'file header contains correct EM_AARCH64 machine descriptor (183)';
    close $fh;

    if ( is_host_arm64_linux() ) {
        my $cmd = './' . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 15, 'executed native ARM64 binary on Linux ARM64 and verified exit code matches calculation (15)';
    }
    else {
        skip_all 'Skipping native execution test on non-ARM64-Linux host';
    }
};
subtest 'Cross-Platform ARM64 PE File Generation' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $t           = Brocken::Target::Triple->new( raw_string => 'arm64-windows-pe' );
    my $arm64       = Brocken::Target::Architecture::ARM64->new();
    my $bin         = $arm64->assemble( $generator->blocks, $t );
    my $pe          = Brocken::Target::Format::PE->new();
    my $output_file = File::Temp->new( TEMPLATE => 'arm_pe_XXXXX', SUFFIX => '.exe' );
    $output_file->close();
    $pe->write_executable( $output_file->filename, $bin, $t, undef, undef );
    ok -e $output_file->filename, 'successfully generated ARM64 PE binary file';

    if ( is_host_arm64_windows() ) {
        my $cmd = $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 15, 'executed native ARM64 binary on Windows ARM64 and verified exit code matches calculation (15)';
    }
    else {
        skip_all 'Skipping native execution test on non-ARM64-Windows host';
    }
};
subtest 'Cross-Platform ARM64 Mach-O File Generation' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $t           = Brocken::Target::Triple->new( raw_string => 'arm64-macos-macho' );
    my $arm64       = Brocken::Target::Architecture::ARM64->new();
    my $bin         = $arm64->assemble( $generator->blocks, $t );
    my $macho       = Brocken::Target::Format::MachO->new();
    my $output_file = File::Temp->new( TEMPLATE => 'arm_macho_XXXXX', SUFFIX => '.macho' );
    $output_file->close();
    $macho->write_executable( $output_file->filename, $bin, $t, undef, undef );
    ok -e $output_file->filename, 'successfully generated macOS ARM64 Mach-O binary file';

    # Assert Mach-O 64-bit magic header (0xfeedfacf)
    open my $fh, '<', $output_file->filename or die $!;
    binmode $fh;
    read $fh, my $hdr, 4;
    is unpack( 'L', $hdr ), 0xfeedfacf, 'file starts with Mach-O 64-bit feedfacf header magic';
    close $fh;
    if ( is_host_arm64_macos() ) {
        open my $mh, '<', $output_file->filename or die $!;
        binmode $mh;
        read $mh, my $hdr_buf, 32;
        my ( $mag, $cpu, $sub, $ft, $ncmds, $szcmds, $fl, $rsvd ) = unpack 'L7 L', $hdr_buf;
        diag sprintf 'header: magic=0x%x cpu=0x%x subtype=0x%x filetype=%d ncmds=%d sizeofcmds=%d flags=0x%x', $mag, $cpu, $sub, $ft, $ncmds,
            $szcmds, $fl;
        for my $i ( 1 .. $ncmds ) {
            read $mh, my $lc_hdr, 8;
            my ( $cmd, $cmdsz ) = unpack 'L2', $lc_hdr;
            my $cname = sprintf '0x%x', $cmd;
            $cname = 'LC_SEGMENT_64'    if $cmd == 0x19;
            $cname = 'LC_BUILD_VERSION' if $cmd == 0x32;
            $cname = 'LC_MAIN'          if $cmd == 0x80000028;
            read $mh, my $lc_body, $cmdsz - 8;
            if ( $cmd == 0x19 && $cmdsz == 152 ) {
                my ( $segname, $vmaddr, $vmsize, $fileoff, $filesz ) = unpack 'a16 Q4', $lc_body;
                diag sprintf '  %s segname=%-16s vmaddr=0x%x vmsize=%d fileoff=%d filesize=%d', $cname, $segname, $vmaddr, $vmsize, $fileoff, $filesz;
            }
            elsif ( $cmd == 0x32 ) {
                my ( $platform, $minos, $sdk, $ntools ) = unpack 'L4', $lc_body;
                diag sprintf '  %s platform=%d minos=0x%x sdk=0x%x ntools=%d', $cname, $platform, $minos, $sdk, $ntools;
            }
            elsif ( $cmd == 0x80000028 ) {
                my ( $entryoff, $stacksize ) = unpack 'Q2', $lc_body;
                diag sprintf '  %s entryoff=%d stacksize=%d', $cname, $entryoff, $stacksize;
            }
            else {
                diag "  $cname cmdsize=$cmdsz";
            }
        }
        close $mh;

        # Ad-hoc sign the binary to satisfy OS security guidelines and prevent SIGKILL
        my $cs_file = $output_file->filename;
        diag sprintf "file size: %d bytes", -s $cs_file;
        my $cs_out  = `codesign -s - -vvv '$cs_file' 2>&1`;
        my $cs_exit = $? >> 8;
        diag "codesign exit code: $cs_exit";
        diag "codesign output: $cs_out";
        if ( $cs_exit != 0 ) {
            diag 'trying codesign -d -vvv...';
            my $cd_out = `codesign -d -vvv '$cs_file' 2>&1`;
            diag 'codesign -d output: ' . $cd_out;
        }
        my $cmd = './' . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        my $exit_sig  = $? & 127;
        diag "execution exit code: $exit_code, signal: $exit_sig" if $exit_code != 15;
        is $exit_code, 15, 'executed native ARM64 binary on macOS Apple Silicon and verified exit code matches calculation (15)';
        unlink $output_file->filename;
    }
    else {
        skip_all 'Skipping native execution test on non-ARM64-macOS host';
    }
};
subtest 'End-to-End Native Execution (ARM64 Loops)' => sub {
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
    my $t           = Brocken::Target::Triple->new( raw_string => 'arm64-linux-elf' );
    my $arm64       = Brocken::Target::Architecture::ARM64->new();
    my $bin         = $arm64->assemble( $generator->blocks, $t );
    my $elf         = Brocken::Target::Format::ELF->new();
    my $output_file = File::Temp->new( TEMPLATE => 'arm_while_XXXXX', SUFFIX => '.elf' );
    $output_file->close();
    $elf->write_executable( $output_file->filename, $bin, $t );
    ok -e $output_file->filename, 'successfully generated ARM64 loop ELF binary file';

    if ( is_host_arm64_linux() ) {
        my $cmd = './' . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 50, 'executed native loop binary on Linux ARM64 and verified exit code matches loop logic (50)';
    }
    else {
        skip_all 'Skipping native loop execution test on non-ARM64-Linux host';
    }
};
#
done_testing;
