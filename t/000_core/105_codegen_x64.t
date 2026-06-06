use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Config;
use Brocken;
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::IR;
use Brocken::Core::IRGenerator;
use Brocken::Target::Architecture::X64;
use Brocken::Target::Format::ELF;
use Brocken::Target::Format::MachO;
use Brocken::Target::Format::PE;
use Brocken::Target::Format::DWARF;
use File::Temp;

# Helper to verify standard AMD64 architecture compatibility
sub is_host_x64_linux {
    return 0 if $^O eq 'MSWin32' || $^O eq 'MSWin64' || $^O eq 'darwin';
    return 0 if $^O ne 'linux';

    # Query kernel hardware architecture directly to prevent false matching on ARM/RISCV Linux hosts
    require POSIX;
    my ( $sysname, $nodename, $release, $version, $machine ) = POSIX::uname();
    return ( $machine =~ /x86_64|amd64/i ) ? 1 : 0;
}
subtest 'X64 Assembler Code Generation' => sub {
    my $code   = 'my $x = 10; my $y = $x + 5;';
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $tokens = $lexer->tokenize();
    my $parser = Brocken::Core::Parser->new( tokens => $tokens );
    my @stmts;
    while ( $parser->peek->type ne 'EOF' ) {
        push @stmts, $parser->parse_statement();
    }
    my $generator = Brocken::Core::IRGenerator->new();
    for my $s (@stmts) {
        $generator->lower_statement($s);
    }
    my $blocks = $generator->blocks;
    my $x64    = Brocken::Target::Architecture::X64->new();
    my $t      = Brocken::Target::Triple->new( raw_string => 'x86_64-linux-elf' );
    my $bin    = $x64->assemble( $blocks, $t );
    ok length($bin) > 0, 'successfully generated raw x86-64 machine code bytes';
    is substr( $bin, 0, 1 ), pack( 'C', 0x55 ), 'emitted standard AMD64 push rbp prologue';
    is substr( $bin, -2 ), pack( 'C2', 0xC9, 0xC3 ), 'emitted standard leave/ret epilogue';
};
subtest 'End-to-End Native Execution (Linear Math)' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $t           = Brocken::Target::Triple->new( raw_string => 'x86_64-linux-elf' );
    my $x64         = Brocken::Target::Architecture::X64->new();
    my $bin         = $x64->assemble( $generator->blocks, $t );
    my $elf         = Brocken::Target::Format::ELF->new();
    my $output_file = File::Temp->new( TEMPLATE => 'x64_linux_XXXXX', SUFFIX => '.elf' );
    $output_file->close();    # Close File::Temp handle to release OS locks
    $elf->write_executable( $output_file->filename, $bin, $t );
    ok -e $output_file->filename, 'successfully generated native ELF binary file';

    if ( is_host_x64_linux() ) {
        my $cmd = './' . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 15, 'executed native binary on Linux x86-64 and verified exit code matches calculation (15)';
    }
    else {
        skip_all 'Skipping native execution test on non-Linux-x86_64 host (' . $^O . ' ' . $Config{archname} . ')';
    }
};
subtest 'End-to-End Native Execution (While Loops)' => sub {
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
    my $t           = Brocken::Target::Triple->new( raw_string => 'x86_64-linux-elf' );
    my $x64         = Brocken::Target::Architecture::X64->new();
    my $bin         = $x64->assemble( $generator->blocks, $t );
    my $elf         = Brocken::Target::Format::ELF->new();
    my $output_file = File::Temp->new( TEMPLATE => 'while_test_XXXXX', SUFFIX => '.elf' );
    $output_file->close();    # Close File::Temp handle to release OS locks
    $elf->write_executable( $output_file->filename, $bin, $t );
    ok -e $output_file->filename, 'successfully generated loop ELF binary file';

    if ( is_host_x64_linux() ) {
        my $cmd = "./" . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 50, 'executed native loop binary on Linux x86-64 and verified exit code matches loop logic (50)';
    }
    else {
        skip_all 'Skipping native execution test on non-Linux-x86_64 host (' . $^O . ' ' . $Config{archname} . ')';
    }
};
subtest 'End-to-End Native Parameter Passing' => sub {
    my $code = q{
        class TargetDemo {
            method process(Int $count) {
                my $res = $count + 25;
                $res;
            }
        }
    };
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    $parser->parse_program();
    my $class       = $parser->classes->{TargetDemo};
    my $method      = $class->methods->{process};
    my $generator   = Brocken::Core::IRGenerator->new();
    my $blocks      = $generator->lower_method($method);
    my $t           = Brocken::Target::Triple->new( raw_string => 'x86_64-linux-elf' );
    my $x64         = Brocken::Target::Architecture::X64->new();
    my $bin         = $x64->assemble( $blocks, $t );
    my $elf         = Brocken::Target::Format::ELF->new();
    my $output_file = File::Temp->new( TEMPLATE => 'binary_param_XXXXX', SUFFIX => '.elf' );
    $output_file->close();    # Close File::Temp handle to release OS locks
    $elf->write_executable( $output_file->filename, $bin, $t, 15 );
    ok -e $output_file->filename, 'successfully generated parameter ELF binary file';

    if ( is_host_x64_linux() ) {
        my $cmd = './' . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 40, 'executed native binary with System V argument registers and verified exit code matches parameter addition (40)';
    }
    else {
        skip_all 'Skipping native execution test on non-Linux-x86_64 host (' . $^O . ' ' . $Config{archname} . ')';
    }
};
subtest 'Cross-Platform Mach-O File Generation' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $t           = Brocken::Target::Triple->new( raw_string => 'x86_64-macos-macho' );
    my $x64         = Brocken::Target::Architecture::X64->new();
    my $bin         = $x64->assemble( $generator->blocks, $t );
    my $macho       = Brocken::Target::Format::MachO->new();
    my $output_file = File::Temp->new( TEMPLATE => 'macho_XXXXX', SUFFIX => '.macho' );
    $output_file->close();    # Close File::Temp handle to release OS locks
    $macho->write_executable( $output_file->filename, $bin, $t );
    ok( -e $output_file->filename, 'successfully generated macOS Mach-O 64-bit binary file' );
    open my $fh, '<', $output_file->filename or die $!;
    binmode $fh;
    read $fh, my $hdr, 4;
    is unpack( 'L', $hdr ), 0xfeedfacf, 'file starts with Mach-O 64-bit feedfacf header magic';
    close $fh;
};
subtest 'Cross-Platform PE File Generation' => sub {
    my $code      = 'my $x = 10; my $y = $x + 5;';
    my $lexer     = Brocken::Core::Lexer->new( source => $code );
    my $parser    = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $generator = Brocken::Core::IRGenerator->new();
    while ( $parser->peek->type ne 'EOF' ) {
        $generator->lower_statement( $parser->parse_statement() );
    }
    my $t           = Brocken::Target::Triple->new( raw_string => 'x86_64-windows-pe' );
    my $x64         = Brocken::Target::Architecture::X64->new();
    my $bin         = $x64->assemble( $generator->blocks, $t );
    my $pe          = Brocken::Target::Format::PE->new();
    my $output_file = File::Temp->new( TEMPLATE => 'crossXXXXX', SUFFIX => '.exe' );
    $output_file->close();    # Close File::Temp handle to release OS locks
    $pe->write_executable( $output_file->filename, $bin, $t );
    ok -e $output_file->filename, 'successfully generated Windows PE x64 binary file';
    open my $fh, '<', $output_file->filename or die $!;
    binmode $fh;
    read $fh, my $hdr, 2;
    is $hdr, 'MZ', 'file starts with MS-DOS MZ header magic';
    close $fh;
};
subtest 'DWARF v4 Line Table Compilation (-g1)' => sub {
    my $dwarf = Brocken::Target::Format::DWARF->new();

    # Test LEB128 Compression (TDD math checks)
    my $uleb = $dwarf->encode_uleb128(624485);
    is $uleb, pack( 'C*', 0xE5, 0x8E, 0x26 ), 'ULEB128 compresses 624485 correctly';
    my $sleb = $dwarf->encode_sleb128(-624485);
    is $sleb, pack( 'C*', 0x9B, 0xF1, 0x59 ), 'SLEB128 compresses -624485 correctly';

    # Test Line Program Generation
    my $mappings   = [ { address => 0x401011, line => 2 }, { address => 0x401025, line => 3 }, { address => 0x40103a, line => 5 } ];
    my $line_table = $dwarf->generate_line_table( 'main.brocken', $mappings );
    ok length($line_table) > 0, 'successfully compiled valid .debug_line byte stream';

    # Verify DWARF version (offset 4, size 2) is version 4
    my $ver = unpack 'S', substr $line_table, 4, 2;
    is $ver, 4, 'emitted valid DWARF version 4 line program';
};
subtest 'Multi-Target Decoupled Compilation (Parse Once, Lower N Times)' => sub {
    my $code    = 'my $x = 10; my $y = $x + 5;';
    my $brocken = Brocken->new();

    # Phase 1: Parse ONCE
    $brocken->parse( $code, 'shared_compile.brocken' );
    ok defined $brocken->blocks, 'successfully parsed and cached target-independent IR blocks';

    # Phase 2: Lower to multiple executable architectures & shared libraries
    my $elf_bin   = File::Temp->new( TEMPLATE => 'temp_elfXXXXX',   SUFFIX => '' );
    my $pe_bin    = File::Temp->new( TEMPLATE => 'temp_peXXXXX',    SUFFIX => '.exe' );
    my $macho_bin = File::Temp->new( TEMPLATE => 'temp_machoXXXXX', SUFFIX => '' );
    my $so_lib    = File::Temp->new( TEMPLATE => 'temp_soXXXXX',    SUFFIX => '' );
    my $dll_lib   = File::Temp->new( TEMPLATE => 'tempdll_XXXXX',   SUFFIX => '.dll' );
    my $dylib_lib = File::Temp->new( TEMPLATE => 'tempdylib_XXXXX', SUFFIX => '.dylib' );
    $elf_bin->close();
    $pe_bin->close();
    $macho_bin->close();
    $so_lib->close();
    $dll_lib->close();
    $dylib_lib->close();
    $brocken->write_executable( $elf_bin->filename,   'x86_64-linux-elf' );
    $brocken->write_executable( $pe_bin->filename,    'x86_64-windows-pe' );
    $brocken->write_executable( $macho_bin->filename, 'x86_64-macos-macho' );
    $brocken->write_lib( $dylib_lib->filename, 'x86_64-macos-macho' );
    $brocken->write_lib( $so_lib->filename,    'x86_64-linux-elf' );
    $brocken->write_lib( $dll_lib->filename,   'x86_64-windows-pe' );
    ok -e $elf_bin->filename,   'compiled target-independent IR to ELF executable';
    ok -e $pe_bin->filename,    'compiled target-independent IR to PE executable';
    ok -e $macho_bin->filename, 'compiled target-independent IR to Mach-O executable';
    ok -e $dylib_lib->filename, 'compiled target-independent IR to macOS Mach-O shared library (.dylib)';
    ok -e $so_lib->filename,    'compiled target-independent IR to ELF shared library (.so)';
    ok -e $dll_lib->filename,   'compiled target-independent IR to Windows DLL (.dll)';
};
subtest 'Sugary Brocken API and ELF DWARF Linking' => sub {
    my $code = q{
        my $x = 10;
        my $y = $x + 15;
        $y;
    };
    my $compiler    = Brocken->new( triple => 'x86_64-linux-elf', debug => 1 );
    my $output_file = File::Temp->new( TEMPLATE => 'tempXXXXX' );
    $output_file->close();    # Close File::Temp handle to release OS locks
    $compiler->compile( $code, $output_file->filename );
    ok -e $output_file->filename, 'successfully compiled executable via top-level Brocken API';
    open my $fh, '<', $output_file->filename or die $!;
    binmode $fh;
    seek $fh, 40, 0;
    read $fh, my $shoff_bytes, 8;
    my $e_shoff = unpack 'Q', $shoff_bytes;
    seek $fh, 60, 0;
    read $fh, my $shnum_bytes, 2;
    my $e_shnum = unpack 'S', $shnum_bytes;
    close $fh;
    ok $e_shoff > 0, "ELF Section Header Table is compiled and starts at byte offset $e_shoff on disk";
    is $e_shnum, 4, 'ELF Header successfully linked 4 sections (Null, .text, .debug_line, .shstrtab)';

    if ( is_host_x64_linux() ) {
        my $cmd = "./" . $output_file->filename;
        system($cmd);
        my $exit_code = $? >> 8;
        is $exit_code, 25, 'executed unified Brocken API compiled binary natively and verified exit status (25)';
    }
    else {
        skip_all 'Skipping native execution test on non-Linux-x86_64 host (' . $^O . ' ' . $Config{archname} . ')';
    }
};
subtest 'Dynamic Host and Architecture Detection' => sub {
    my $compiler = Brocken->new();
    my $detected = $compiler->triple;
    ok defined $detected, 'automatically detected host triple: ' . $detected->to_string;

    # Assert Operating System Matches
    if ( $^O eq 'MSWin32' || $^O eq 'MSWin64' ) {
        like $detected->to_string, qr/-windows-pe$/, 'successfully identified host as Windows PE format';
    }
    elsif ( $^O eq 'darwin' ) {
        like $detected->to_string, qr/-macos-macho$/, 'successfully identified host as macOS Mach-O format';
    }
    elsif ( $^O eq 'linux' ) {
        like $detected->to_string, qr/-linux-elf$/, 'successfully identified host as Linux ELF format';
    }

    # Test WoA Emulation Check Override
    local $ENV{PROCESSOR_ARCHITEW6432} = 'ARM64';
    my $woa_triple = Brocken::detect_host_triple();
    like $woa_triple, qr/^arm64-/, 'successfully identified ARM64 target architecture under Windows x64 process emulation';
};
#
done_testing;
