use v5.38;
use feature 'class';
no warnings qw[experimental::class experimental::builtin];
use Module::Load;
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::IRGenerator;
use Brocken::Target::Triple;

class Brocken {
    field $triple_raw  : param(triple) : reader //= detect_host_triple();
    field $triple      : reader = Brocken::Target::Triple->new( raw_string => $triple_raw );
    field $debug       : param : reader = 0;        # 0: none, 1: line numbers
    field $blocks      : reader = undef;            # Abstract, target-independent basic blocks
    field $source_file : reader = 'main.brocken';

    # Dynamically detects the host's OS, format, and CPU architecture
    sub detect_host_triple() {
        use Config;

        # Detect CPU Architecture via Perl Configuration
        my $arch     = 'x86_64';                  # Standard fallback
        my $archname = $Config{archname} // '';
        if ( $archname =~ /x86_64|amd64/i ) {
            $arch = 'x86_64';
        }
        elsif ( $archname =~ /aarch64|arm64/i ) {
            $arch = 'arm64';
        }

        # Fallback to POSIX::uname() on Unix/macOS to unwrap generic perl configurations
        if ( $^O ne 'MSWin32' && $^O ne 'MSWin64' ) {
            require POSIX;
            my ( $sysname, $nodename, $release, $version, $machine ) = POSIX::uname();
            if ( $machine =~ /arm64|aarch64/i ) {
                $arch = 'arm64';
            }
            elsif ( $machine =~ /riscv64/i ) {
                $arch = 'riscv64';
            }
        }

        # Windows on ARM64 (WoA) Emulation Override:
        # If running an emulated x64 Perl process on ARM64 Windows, PROCESSOR_ARCHITEW6432 holds 'ARM64'
        if ( defined $ENV{PROCESSOR_ARCHITEW6432} && $ENV{PROCESSOR_ARCHITEW6432} eq 'ARM64' ) {
            $arch = 'arm64';
        }
        elsif ( defined $ENV{PROCESSOR_ARCHITECTURE} && $ENV{PROCESSOR_ARCHITECTURE} eq 'ARM64' ) {
            $arch = 'arm64';
        }

        # Detect OS & File Format
        my $os     = 'linux';
        my $format = 'elf';
        if ( $^O eq 'MSWin32' || $^O eq 'MSWin64' ) {
            $os     = 'windows';
            $format = 'pe';
        }
        elsif ( $^O eq 'darwin' ) {
            $os     = 'macos';
            $format = 'macho';
        }
        elsif ( $^O eq 'freebsd' ) {
            $os     = 'freebsd';
            $format = 'elf';
        }
        return "$arch-$os-$format";
    }

    # Parses, optimizes, and compiles raw source into abstract IR once. Target-independent
    method parse ( $source_code, $filename = 'main.brocken' ) {
        $source_file = $filename;

        # Lexical Analysis
        my $lexer  = Brocken::Core::Lexer->new( source => $source_code );
        my $tokens = $lexer->tokenize();

        # Syntax Parsing
        my $parser = Brocken::Core::Parser->new( tokens => $tokens );
        my @statements;
        while ( $parser->peek->type ne 'EOF' ) {
            push @statements, $parser->parse_statement();
        }

        # Compile-time Constant Folding Optimization
        require Brocken::Core::Optimizer;
        my $optimizer       = Brocken::Core::Optimizer->new();
        my @optimized_stmts = map { $optimizer->fold_constants($_) } @statements;

        # AST-to-IR Lowering into Basic Blocks
        my $generator = Brocken::Core::IRGenerator->new();
        for my $stmt (@optimized_stmts) {
            $generator->lower_statement($stmt);
        }

        # Cache the generated abstract IR blocks
        $blocks = $generator->blocks;
        return $self;
    }

    # Helper to dynamically resolve and standardize target triple combos
    method _load_target ( $target_triple = undef ) {
        $target_triple //= $triple;
        $target_triple = ref($target_triple) ? $target_triple : Brocken::Target::Triple->new( raw_string => $target_triple );

        # Load correct architecture and format drivers using mapped properties
        my $arch_class   = 'Brocken::Target::Architecture::' . $target_triple->class_arch;
        my $format_class = 'Brocken::Target::Format::' . $target_triple->class_format;
        builtin::load_module $arch_class;
        builtin::load_module $format_class;
        return ( $arch_class->new(), $format_class->new() );
    }

    # Lowers the cached abstract IR to a specific native executable target
    method write_executable ( $output_file, $target_triple = undef, $passed_argument = undef, $debug_level = undef ) {
        $target_triple //= $triple;
        $target_triple = ref($target_triple) ? $target_triple : Brocken::Target::Triple->new( raw_string => $target_triple );
        $blocks // die "Compilation Error: No source code parsed yet. Call ->parse() first.\n";
        my ( $arch, $format ) = $self->_load_target($target_triple);

        # Assemble passing the full Triple object
        my $bin = $arch->assemble( $blocks, $target_triple );

        # Optional DWARF generation using assembler line mappings
        my $debug_bytes = undef;
        my $lvl         = $debug_level // $debug;
        if ( $lvl > 0 ) {
            require Brocken::Target::Format::DWARF;
            my $dwarf    = Brocken::Target::Format::DWARF->new();
            my $mappings = $arch->line_mappings;
            $debug_bytes = $dwarf->generate_line_table( $source_file, $mappings );
        }
        $format->write_executable( $output_file, $bin, $target_triple, $passed_argument, $debug_bytes );
    }

    # Lowers the cached abstract IR to a native shared library (.dll, .so, .dylib)
    method write_lib ( $output_file, $target_triple = undef, $debug_level = undef ) {
        $target_triple //= $triple;
        $target_triple = ref($target_triple) ? $target_triple : Brocken::Target::Triple->new( raw_string => $target_triple );
        $blocks // die "Compilation Error: No source code parsed yet. Call ->parse() first.\n";
        my ( $arch, $format ) = $self->_load_target($target_triple);

        # Assemble passing the full Triple object
        my $bin         = $arch->assemble( $blocks, $target_triple );
        my $debug_bytes = undef;
        my $lvl         = $debug_level // $debug;

        # Optional DWARF generation using assembler line mappings
        if ( $lvl > 0 ) {
            require Brocken::Target::Format::DWARF;
            my $dwarf    = Brocken::Target::Format::DWARF->new();
            my $mappings = $arch->line_mappings;
            $debug_bytes = $dwarf->generate_line_table( $source_file, $mappings );
        }
        if ( $format->can('write_shared_library') ) {
            $format->write_shared_library( $output_file, $bin, $target_triple, $debug_bytes );
        }
        else {
            $format->write_executable( $output_file, $bin, $target_triple, undef, $debug_bytes );
        }
    }

    # Classic Pipeline API: compiles end-to-end immediately
    method compile ( $source_code, $output_file, $target_triple = undef, $passed_argument = undef ) {
        $target_triple //= $triple;
        $self->parse($source_code);
        $self->write_executable( $output_file, $target_triple, $passed_argument, $debug );
    }
}
1;
