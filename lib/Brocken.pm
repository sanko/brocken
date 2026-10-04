use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken v0.0.1 {
    use File::Basename qw[dirname];
    use File::Spec;
    use File::Temp;
    #
    use Brocken::Katsuro;
    use Brocken::Lindsay;
    use Brocken::Jenny;
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

    # The three runtime limits are per instance. Each one falls back to the package variable above, so a class method
    # can move the default for every instance built afterwards without touching the ones that already exist.
    sub set_default_policy {
        my @args = @_;
        shift @args if @args && $args[0] eq __PACKAGE__;
        my %opts = @args;
        $Brocken::default_fuel         = $opts{fuel}         if exists $opts{fuel};
        $Brocken::default_mem_limit    = $opts{mem_limit}    if exists $opts{mem_limit};
        $Brocken::default_capabilities = $opts{capabilities} if exists $opts{capabilities};
        return;
    }

    # Found by walking up from this file instead of by assuming it sits beside it. A build tree loads the module out of
    # blib/lib, which carries a copy of the modules and none of src, so the sibling path names a directory that is not
    # there, the runtime reads as empty, and every compiled program loses it. lib, blib/lib and an installed copy all
    # resolve this way.
    sub DEFAULT_RUNTIME {
        my $dir   = dirname( File::Spec->rel2abs(__FILE__) );
        my $found = File::Spec->catfile( $dir, 'src', 'runtime', 'core.brocken' );
        while ( !-f $found ) {
            ( my $up = $dir ) =~ s{[\\/][^\\/]+\z}{};
            last if $up eq $dir;
            $dir   = $up;
            $found = File::Spec->catfile( $dir, 'src', 'runtime', 'core.brocken' );
        }
        $found;
    }
    #
    field $platform     : reader : param = Brocken::Katsuro::Platform::parse();
    field $codegen      : reader;
    field $linker       : reader;
    field $ext          : reader = '';
    field $tmpdir       : reader = File::Temp->newdir( CLEANUP => 1 );
    field $fuel         : reader : param = $Brocken::default_fuel;
    field $mem_limit    : reader : param = $Brocken::default_mem_limit;
    field $capabilities : reader : param = $Brocken::default_capabilities;
    field $runtime      : reader : param = __CLASS__->DEFAULT_RUNTIME;
    #
    ADJUST {
        # The platform knows which back end targets it, and which extension the output needs, so there is no dispatch
        # table to keep in step here.
        my $codegen_class = $platform->codegen_class or die 'Unsupported platform for Brocken: ' . $platform->friendly;
        my $linker_class  = $platform->linker_class  or die 'No linker for the ' . $platform->format . ' format: ' . $platform->friendly;
        $codegen = $codegen_class->new( platform => $platform );
        $linker  = $linker_class->new();
        $ext     = $platform->bin_ext;
    }
    #
    method _read_core_brocken() {
        open my $fh, '<', $runtime or return '';
        local $/;
        my $src = <$fh>;
        close $fh;
        return $src;
    }

    method parse( $source, $filename = '(eval)' ) {
        my $lexer  = Brocken::Katsuro::Lexer->new( source => $source, filename => $filename );
        my $tokens = $lexer->lex();
        my $parser = Brocken::Katsuro::Parser->new( tokens => $tokens, filename => $filename );
        return $parser->parse_program();
    }

    # Parses and lowers $source for this instance's platform. The runtime is parsed and merged ahead of the caller's
    # own statements, so the allocator, the collector, the fiber machinery, and the exception support travel with
    # every program.
    #
    # The platform argument is deliberately not defaulted from $self->platform. The lowerer uses it to pick the
    # runtime's C symbol names, where puts is the portable spelling and _puts the one a Windows target needs, and to
    # resolve syscall_by_name.  Leaving it unset keeps the portable spelling and makes syscall_by_name report that it
    # needs a platform.
    method compile( $source, $filename = '(eval)', $platform = undef ) {
        my @all_stmts;
        my $core_source = $self->_read_core_brocken();
        if ( length $core_source ) {
            my $core_ast = $self->parse( $core_source, $runtime );
            push @all_stmts, $core_ast->statements->@*;
        }
        my $user_ast = $self->parse( $source, $filename );
        push @all_stmts, $user_ast->statements->@*;
        my $merged_ast = Brocken::Katsuro::AST::Program->new( statements => \@all_stmts );
        my $lowerer = Brocken::Katsuro::Lowerer->new( platform => $platform, fuel => $fuel, mem_limit => $mem_limit, capabilities => $capabilities );
        my $module  = $lowerer->lower_program($merged_ast);
        $module->set_class_info( $lowerer->classes );
        $module->set_rodata( $lowerer->rodata );
        return $module;
    }
    #
    method os()   { $platform->os }
    method arch() { $platform->arch }
};
#
1;
