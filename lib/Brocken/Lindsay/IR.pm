use v5.42;
use feature qw[class];
no warnings qw[experimental::class];

# ============================================================
# Types
# ============================================================
class Brocken::Lindsay::IR::Type {
    field $kind : reader : param;        # 'int', 'float', 'ptr', 'void', 'dynamic'
    field $bits : reader : param = 0;    # 8, 16, 32, 64, ...

    # Singletons for common types to save memory and allow `==` comparison
    sub i1      { state $t //= __PACKAGE__->new( kind => 'int',   bits => 1 );   $t }      # bool
    sub i8      { state $t //= __PACKAGE__->new( kind => 'int',   bits => 8 );   $t }      # byte / int8 / uint8
    sub i16     { state $t //= __PACKAGE__->new( kind => 'int',   bits => 16 );  $t }      # short / int16 / uint16
    sub i32     { state $t //= __PACKAGE__->new( kind => 'int',   bits => 32 );  $t }      # int / char / int32 / uint32
    sub i64     { state $t //= __PACKAGE__->new( kind => 'int',   bits => 64 );  $t }      # long / int64 / uint64
    sub i128    { state $t //= __PACKAGE__->new( kind => 'int',   bits => 128 ); $t }      # __int128
    sub f32     { state $t //= __PACKAGE__->new( kind => 'float', bits => 32 );  $t }      # float
    sub f64     { state $t //= __PACKAGE__->new( kind => 'float', bits => 64 );  $t }      # double
    sub ptr     { state $t //= __PACKAGE__->new( kind => 'ptr' );                  $t }    # opaque pointer
    sub void    { state $t //= __PACKAGE__->new( kind => 'void' );                 $t }
    sub dynamic { state $t //= __PACKAGE__->new( kind => 'dynamic', bits => 128 ); $t }    # 16-byte Fat Scalar (Tag + Payload), our SV*

    method as_string() {
        return "i$bits" if $kind eq 'int';
        return "f$bits" if $kind eq 'float';
        return $kind;
    }
}

# ============================================================
# Value
# ============================================================
class Brocken::Lindsay::IR::Value {
    field $type : reader : param;
    field $name : reader : param = undef;

    # Every value needs a way to print itself in IR dumps
    method as_string() { $name // '%<anon>' }
}

# ============================================================
# Constant
# ============================================================
class Brocken::Lindsay::IR::Constant : isa(Brocken::Lindsay::IR::Value) {
    field $value : reader : param;
    method as_string() {$value}
}

# ============================================================
# Instruction (base)
# ============================================================
class Brocken::Lindsay::IR::Instruction : isa(Brocken::Lindsay::IR::Value) {
    field $opcode   : reader : param;
    field $operands : reader : param = [];
    field $parent   : reader : param = undef;    # The Basic Block

    method render() {
        my $res = $self->type->kind eq 'void' ? '' : ( $self->name // '%<anon>' ) . ' = ';

        # Binary operations in LLVM usually take the form: <op> <type> <op1>, <op2>
        if ( scalar $operands->@* == 2 && $operands->[0]->type->as_string eq $operands->[1]->type->as_string ) {
            return sprintf "  %s%s %s %s, %s", $res, $opcode, $operands->[0]->type->as_string, $operands->[0]->as_string, $operands->[1]->as_string;
        }
        my $ops = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $operands->@*;
        return "  $res$opcode $ops";
    }
}

# ============================================================
# Instruction subclasses
# ============================================================
class Brocken::Lindsay::IR::Instruction::ICmp : isa(Brocken::Lindsay::IR::Instruction) {
    field $predicate : reader : param;    # 'eq', 'ne', 'sgt' (signed greater than), 'slt', etc.

    method render() {
        my ( $lhs, $rhs ) = $self->operands->@*;
        return sprintf '  %s = icmp %s %s %s, %s', ( $self->name // '%<anon>' ), $predicate, $lhs->type->as_string, $lhs->as_string, $rhs->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::Br : isa(Brocken::Lindsay::IR::Instruction) {
    field $dest_block : reader : param;

    method render() {
        return '  br label %' . $dest_block->name;
    }
}

class Brocken::Lindsay::IR::Instruction::CondBr : isa(Brocken::Lindsay::IR::Instruction) {
    field $true_block  : reader : param;
    field $false_block : reader : param;

    method render() {
        my $cond = $self->operands->[0];
        return sprintf '  br %s %s, label %%%s, label %%%s', $cond->type->as_string, $cond->as_string, $true_block->name, $false_block->name;
    }
}

class Brocken::Lindsay::IR::Instruction::Ret : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        return '  ret void' if $self->type->kind eq 'void';
        my $val = $self->operands->[0];
        return '  ret ' . $val->type->as_string . ' ' . $val->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::Call : isa(Brocken::Lindsay::IR::Instruction) {
    field $callee : reader : param;    # Brocken::Lindsay::IR::Function

    method render() {
        my $args = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $self->operands->@*;
        my $res  = $self->type->kind eq 'void' ? '' : ( $self->name // '%<anon>' ) . ' = ';
        return sprintf '  %scall %s @%s(%s)', $res, $self->type->as_string, $callee->name, $args;
    }
}

class Brocken::Lindsay::IR::Instruction::Box : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = box %s %s to dynamic', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::Unbox : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = unbox %s %s to %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string, $self->type->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::Phi : isa(Brocken::Lindsay::IR::Instruction) {
    field $incoming : reader : param = [];    # Array of [Value, Block]

    method render() {
        my $incoming_str = join ', ', map { sprintf '[ %s, %%%s ]', $_->[0]->as_string, $_->[1]->name } $incoming->@*;
        return sprintf '  %s = phi %s %s', ( $self->name // '%<anon>' ), $self->type->as_string, $incoming_str;
    }

    method add_incoming( $val, $block ) {
        push $incoming->@*, [ $val, $block ];
    }
}

class Brocken::Lindsay::IR::Instruction::Select : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $cond, $true_val, $false_val ) = $self->operands->@*;
        return sprintf '  %s = select %s %s, %s %s, %s %s', ( $self->name // '%<anon>' ), $cond->type->as_string, $cond->as_string,
            $true_val->type->as_string, $true_val->as_string, $false_val->type->as_string, $false_val->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::GetElementPtr : isa(Brocken::Lindsay::IR::Instruction) {
    field $base_type : reader : param;

    method render() {
        my ( $ptr, @indices ) = $self->operands->@*;
        my $idx_str = join ', ', map { $_->type->as_string . ' ' . $_->as_string } @indices;
        return sprintf '  %s = getelementptr %s, %s %s, %s', ( $self->name // '%<anon>' ), $base_type->as_string, $ptr->type->as_string,
            $ptr->as_string, $idx_str;
    }
}

class Brocken::Lindsay::IR::Instruction::Alloca : isa(Brocken::Lindsay::IR::Instruction) {
    field $allocated_type : reader : param;

    method render() {
        return sprintf '  %s = alloca %s', ( $self->name // '%<anon>' ), $allocated_type->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::Load : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $ptr = $self->operands->[0];
        return sprintf '  %s = load %s, %s %s', ( $self->name // '%<anon>' ), $self->type->as_string, $ptr->type->as_string, $ptr->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::Store : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $val, $ptr ) = $self->operands->@*;
        return sprintf '  store %s %s, %s %s', $val->type->as_string, $val->as_string, $ptr->type->as_string, $ptr->as_string;
    }
}

# ============================================================
# Block
# ============================================================
class Brocken::Lindsay::IR::Block {
    field $name         : reader : param;
    field $parent       : reader : param = undef;    # The function
    field $instructions : reader = [];

    method append_inst($inst) {
        push $instructions->@*, $inst;
        return $inst;
    }

    method as_string() {
        my $out = "$name:\n";
        $out .= $_->render . "\n" for $instructions->@*;
        return $out;
    }
}

# ============================================================
# Function
# ============================================================
class Brocken::Lindsay::IR::Function {
    field $name        : reader : param;
    field $return_type : reader : param;
    field $params      : reader : param = [];    # Array of Brocken::Lindsay::IR::Value
    field $blocks      : reader = [];

    method append_block($name) {
        my $bb = Brocken::Lindsay::IR::Block->new( name => $name, parent => $self );
        push $blocks->@*, $bb;
        return $bb;
    }

    method as_string() {
        if ( scalar( $blocks->@* ) == 0 ) {
            my $p_str = join ', ', map { $_->type->as_string } $params->@*;
            return sprintf qq[declare %s @%s(%s)\n], $return_type->as_string, $name, $p_str;
        }
        my $p_str = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $params->@*;
        my $out   = sprintf qq[define %s @%s(%s) {\n], $return_type->as_string, $name, $p_str;
        $out .= $_->as_string for $blocks->@*;
        $out .= qq[}\n];
        return $out;
    }
}

# ============================================================
# Module
# ============================================================
class Brocken::Lindsay::IR::Module {
    field $name : reader : param = 'main';
    field $functions : reader = [];

    method add_function($func) {
        push $functions->@*, $func;
        return $func;
    }

    method as_string() {
        my $out = "; ModuleID = '$name'\n\n";
        $out .= $_->as_string . "\n" for $functions->@*;
        return $out;
    }
}
1;
