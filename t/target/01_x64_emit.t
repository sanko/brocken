use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib '../lib', 'lib';
require Brocken::Target::Architecture::X64;

subtest 'mov_reg' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->mov_reg( 'rax', 'rbx' );
    my $code = $as->code;
    is length($code),         3,        'mov_reg is 3 bytes';
    is unpack( 'H*', $code ), '4889d8', 'mov rax, rbx encoding';
};

subtest 'mov_imm' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->mov_imm( 'rax', 42 );
    my $code = $as->code;
    ok length($code) >= 7, 'mov_imm is at least 7 bytes';
    like unpack( 'H*', $code ), qr/^48(?:c7c0|b8)/, 'mov_imm starts with REX.W';
};

subtest 'push_reg and pop_reg' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->push_reg('rbx');
    $as->push_reg('r15');
    $as->pop_reg('r15');
    $as->pop_reg('rbx');
    my $code = $as->code;
    ok length($code) >= 4, 'push/pop produces code';
};

subtest 'Arithmetic immediate' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->add_imm( 'rax', 8 );
    $as->sub_imm( 'rsp', 32 );
    my $code = $as->code;
    ok length($code) > 0, 'arithmetic imm ops produce code';
};

subtest 'Comparison' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->cmp_reg_reg( 'rax', 'rbx' );
    $as->cmp_reg_imm( 'rcx', 99 );
    $as->test_reg_reg( 'rdx', 'rdx' );
    my $code = $as->code;
    ok length($code) > 0, 'compare ops produce code';
};

subtest 'Memory operations' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->store_mem_disp_reg( 'rbx', 0, 'rax' );
    $as->load_reg_mem( 'rcx', 'rbx', 8 );
    $as->lea_reg_disp( 'rdi', 'rbx', 16 );
    my $code = $as->code;
    ok length($code) > 0, 'memory ops produce code';
};

subtest 'Control flow' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->mark_label('L_start');
    $as->mark_label('L_mid');
    $as->jmp('L_end');
    $as->call_label('L_func');
    $as->call_reg('rax');
    $as->jmp_reg('rbx');
    $as->jcc( 0x4, 'L_cond' );
    my $code = $as->code;
    ok length($code) > 0, 'control flow produces code';
    is scalar( keys %{ $as->labels } ), 2, 'two labels defined';
    ok exists $as->labels->{L_start}, 'L_start label exists';
    ok exists $as->labels->{L_mid},   'L_mid label exists';
};

subtest 'resolve fixups' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->mark_label('L_func');
    $as->mov_imm( 'rax', 42 );
    $as->mark_label('L_after');
    $as->jmp('L_func');
    $as->call_label('L_func');
    $as->jcc( 0x4, 'L_func' );
    $as->resolve;
    my $code = $as->code;
    ok length($code) > 0, 'resolved code produced';
};

subtest 'SSE2 floating point' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->addsd_reg( 'xmm0', 'xmm1' );
    $as->subsd_reg( 'xmm2', 'xmm3' );
    $as->mulsd_reg( 'xmm4', 'xmm5' );
    $as->divsd_reg( 'xmm6', 'xmm7' );
    $as->ucomisd_reg( 'xmm0', 'xmm1' );
    $as->movq_reg_xmm( 'xmm0', 'rax' );
    $as->movq_xmm_reg( 'rax', 'xmm0' );
    my $code = $as->code;
    ok length($code) > 0, 'SSE2 ops produce code';
};

subtest 'syscall' => sub {
    my $as = Brocken::Target::Architecture::X64->new;
    $as->syscall();
    is unpack( 'H*', $as->code ), '0f05', 'syscall encoding';
};

done_testing;
