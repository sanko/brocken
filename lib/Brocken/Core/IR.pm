use v5.40;
use feature 'class';
no warnings 'experimental::class';

# Representing an atomic 3-Address Code instruction
class Brocken::Core::IR::Instruction {
    field $op   : param : reader;            # 'ADD', 'SUB', 'LOAD', 'STORE', 'BRANCH', 'CALL', 'RET', etc.
    field $dest : param : reader = undef;    # virtual register name (e.g., 'v1', 'v2') or undef (for void/jumps)
    field $srcs : param : reader = [];       # arrayref of operands (virtual registers, symbols, or literals)
    field $type : param : reader = 'Any';    # Brocken::Core::Type object or string representing the evaluated type
    field $line : param : reader = undef;    # Captured source line
    field $col  : param : reader = undef;    # Captured source column

    method to_string() {
        my $dest_str = defined $dest ? "$dest = " : '';
        my $srcs_str = join ', ', map { ref($_) ? "$_" : $_ } @$srcs;
        my $type_str = $type         ? " [$type]"           : "";
        my $pos_str  = defined $line ? " # line $line:$col" : '';
        sprintf '%s%s %s%s%s', $dest_str, $op, $srcs_str, $type_str, $pos_str;
    }
}

# Representing a basic block within our Control Flow Graph (CFG)
class Brocken::Core::IR::Block {
    field $label        : param : reader;
    field $instructions : reader = [];
    field $predecessors : reader = [];
    field $successors   : reader = [];

    method add_instruction ($inst) {
        push @$instructions, $inst;
    }
}
#
1;
