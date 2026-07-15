use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Compiler;
use Brocken::Lindsay::IR;
use Brocken::Katsuro::Platform;

sub find_function {
    my ( $mod, $name ) = @_;
    for my $f ( $mod->functions->@* ) {
        return $f if $f->name eq $name;
    }
    return undef;
}
subtest 'Empty program produces empty module' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile('');
    isa_ok( $mod, ['Brocken::Lindsay::IR::Module'] );
    is( $mod->name, 'main' );
};
subtest 'Function with no body becomes declare' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile('sub foo() -> i64;');
    my $f   = find_function( $mod, 'foo' );
    ok( $f, 'found function foo' );
    is( $f->name,                   'foo' );
    is( $f->return_type->as_string, 'i64' );
    is( $f->params->@*,             2 );
    is( $f->params->[0]->name,      '%__heap_base' );
    is( $f->params->[1]->name,      '%__want' );
};
subtest 'Function with parameters' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
sub add(i64 $a, i64 $b) -> i64 {
    return 0;
}
BROCKEN
    my $f = find_function( $mod, 'add' );
    ok( $f, 'found function add' );
    is( $f->name,                         'add' );
    is( $f->return_type->as_string,       'i64' );
    is( $f->params->@*,                   4 );
    is( $f->params->[0]->type->as_string, 'ptr' );
    is( $f->params->[0]->name,            '%__heap_base' );
    is( $f->params->[1]->type->as_string, 'i64' );
    is( $f->params->[1]->name,            '%__want' );
    is( $f->params->[2]->type->as_string, 'i64' );
    is( $f->params->[2]->name,            '%a' );
    is( $f->params->[3]->type->as_string, 'i64' );
    is( $f->params->[3]->name,            '%b' );
};
subtest 'Return constant' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
return 42;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/ret\s+i64\s+42/, 'returns constant 42' );
};
subtest 'Variable declaration and assignment' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $x = 10;
my i64 $y;
$y = 20;
return $x;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i64/,     'alloca for i64' );
    like( $text, qr/store\s+i64\s+10/, 'store initializer 10' );
    like( $text, qr/store\s+i64\s+20/, 'store assignment 20' );
    like( $text, qr/load\s+i64/,       'load before return' );
};
subtest 'Binary arithmetic with precedence' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $r = 1 + 2 * 3;
return $r;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/mul\s+i64\s+2,\s+3/, 'multiply first' );
    like( $text, qr/add\s+i64\s+1,/,     'then add' );
};
subtest 'If/else control flow' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $x = 0;
if ($x) {
    $x = 1;
} else {
    $x = 2;
}
return $x;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/br\s+i1/,     'conditional branch' );
    like( $text, qr/then_\d+:/,   'then label' );
    like( $text, qr/if_end_\d+:/, 'merge label' );
};
subtest 'While loop' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $i = 0;
while ($i < 10) {
    $i = $i + 1;
}
return $i;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/while_header_\d+:/, 'header label' );
    like( $text, qr/while_body_\d+:/,   'body label' );
    like( $text, qr/while_end_\d+:/,    'exit label' );
};
subtest 'Comparison operators' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $a = 10;
my i64 $b = 20;
if ($a == $b) { return 1; }
if ($a != $b) { return 2; }
if ($a < $b)  { return 3; }
if ($a > $b)  { return 4; }
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/icmp\s+eq/,  'icmp eq' );
    like( $text, qr/icmp\s+ne/,  'icmp ne' );
    like( $text, qr/icmp\s+slt/, 'icmp slt' );
    like( $text, qr/icmp\s+sgt/, 'icmp sgt' );
};
subtest 'Unary negation and logical not' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $a = -5;
if (! $a) { return 1; }
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/neg\s+i64/, 'neg for negation' );
};
subtest 'Intrinsic calls' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my ptr $p = 0;
my ptr $q = Brocken::ptr_add($p, 16);
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/add\s+ptr/, 'ptr_add lowered to add' );
};
subtest 'Bitwise intrinsics' => sub {
    for my $tc (
        [ band => 'and',  q{Brocken::band(3, 6)} ],
        [ bor  => 'or',   q{Brocken::bor(3, 6)} ],
        [ bxor => 'xor',  q{Brocken::bxor(3, 6)} ],
        [ shl  => 'shl',  q{Brocken::shl(3, 1)} ],
        [ shr  => 'lshr', q{Brocken::shr(6, 1)} ],
    ) {
        my ( $name, $op, $src ) = @$tc;
        my $c   = Brocken::Compiler->new;
        my $mod = $c->compile("my i64 \$x = $src;\nreturn \$x;\n");
        my $f   = find_function( $mod, '_BROCKEN_ENTRY' );
        ok( $f, "found entry function for $name" );
        my $text = $f->as_string();
        like( $text, qr/$op\s+/i, "$name lowered to $op" );
    }
};
subtest 'Syscall intrinsic' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $ret = Brocken::syscall(0, 0, 0, 0);
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/syscall\(/, 'syscall lowered to syscall IR' );
};
subtest 'Class field access via $self->field in method' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
class Point {
    field i64 $x;
    method get_x() -> i64 { return $self->x; }
}
BROCKEN
    my $f = find_function( $mod, 'Point::get_x' );
    ok( $f, 'found method Point::get_x' );
    is( $f->params->@*,                   3,     'three params (__heap_base, __want, $self)' );
    is( $f->params->[2]->type->as_string, 'ptr', '$self is ptr' );
    my $text = $f->as_string();
    like( $text, qr/getelementptr/, 'GEP for field access' );
    like( $text, qr/load\s+i64/,    'load i64 from field' );
};
subtest 'Auto-generated :reader method' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
class Point {
    field i64 $x :reader;
}
BROCKEN
    my $f = find_function( $mod, 'Point::x' );
    ok( $f, 'found auto-generated reader Point::x' );
    is( $f->return_type->as_string, 'i64', 'returns i64' );
    is( $f->params->@*,             3,     'three params (__heap_base, __want, $self)' );
};
subtest 'Auto-generated :writer method' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
class Point {
    field i64 $x :writer;
}
BROCKEN
    my $f = find_function( $mod, 'Point::set_x' );
    ok( $f, 'found auto-generated writer Point::set_x' );
    is( $f->return_type->as_string, 'void', 'returns void' );
    is( $f->params->@*,             4,      'four params (__heap_base, __want, $self, $value)' );
};
subtest 'Named constructor with fields' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
class Point {
    field i64 $x;
}
my ptr $p = Point->new(x => 42);
return $p->x;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/bump_alloc/,    'allocates object via bump_alloc' );
    like( $text, qr/getelementptr/, 'GEP for field access' );
    like( $text, qr/store/,         'stores field value' );
};
subtest 'ADJUST block' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
class Point {
    field i64 $x;
    ADJUST {
        if ($x < 0) { $x = 0; }
    }
}
BROCKEN
    my $f = find_function( $mod, 'Point::ADJUST' );
    ok( $f, 'found ADJUST function' );
    is( $f->params->@*,                   3,     'three params (__heap_base, __want, $self)' );
    is( $f->params->[2]->type->as_string, 'ptr', '$self is ptr' );
    my $text = $f->as_string();
    like( $text, qr/icmp/, 'comparison in ADJUST' );
};
subtest 'Method declaration with params and return type' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
class Counter {
    field i64 $count;
    method add(i64 $n) -> i64 { $count = $count + $n; return $count; }
}
BROCKEN
    my $f = find_function( $mod, 'Counter::add' );
    ok( $f, 'found method Counter::add' );
    is( $f->return_type->as_string,       'i64', 'returns i64' );
    is( $f->params->@*,                   4,     'four params (__heap_base, __want, $self, $n)' );
    is( $f->params->[2]->type->as_string, 'ptr', '$self is ptr' );
    is( $f->params->[3]->type->as_string, 'i64', '$n is i64' );
    my $text = $f->as_string();
    like( $text, qr/alloca/,    'has alloca for $n' );
    like( $text, qr/add\s+i64/, 'arithmetic on $count' );
};
subtest 'Function calls' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
sub helper() -> i64 {
    return 42;
}
return helper();
BROCKEN
    is( $mod->functions->@*, 40, '40 functions (38 runtime + helper + entry)' );
    my $text = $mod->as_string();
    like( $text, qr/call\s+i64\s+\@helper/, 'call to helper' );
};
subtest 'Full pipeline: lex -> parse -> lower' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
sub factorial(i64 $n) -> i64 {
    my i64 $result = 1;
    my i64 $i = 1;
    while ($i <= $n) {
        $result = $result * $i;
        $i = $i + 1;
    }
    return $result;
}
BROCKEN
    my $f = find_function( $mod, 'factorial' );
    ok( $f, 'found function factorial' );
    is( $f->name,                         'factorial' );
    is( $f->params->@*,                   3 );
    is( $f->params->[0]->type->as_string, 'ptr' );
    is( $f->params->[0]->name,            '%__heap_base' );
    is( $f->params->[1]->type->as_string, 'i64' );
    is( $f->params->[1]->name,            '%__want' );
    is( $f->params->[2]->type->as_string, 'i64' );
    is( $f->params->[2]->name,            '%n' );
    my $text = $f->as_string();
    like( $text, qr/define\s+i64\s+\@factorial/, 'define factorial' );
    like( $text, qr/alloca/,                     'has allocas' );
    like( $text, qr/while_header_\d+:/,          'loop header' );
    like( $text, qr/icmp\s+sle/,                 '<= comparison' );
    like( $text, qr/mul\s+i64/,                  'multiply' );
};
subtest 'Standalone field access as expression statement' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
}
my ptr $p = Point->new(x => 42);
$p->x;
return $p->x;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/getelementptr/, 'GEP for field access' );
    like( $text, qr/load\s+i64/,    'load i64 from field' );
};
subtest 'Complex expression field access (function returning class)' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
class Point {
    field i64 $x :param;
}
sub make() -> Point {
    return Point->new(x => 42);
}
return make()->x;
BROCKEN
    my $make = find_function( $mod, 'make' );
    ok( $make, 'found function make' );
    is( $make->params->@*,             2,     'make takes two params (__heap_base, __want)' );
    is( $make->return_type->as_string, 'ptr', 'make returns ptr' );
    my $entry = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $entry, 'found entry function' );
    my $text = $entry->as_string();
    like( $text, qr/call\s+ptr\s+\@make/, 'call to make' );
    like( $text, qr/getelementptr/,       'GEP for field access' );
    like( $text, qr/load\s+i64/,          'load i64 from field' );
};

# Subtest: Array declaration and element read
subtest 'Array declaration and element read' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my [i64; 10] @arr;
return @arr[3];
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i64,\s+i64\s+10/, 'alloca with count 10' );
    like( $text, qr/getelementptr\s+i64/,      'GEP with i64 base type' );
    like( $text, qr/load\s+i64/,               'load i64 from element' );
};

# Subtest: Array element write
subtest 'Array element write' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my [i64; 5] @arr;
@arr[2] = 42;
return @arr[2];
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i64,\s+i64\s+5/, 'alloca with count 5' );
    like( $text, qr/store\s+i64\s+42/,        'store to array element' );
    like( $text, qr/getelementptr\s+i64/,     'GEP for array access' );
};
subtest 'Top-level code becomes entry function' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $x = 10;
my i64 $y = 20;
return $x + $y;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'entry function created from top-level code' );
    is( $f->return_type->as_string, 'i64', 'entry returns i64' );
    ok( $f->params->@* > 0, 'entry has heap_base param' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i64/,     'alloca in entry' );
    like( $text, qr/store\s+i64\s+10/, 'store 10 in entry' );
    like( $text, qr/store\s+i64\s+20/, 'store 20 in entry' );
    like( $text, qr/add\s+i64/,        'add in entry' );
    like( $text, qr/ret\s+i64/,        'return in entry' );
};
subtest 'Top-level code with array' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my [i64; 3] @arr;
@arr[0] = 10;
@arr[1] = 20;
return @arr[0] + @arr[1];
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'entry function with array' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i64,\s+i64\s+3/, 'alloca with count 3' );
    like( $text, qr/getelementptr\s+i64/,     'GEP for array access' );
    like( $text, qr/ret\s+i64/,               'return in entry' );
};
subtest 'int type lowers to i64' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my int $x = 42;
return $x;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i64/,     'int variable is i64 alloca' );
    like( $text, qr/store\s+i64\s+42/, 'int store as i64' );
    like( $text, qr/load\s+i64/,       'load i64' );
    like( $text, qr/ret\s+i64/,        'return i64' );
};
subtest 'bool type lowers to i1' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my bool $flag = 1;
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i1/, 'bool variable is i1 alloca' );
};
subtest 'u64 type variable' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my u64 $x = 100;
return $x;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+u64/,      'u64 variable is u64 alloca' );
    like( $text, qr/store\s+i64\s+100/, 'u64 store as i64 (literal)' );
    like( $text, qr/load\s+u64/,        'load u64' );
    like( $text, qr/ret\s+u64/,         'return u64' );
};
subtest 'u8 and u16 type variables' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my u8 $a = 10;
my u16 $b = 20;
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+u8/,  'u8 variable is u8 alloca' );
    like( $text, qr/alloca\s+u16/, 'u16 variable is u16 alloca' );
};
subtest 'u32 type variable' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my u32 $x = 50;
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+u32/, 'u32 variable is u32 alloca' );
};
subtest 'Int alias (capital I) lowers to i64' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my Int $x = 7;
return $x;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i64/, 'Int variable is i64 alloca' );
};
subtest 'Bool alias (capital B) lowers to i1' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my Bool $flag = 1;
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/alloca\s+i1/, 'Bool variable is i1 alloca' );
};
subtest 'unsigned widening emits zext' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my u8 $small = 200;
my i64 $big = $small;
return $big;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/zext\s+u8/, 'unsigned widening uses zext' );
};
subtest 'bool widening emits zext (not sext)' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my bool $flag = 1;
return $flag;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/zext\s+i1/, 'bool widening uses zext (not sext)' );
    unlike( $text, qr/sext\s+i1/, 'bool widening does NOT use sext' );
};
subtest 'Shift operators << and >>' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i64 $a = 1 << 3;
my i64 $b = 8 >> 1;
my u32 $c = 16;
my u32 $d = 32 >> 2;
my u64 $e = $c >> 1;
return $a + $b + $d + $e;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/shl\s+i64/,  '1 << 3 emits shl' );
    like( $text, qr/ashr\s+i64/, 'signed >> emits ashr' );
    like( $text, qr/lshr\s+u32/, 'unsigned >> emits lshr' );
};
subtest 'signed widening emits sext' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my i8 $small = -5;
my i64 $big = $small;
return $big;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry' );
    my $text = $f->as_string();
    like( $text, qr/sext\s+i8/, 'signed widening uses sext' );
};

# === Error message position tests ===
subtest 'Undefined variable error includes position' => sub {
    my $c = Brocken::Compiler->new;
    eval { $c->compile( 'my i64 $x = $undefined;', 'test.br' ) };
    ok( $@, 'undefined variable error thrown' );
    like( $@, qr/test\.br/,  'error mentions filename' );
    like( $@, qr/line 1/,    'error mentions line' );
    like( $@, qr/undefined/, 'error mentions variable name' );
};
subtest 'Undefined function error includes position' => sub {
    my $c = Brocken::Compiler->new;
    eval { $c->compile( 'my i64 $x = nonexistent();', 'test.br' ) };
    ok( $@, 'undefined function error thrown' );
    like( $@, qr/test\.br/,    'error mentions filename' );
    like( $@, qr/line 1/,      'error mentions line' );
    like( $@, qr/nonexistent/, 'error mentions function name' );
};
subtest 'Undefined array variable error includes position' => sub {
    my $c = Brocken::Compiler->new;
    eval { $c->compile( 'my i64 $x = $bad[0];', 'test.br' ) };
    ok( $@, 'undefined array variable error thrown' );
    like( $@, qr/test\.br/, 'error mentions filename' );
    like( $@, qr/line 1/,   'error mentions line' );
};
subtest 'Unknown class error includes position' => sub {
    my $c = Brocken::Compiler->new;
    eval { $c->compile( 'my ptr $p = Nonexistent->new();', 'test.br' ) };
    ok( $@, 'unknown class error thrown' );
    like( $@, qr/test\.br/,    'error mentions filename' );
    like( $@, qr/line 1/,      'error mentions line' );
    like( $@, qr/Nonexistent/, 'error mentions class name' );
};
subtest 'syscall_by_name resolves to correct syscall number' => sub {
    my $platform = Brocken::Katsuro::Platform::parse();
    my $exit_num = $platform->syscall('exit');
    skip 'Platform does not resolve syscall names', 3 unless defined $exit_num;
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile( <<'BROCKEN', 'test.br', $platform );
sub foo() -> i64 {
    return Brocken::syscall_by_name("exit", 42);
}
BROCKEN
    my $f = find_function( $mod, 'foo' );
    ok( $f, 'found function foo' );
    my $ir = $f->as_string;
    like( $ir, qr/syscall\(i64 \Q$exit_num\E/, "syscall_by_name(\"exit\") resolves to $exit_num" );
    like( $ir, qr/i64 42/,                     'syscall arguments are preserved' );
};
subtest 'syscall_by_name errors without platform' => sub {
    my $c = Brocken::Compiler->new;
    eval { $c->compile( 'return Brocken::syscall_by_name("exit", 0);', 'test.br' ) };
    ok( $@, 'error thrown without platform' );
    like( $@, qr/platform/, 'error mentions platform' );
};
subtest 'syscall_by_name errors on unknown syscall name' => sub {
    my $platform = Brocken::Katsuro::Platform::parse();
    my $c        = Brocken::Compiler->new;
    eval { $c->compile( 'return Brocken::syscall_by_name("nonexistent", 0);', 'test.br', $platform ) };
    ok( $@, 'error thrown for unknown syscall name' );
    like( $@, qr/nonexistent/, 'error mentions unknown name' );
};
subtest 'syscall_by_name errors on non-string first argument' => sub {
    my $platform = Brocken::Katsuro::Platform::parse();
    my $c        = Brocken::Compiler->new;
    eval { $c->compile( 'return Brocken::syscall_by_name(42, 0);', 'test.br', $platform ) };
    ok( $@, 'error thrown for non-string argument' );
    like( $@, qr/string/, 'error mentions string literal requirement' );
};
subtest 'libc intrinsic produces call to named function' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
sub foo() -> i64 {
    return Brocken::libc("write", 1, 0, 6);
}
BROCKEN
    my $f = find_function( $mod, 'foo' );
    ok( $f, 'found function foo' );
    my $ir = $f->as_string;
    like( $ir, qr/call\s+i64\s+\@write/, 'libc("write") produces call to @write' );
    like( $ir, qr/i64\s+1/,              'first arg (fd=1) preserved' );
    like( $ir, qr/i64\s+6/,              'third arg (count=6) preserved' );
};
subtest 'libc intrinsic errors on non-string first argument' => sub {
    my $c = Brocken::Compiler->new;
    eval { $c->compile( 'return Brocken::libc(42, 1, 0);', 'test.br' ) };
    ok( $@, 'error thrown for non-string argument' );
    like( $@, qr/string/, 'error mentions string literal requirement' );
};
subtest 'Mixed-signedness comparison widens operands (u8 vs i8)' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
use feature 'brocken_native_types';
my u8 $a = 227;
my i8 $b = -73;
if ($a > $b) {
    return 1;
}
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/zext\s+i8\s+.*\s+to\s+u32/, 'LHS (u8) zero-extended to u32' );
    like( $text, qr/zext\s+i8\s+.*\s+to\s+u32/, 'RHS (i8) zero-extended to u32 (both zext for unsigned LHS)' );
    like( $text, qr/icmp\s+ugt\s+u32/,          'icmp uses u32 type' );
};
subtest 'Mixed-signedness comparison widens operands (i8 vs u8, signed LHS)' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
use feature 'brocken_native_types';
my i8 $a = -1;
my u8 $b = 0;
if ($a < $b) {
    return 1;
}
return 0;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/sext\s+i8\s+.*\s+to\s+i32/, 'LHS (i8) sign-extended to i32' );
    like( $text, qr/sext\s+i8\s+.*\s+to\s+i32/, 'RHS (u8) sign-extended to i32' );
    like( $text, qr/icmp\s+slt\s+i32/,          'icmp uses i32 type with signed predicate' );
};
subtest 'Bool negation promotes i1 to i8' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my bool $b = true;
my i64 $v = -$b;
return $v;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/zext\s+i1\s+.*\s+to\s+i8/, 'bool promoted from i1 to i8 before neg' );
    like( $text, qr/neg\s+i8/,                 'neg operates on i8, not i1' );
};
subtest 'Bool negation double-negate preserves value' => sub {
    my $c   = Brocken::Compiler->new;
    my $mod = $c->compile(<<'BROCKEN');
my bool $b = true;
$b = -$b;
$b = -$b;
return $b;
BROCKEN
    my $f = find_function( $mod, '_BROCKEN_ENTRY' );
    ok( $f, 'found entry function' );
    my $text = $f->as_string();
    like( $text, qr/neg\s+i8/,           'first neg on i8' );
    like( $text, qr/and\s+i8\s+.*,\s+1/, 'result masked to 1-bit for bool storage' );
};
done_testing;
