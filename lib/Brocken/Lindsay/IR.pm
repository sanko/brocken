use v5.42;
use feature qw[class];
no warnings qw[experimental::class];

# Types
class Brocken::Lindsay::IR::Type v0.0.1 {
    field $kind           : reader : param;            # 'int', 'float', 'ptr', 'void', 'dynamic', 'struct'
    field $bits           : reader : param = 0;        # 8, 16, 32, 64, ... (struct: total bits)
    field $signed         : reader : param = 1;        # 1=signed, 0=unsigned (only for 'int' kind)
    field $struct_name    : reader : param = undef;    # struct type name
    field $field_types    : reader : param = [];       # struct: [Type, ...]
    field $field_names    : reader : param = [];       # struct: [name, ...]
    field $_field_offsets : reader : param = [];       # computed byte offsets

    # Singletons for common types to save memory and allow `==` comparison
    sub i1   { state $t //= __PACKAGE__->new( kind => 'int', bits => 1,   signed => 1 ); $t }
    sub i8   { state $t //= __PACKAGE__->new( kind => 'int', bits => 8,   signed => 1 ); $t }
    sub i16  { state $t //= __PACKAGE__->new( kind => 'int', bits => 16,  signed => 1 ); $t }
    sub i32  { state $t //= __PACKAGE__->new( kind => 'int', bits => 32,  signed => 1 ); $t }
    sub i64  { state $t //= __PACKAGE__->new( kind => 'int', bits => 64,  signed => 1 ); $t }
    sub i128 { state $t //= __PACKAGE__->new( kind => 'int', bits => 128, signed => 1 ); $t }
    sub u8   { state $t //= __PACKAGE__->new( kind => 'int', bits => 8,   signed => 0 ); $t }
    sub u16  { state $t //= __PACKAGE__->new( kind => 'int', bits => 16,  signed => 0 ); $t }
    sub u32  { state $t //= __PACKAGE__->new( kind => 'int', bits => 32,  signed => 0 ); $t }
    sub u64  { state $t //= __PACKAGE__->new( kind => 'int', bits => 64,  signed => 0 ); $t }
    sub u128 { state $t //= __PACKAGE__->new( kind => 'int', bits => 128, signed => 0 ); $t }

    # The signed integer type of a given width. Needed wherever a value has to be sign-extended to a width and then
    # reinterpreted at that width, because
    # that cannot be written as a Sext with an unsigned destination: the backends size an extension from its source
    # operand and sign-extend all the way out to 32 or 64 bits, with no way to stop at the destination width.
    # Sign-extend to the signed type here, then zero-extend to the unsigned one.
    sub signed_for($bits) {
        return i8()   if $bits == 8;
        return i16()  if $bits == 16;
        return i32()  if $bits == 32;
        return i64()  if $bits == 64;
        return i128() if $bits == 128;
        return __PACKAGE__->new( kind => 'int', bits => $bits, signed => 1 );
    }
    sub f32              { state $t //= __PACKAGE__->new( kind => 'float', bits => 32 ); $t }
    sub f64              { state $t //= __PACKAGE__->new( kind => 'float', bits => 64 ); $t }
    sub ptr              { state $t //= __PACKAGE__->new( kind => 'ptr', bits => 64 ); $t }
    sub void             { state $t //= __PACKAGE__->new( kind => 'void' ); $t }
    sub dynamic          { state $t //= __PACKAGE__->new( kind => 'dynamic', bits => 128 ); $t }
    method is_signed()   { $kind eq 'int' ? $signed  : 1 }
    method is_unsigned() { $kind eq 'int' ? !$signed : 0 }

    method struct_size() {
        return 0 unless $kind eq 'struct';
        return $bits / 8;
    }

    method byte_size() {
        return 0                  if $kind eq 'void';
        return 8                  if $kind eq 'ptr' || $kind eq 'dynamic';
        return $bits / 8          if $kind eq 'int' || $kind eq 'float';
        return $self->struct_size if $kind eq 'struct';
        return 8;
    }

    method field_offset($idx) {
        return $_field_offsets->[$idx] // 0;
    }

    method as_string() {
        return "%$struct_name"               if $kind eq 'struct';
        return $signed ? "i$bits" : "u$bits" if $kind eq 'int';
        return "f$bits"                      if $kind eq 'float';
        return $kind;
    }
};

class Brocken::Lindsay::IR::Value v0.0.1{
    field $type : reader : param;
    field $name : reader : param = undef;

    # Every value needs a way to print itself in IR dumps
    method as_string() { $name // '%<anon>' }
};

class Brocken::Lindsay::IR::Constant v0.0.1: isa(Brocken::Lindsay::IR::Value) {
    field $value : reader : param;
    method as_string() {$value}
};

class Brocken::Lindsay::IR::RodataRef v0.0.1: isa(Brocken::Lindsay::IR::Value) {
    field $label : reader : param;
    field $bytes : reader : param;
    method as_string() {$label}
};

class Brocken::Lindsay::IR::Instruction v0.0.1: isa(Brocken::Lindsay::IR::Value) {
    field $opcode   : reader : param;
    field $operands : reader : param = [];
    field $parent   : reader : param = undef;    # The Basic Block
    field $line     : reader : param = 0;
    field $col      : reader : param = 0;

    method render() {
        my $res = $self->type->kind eq 'void' ? '' : ( $self->name // '%<anon>' ) . ' = ';

        # Binary operations in LLVM usually take the form: <op> <type> <op1>, <op2>
        if ( scalar $operands->@* == 2 && $operands->[0]->type->as_string eq $operands->[1]->type->as_string ) {
            return sprintf "  %s%s %s %s, %s", $res, $opcode, $operands->[0]->type->as_string, $operands->[0]->as_string, $operands->[1]->as_string;
        }
        my $ops = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $operands->@*;
        return "  $res$opcode $ops";
    }
};

class Brocken::Lindsay::IR::Instruction::ICmp v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $predicate : reader : param;    # 'eq', 'ne', 'sgt' (signed greater than), 'slt', etc.

    method render() {
        my ( $lhs, $rhs ) = $self->operands->@*;
        return sprintf '  %s = icmp %s %s %s, %s', ( $self->name // '%<anon>' ), $predicate, $lhs->type->as_string, $lhs->as_string, $rhs->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Br v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $dest_block : reader : param;

    method render() {
        return '  br label %' . $dest_block->name;
    }
};

class Brocken::Lindsay::IR::Instruction::CondBr v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $true_block  : reader : param;
    field $false_block : reader : param;

    method render() {
        my $cond = $self->operands->[0];
        return sprintf '  br %s %s, label %%%s, label %%%s', $cond->type->as_string, $cond->as_string, $true_block->name, $false_block->name;
    }
};

class Brocken::Lindsay::IR::Instruction::Ret v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        return '  ret void' if $self->type->kind eq 'void';
        my $val = $self->operands->[0];
        return '  ret ' . $val->type->as_string . ' ' . $val->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Call v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $callee : reader : param;    # Brocken::Lindsay::IR::Function

    method render() {
        my $args = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $self->operands->@*;
        my $res  = $self->type->kind eq 'void' ? '' : ( $self->name // '%<anon>' ) . ' = ';
        return sprintf '  %scall %s @%s(%s)', $res, $self->type->as_string, $callee->name, $args;
    }
};

class Brocken::Lindsay::IR::Instruction::Syscall v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $args = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $self->operands->@*;
        my $res  = $self->name // '%<anon>';
        return sprintf '  %s = syscall(%s)', $res, $args;
    }
};

class Brocken::Lindsay::IR::Instruction::Box v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = box %s %s to dynamic', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Unbox v0.0.1 : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = unbox %s %s to %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string, $self->type->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Zext v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $target_type : reader : param;

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = zext %s %s to %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string, $target_type->as_string;
    }
}

class Brocken::Lindsay::IR::Instruction::Sext v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $target_type : reader : param;

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = sext %s %s to %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string, $target_type->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::SIToFP v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $target_type : reader : param;

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = sitofp %s %s to %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string, $target_type->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::FPToSI v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $target_type : reader : param;

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = fptosi %s %s to %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string, $target_type->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Incref v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  incref %s %s', $val->type->as_string, $val->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Decref v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val  = $self->operands->[0];
        my $heap = $self->operands->[1];
        my $s    = sprintf '  decref %s %s', $val->type->as_string, $val->as_string;
        $s .= sprintf ' [heap_base=%s]', $heap->as_string if $heap;
        return $s;
    }
};

class Brocken::Lindsay::IR::Instruction::FiberCreate v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $callee : reader : param;    # Brocken::Lindsay::IR::Function

    method render() {
        my $args = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $self->operands->@*;
        return sprintf '  %s = fiber_create @%s(%s)', ( $self->name // '%<anon>' ), $callee->name, $args;
    }
};

class Brocken::Lindsay::IR::Instruction::IsolateCreate v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $callee : reader : param;    # Brocken::Lindsay::IR::Function

    method render() {
        my $args = join ', ', map { $_->type->as_string . ' ' . $_->as_string } $self->operands->@*;
        return sprintf '  %s = isolate_create @%s(%s)', ( $self->name // '%<anon>' ), $callee->name, $args;
    }
};

class Brocken::Lindsay::IR::Instruction::IsolateJoin v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $isolate = $self->operands->[0];
        return sprintf '  isolate_join %s %s', $isolate->type->as_string, $isolate->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::FiberTransfer v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $fiber, $val ) = $self->operands->@*;
        return sprintf '  %s = fiber_transfer %s %s, %s %s', ( $self->name // '%<anon>' ), $fiber->type->as_string, $fiber->as_string,
            $val->type->as_string, $val->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::FiberYield v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $val = $self->operands->[0];
        return sprintf '  %s = fiber_yield %s %s', ( $self->name // '%<anon>' ), $val->type->as_string, $val->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::FiberId v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        return sprintf '  %s = fiber_id', ( $self->name // '%<anon>' );
    }
};

class Brocken::Lindsay::IR::Instruction::FiberPin v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $fiber, $tid ) = $self->operands->@*;
        return sprintf '  fiber_pin %s %s, %s %s', $fiber->type->as_string, $fiber->as_string, $tid->type->as_string, $tid->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::ChanCreate v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $capacity = $self->operands->[0];
        return sprintf '  %s = chan_create %s %s', ( $self->name // '%<anon>' ), $capacity->type->as_string, $capacity->as_string;
    }
}
;
class Brocken::Lindsay::IR::Instruction::ChanSend v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $chan, $val ) = $self->operands->@*;
        return sprintf '  chan_send %s %s, %s %s', $chan->type->as_string, $chan->as_string, $val->type->as_string, $val->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::ChanRecv v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $chan = $self->operands->[0];
        return sprintf '  %s = chan_recv %s %s', ( $self->name // '%<anon>' ), $chan->type->as_string, $chan->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::ChanClose v0.0.1 : isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $chan = $self->operands->[0];
        return sprintf '  chan_close %s %s', $chan->type->as_string, $chan->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::ChanTrySend v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $chan, $val ) = $self->operands->@*;
        return sprintf '  %s = chan_try_send %s %s, %s %s', ( $self->name // '%<anon>' ), $chan->type->as_string, $chan->as_string,
            $val->type->as_string, $val->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::ChanTryRecv v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $chan = $self->operands->[0];
        return sprintf '  %s = chan_try_recv %s %s', ( $self->name // '%<anon>' ), $chan->type->as_string, $chan->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::FrameAddr v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        return sprintf '  %s = frame_addr %s', ( $self->name // '%<anon>' ), $self->type->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Phi v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $incoming : reader : param = [];    # Array of [Value, Block]

    method render() {
        my $incoming_str = join ', ', map { sprintf '[ %s, %%%s ]', $_->[0]->as_string, $_->[1]->name } $incoming->@*;
        return sprintf '  %s = phi %s %s', ( $self->name // '%<anon>' ), $self->type->as_string, $incoming_str;
    }

    method add_incoming( $val, $block ) {
        push $incoming->@*, [ $val, $block ];
    }
};

class Brocken::Lindsay::IR::Instruction::Select v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $cond, $true_val, $false_val ) = $self->operands->@*;
        return sprintf '  %s = select %s %s, %s %s, %s %s', ( $self->name // '%<anon>' ), $cond->type->as_string, $cond->as_string,
            $true_val->type->as_string, $true_val->as_string, $false_val->type->as_string, $false_val->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::GetElementPtr v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $base_type : reader : param;
    field $struct_field_idx : reader : param = undef;

    method render() {
        my ( $ptr, @indices ) = $self->operands->@*;
        my $idx_str;
        if ( defined $struct_field_idx && $base_type->kind eq 'struct' ) {
            $idx_str = 'i64 0, i32 ' . $struct_field_idx;
        }
        else {
            $idx_str = join ', ', map { $_->type->as_string . ' ' . $_->as_string } @indices;
        }
        return sprintf '  %s = getelementptr %s, %s %s, %s', ( $self->name // '%<anon>' ), $base_type->as_string, $ptr->type->as_string,
            $ptr->as_string, $idx_str;
    }
};

class Brocken::Lindsay::IR::Instruction::Alloca v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {
    field $allocated_type  : reader : param;
    field $count           : reader : param = undef;
    field $debug_name      : reader : param = undef;
    field $debug_type_name : reader : param = undef;

    method render() {
        my $str = sprintf '  %s = alloca %s', ( $self->name // '%<anon>' ), $allocated_type->as_string;
        $str .= ', i64 ' . $count->as_string if $count;
        if ($debug_name) {
            $str .= ', !dbg name="' . $debug_name . '"' . ( defined $debug_type_name ? ' type="' . $debug_type_name . '"' : '' );
        }
        return $str;
    }
};

class Brocken::Lindsay::IR::Instruction::StackSave v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    # Captures the current stack pointer (the bottom of the dynamic region) as an opaque ptr value.  StackRestore
    # below hands that value back to the stack pointer, popping every dynamic alloca carved since the save.
    method render() {
        return sprintf '  %s = stack_save %s', ( $self->name // '%<anon>' ), $self->type->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::StackRestore v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $saved = $self->operands->[0];
        return sprintf '  stack_restore %s %s', $saved->type->as_string, $saved->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Load v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my $ptr = $self->operands->[0];
        return sprintf '  %s = load %s, %s %s', ( $self->name // '%<anon>' ), $self->type->as_string, $ptr->type->as_string, $ptr->as_string;
    }
};

class Brocken::Lindsay::IR::Instruction::Store v0.0.1: isa(Brocken::Lindsay::IR::Instruction) {

    method render() {
        my ( $val, $ptr ) = $self->operands->@*;
        return sprintf '  store %s %s, %s %s', $val->type->as_string, $val->as_string, $ptr->type->as_string, $ptr->as_string;
    }
};

class Brocken::Lindsay::IR::Block v0.0.1 {
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
        return undef unless $instructions->@*;
        my $last = $instructions->[-1];
        return $last
            if $last->isa('Brocken::Lindsay::IR::Instruction::Ret') ||
            $last->isa('Brocken::Lindsay::IR::Instruction::Br') ||
            $last->isa('Brocken::Lindsay::IR::Instruction::CondBr');
        return undef;
    }

    method as_string() {
        my $out = "$name:\n";
        $out .= $_->render . "\n" for $instructions->@*;
        return $out;
    }
};

class Brocken::Lindsay::IR::Function v0.0.1{
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
};

class Brocken::Lindsay::IR::Module v0.0.1 {
    field $name : reader : param = 'main';
    field $functions : reader = [];
    field $_class_info = {};
    method class_info         { return $_class_info }
    method set_class_info($v) { $_class_info = $v }
    field $_rodata = {};
    method rodata         { return $_rodata }
    method set_rodata($v) { $_rodata = $v }

    method add_function($func) {
        push $functions->@*, $func;
        return $func;
    }

    method as_string() {
        my $out = "; ModuleID = '$name'\n\n";
        $out .= $_->as_string . "\n" for $functions->@*;
        return $out;
    }
};
#
1;
