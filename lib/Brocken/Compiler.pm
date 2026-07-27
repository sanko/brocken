use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken;
use Brocken::Katsuro::Lexer;
use Brocken::Katsuro::Parser;
use Brocken::Katsuro::Lowerer;

class Brocken::Compiler {
    use File::Basename qw[dirname];
    use File::Spec;
    field $fuel         : param = $Brocken::default_fuel;
    field $mem_limit    : param = $Brocken::default_mem_limit;
    field $capabilities : param = $Brocken::default_capabilities;
    my %_CLASS_DEFAULTS;

    sub set_default_policy {
        my @args = @_;
        shift @args if @args && $args[0] eq __PACKAGE__;
        my %opts = @args;
        $_CLASS_DEFAULTS{fuel}         = $opts{fuel}         if exists $opts{fuel};
        $_CLASS_DEFAULTS{mem_limit}    = $opts{mem_limit}    if exists $opts{mem_limit};
        $_CLASS_DEFAULTS{capabilities} = $opts{capabilities} if exists $opts{capabilities};
        $Brocken::default_fuel         = $opts{fuel}         if exists $opts{fuel};
        $Brocken::default_mem_limit    = $opts{mem_limit}    if exists $opts{mem_limit};
        $Brocken::default_capabilities = $opts{capabilities} if exists $opts{capabilities};
        return;
    }
    ADJUST {
        if ( exists $_CLASS_DEFAULTS{fuel} && $fuel == $Brocken::default_fuel ) {
            $fuel = $_CLASS_DEFAULTS{fuel};
        }
        if ( exists $_CLASS_DEFAULTS{mem_limit} && $mem_limit == $Brocken::default_mem_limit ) {
            $mem_limit = $_CLASS_DEFAULTS{mem_limit};
        }
        if ( exists $_CLASS_DEFAULTS{capabilities} && $capabilities == $Brocken::default_capabilities ) {
            $capabilities = $_CLASS_DEFAULTS{capabilities};
        }
    }

    method _core_brocken_path() {
        return File::Spec->catfile( dirname(__FILE__), '..', '..', 'src', 'runtime', 'core.brocken' );
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

    method parse_only( $source, $filename = '(eval)' ) {
        my $lexer  = Brocken::Katsuro::Lexer->new( source => $source, filename => $filename );
        my $tokens = $lexer->lex();
        my $parser = Brocken::Katsuro::Parser->new( tokens => $tokens, filename => $filename );
        return $parser->parse_program();
    }
}

=head1 NAME

Brocken::Compiler - Frontend compilation driver

=head1 DESCRIPTION

Orchestrates the frontend compilation pipeline: reads the runtime C<core.brocken>, parses both runtime and user source,
merges their ASTs, lowers to Lindsay IR, and attaches class metadata.

=head1 METHODS

=head2 compile( $source, $filename )

Parses and lowers Brocken source C<$source> (scalar string) with optional C<$filename> (default C<(eval)>). Returns a
L<Brocken::Lindsay::IR::Module> with class_info attached.

=head2 parse_only( $source, $filename )

Like C<compile> but returns the raw AST (L<Brocken::Katsuro::AST::Program>) without lowering to IR. Useful for
introspection and testing.

=cut

1;
