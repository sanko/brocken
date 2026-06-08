# lib/Brocken/Core/Type.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

package Brocken::Core::Type;

# Defensively declare file-level lexicals and helper subroutines outside the
# class block to prevent interpreter pad-sealing segfaults
my %TYPEDEF_REGISTRY;
my %STRUCT_REGISTRY;

sub register_typedef( $alias_name, $type_obj ) {
    $TYPEDEF_REGISTRY{$alias_name} = $type_obj;
}

sub lookup_typedef($alias_name) {
    return $TYPEDEF_REGISTRY{$alias_name};
}

sub register_struct( $struct_name, $fields_hashref ) {
    $STRUCT_REGISTRY{$struct_name} = $fields_hashref;
}

sub lookup_struct($struct_name) {
    return $STRUCT_REGISTRY{$struct_name};
}

class Brocken::Core::Type {
    field $name      : param : reader;            # e.g., 'Int', 'Array', 'StructName'
    field $parameter : param : reader = undef;    # T in Pointer[T] or Array[T, N]
    field $size      : param : reader = undef;    # N in Array[T, N]
    field $fields    : param : reader = undef;    # Hashref of FieldName -> Type for Struct/Union

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
        return 1 if exists $STRUCT_REGISTRY{$name};    # Unboxed structs are native
        if ( $name eq 'Struct' || $name eq 'Union' ) {

            # Inline Struct/Union represented as managed heap references
            return 0;
        }
        if ( $name eq 'Array' ) {
            return defined $size ? 1 : 0;    # Fixed arrays are native; dynamic are managed
        }
        return ( $name =~ /^(Int|UInt|Double|Float|Char|Bool|Pointer|Vector)/ ) ? 1 : 0;
    }

    # Managed types are allocated on our heap and track reference counts
    method is_managed() {
        return !$self->is_native();
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
        return ( $name eq 'Struct' || exists $STRUCT_REGISTRY{$name} ) ? 1 : 0;
    }

    method is_union() {
        return ( $name eq 'Union' ) ? 1 : 0;
    }

    # Returns the physical memory requirement of the type in bytes
    method byte_size() {

        # 1. Resolve Struct Sizes (sum of all member fields)
        if ( exists $STRUCT_REGISTRY{$name} ) {
            my $fields = $STRUCT_REGISTRY{$name};
            my $sum    = 0;
            for my $f_name ( keys %$fields ) {
                $sum += $fields->{$f_name}->byte_size;
            }
            return $sum;
        }

        # 2. Resolve Inline Struct Sizes (pointer to heap-allocated)
        if ( $name eq 'Struct' ) {
            return 8;
        }

        # 3. Resolve Native Union Sizes (pointer to heap-allocated)
        if ( $name eq 'Union' ) {
            return 8;
        }

        # 4. Resolve Array Sizes
        if ( $name eq 'Array' ) {
            if ( defined $size ) {
                return $parameter->byte_size * $size;
            }
            return 8;    # Dynamic array pointer
        }

        # 5. Standard primitives
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
        if ( $name eq 'Struct' || $name eq 'Union' ) {
            my @kv = map { "$_ => " . $fields->{$_}->to_string } sort keys %$fields;
            return "$name\[" . join( ", ", @kv ) . "]";
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
