use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $check = sub {
    my ( $lowerer_class, $ir_name, $ir_body, %checks ) = @_;
    my $func    = Brocken::Lindsay::IR::Function->new( name => $ir_name, return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $ir_body->($builder);
    my $lowerer = $lowerer_class->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;

    for my ( $opcode, $label )(%checks) {
        ok( grep( { $_->opcode eq $opcode } @insts ), $label );
    }
};
my $X = 'Brocken::Jenny::Lowerer::X86_64';
my $A = 'Brocken::Jenny::Lowerer::ARM64';
my $R = 'Brocken::Jenny::Lowerer::RISCV64';
my $W = 'Brocken::Jenny::Lowerer::Wasm';
$check->(
    $X,
    'i128_add',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                '%r'
            )
        );
    },
    adc => 'x86_64 i128 add: adc produced',
    add => 'x86_64 i128 add: add for lo'
);
$check->(
    $X,
    'i128_sub',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_sub(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                '%r'
            )
        );
    },
    sbb => 'x86_64 i128 sub: sbb produced'
);
$check->(
    $X,
    'i128_and',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_and(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xFFFFFFFFFFFFFFFF ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                '%r'
            )
        );
    },
    and => 'x86_64 i128 and: and produced'
);
$check->(
    $X,
    'i128_or',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_or(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xFFFFFFFFFFFFFFFF ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                '%r'
            )
        );
    },
    or => 'x86_64 i128 or: or produced'
);
$check->(
    $X,
    'i128_xor',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_xor(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xFFFFFFFFFFFFFFFF ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                '%r'
            )
        );
    },
    xor => 'x86_64 i128 xor: xor produced'
);
$check->(
    $A,
    'i128_add',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                '%r'
            )
        );
    },
    sltu => 'ARM64 i128 add: sltu carry produced'
);
$check->(
    $A,
    'i128_sub',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_sub(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                '%r'
            )
        );
    },
    sltu => 'ARM64 i128 sub: sltu borrow produced'
);
$check->(
    $R,
    'i128_add',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                '%r'
            )
        );
    },
    sltu => 'RISCV64 i128 add: sltu carry produced'
);
$check->(
    $R,
    'i128_sub',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_sub(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                '%r'
            )
        );
    },
    sltu => 'RISCV64 i128 sub: sltu borrow produced'
);
$check->(
    $W,
    'i128_add',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                '%r'
            )
        );
    },
    i64_gt_u => 'Wasm i128 add: i64_gt_u carry produced'
);
$check->(
    $W,
    'i128_sub',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_sub(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                '%r'
            )
        );
    },
    i64_lt_u => 'Wasm i128 sub: i64_lt_u borrow produced'
);
$check->(
    $W,
    'i128_and',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_and(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xFFFFFFFFFFFFFFFF ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                '%r'
            )
        );
    },
    i64_and => 'Wasm i128 and: i64_and produced'
);

# x86_64 i128 store/load
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_load_store', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
    my $val = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xDEADBEEFCAFEBABE );
    $builder->build_store( $val, $ptr );
    my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i128(), $ptr, '%loaded' );
    $builder->build_ret($loaded);
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @stores  = grep { $_->opcode =~ /^store/ && $_->comment =~ /i128/ } @insts;
    ok( scalar @stores == 2, 'x86_64 i128 store: two stores (lo+hi)' );
    my @loads = grep { $_->opcode eq 'load' && $_->comment =~ /i128/ } @insts;
    ok( scalar @loads == 2, 'x86_64 i128 load: two loads (lo+hi)' );
}

# x86_64 i128 ret
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_ret', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
    my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @rax     = grep { $_->opcode eq 'mov' && $_->comment =~ /rax/ } @insts;
    ok( scalar @rax == 1, 'x86_64 i128 ret: mov to rax' );
    my @rdx = grep { $_->opcode eq 'mov' && $_->comment =~ /rdx/ } @insts;
    ok( scalar @rdx == 1, 'x86_64 i128 ret: mov to rdx' );
}

# ARM64 i128 store/load
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_load_store', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
    my $val = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xDEADBEEFCAFEBABE );
    $builder->build_store( $val, $ptr );
    my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i128(), $ptr, '%loaded' );
    $builder->build_ret($loaded);
    my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @stores  = grep { $_->opcode =~ /^store/ && $_->comment =~ /i128/ } @insts;
    ok( scalar @stores == 2, 'ARM64 i128 store: two stores (lo+hi)' );
    my @loads = grep { $_->opcode eq 'load' && $_->comment =~ /i128/ } @insts;
    ok( scalar @loads == 2, 'ARM64 i128 load: two loads (lo+hi)' );
}

# ARM64 i128 ret
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_ret', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
    my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @x0      = grep { $_->opcode eq 'mov' && $_->comment =~ /x0/ } @insts;
    ok( scalar @x0 == 1, 'ARM64 i128 ret: mov to x0' );
    my @x1 = grep { $_->opcode eq 'mov' && $_->comment =~ /x1/ } @insts;
    ok( scalar @x1 == 1, 'ARM64 i128 ret: mov to x1' );
}

# RISCV64 i128 store/load
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_load_store', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
    my $val = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xDEADBEEFCAFEBABE );
    $builder->build_store( $val, $ptr );
    my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i128(), $ptr, '%loaded' );
    $builder->build_ret($loaded);
    my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @stores  = grep { $_->opcode =~ /^store/ && $_->comment =~ /i128 store/ } @insts;
    ok( scalar @stores == 2, 'RISCV64 i128 store: two stores (lo+hi)' );
    my @loads = grep { $_->opcode eq 'load' && $_->comment =~ /i128 load/ } @insts;
    ok( scalar @loads == 2, 'RISCV64 i128 load: two loads (lo+hi)' );
}

# RISCV64 i128 ret
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_ret', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
    my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @a0      = grep { $_->comment =~ /i128 lo/ } @insts;
    ok( scalar @a0 == 1, 'RISCV64 i128 ret: mv to a0' );
    my @a1 = grep { $_->comment =~ /i128 hi/ } @insts;
    ok( scalar @a1 == 1, 'RISCV64 i128 ret: mv to a1' );
}

# Wasm i128 store
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_store', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
    $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ), $ptr );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ) );
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @stores  = grep { $_->opcode eq 'i64_store' && $_->comment =~ /store lo/ } @insts;
    ok( scalar @stores == 1, 'Wasm i128 store: i64_store lo' );
    my @stores_hi = grep { $_->opcode eq 'i64_store' && $_->comment =~ /store hi/ } @insts;
    ok( scalar @stores_hi == 1, 'Wasm i128 store: i64_store hi' );
}

# Wasm i128 load
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_load', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
    $builder->build_ret( $builder->build_load( Brocken::Lindsay::IR::Type::i128(), $ptr, '%loaded' ) );
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @loads   = grep { $_->opcode eq 'i64_load' && $_->comment =~ /load lo/ } @insts;
    ok( scalar @loads == 1, 'Wasm i128 load: i64_load lo' );
    my @loads_hi = grep { $_->opcode eq 'i64_load' && $_->comment =~ /load hi/ } @insts;
    ok( scalar @loads_hi == 1, 'Wasm i128 load: i64_load hi' );
}

# Wasm i128 ret
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_ret', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
    my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
    my $mf      = $lowerer->lower($func);
    my @insts   = $mf->blocks->[0]->instructions->@*;
    my @ret_lo  = grep { $_->comment =~ /retval lo/ } @insts;
    ok( scalar @ret_lo == 1, 'Wasm i128 ret: push retval lo' );
    my @ret_hi = grep { $_->comment =~ /retval hi/ } @insts;
    ok( scalar @ret_hi == 1, 'Wasm i128 ret: push retval hi' );
}

# x86_64 i128 shl/1
$check->(
    $X,
    'i128_shl_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_shl(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    shl  => 'x86_64 i128 shl/1: shl produced',
    lshr => 'x86_64 i128 shl/1: lshr carry produced',
    or   => 'x86_64 i128 shl/1: or carry merge'
);
$check->(
    $X,
    'i128_lshr_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_lshr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    lshr => 'x86_64 i128 lshr/1: lshr produced',
    shl  => 'x86_64 i128 lshr/1: shl carry produced',
    or   => 'x86_64 i128 lshr/1: or carry merge'
);
$check->(
    $X,
    'i128_ashr_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_ashr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    ashr => 'x86_64 i128 ashr/1: ashr produced',
    shl  => 'x86_64 i128 ashr/1: shl carry produced',
    or   => 'x86_64 i128 ashr/1: or carry merge'
);
$check->(
    $A,
    'i128_shl_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_shl(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    shl  => 'ARM64 i128 shl/1: shl produced',
    lshr => 'ARM64 i128 shl/1: lshr carry produced',
    or   => 'ARM64 i128 shl/1: or carry merge'
);
$check->(
    $A,
    'i128_lshr_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_lshr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    lshr => 'ARM64 i128 lshr/1: lshr produced',
    shl  => 'ARM64 i128 lshr/1: shl carry produced',
    or   => 'ARM64 i128 lshr/1: or carry merge'
);
$check->(
    $A,
    'i128_ashr_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_ashr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    ashr => 'ARM64 i128 ashr/1: ashr produced',
    shl  => 'ARM64 i128 ashr/1: shl carry produced',
    or   => 'ARM64 i128 ashr/1: or carry merge'
);
$check->(
    $R,
    'i128_shl_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_shl(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    shl  => 'RISCV64 i128 shl/1: shl produced',
    lshr => 'RISCV64 i128 shl/1: lshr carry produced',
    or   => 'RISCV64 i128 shl/1: or carry merge'
);
$check->(
    $R,
    'i128_lshr_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_lshr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    lshr => 'RISCV64 i128 lshr/1: lshr produced',
    shl  => 'RISCV64 i128 lshr/1: shl carry produced',
    or   => 'RISCV64 i128 lshr/1: or carry merge'
);
$check->(
    $R,
    'i128_ashr_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_ashr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    ashr => 'RISCV64 i128 ashr/1: ashr produced',
    shl  => 'RISCV64 i128 ashr/1: shl carry produced',
    or   => 'RISCV64 i128 ashr/1: or carry merge'
);
$check->(
    $W,
    'i128_shl_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_shl(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    i64_shl   => 'Wasm i128 shl/1: i64_shl produced',
    i64_shr_u => 'Wasm i128 shl/1: i64_shr_u carry produced',
    i64_or    => 'Wasm i128 shl/1: i64_or carry merge'
);
$check->(
    $W,
    'i128_lshr_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_lshr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    i64_shr_u => 'Wasm i128 lshr/1: i64_shr_u produced',
    i64_shl   => 'Wasm i128 lshr/1: i64_shl carry produced',
    i64_or    => 'Wasm i128 lshr/1: i64_or carry merge'
);
$check->(
    $W,
    'i128_ashr_1',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_ashr(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                '%r'
            )
        );
    },
    i64_shr_s => 'Wasm i128 ashr/1: i64_shr_s produced',
    i64_shl   => 'Wasm i128 ashr/1: i64_shl carry produced',
    i64_or    => 'Wasm i128 ashr/1: i64_or carry merge'
);
$check->(
    $X,
    'i128_mul',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_mul(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    mul   => 'x86_64 i128 mul: mul produced',
    umulh => 'x86_64 i128 mul: umulh produced'
);
$check->(
    $A,
    'i128_mul',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_mul(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    mul   => 'ARM64 i128 mul: mul produced',
    umulh => 'ARM64 i128 mul: umulh produced'
);
$check->(
    $R,
    'i128_mul',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_mul(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    mul   => 'RISCV64 i128 mul: mul produced',
    mulhu => 'RISCV64 i128 mul: mulhu produced'
);
$check->(
    $W,
    'i128_mul',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_mul(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    i64_mul   => 'Wasm i128 mul: i64_mul produced',
    i64_and   => 'Wasm i128 mul: i64_and produced',
    i64_shr_u => 'Wasm i128 mul: i64_shr_u produced'
);
$check->(
    $X,
    'i128_div',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_div(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    seta  => 'x86_64 i128 div: seta produced',
    setae => 'x86_64 i128 div: setae produced'
);
$check->(
    $X,
    'i128_rem',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_rem(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    setb => 'x86_64 i128 rem: setb produced',
    seta => 'x86_64 i128 rem: seta produced'
);
$check->(
    $A,
    'i128_div',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_div(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    cset_hi => 'ARM64 i128 div: cset_hi produced',
    cset_cs => 'ARM64 i128 div: cset_cs produced'
);
$check->(
    $A,
    'i128_rem',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_rem(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    cset_hi => 'ARM64 i128 rem: cset_hi produced',
    cset_cc => 'ARM64 i128 rem: cset_cc produced'
);
$check->(
    $R,
    'i128_div',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_div(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    sltu => 'RISCV64 i128 div: sltu produced'
);
$check->(
    $R,
    'i128_rem',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_rem(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    sltu => 'RISCV64 i128 rem: sltu produced'
);
$check->(
    $W,
    'i128_div',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_div(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    i64_sub => 'Wasm i128 div: i64_sub produced'
);
$check->(
    $W,
    'i128_rem',
    sub {
        my $b = shift;
        $b->build_ret(
            $b->build_rem(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                '%r'
            )
        );
    },
    i64_sub => 'Wasm i128 rem: i64_sub produced'
);
done_testing;
