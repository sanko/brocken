use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Type {
    field $name : reader : param;
    field $size : reader : param = 8; # Default to 64-bit/pointer size

    method to_string() { return $name; }
    method is_numeric() { return 0; }
    method is_pointer() { return 0; }
    method set_name($n) { $name = $n; }
    method set_size($s) { $size = $s; }
}

class Brocken::Type::Primitive : isa(Brocken::Type) {
    method is_primitive() { return 1; }
}

class Brocken::Type::Int : isa(Brocken::Type::Primitive) {
    ADJUST {
        $self->set_name('Int');
        $self->set_size(8);
    }
    method is_numeric() { return 1; }
}

class Brocken::Type::Double : isa(Brocken::Type::Primitive) {
    ADJUST {
        $self->set_name('Double');
        $self->set_size(8);
    }
    method is_numeric() { return 1; }
}

class Brocken::Type::Bool : isa(Brocken::Type::Primitive) {
    ADJUST {
        $self->set_name('Bool');
        $self->set_size(1);
    }
}

class Brocken::Type::String : isa(Brocken::Type::Primitive) {
    ADJUST {
        $self->set_name('String');
        $self->set_size(16);
    } # Pointer + Length
    method is_pointer() { return 1; }
}

class Brocken::Type::Any : isa(Brocken::Type) {
    ADJUST {
        $self->set_name('Any');
        $self->set_size(8);
    }
}

class Brocken::Type::Array : isa(Brocken::Type) {
    field $element_type : reader : param;
    ADJUST {
        $self->set_name("Array[" . $element_type->to_string . "]");
        $self->set_size(8);
    }
}

class Brocken::Type::Hash : isa(Brocken::Type) {
    field $key_type : reader : param;
    field $value_type : reader : param;
    ADJUST {
        $self->set_name("Hash[" . $key_type->to_string . ", " . $value_type->to_string . "]");
        $self->set_size(8);
    }
}

class Brocken::Type::Registry {
    my %types;
    
    sub get_type($name) {
        return $types{$name} if exists $types{$name};
        
        my $type = 
            $name eq 'Int'    ? Brocken::Type::Int->new(name => 'Int') :
            $name eq 'Double' ? Brocken::Type::Double->new(name => 'Double') :
            $name eq 'Bool'   ? Brocken::Type::Bool->new(name => 'Bool') :
            $name eq 'String' ? Brocken::Type::String->new(name => 'String') :
            $name eq 'Any'    ? Brocken::Type::Any->new(name => 'Any') :
            undef;
            
        $types{$name} = $type if $type;
        return $type;
    }
}
1;
