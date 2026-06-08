# lib/Brocken/Core/OOP.pm
use v5.38;
use feature 'class';
no warnings 'experimental::class';

# Tracks metadata for an individual field
class Brocken::Core::OOP::Field {
    field $name          : param  : reader;            # e.g. '$id'
    field $is_param      : param  : reader = 0;        # 1 if has :param
    field $reader_name   : param  : reader = undef;    # name of automatically generated getter if :reader
    field $writer_name   : param  : reader = undef;    # name of automatically generated setter if :writer
    field $default_op    : param  : reader = undef;    # '=', '//=', or '||='
    field $default_expr  : param  : reader = undef;    # AST node of the default value expression
    field $type          : param  : reader = 'Any';    # Declared type (e.g., Int, Vector[Double, 8])
    field $memory_offset : writer : reader = undef;    # Set during offset calculation phase

    method has_default() {
        return defined $default_op;
    }
}

# Tracks metadata for a complete class definition
class Brocken::Core::OOP::Class {
    field $name            : param : reader;            # e.g. 'Employee'
    field $superclass_name : param : reader = undef;    # e.g. 'Person' from :isa(Person)
    field $fields  : reader;
    field $methods : reader;
    field $roles   : reader;
    field $vtable  : reader;
    field $resolved_fields : writer : reader;

    # Defensively instantiate reference-types inside ADJUST to prevent compiler memory corruption
    ADJUST {
        $fields          = {};
        $methods         = {};
        $roles           = [];
        $vtable          = [];
        $resolved_fields = {};
    }

    method add_field ($field) {
        $fields->{ $field->name } = $field;
    }

    method add_method ( $name, $method_ast ) {
        $methods->{$name} = $method_ast;
    }

    method add_role ($role_name) {
        push @$roles, $role_name;
    }
}

class Brocken::Core::OOP::Resolver {
    field $class_registry : param;

    # Recursively retrieves all unique fields, cloning parent fields for isolation
    method resolve_all_fields ($class_name) {
        my $class = $class_registry->{$class_name} or die "Unknown class: $class_name";
        my @all_fields;
        my %seen_fields;    # Defensively prevent duplicate layout offsets

        # 1. Resolve and clone parent fields first
        if ( defined $class->superclass_name ) {
            my @parent_fields = $self->resolve_all_fields( $class->superclass_name );
            for my $p_field (@parent_fields) {
                next if !defined $p_field->name || $p_field->name eq '';
                next if $seen_fields{ $p_field->name }++;                  # Skip duplicates
                push @all_fields,
                    Brocken::Core::OOP::Field->new(
                    name         => $p_field->name,
                    is_param     => $p_field->is_param,
                    reader_name  => $p_field->reader_name,
                    writer_name  => $p_field->writer_name,
                    default_op   => $p_field->default_op,
                    default_expr => $p_field->default_expr,
                    type         => $p_field->type,
                    );
            }
        }

        # 2. Append locally defined fields
        for my $name ( sort keys %{ $class->fields } ) {
            next if !defined $name || $name eq '';
            next if $seen_fields{$name}++;           # Skip duplicates (such as inherited duplicates)
            push @all_fields, $class->fields->{$name};
        }
        return @all_fields;
    }

    # Calculates final stack offsets and stores mapping
    method resolve_layout ($class_name) {
        my @fields         = $self->resolve_all_fields($class_name);
        my $current_offset = 16;                                       # 8-byte header + 8-byte vtable pointer
        my $resolved_map   = {};
        for my $field (@fields) {
            $field->set_memory_offset($current_offset);
            $resolved_map->{ $field->name } = $field;
            $current_offset += 8;
        }

        # Register the resolved mapping back inside the class
        my $class = $class_registry->{$class_name};
        $class->set_resolved_fields($resolved_map);
        return $current_offset;
    }
}
1;
