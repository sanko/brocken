use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

# `xori` is the only XOR against a constant, and it is an OP-IMM instruction
# (opcode 0x13, funct3 4). Its bits 31..25 are imm[11:5] of the constant, not
# a funct7: the register XOR is funct3 4 of the *other* opcode (0x33), so
# nothing has to tell the two forms apart. An earlier fix read bit 30 as a
# funct7 and set it the way SRAI does, which put 0x400 into every constant this
# emits.
#
# The lowerer negates a comparison with `xori cond, 1` whenever the branch
# wants the opposite sense, and 0x400 | 1 is never zero, so the negated
# condition came out true for every input: `if ($x)` took its then-arm with a
# false `$x`, and the inverted exit test of a `while ($i <= $n)` never became
# true, so the loop never terminated. The second symptom is worse than a wrong
# answer, because the test run hangs rather than fails.
#
# This is checked from the encoding rather than by running the module on
# purpose. Every other RISC-V test in this directory is `is_riscv64 &&
# is_native`, so off real RISC-V hardware none of them execute and a wrong bit
# in an instruction word cannot be seen at all. Targeting riscv64 explicitly
# lets the bytes be checked from any host.

my $platform = Brocken::Katsuro::Platform::parse('riscv64-unknown-linux-gnu');

sub func_bytes {
    my ($src) = @_;
    my $module  = Brocken::Compiler->new->compile($src);
    my $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform );
    my $funcs   = $codegen->emit_functions( $module->functions );
    return { map { $_->{name} => $_->{bytes} } @$funcs };
}

# Every 4-byte-aligned word that decodes as an I-type XORI.
sub xori_words {
    my ($bytes) = @_;
    my @found;
    for ( my $off = 0; $off + 4 <= length $bytes; $off += 4 ) {
        my $w = unpack( 'V', substr( $bytes, $off, 4 ) );
        next unless ( $w & 0x7F ) == 0x13;
        next unless ( ( $w >> 12 ) & 0x7 ) == 4;
        my $imm = ( $w >> 20 ) & 0xFFF;
        push @found, { off => $off, imm => ( $imm >= 0x800 ? $imm - 0x1000 : $imm ), w => $w };
    }
    return @found;
}

# Each of these needs a negated condition, so each must contain an XORI that
# negates a 0/1 value.
my @cases = (
    {
        name  => 'if/else',
        want  => '_BROCKEN_ENTRY',
        note  => 'an if branches on the negation of the comparison',
        src   => "my i64 \$x = 0;\nif (\$x) { return 0; } else { return 42; }\n",
    },
    {
        name  => 'if with a != comparison',
        want  => '_BROCKEN_ENTRY',
        note  => 'a != comparison is inverted in place',
        src   => "my i64 \$x = 0;\nif (\$x != 5) { return 42; }\nreturn 0;\n",
    },
    {
        name  => 'while with <=',
        want  => '_BROCKEN_ENTRY',
        note  => 'a <= loop exits on the negation, so it never stopped',
        src   => "my i64 \$i = 0;\nwhile (\$i <= 3) { \$i = \$i + 1; }\nreturn \$i;\n",
    },
    {
        name  => 'while with >=',
        want  => '_BROCKEN_ENTRY',
        note  => 'same, the other direction',
        src   => "my i64 \$i = 5;\nwhile (\$i >= 2) { \$i = \$i - 1; }\nreturn \$i;\n",
    },
    {
        name  => 'while with !=',
        want  => '_BROCKEN_ENTRY',
        note  => 'an != loop is the inverted exit test too',
        src   => "my i64 \$i = 0;\nwhile (\$i != 10) { \$i = \$i + 1; }\nreturn \$i;\n",
    },
    {

        # The program from 1050_integration.t that hung: the loop is inside the
        # callee, not the entry function, so the whole function set has to be
        # searched rather than just _BROCKEN_ENTRY.
        name  => 'factorial',
        want  => 'factorial',
        note  => 'the loop lives in the callee, not the entry function',
        src   => "sub factorial(i64 \$n) -> i64 {\n    my i64 \$result = 1;\n    my i64 \$i = 1;\n"
            . "    while (\$i <= \$n) {\n        \$result = \$result * \$i;\n        \$i = \$i + 1;\n    }\n"
            . "    return \$result;\n}\nreturn factorial(5);\n",
    },
);

for my $case (@cases) {
    my $funcs = func_bytes( $case->{src} );
    my $bytes = $funcs->{ $case->{want} };
    ok( $bytes, "$case->{name}: $case->{want} was emitted" ) or next;

    my @xori = xori_words($bytes);
    ok( scalar @xori, "$case->{name}: $case->{note} uses an I-type XORI" ) or next;

    for my $x (@xori) {
        is( ( $x->{w} >> 30 ) & 0x1, 0,
            "$case->{name}: xori at +$x->{off} leaves bit 30 clear (it is imm[10], not a funct7)" );
        is( $x->{imm}, 1, "$case->{name}: xori at +$x->{off} carries the constant 1, not 0x" . sprintf( '%x', $x->{imm} & 0xFFF ) );
    }
}

# Bit 30 is the one place an OP-IMM instruction does mean it: SRAI. Check that
# the shift still sets it, so the fix cannot be a blanket "stop setting bit 30".
# The frontend has no shift operator, so this one is built through the IR
# builder the way 3260_i128_lowering.t does.
{
    my $func = Brocken::Lindsay::IR::Function->new( name => 'srai_only', return_type => Brocken::Lindsay::IR::Type::i64() );
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $entry = $func->append_block('entry');
    $b->position_at_end($entry);
    $b->build_ret(
        $b->build_ashr(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => -16 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 2 ),
            '%r'
        )
    );
    my $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform );
    my $bytes   = $codegen->emit_function($func);

    # The constant amount is materialised into a register, so this comes out as
    # the register SRA (funct7 0x20) rather than SRAI. Both spell bit 30, and
    # neither is a logical shift, which is what this is here to distinguish from
    # the XORI above.
    my $saw_sra = 0;
    for ( my $off = 0; $off + 4 <= length $bytes; $off += 4 ) {
        my $w = unpack( 'V', substr( $bytes, $off, 4 ) );
        next unless ( ( $w >> 12 ) & 0x7 ) == 5;
        $saw_sra = 1 if ( $w >> 30 ) & 0x1;
    }
    ok( $saw_sra, 'an arithmetic shift right still sets bit 30 (SRA/SRAI)' );
}

done_testing;
