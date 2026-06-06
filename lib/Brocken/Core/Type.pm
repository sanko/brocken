# lib/Brocken/Core/Type.pm (Updated)
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Core::Type {
    field $name      : param : reader;            # e.g., 'Int', 'Struct', 'Pointer'
    field $parameter : param : reader = undef;    # T in Pointer[T]
    field $size      : param : reader = undef;    # N in Vector[T, N]
    field $fields    : param : reader = undef;    # Hashref of FieldName -> Type for Struct[...]

    # Factory method to parse and instantiate any type string dynamically at runtime
    sub parse_string($type_str) {
        require Brocken::Core::Lexer;
        require Brocken::Core::Parser;
        my $lexer  = Brocken::Core::Lexer->new( source => $type_str );
        my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
        return $parser->parse_type();
    }

    # Native unboxed types can live directly on the stack / CPU registers
    method is_native() {
        if ( $name eq 'Struct' ) { return 0; }    # Managed Perl-ish hash references are not native
        if ( $name eq 'Array' ) {
            return defined $size ? 1 : 0;
        }
        return ( $name =~ /^(Int|UInt|Double|Float|Char|Bool|Pointer|Vector)/ ) ? 1 : 0;
    }

    # Managed types are allocated on our heap and track reference counts
    method is_managed() {
        if ( $name eq 'Struct' ) { return 1; }    # Managed Perl-ish hash references
        if ( $name eq 'Array' ) {
            return defined $size ? 0 : 1;
        }
        return ( $name eq 'Any' || $name eq 'String' || !$self->is_native ) ? 1 : 0;
    }

    method is_pointer() {
        return ( $name eq 'Pointer' ) ? 1 : 0;
    }

    method is_float() {
        return ( $name eq 'Float' || $name eq 'Double' ) ? 1 : 0;
    }

    method is_bool() {
        return ( $name eq 'Bool' ) ? 1 : 0;
    }

    method is_128bit() {
        return ( $name eq 'Int128' || $name eq 'UInt128' ) ? 1 : 0;
    }

    method is_struct() {
        return ( $name eq 'Struct' ) ? 1 : 0;
    }

    # Returns the physical memory requirement of the type in bytes
    method byte_size() {
        if ( $name eq 'Struct' ) {
            return 8;    # Managed hash reference pointer
        }

        # Resolve Array Sizes
        if ( $name eq 'Array' ) {
            if ( defined $size ) {

                # Fixed Array size = member size * N
                return $parameter->byte_size * $size;
            }

            # Dynamic Array is represented as an 8-byte heap pointer
            return 8;
        }

        # Standard primitives
        if ( $name eq 'Bool' || $name eq 'Char' || $name eq 'Int8' || $name eq 'UInt8' )                          { return 1; }
        if ( $name eq 'Int16' || $name eq 'UInt16' )                                                              { return 2; }
        if ( $name eq 'Int32' || $name eq 'UInt32' || $name eq 'Float' )                                          { return 4; }
        if ( $name eq 'Int' || $name eq 'Int64' || $name eq 'UInt64' || $name eq 'Double' || $name eq 'Pointer' ) { return 8; }
        if ( $name eq 'Int128' || $name eq 'UInt128' )                                                            { return 16; }
        if ( $name eq 'Any' || $name eq 'String' )                                                                { return 8; }
        if ( $name eq 'Vector' ) {
            return $parameter->byte_size * $size;
        }

        # Class reference pointers
        return 8;
    }

    method to_string() {
        if ( $name eq 'Struct' ) {

            # Sort keys guarantees deterministic stringification of the inline struct hash
            my @kv = map { "$_ => " . $fields->{$_}->to_string } sort keys %$fields;
            return "Struct[" . join( ", ", @kv ) . "]";
        }
        if ( $name eq 'Pointer' ) {
            return "Pointer[" . $parameter->to_string . "]";
        }
        if ( $name eq 'Vector' ) {
            return "Vector[" . $parameter->to_string . ", $size]";
        }
        if ( $name eq 'Array' ) {
            return defined $size ? "Array[" . $parameter->to_string . ", $size]" : "Array[" . $parameter->to_string . "]";
        }
        return $name;
    }
}
1;
