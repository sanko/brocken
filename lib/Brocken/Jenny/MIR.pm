use v5.42;
use feature qw[class];

class Brocken::Jenny::MIR::MachineOperand {
    field $kind  : param : reader;
    field $value : param : reader;
    field $type  : param : reader = undef;
}

class Brocken::Jenny::MIR::MachineInstruction {
    field $opcode   : param : reader;
    field $operands : param : reader = [];
    field $comment  : param : reader = '';
}

class Brocken::Jenny::MIR::MachineBasicBlock {
    field $name : param : reader;
    field $instructions : param : reader = [];
    method add_instruction($inst) { push $self->instructions->@*, $inst }
}

class Brocken::Jenny::MIR::MachineFunction {
    field $name       : param : reader;
    field $blocks     : param : reader = [];
    field $frame_size : param : reader = 0;
    method add_block($block) { push $self->blocks->@*, $block }
}
1;
