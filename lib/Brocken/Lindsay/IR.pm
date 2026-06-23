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
    sub ptr     { state $t //= __PACKAGE__->new( kind => 'ptr',   bits => 64 );  $t }      # opaque pointer (64-bit on this arch)
    sub void    { state $t //= __PACKAGE__->new( kind => 'void' );                 $t }
    sub dynamic { state $t //= __PACKAGE__->new( kind => 'dynamic', bits => 128 ); $t }    # 16-byte Fat Scalar (Tag + Payload), our SV*

    method as_string() {
        return "i$bits" if $kind eq 'int';
        return "f$bits" if $kind eq 'float';
        return $kind;
    }
}

class Brocken::Lindsay::IR::Value {
    field $type : reader : param;
    field $name : reader : param = undef;

    # Every value needs a way to print itself in IR dumps
    method as_string() { $name // '%<anon>' }
}

class Brocken::Lindsay::IR::Constant : isa(Brocken::Lindsay::IR::Value) {
    field $value : reader : param;
    method as_string() {$value}
}

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

class Brocken::Lindsay::IR::Instruction::Incref : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  incref %s %s', $val->type->as_string, $val->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::Decref : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  decref %s %s', $val->type->as_string, $val->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::FiberCreate : isa(Brocken::Lindsay::IR::Instruction) {
    field $callee : reader : param;    # Brocken::Lindsay::IR::Function

    method render() {
        my $args = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $self->operands->@*;
        return sprintf '  %s = fiber_create @%s(%s)', ( $self->name // '%<anon>' ), $callee->name, $args;
    }
}

class Brocken::Lindsay::IR::Instruction::IsolateCreate : isa(Brocken::Lindsay::IR::Instruction) {
    field $callee : reader : param;    # Brocken::Lindsay::IR::Function

    method render() {
        my $args = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $self->operands->@*;
        return sprintf '  %s = isolate_create @%s(%s)', ( $self->name // '%<anon>' ), $callee->name, $args;
    }
}

class Brocken::Lindsay::IR::Instruction::IsolateJoin : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $isolate = $self->operands->[0];
        return sprintf '  isolate_join %s %s', $isolate->type->as_string, $isolate->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::FiberTransfer : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $fiber, $val ) = $self->operands->@*;
        return sprintf '  %s = fiber_transfer %s %s, %s %s', ( $self->name // '%<anon>' ), $fiber->type->as_string, $fiber->as_string,
            $val->type->as_string, $val->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::FiberYield : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = fiber_yield %s %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::FiberId : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        return sprintf '  %s = fiber_id', ( $self->name // '%<anon>' );
    }
}

class Brocken::Lindsay::IR::Instruction::FiberPin : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $fiber, $tid ) = $self->operands->@*;
        return sprintf '  fiber_pin %s %s, %s %s', $fiber->type->as_string, $fiber->as_string, $tid->type->as_string, $tid->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::FrameAddr : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        return sprintf '  %s = frame_addr %s', ( $self->name // '%<anon>' ), $self->type->as_string;
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

class Brocken::Lindsay::IR::Block {
    field $name         : reader : param;
    field $parent       : reader : param = undef;    # The function
    field $instructions : reader = [];

    method append_inst($inst) {
        push $instructions->@*, $inst;
        return $inst;
    }

    method insert_before( $target, $new_inst ) {
        my $idx = 0;
        for my $inst ( $instructions->@* ) {
            last if $inst == $target;
            $idx++;
        }
        splice $instructions->@*, $idx, 0, $new_inst;
        return $new_inst;
    }

    method remove_inst($inst) {
        $instructions->@* = grep { $_ != $inst } $instructions->@*;
    }

    method replace_inst( $old, $new ) {
        for my $i ( 0 .. $#{$instructions} ) {
            if ( $instructions->[$i] == $old ) {
                $instructions->[$i] = $new;
                return $new;
            }
        }
        return undef;
    }

    method terminator() {
        return $instructions->[-1] if $instructions->@*;
        return undef;
    }

    method as_string() {
        my $out = "$name:\n";
        $out .= $_->render . "\n" for $instructions->@*;
        return $out;
    }
}

class Brocken::Lindsay::IR::Function {
    field $name        : reader : param;
    field $return_type : reader : param;
    field $params      : reader : param = [];    # Array of Brocken::Lindsay::IR::Value
    field $blocks      : reader = [];
    method set_return_type($t) { $return_type = $t }
    method set_blocks($b)      { $blocks      = $b }

    method append_block($name) {
        my $bb = Brocken::Lindsay::IR::Block->new( name => $name, parent => $self );
        push $blocks->@*, $bb;
        return $bb;
    }

    method prepend_block($name) {
        my $bb = Brocken::Lindsay::IR::Block->new( name => $name, parent => $self );
        unshift $blocks->@*, $bb;
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

=encoding utf-8

=head1 NAME

Brocken::Lindsay::IR - High-Level Intermediate Representation Types

=head1 DESCRIPTION

Defines the core data structures for Brocken's SSA-form intermediate representation. The IR is LLVM-inspired and uses
an SSA representation with typed values, instructions, basic blocks, functions, and modules.

=head2 Type System

Types are represented as singleton objects via the L<Brocken::Lindsay::IR::Type> class. Common types (i1, i8, i32, i64,
f32, f64, ptr, void, dynamic) are created once and cached.

=head2 Value Hierarchy

=over 4

=item L<Brocken::Lindsay::IR::Value> - Base class for all IR values

=item L<Brocken::Lindsay::IR::Constant> - Constant values (literals)

=item L<Brocken::Lindsay::IR::Instruction> - Base instruction class

=back

=head2 Instruction Types

=over 4

=item B<Arithmetic>: add, sub, mul, div, rem, neg, abs, sqrt, shl, lshr, ashr, and, or, xor, min, max

=item B<Comparison>: icmp (eq, ne, sgt, slt, etc.)

=item B<Memory>: alloca, load, store, getelementptr

=item B<Control flow>: br, cond_br, ret, call, select, phi

=item B<Runtime>: box, unbox, incref, decref

=back

=head2 Program Structure

=over 4

=item L<Brocken::Lindsay::IR::Module> - Top-level container of functions

=item L<Brocken::Lindsay::IR::Function> - Function with params, return type, and blocks

=item L<Brocken::Lindsay::IR::Block> - Basic block containing a sequence of instructions

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
