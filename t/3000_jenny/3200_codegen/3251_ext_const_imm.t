use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# zext/sext of a *constant* must not reach a form encoder as a bare immediate.
#
# Constant folding leaves the operand as a literal, so the lowerers emit
# movzx/movsx straight onto an `imm` operand. Both the ARM64 and RISC-V encoders
# resolve their source operand through a helper that only understands
# virt_reg/phys_reg, so the emit died with "Unexpected operand kind: imm" --
# which is why the aarch64 and RISC-V CI legs were red while x86_64 was green.
# x86_64 already routed these through _reg_opnd.

my $i8  = Brocken::Lindsay::IR::Type::i8();
my $i16 = Brocken::Lindsay::IR::Type::i16();
my $i32 = Brocken::Lindsay::IR::Type::i32();
my $i64 = Brocken::Lindsay::IR::Type::i64();

my @backends = (
    [ 'x86_64',  'Brocken::Jenny::Lowerer::X86_64',  'Brocken::Jenny::Codegen::X86_64',  'x86_64-unknown-linux-gnu' ],
    [ 'aarch64', 'Brocken::Jenny::Lowerer::ARM64',  'Brocken::Jenny::Codegen::ARM64',  'aarch64-unknown-linux-gnu' ],
    [ 'riscv64', 'Brocken::Jenny::Lowerer::RISCV64', 'Brocken::Jenny::Codegen::RISCV64', 'riscv64-unknown-linux-gnu' ],
);

for my $spec (@backends) {
    my ( $arch, $lclass, $cclass, $triple ) = @$spec;
    subtest "$arch: zext/sext of a constant emits" => sub {
        SKIP: {
            skip "$lclass unavailable", 1 unless eval "require $lclass; require $cclass; 1";
            my $platform = Brocken::Katsuro::Platform::parse($triple);
            my $codegen  = $cclass->new( platform => $platform );

            for my $case (
                [ 'zext', $i8,  7 ],
                [ 'zext', $i16, 300 ],
                [ 'zext', $i32, 70000 ],
                [ 'sext', $i8,  -7 ],
                [ 'sext', $i16, -300 ],
                [ 'sext', $i32, -70000 ],
                )
            {
                my ( $kind, $from, $value ) = @$case;
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'ext', return_type => $i64 );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                my $const = Brocken::Lindsay::IR::Constant->new( type => $from, value => $value );
                my $res
                    = $kind eq 'zext'
                    ? $builder->build_zext( $const, $i64, '%r' )
                    : $builder->build_sext( $const, $i64, '%r' );
                $builder->build_ret($res);

                my $label = "$kind $value";

                # The immediate has to be parked in a virtual register first, so
                # the form instruction's source must be a register, not a literal.
                my $mf = eval { $lclass->new( platform => $platform )->lower($func) };
                ok( $mf, "$label: lower survived" ) or do { diag $@; next };

                my @form = grep { $_->opcode eq 'movzx' or $_->opcode eq 'movsx' }
                    $mf->blocks->[0]->instructions->@*;
                is( scalar @form, 1, "$label: exactly one form instruction" ) or next;

                my $src = $form[0]->operands->[1];
                isnt( $src->kind, 'imm', "$label: source is not a bare immediate" )
                    or diag 'the constant was handed straight to a form encoder';
                like( $src->kind, qr/^(?:virt_reg|phys_reg)$/, "$label: source is a register" );

                # End to end: this is the call that used to throw.
                my $bytes = eval { $codegen->emit_function($func) };
                ok( defined $bytes && length($bytes), "$label: emit_function produced bytes" )
                    or diag $@;
            }
        }
    };
}

done_testing;
