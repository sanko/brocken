use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers wasm_platform wasm_runner];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# A u128 argument narrowed to an i64 parameter used to keep the source width: `maybe_convert_type` built the
# masking `and` through `build_binop`, which types a result from its left operand, so the IR still called it
# i128. Argument placement classifies by those types, pushed lo/hi on the stack, and the callee read an
# uninitialized parameter register -- the same program returned a different wrong answer on each run. The
# instruction now carries the target type instead, and Wasm pushes the `_lo` half of the wide source when a
# binop typed at the narrow target feeds it one.
#
# Source is fuzz case 9's minimal reduction (`x2`), where `$obj1->f1()` after the call is the u128 value
# reinterpreted as its low 64 bits.
my $src = <<'BROCKEN';
use feature 'brocken_native_types';
class Point {
    field i64 $f1 :param :reader :writer;
}
my u128 $v2 = 11671637082321175394;
my ptr $obj1 = Point->new(f1 => -63);
$obj1->set_f1($v2);
return $obj1->f1();
BROCKEN
subtest 'the masking and is typed at the destination width' => sub {
    my $module = Brocken->new->compile($src);
    my @calls;
    for my $fn ( $module->functions->@* ) {
        for my $block ( $fn->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                next unless $inst->isa('Brocken::Lindsay::IR::Instruction::Call') && $inst->callee;
                push @calls, $inst if $inst->callee->name eq 'Point::set_f1';
            }
        }
    }
    is scalar @calls, 1, 'the source calls Point::set_f1 once';
    my $arg = $calls[0]->operands->[3];
    isa_ok $arg, ['Brocken::Lindsay::IR::Instruction'], 'the narrowed argument is an instruction';
    is $arg->opcode,                    'and', 'the argument is the masking and';
    is $arg->type->bits,                64,    'the and carries the i64 destination, not the u128 source';
    is $arg->operands->[0]->type->bits, 128,   'its left operand is the u128 value';
};
subtest 'the narrowed argument arrives in the parameter register' => sub {

    # The host sees the entry's value as the exit status, which masks it to eight bits; the Wasm lane reads
    # the entry's return value directly and gets the whole number.
    answers( $src, 98, 'u128 narrowed to i64 for the call', targets => [ [ 'host', undef ] ] );
SKIP: {
        skip 'no Wasm runner is available', 1 unless wasm_runner();
        answers( $src, -6775106991388376222, 'u128 narrowed to i64 for the call [wasm]', targets => [ [ 'wasm32-unknown-wasi', wasm_platform() ] ] );
    }
};
#
done_testing;
