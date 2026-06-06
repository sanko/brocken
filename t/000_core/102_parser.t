use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::OOP;
#
subtest 'Parsing OOP Declarations' => sub {
    my $code = q{
        class Person {
            field $age :param = 0;
        }
        class Employee :isa(Person) {
            field $id :param //= 999;
        }
    };
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $tokens = $lexer->tokenize();
    my $parser = Brocken::Core::Parser->new( tokens => $tokens );
    $parser->parse_program();
    my $classes = $parser->classes;
    ok( exists $classes->{Person},   'Person class registered' );
    ok( exists $classes->{Employee}, 'Employee class registered' );
    my $emp = $classes->{Employee};
    is( $emp->superclass_name, 'Person', 'Employee inherits from Person' );
    my $id_field = $emp->fields->{'$id'};
    ok( $id_field->is_param, 'id field recognized as param' );
    is( $id_field->default_op, '//=', 'id field has //= default operator' );
};
subtest 'Memory Layout Offsets with Resolved Fields' => sub {
    my $code = q{
        class Parent {
            field $first;
        }
        class Child :isa(Parent) {
            field $second;
        }
    };
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    $parser->parse_program();
    my $resolver = Brocken::Core::OOP::Resolver->new( class_registry => $parser->classes );
    my $size     = $resolver->resolve_layout('Child');
    is( $size, 32, 'Child instances require 32 bytes in memory' );

    # Access fields from Child's resolved_fields map!
    my $parent_field = $parser->classes->{Child}->resolved_fields->{'$first'};
    my $child_field  = $parser->classes->{Child}->resolved_fields->{'$second'};
    is( $parent_field->memory_offset, 16, 'inherited field is placed at offset 16' );
    is( $child_field->memory_offset,  24, 'subclass field is placed at offset 24' );
};
subtest 'Sibling Subclass OOP Metadata Isolation' => sub {
    my $code = q{
        class Animal {
            field $name;
        }
        class Dog :isa(Animal) {
            field $barks;
        }
        class Cat :isa(Animal) {
            field $meows;
            field $purrs;
        }
    };
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    $parser->parse_program();
    my $resolver = Brocken::Core::OOP::Resolver->new( class_registry => $parser->classes );

    # Resolve sibling layouts
    $resolver->resolve_layout('Dog');
    $resolver->resolve_layout('Cat');
    my $dog_name_field = $parser->classes->{Dog}->resolved_fields->{'$name'};
    my $cat_name_field = $parser->classes->{Cat}->resolved_fields->{'$name'};

    # The field $name is placed at offset 16 in both subclasses, but must reside
    # in different physical Field metadata objects to ensure compiler isolation.
    is( $dog_name_field->memory_offset, 16, 'Dog name field resolved at offset 16' );
    is( $cat_name_field->memory_offset, 16, 'Cat name field resolved at offset 16' );

    # Use standard scalar reference inequality
    ok( $dog_name_field != $cat_name_field, 'Dog name field is isolated and distinct from Cat name field reference' );
};
#
done_testing;
