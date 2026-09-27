use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

my $brocken  = Brocken->new();
my $platform = $brocken->platform;

# Every immediate-form x86 encoder (mov r/m,imm32, add/sub/and/or/xor r/m,imm32,
# cmp r/m,imm32, imul) takes a sign-extended imm32, so a 64-bit constant outside
# that range used to be silently truncated to its low 32 bits. These checks all
# fail if that comes back.

subtest 'wide 64-bit constants' => sub {
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );

    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # Decimal literals, not 2**n: 2**n is a UV, and "2**n - 1" degrades to an NV
    # that rounds, which would test Perl rather than the compiler.
    my $W  = 8589934592;              # 2**33
    my $W7 = 8589934599;              # 2**33 + 7
    my $BIG = 12000000000;            # low 32 bits have bit 31 set: the case that broke
    my $NEG = -12000000000;

    # The lowerer resolves operands by IR value name, so every value needs its own.
    my $seq = 0;
    my $nm  = sub { sprintf '%%v%d', $seq++ };
    my $K   = sub { Brocken::Lindsay::IR::Constant->new( @_ ) };

    my @checks;
    my $chk = sub {
        my ( $got, $want_type, $want_value ) = @_;
        push @checks, $builder->build_icmp( 'eq', $got, $K->( type => $want_type, value => $want_value ), $nm->() );
    };
    my $eqr = sub {
        my ( $lhs, $rhs ) = @_;
        push @checks, $builder->build_icmp( 'eq', $lhs, $rhs, $nm->() );
    };

    my $loaded = sub {
        my ( $value ) = @_;
        my $slot = $builder->build_alloca( $i64, $nm->() );
        $builder->build_store( $K->( type => $i64, value => $value ), $slot );
        $builder->build_load( $i64, $slot, $nm->() );
    };
    my $C = sub { $K->( type => $i64, value => $_[0] ) };

    # Keep only the bits above the wide constant, so the expected value stays small
    # enough for the comparison itself not to need a wide constant.
    my $top = sub { $builder->build_lshr( $_[0], $C->(33), $nm->() ) };

    # Binary ops with a wide immediate. Before the fix each of these operated on
    # 0 instead, because the immediate was truncated.
    $chk->( $top->( $builder->build_add( $loaded->(7),  $C->($W), $nm->() ) ), $i64, 1 );
    $chk->( $top->( $builder->build_sub( $loaded->($W7), $C->($W), $nm->() ) ), $i64, 0 );
    $chk->( $top->( $builder->build_and( $loaded->($W7), $C->($W), $nm->() ) ), $i64, 1 );
    $chk->( $top->( $builder->build_or(  $loaded->(7),  $C->($W), $nm->() ) ), $i64, 1 );
    $chk->( $top->( $builder->build_xor( $loaded->(7),  $C->($W), $nm->() ) ), $i64, 1 );
    $chk->( $top->( $builder->build_mul( $loaded->(1),  $C->($W), $nm->() ) ), $i64, 1 );

    # Storing a wide constant. 12000000000 has bit 31 set in its low word, so the
    # imm32 store form sign-extended it to -884901888 and the quotient came out 0.
    $chk->( $builder->build_udiv( $loaded->($BIG), $C->(1000000000), $nm->() ), $i64, 12 );
    $chk->( $builder->build_udiv( $builder->build_abs( $loaded->($NEG), $nm->() ), $C->(1000000000), $nm->() ), $i64, 12 );
    $chk->( $builder->build_udiv( $loaded->(2576980377), $C->(2576980377), $nm->() ), $i64, 1 );

    # Comparing against a wide constant. The shift is already correct on its own,
    # so this isolates the comparison from the arithmetic above.
    my $shifted = $builder->build_shl( $loaded->(1), $C->(33), $nm->() );
    push @checks, $builder->build_icmp( 'eq', $builder->build_zext( $builder->build_icmp( 'eq', $shifted, $C->($W), $nm->() ), $i64, $nm->() ), $C->(1), $nm->() );
    push @checks, $builder->build_icmp( 'eq', $builder->build_zext( $builder->build_icmp( 'ne', $shifted, $C->($W), $nm->() ), $i64, $nm->() ), $C->(0), $nm->() );

    # A wide constant must not be confused with its own truncated low word.
    $eqr->( $builder->build_zext( $builder->build_icmp( 'ne', $loaded->($BIG), $C->(-884901888), $nm->() ), $i64, $nm->() ), $C->(1) );

    # Enough simultaneously live values that the allocator spills, so the
    # materialized constant has to survive being written from another register.
    my @live = map { $builder->build_add( $C->($_), $C->(1), $nm->() ) } 1 .. 12;
    my $acc  = $live[0];
    $acc = $builder->build_add( $acc, $live[$_], $nm->() ) for 1 .. $#live;
    $chk->( $top->( $builder->build_add( $acc, $C->($W), $nm->() ) ), $i64, 1 );    # 2..13 sums to 90

    # Two wide stores to one slot in a single block: the materialized constants
    # must not be given the same virtual register name.
    my $slot = $builder->build_alloca( $i64, $nm->() );
    $builder->build_store( $C->($W), $slot );
    my $first = $builder->build_load( $i64, $slot, $nm->() );
    $builder->build_store( $C->($BIG), $slot );
    my $second = $builder->build_load( $i64, $slot, $nm->() );
    $chk->( $top->($first), $i64, 1 );
    $chk->( $builder->build_udiv( $second, $C->(1000000000), $nm->() ), $i64, 12 );

    my $all = $checks[0];
    $all = $builder->build_and( $all, $checks[$_], $nm->() ) for 1 .. $#checks;

    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->build_cond_br( $all, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( $K->( type => $i32, value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( $K->( type => $i32, value => 0 ) );

    my $bytes = $brocken->codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated wide-constant bytes for ' . $platform->friendly );

    SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $out = $brocken->tmpdir . '/wide_const' . $brocken->ext;
        $brocken->linker->write_executable( $out, $bytes, $platform );
        ok( -e $out, 'Wide-constant binary exists' );
        my $ret = system $out;
        SKIP: {
            skip "system() failed to spawn ($!)", 1 if $ret == -1;
            is( $? >> 8, 42, 'Wide constants returned 42 on ' . $platform->friendly );
        }
        unlink $out;
    }
};

done_testing;
