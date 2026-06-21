use v5.42;
use Test2::V0;
use lib 'lib', '../../lib', '../../../lib';
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
use Brocken::Jenny::Pass::Fiber;
use Brocken::Jenny::Lowerer::X86_64;
no warnings qw[experimental::class];
use feature qw[class];
my $i32  = Brocken::Lindsay::IR::Type::i32();
my $i64  = Brocken::Lindsay::IR::Type::i64();
my $ptr  = Brocken::Lindsay::IR::Type::ptr();
my $void = Brocken::Lindsay::IR::Type::void();
my $dyn  = Brocken::Lindsay::IR::Type::dynamic();

# 1. needs_lowering detection
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $func = Brocken::Lindsay::IR::Function->new( name => 'plain', return_type => $void );
    $b->position_at_end( $func->append_block('entry') );
    $b->build_ret();
    my $pass = Brocken::Jenny::Pass::Fiber->new();
    ok !$pass->needs_lowering($func), 'plain function does not need lowering';
}

# 2. needs_lowering detection for fiber_yield
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $func = Brocken::Lindsay::IR::Function->new( name => 'fiber_fn', return_type => $i32 );
    $b->position_at_end( $func->append_block('entry') );
    $b->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ), '%yv' );
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    my $pass = Brocken::Jenny::Pass::Fiber->new();
    ok $pass->needs_lowering($func), 'fiber function needs lowering';
}

# 3. pass lower is a no-op (fiber IR instructions stay)
{
    my $b      = Brocken::Lindsay::IR::Builder->new();
    my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker', return_type => $void );
    $b->position_at_end( $worker->append_block('entry') );
    $b->build_ret();
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    $b->position_at_end( $main->append_block('entry') );
    my $fiber  = $b->build_fiber_create( $worker, [], '%f' );
    $b->build_fiber_transfer( $fiber, Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ), '%r' );
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    my $pass = Brocken::Jenny::Pass::Fiber->new();
    $pass->lower($main);
    my @fiber_ops = ();
    for my $block ( $main->blocks->@* ) {
        for my $inst ( $block->instructions->@* ) {
            push @fiber_ops, $inst if $inst->isa('Brocken::Lindsay::IR::Instruction::FiberCreate')
                || $inst->isa('Brocken::Lindsay::IR::Instruction::FiberTransfer');
        }
    }
    ok scalar(@fiber_ops) >= 2, 'fiber instructions preserved after lower';
}

# 4. lowerer produces MIR ctx_save/ctx_restore/lea_func for fiber ops
{
    my $b      = Brocken::Lindsay::IR::Builder->new();
    my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker', return_type => $void );
    $b->position_at_end( $worker->append_block('entry') );
    $b->build_ret();
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    $b->position_at_end( $main->append_block('entry') );
    $b->build_fiber_create( $worker, [], '%f' );
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
    my $mf      = $lowerer->lower($main);
    my %opcodes;
    for my $mbb ( $mf->blocks->@* ) {
        for my $inst ( $mbb->instructions->@* ) {
            $opcodes{ $inst->opcode }++;
        }
    }
    ok $opcodes{lea_func}, 'fiber_create lowered to lea_func';
    ok !$opcodes{ctx_save}, 'fiber_create does not emit ctx_save (initial setup only)';
}

# 5. fiber_transfer lowered produces ctx_save + ctx_restore
{
    my $b      = Brocken::Lindsay::IR::Builder->new();
    my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker', return_type => $void );
    $b->position_at_end( $worker->append_block('entry') );
    $b->build_ret();
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    $b->position_at_end( $main->append_block('entry') );
    my $fiber = $b->build_fiber_create( $worker, [], '%f' );
    $b->build_fiber_transfer( $fiber, Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ), '%r' );
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
    my $mf      = $lowerer->lower($main);
    my %opcodes;
    for my $mbb ( $mf->blocks->@* ) {
        for my $inst ( $mbb->instructions->@* ) {
            $opcodes{ $inst->opcode }++;
        }
    }
    ok $opcodes{ctx_save},  'fiber_transfer produces ctx_save';
    ok $opcodes{ctx_restore}, 'fiber_transfer produces ctx_restore';
}

# 6. fiber_yield lowered produces ctx_save + ctx_restore
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $func = Brocken::Lindsay::IR::Function->new( name => 'yielder', return_type => $i32 );
    $b->position_at_end( $func->append_block('entry') );
    $b->build_fiber_yield( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ), '%yv' );
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
    my $mf      = $lowerer->lower($func);
    my %opcodes;
    for my $mbb ( $mf->blocks->@* ) {
        for my $inst ( $mbb->instructions->@* ) {
            $opcodes{ $inst->opcode }++;
        }
    }
    ok $opcodes{ctx_save},  'fiber_yield produces ctx_save';
    ok $opcodes{ctx_restore}, 'fiber_yield produces ctx_restore';
}

# 7. fiber_id lowered to mov 0
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $func = Brocken::Lindsay::IR::Function->new( name => 'id_test', return_type => $i64 );
    $b->position_at_end( $func->append_block('entry') );
    $b->build_fiber_id('%tid');
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ) );
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
    my $mf      = $lowerer->lower($func);
    ok $mf, 'fiber_id lowered successfully';
}

# 8. fiber_pin lowers without error
{
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $func = Brocken::Lindsay::IR::Function->new( name => 'pin_test', return_type => $void );
    $b->position_at_end( $func->append_block('entry') );
    my $dummy = Brocken::Lindsay::IR::Function->new( name => 'target', return_type => $void );
    my $f = $b->build_fiber_create( $dummy, [], '%f' );
    $b->build_fiber_pin( $f, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ) );
    $b->build_ret();
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
    my $mf      = $lowerer->lower($func);
    ok $mf, 'fiber_pin lowered successfully';
}

done_testing;
