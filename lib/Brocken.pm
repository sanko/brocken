use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken v0.0.1 {
    use Brocken::Katsuro;
    use Brocken::Lindsay;
    use Brocken::Jenny;
    use Brocken::Jenny::Codegen::X86_64;
    use Brocken::Jenny::Codegen::ARM64;
    use Brocken::Jenny::Codegen::RISCV64;
    use Brocken::Jenny::Linker::MachO;
    use Brocken::Jenny::Linker::PE;
    use Brocken::Jenny::Linker::ELF64;
    use Brocken::Katsuro::Lexer;
    use Brocken::Katsuro::Parser;
    use Brocken::Katsuro::Lowerer;
    use File::Basename qw[dirname];
    use File::Spec;
    use File::Temp;
    #
    our $default_fuel         = 1000000;    # initial fuel budget for entry function
    our $default_mem_limit    = 0;          # 0 = unlimited; max heap bytes per isolate
    our $default_capabilities = ~0;         # all capabilities enabled by default

    # Capability bitmask constants
    our $CAP_FS_READ  = 1 << 0;             # 1   - file system read
    our $CAP_FS_WRITE = 1 << 1;             # 2   - file system write
    our $CAP_NET      = 1 << 2;             # 4   - network access
    our $CAP_SYSTEM   = 1 << 3;             # 8   - system() / process spawn
    our $CAP_FFI      = 1 << 4;             # 16  - syscall / libc / raw FFI

    # The three runtime limits are per instance.  Each one falls back to the
    # package variable above, so a class method can move the default for every
    # instance built afterwards without touching the ones that already exist.
    #
    sub set_default_policy {
        my @args = @_;
        shift @args if @args && $args[0] eq __PACKAGE__;
        my %opts = @args;
        $Brocken::default_fuel         = $opts{fuel}         if exists $opts{fuel};
        $Brocken::default_mem_limit    = $opts{mem_limit}    if exists $opts{mem_limit};
        $Brocken::default_capabilities = $opts{capabilities} if exists $opts{capabilities};
        return;
    }
    #
    field $platform     : reader : param = Brocken::Katsuro::Platform::parse();
    field $codegen      : reader;
    field $linker       : reader;
    field $ext          : reader = '';
    field $tmpdir       : reader = File::Temp->newdir( CLEANUP => 1 );
    field $fuel         : param : reader = undef;
    field $mem_limit    : param : reader = undef;
    field $capabilities : param : reader = undef;
    #
    ADJUST {
        $fuel         //= $Brocken::default_fuel;
        $mem_limit    //= $Brocken::default_mem_limit;
        $capabilities //= $Brocken::default_capabilities;
        if ( $platform->is_arm64 && $platform->is_macos ) {
            $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::MachO->new();
        }
        elsif ( $platform->is_arm64 && $platform->is_windows ) {
            $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::PE->new();
            $ext     = '.exe';
        }
        elsif ( $platform->is_arm64 ) {
            $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::ELF64->new();
        }
        elsif ( $platform->is_riscv64 ) {
            $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::ELF64->new();
        }
        elsif ( $platform->is_x64 && $platform->is_macos ) {
            $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::MachO->new();
        }
        elsif ( $platform->is_x64 && $platform->is_windows ) {
            $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::PE->new();
            $ext     = '.exe';
        }
        elsif ( $platform->is_x64 ) {
            $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
            $linker  = Brocken::Jenny::Linker::ELF64->new();
        }
        else {
            die 'Unsupported platform for Brocken: ' . $platform->friendly;
        }
    }
    #
    method _core_brocken_path() {
        return File::Spec->catfile( dirname(__FILE__), '..', 'src', 'runtime', 'core.brocken' );
    }

    method _read_core_brocken() {
        my $path = $self->_core_brocken_path();
        open my $fh, '<', $path or return '';
        local $/;
        my $src = <$fh>;
        close $fh;
        return $src;
    }

    method _parse( $source, $filename = '(eval)' ) {
        my $lexer  = Brocken::Katsuro::Lexer->new( source => $source, filename => $filename );
        my $tokens = $lexer->lex();
        my $parser = Brocken::Katsuro::Parser->new( tokens => $tokens, filename => $filename );
        return $parser->parse_program();
    }

    # Parses and lowers $source for this instance's platform.  The runtime in
    # src/runtime/core.brocken is parsed and merged ahead of the caller's own
    # statements, so the allocator, the collector, the fiber machinery, and the
    # exception support travel with every program.
    #
    # The platform argument is deliberately not defaulted from $self->platform.
    # The lowerer uses it to pick the runtime's C symbol names, where puts is
    # the portable spelling and _puts the one a Windows target needs, and to
    # resolve syscall_by_name.  Leaving it unset keeps the portable spelling and
    # makes syscall_by_name report that it needs a platform.
    #
    method compile( $source, $filename = '(eval)', $platform = undef ) {
        my @all_stmts;
        my $core_source = $self->_read_core_brocken();
        if ( length $core_source ) {
            my $core_path = $self->_core_brocken_path();
            my $core_ast  = $self->_parse( $core_source, $core_path );
            push @all_stmts, $core_ast->statements->@*;
        }
        my $user_ast = $self->_parse( $source, $filename );
        push @all_stmts, $user_ast->statements->@*;
        my $merged_ast = Brocken::Katsuro::AST::Program->new( statements => \@all_stmts );
        my $lowerer = Brocken::Katsuro::Lowerer->new( platform => $platform, fuel => $fuel, mem_limit => $mem_limit, capabilities => $capabilities, );
        my $module  = $lowerer->lower_program($merged_ast);
        $module->set_class_info( $lowerer->classes );
        $module->set_rodata( $lowerer->rodata );
        return $module;
    }

    # Like C<compile> but stops at the AST, for introspection and testing.
    #
    method parse_only( $source, $filename = '(eval)' ) {
        return $self->_parse( $source, $filename );
    }
    #
    method os()   { return $platform->os }
    method arch() { return $platform->arch }
};
#
1;
