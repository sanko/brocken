use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Brocken::Core::Lexer;
use Brocken::Core::Parser;
use Brocken::Core::Type;
#
subtest 'Type Metadata Layouts and Byte Sizes' => sub {

    # Test 1: Bools
    my $bool_type = Brocken::Core::Type->new( name => 'Bool' );
    ok( $bool_type->is_bool, 'Bool is recognized as boolean' );
    is( $bool_type->byte_size, 1, 'Bool requires 1 byte' );

    # Test 2: Floats and Doubles
    my $float_type = Brocken::Core::Type->new( name => 'Float' );
    ok( $float_type->is_float, 'Float is recognized as floating-point' );
    is( $float_type->byte_size, 4, 'Float requires 4 bytes (single-precision)' );
    my $double_type = Brocken::Core::Type->new( name => 'Double' );
    ok( $double_type->is_float, 'Double is recognized as floating-point' );
    is( $double_type->byte_size, 8, 'Double requires 8 bytes (double-precision)' );

    # Test 3: 128-bit Numerics
    my $int128_type = Brocken::Core::Type->new( name => 'Int128' );
    ok( $int128_type->is_128bit, 'Int128 is recognized as 128-bit' );
    is( $int128_type->byte_size, 16, 'Int128 requires 16 bytes' );

    # Test 4: Fixed and Dynamic Arrays
    my $fixed_arr = Brocken::Core::Type->new( name => 'Array', parameter => $double_type, size => 10 );
    ok( $fixed_arr->is_native, 'fixed array is native stack-allocated' );
    is( $fixed_arr->byte_size, 80, 'fixed array size = Double (8) * 10 = 80 bytes' );
    my $dyn_arr = Brocken::Core::Type->new( name => 'Array', parameter => $double_type );
    ok( $dyn_arr->is_managed, 'dynamic array is managed heap-allocated' );
    is( $dyn_arr->byte_size, 8, 'dynamic array reference requires an 8-byte pointer' );
};
subtest 'Recursive Parametric Type Parsing' => sub {
    my $code = q{
        my Pointer[Char] $ptr;
        my Vector[Double, 8] $vec;
        my Array[Int32, 100] $arr;
    };
    my $lexer  = Brocken::Core::Lexer->new( source => $code );
    my $parser = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my @stmts;
    while ( $parser->peek->type ne 'EOF' ) {
        push @stmts, $parser->parse_statement();
    }
    is( @stmts, 3, 'parsed exactly 3 typed lexical declarations' );
    my $ptr_type = $stmts[0]->type;
    is( $ptr_type->name,            'Pointer', 'outer type is Pointer' );
    is( $ptr_type->parameter->name, 'Char',    'inner type is Char' );
    my $arr_type = $stmts[2]->type;
    is( $arr_type->name,            'Array', 'outer type is Array' );
    is( $arr_type->parameter->name, 'Int32', 'inner type is Int32' );
    is( $arr_type->size,            100,     'array dimensions match' );
};
subtest 'Runtime Type Parsing & Instantiation' => sub {
    my $t1 = Brocken::Core::Type::parse_string("Pointer[Char]");
    is( $t1->to_string, 'Pointer[Char]', 'dynamically compiled Pointer[Char] string' );
    my $t2 = Brocken::Core::Type::parse_string("Vector[Int32, 4]");
    is( $t2->byte_size, 16, 'dynamically compiled Vector[Int32, 4] byte size is 16' );
};
subtest 'Built-in C FFI Parsing' => sub {
    my $code     = 'ffi sub ExitProcess(Int32 $code) :lib(kernel32);';
    my $lexer    = Brocken::Core::Lexer->new( source => $code );
    my $parser   = Brocken::Core::Parser->new( tokens => $lexer->tokenize() );
    my $ffi_decl = $parser->parse_statement();
    is( $ffi_decl->name,     'ExitProcess', 'parsed C FFI function name' );
    is( $ffi_decl->lib_name, 'kernel32',    'parsed C library target' );
    my $param = $ffi_decl->signature->params->[0];
    is( $param->name,       '$code', 'parsed FFI parameter name' );
    is( $param->type->name, 'Int32', 'parsed FFI parameter type is Int32' );
};
subtest 'Inline Struct Declarations and Layout Mapping' => sub {

    # 1. Compile an inline struct declaration at runtime
    my $t = Brocken::Core::Type::parse_string("Struct[name => String, age => Int]");
    ok( $t->is_struct,  'Point recognized as an inline struct type' );
    ok( $t->is_managed, 'Point struct is represented as a managed hash reference' );
    is( $t->byte_size, 8, 'Point struct reference is mapped to an 8-byte pointer' );

    # Validate member fields parsing
    my $fields = $t->fields;
    ok( exists $fields->{name}, 'parsed member field name' );
    is( $fields->{name}->name, 'String', 'parsed member type for name is String' );
    ok( exists $fields->{age}, 'parsed member field age' );
    is( $fields->{age}->name, 'Int',                                'parsed member type for age is Int' );
    is( $t->to_string,        'Struct[age => Int, name => String]', 'to_string serializes in deterministic sorted key order' );
};
done_testing;
