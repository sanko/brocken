use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib '../lib', 'lib';
require Brocken::Target::Architecture::ARM64;
subtest 'mov_imm small' => sub {
    my $as = Brocken::Target::Architecture::ARM64->new;
    $as->mov_imm( 'x0', 0 );
    $as->mov_imm( 'x1', 255 );
    $as->mov_imm( 'x2', 0xFFFF );
    my $code = $as->code;
    is length($code), 12, 'three imm moves = 12 bytes';
};
subtest 'mov_imm large (multi-part)' => sub {
    my $as = Brocken::Target::Architecture::ARM64->new;
    $as->mov_imm( 'x3', 0xABCDEF0 );
    my $code = $as->code;
    ok length($code) >= 4,  'large imm produces code';
    ok length($code) <= 16, 'large imm within reasonable size';
};
subtest 'mov_reg' => sub {
    my $as = Brocken::Target::Architecture::ARM64->new;
    $as->mov_reg( 'x10', 'x11' );
    my $code = $as->code;
    is length($code), 4, 'mov_reg is 4 bytes';
};
subtest 'Arithmetic immediate' => sub {
    my $as = Brocken::Target::Architecture::ARM64->new;
    $as->add_imm( 'sp', 16 );
    $as->sub_imm( 'sp', 32 );
    $as->cmp_reg_imm( 'x0', 0 );
    my $code = $as->code;
    is length($code), 12, 'three immediate ops = 12 bytes';
};
subtest 'Control flow' => sub {
    my $as = Brocken::Target::Architecture::ARM64->new;
    $as->mark_label('L_start');
    $as->mark_label('L_mid');
    $as->jmp('L_end');
    $as->jcc( 0, 'L_cond' );
    my $code = $as->code;
    ok length($code) > 0, 'control flow produces code';
};
subtest 'resolve fixups' => sub {
    my $as = Brocken::Target::Architecture::ARM64->new;
    $as->mark_label('L_func');
    $as->mov_imm( 'x0', 42 );
    $as->mark_label('L_after');
    $as->jmp('L_func');
    $as->jcc( 0, 'L_func' );
    $as->resolve;
    my $code = $as->code;
    ok length($code) > 0, 'resolved code produced';
};
subtest 'syscall' => sub {
    my $as = Brocken::Target::Architecture::ARM64->new;
    $as->syscall();
    is unpack( 'H*', $as->code ), '010000d4', 'syscall encoding (LE)';
};
done_testing;
