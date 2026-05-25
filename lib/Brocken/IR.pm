use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::IR::Instruction {
    method to_string() { die "Not implemented"; }
    method uses()      { return () }
    method defs()      { return () }
}

class Brocken::IR::Assign : isa(Brocken::IR::Instruction) {
    field $dest : reader : param;
    field $lhs  : reader : param;
    field $op   : reader : param;
    field $rhs  : reader : param;

    method to_string() {
        return sprintf("%s = %s %s %s", $dest, $lhs, $op, $rhs);
    }

    method uses() {
        my @u;
        push @u, $lhs if $lhs =~ /^v\d+$/;
        push @u, $rhs if $rhs =~ /^v\d+$/;
        return @u;
    }
    method defs() { return ($dest) }
}

class Brocken::IR::Load : isa(Brocken::IR::Instruction) {
    field $dest : reader : param;
    field $var  : reader : param;

    method to_string() {
        return sprintf("%s = load %s", $dest, $var);
    }
    method uses() { return () } # Loading from a variable, not a vreg
    method defs() { return ($dest) }
}

class Brocken::IR::Store : isa(Brocken::IR::Instruction) {
    field $var : reader : param;
    field $src : reader : param;

    method to_string() {
        return sprintf("store %s = %s", $var, $src);
    }
    method uses() { return ($src) if $src =~ /^v\d+$/; return () }
    method defs() { return () } # Storing to a variable, not a vreg
}

class Brocken::IR::Jump : isa(Brocken::IR::Instruction) {
    field $label : reader : param;

    method to_string() {
        return sprintf("jmp %s", $label);
    }
    method uses() { return () }
    method defs() { return () }
    method target() { return $label }
}

class Brocken::IR::Branch : isa(Brocken::IR::Instruction) {
    field $label : reader : param;
    field $cond  : reader : param;

    method to_string() {
        return sprintf("jz %s, %s", $label, $cond);
    }
    method uses() { return ($cond) if $cond =~ /^v\d+$/; return () }
    method defs() { return () }
    method target() { return $label }
}

class Brocken::IR::Call : isa(Brocken::IR::Instruction) {
    field $dest : reader : param;
    field $func : reader : param;
    field $args : reader : param;

    method to_string() {
        return sprintf("%s = call %s(%s)", $dest, $func, join(', ', @$args));
    }
    method uses() { return grep { /^v\d+$/ } @$args }
    method defs() { return ($dest) }
}

class Brocken::IR::Return : isa(Brocken::IR::Instruction) {
    field $val : reader : param;

    method to_string() {
        return sprintf("ret %s", $val);
    }
    method uses() { return ($val) if $val =~ /^v\d+$/; return () }
    method defs() { return () }
}

class Brocken::IR::Label : isa(Brocken::IR::Instruction) {
    field $name : reader : param;

    method to_string() {
        return sprintf("%s:", $name);
    }
}

class Brocken::IR::BasicBlock {
    field $name : reader : param;
    field @instructions : reader;
    field $terminator : reader;
    field %live_in : reader;
    field %live_out : reader;

    method add_instruction ($instr) {
        push @instructions, $instr;
    }

    method set_terminator ($instr) {
        $terminator = $instr;
    }

    method set_live_in (%vars) { %live_in = %vars }
    method set_live_out (%vars) { %live_out = %vars }

    method to_string () {
        my $str = "$name:\n";
        $str .= "  # LiveIn: " . join(', ', sort keys %live_in) . "\n" if %live_in;
        for my $i (@instructions) {
            $str .= "  " . $i->to_string() . "\n";
        }
        $str .= "  " . $terminator->to_string() . "\n" if $terminator;
        $str .= "  # LiveOut: " . join(', ', sort keys %live_out) . "\n" if %live_out;
        return $str;
    }
}

class Brocken::IR::CFG {
    field @blocks : reader;
    field %block_map;
    field $entry_block : reader;

    method add_block ($block) {
        push @blocks, $block;
        $block_map{$block->name} = $block;
    }

    method get_block ($name) {
        return $block_map{$name};
    }

    method set_entry_block ($block) {
        $entry_block = $block;
    }

    method to_string () {
        return join( "\n", map { $_->to_string() } @blocks );
    }
}

class Brocken::IR::RefInc : isa(Brocken::IR::Instruction) {
    field $v : reader : param;
    method to_string() { return sprintf("RefInc %s", $v); }
}

class Brocken::IR::RefDec : isa(Brocken::IR::Instruction) {
    field $v : reader : param;
    method to_string() { return sprintf("RefDec %s", $v); }
}

class Brocken::IR::Weaken : isa(Brocken::IR::Instruction) {
    field $v : reader : param;
    method to_string() { return sprintf("Weaken %s", $v); }
} 1;
