use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'Value' => sub {
    my $v = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => 'x' );
    isa_ok $v, ['Brocken::Lindsay::IR::Value'], 'value construction';
    is $v->type->as_string, 'i32', 'value type';
    is $v->name,            'x',   'value name';
    is $v->as_string,       'x',   'value as_string with name';
};
subtest 'Constant' => sub {
    my $c = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 );
    isa_ok $c, ['Brocken::Lindsay::IR::Constant'], 'constant construction';
    is $c->value,     42, 'constant value';
    is $c->as_string, 42, 'constant as_string';
};
subtest 'Instruction base' => sub {
    my $c1   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 );
    my $c2   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 );
    my $inst = Brocken::Lindsay::IR::Instruction->new(
        name     => 'add1',
        type     => Brocken::Lindsay::IR::Type::i32(),
        opcode   => 'add',
        operands => [ $c1, $c2 ],
    );
    isa_ok $inst, ['Brocken::Lindsay::IR::Instruction'], 'instruction construction';
    is $inst->opcode,              'add', 'instruction opcode';
    is scalar $inst->operands->@*, 2,     'instruction operand count';
    like $inst->render, qr/add/, 'instruction render contains opcode';
};
subtest 'ICmp' => sub {
    my $c1   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 5 );
    my $c2   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 3 );
    my $icmp = Brocken::Lindsay::IR::Instruction::ICmp->new(
        name      => 'cmp',
        type      => Brocken::Lindsay::IR::Type::i1(),
        opcode    => 'icmp',
        predicate => 'sgt',
        operands  => [ $c1, $c2 ],
    );
    isa_ok $icmp, ['Brocken::Lindsay::IR::Instruction::ICmp'], 'ICmp construction';
    is $icmp->predicate, 'sgt', 'ICmp predicate';
    like $icmp->render, qr/icmp sgt/, 'ICmp render';
};
subtest 'Br' => sub {
    my $block = Brocken::Lindsay::IR::Block->new( name => 'target' );
    my $br    = Brocken::Lindsay::IR::Instruction::Br->new( type => Brocken::Lindsay::IR::Type::void(), opcode => 'br', dest_block => $block, );
    isa_ok $br, ['Brocken::Lindsay::IR::Instruction::Br'], 'Br construction';
    like $br->render, qr/br label %target/, 'Br render';
};
subtest 'CondBr' => sub {
    my $cond   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => 1 );
    my $tblock = Brocken::Lindsay::IR::Block->new( name => 'then' );
    my $fblock = Brocken::Lindsay::IR::Block->new( name => 'else' );
    my $cbr    = Brocken::Lindsay::IR::Instruction::CondBr->new(
        type        => Brocken::Lindsay::IR::Type::void(),
        opcode      => 'br',
        operands    => [$cond],
        true_block  => $tblock,
        false_block => $fblock,
    );
    isa_ok $cbr, ['Brocken::Lindsay::IR::Instruction::CondBr'], 'CondBr construction';
    like $cbr->render, qr/br i1 1, label %then, label %else/, 'CondBr render';
};
subtest 'Ret' => sub {
    my $val = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 );
    my $ret = Brocken::Lindsay::IR::Instruction::Ret->new( type => Brocken::Lindsay::IR::Type::i32(), opcode => 'ret', operands => [$val], );
    like $ret->render, qr/ret i32 0/, 'Ret with value render';
    my $ret_void = Brocken::Lindsay::IR::Instruction::Ret->new( type => Brocken::Lindsay::IR::Type::void(), opcode => 'ret', operands => [], );
    like $ret_void->render, qr/ret void/, 'Ret void render';
};
subtest 'Alloca' => sub {
    my $alloca = Brocken::Lindsay::IR::Instruction::Alloca->new(
        name           => 'ptr',
        type           => Brocken::Lindsay::IR::Type::ptr(),
        opcode         => 'alloca',
        allocated_type => Brocken::Lindsay::IR::Type::i32(),
    );
    isa_ok $alloca, ['Brocken::Lindsay::IR::Instruction::Alloca'], 'Alloca construction';
    like $alloca->render, qr/alloca i32/, 'Alloca render';
};
subtest 'Load/Store' => sub {
    my $ptr  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 'null' );
    my $val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 );
    my $load = Brocken::Lindsay::IR::Instruction::Load->new(
        name     => 'ld',
        type     => Brocken::Lindsay::IR::Type::i32(),
        opcode   => 'load',
        operands => [$ptr],
    );
    like $load->render, qr/load i32, ptr null/, 'Load render';
    my $store
        = Brocken::Lindsay::IR::Instruction::Store->new( type => Brocken::Lindsay::IR::Type::void(), opcode => 'store', operands => [ $val, $ptr ], );
    like $store->render, qr/store i32 42, ptr null/, 'Store render';
};
subtest 'Call' => sub {
    my $callee = Brocken::Lindsay::IR::Function->new( name => 'foo',                             return_type => Brocken::Lindsay::IR::Type::i32(), );
    my $arg    = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value       => 7 );
    my $call   = Brocken::Lindsay::IR::Instruction::Call->new(
        name     => 'res',
        type     => Brocken::Lindsay::IR::Type::i32(),
        opcode   => 'call',
        callee   => $callee,
        operands => [$arg],
    );
    isa_ok $call, ['Brocken::Lindsay::IR::Instruction::Call'], 'Call construction';
    like $call->render, qr/call i32 \@foo\(i32 7\)/, 'Call render';
};
subtest 'Box/Unbox' => sub {
    my $val = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 );
    my $box = Brocken::Lindsay::IR::Instruction::Box->new(
        name     => 'b',
        type     => Brocken::Lindsay::IR::Type::dynamic(),
        opcode   => 'box',
        operands => [$val],
    );
    like $box->render, qr/box i32 42 to dynamic/, 'Box render';
    my $unbox = Brocken::Lindsay::IR::Instruction::Unbox->new(
        name     => 'ub',
        type     => Brocken::Lindsay::IR::Type::i32(),
        opcode   => 'unbox',
        operands => [$val],
    );
    like $unbox->render, qr/unbox i32 42 to i32/, 'Unbox render';
};
subtest 'Phi' => sub {
    my $b1  = Brocken::Lindsay::IR::Block->new( name => 'entry' );
    my $b2  = Brocken::Lindsay::IR::Block->new( name => 'loop' );
    my $v1  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 );
    my $v2  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 );
    my $phi = Brocken::Lindsay::IR::Instruction::Phi->new( name => 'p', type => Brocken::Lindsay::IR::Type::i32(), opcode => 'phi', );
    $phi->add_incoming( $v1, $b1 );
    $phi->add_incoming( $v2, $b2 );
    isa_ok $phi, ['Brocken::Lindsay::IR::Instruction::Phi'], 'Phi construction';
    like $phi->render, qr/phi/, 'Phi render';
};
done_testing;
