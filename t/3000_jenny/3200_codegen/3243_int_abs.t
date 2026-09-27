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

subtest 'integer abs' => sub {
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );

    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # The lowerer resolves operands by IR value name, so every value needs its own.
    my $seq = 0;
    my $nm  = sub { sprintf '%%v%d', $seq++ };
    my $K   = sub { Brocken::Lindsay::IR::Constant->new( @_ ) };

    my @checks;
    my $chk = sub {
        my ( $got, $want_type, $want_value ) = @_;
        push @checks, $builder->build_icmp( 'eq', $got, $K->( type => $want_type, value => $want_value ), $nm->() );
    };

    # Compare two registers. The icmp constant path encodes the comparison value
    # as a sign-extended imm32, so an expected value above 2**31 has to be built
    # as a register instead; 2**n is made with a shift for the same reason.
    my $eqr = sub {
        my ( $lhs, $rhs ) = @_;
        push @checks, $builder->build_icmp( 'eq', $lhs, $rhs, $nm->() );
    };
    my $pow2 = sub {
        my ( $n ) = @_;
        my $one = $builder->build_alloca( $i64, $nm->() );
        $builder->build_store( $K->( type => $i64, value => 1 ), $one );
        $builder->build_shl( $builder->build_load( $i64, $one, $nm->() ), $K->( type => $i64, value => $n ), $nm->() );
    };
    my $abs = sub { $builder->build_abs( $_[0], $nm->() ) };

    # abs must agree with the identity on non-negative input: this is what
    # separates it from neg, which used to be what abs lowered to.
    $chk->( $abs->( $K->( type => $i64, value => 0 ) ),          $i64, 0 );
    $chk->( $abs->( $K->( type => $i64, value => 1 ) ),          $i64, 1 );
    $chk->( $abs->( $K->( type => $i64, value => 5 ) ),          $i64, 5 );
    $chk->( $abs->( $K->( type => $i64, value => 1000000 ) ),    $i64, 1000000 );
    $chk->( $abs->( $K->( type => $i64, value => 1000000000 ) ), $i64, 1000000000 );

    # ...and fold the sign on negative input.
    $chk->( $abs->( $K->( type => $i64, value => -1 ) ),          $i64, 1 );
    $chk->( $abs->( $K->( type => $i64, value => -5 ) ),          $i64, 5 );
    $chk->( $abs->( $K->( type => $i64, value => -1000000 ) ),    $i64, 1000000 );
    $chk->( $abs->( $K->( type => $i64, value => -1000000000 ) ), $i64, 1000000000 );

    # abs of a value that arrives through memory.
    my $slot = $builder->build_alloca( $i64, $nm->() );
    $builder->build_store( $K->( type => $i64, value => -42 ), $slot );
    $chk->( $abs->( $builder->build_load( $i64, $slot, $nm->() ) ), $i64, 42 );

    # abs of a computed value, so the mask is derived from a register operand.
    my $diff = $builder->build_sub( $K->( type => $i64, value => 7 ), $K->( type => $i64, value => 20 ), $nm->() );
    $chk->( $abs->($diff), $i64, 13 );

    # A result above 2**31, so a lowering that only ever computes 0, -x, or a
    # 32-bit truncation cannot pass.
    $eqr->( $abs->( $builder->build_neg( $pow2->(40), $nm->() ) ), $pow2->(40) );
    $eqr->( $abs->( $builder->build_neg( $pow2->(62), $nm->() ) ), $pow2->(62) );

    # The most negative value has no positive counterpart, so abs has to leave
    # it alone rather than wrap to itself-minus-one.
    $eqr->( $abs->( $pow2->(63) ), $pow2->(63) );
    my $max = $builder->build_sub( $pow2->(63), $K->( type => $i64, value => 1 ), $nm->() );
    $eqr->( $abs->($max), $max );

    # Enough simultaneously live values that the allocator reaches the r8-r15
    # banks and spills; the mask, xor and sub all have to survive that.
    my @live = map { $builder->build_add( $K->( type => $i64, value => $_ ), $K->( type => $i64, value => 1 ), $nm->() ) } 1 .. 14;
    my $acc  = $live[0];
    $acc = $builder->build_add( $acc, $live[$_], $nm->() ) for 1 .. $#live;
    $chk->( $abs->($acc), $i64, ( ( 2 + 15 ) * 14 / 2 ) );

    # abs chained, and feeding a signed comparison.
    my $a9 = $abs->( $builder->build_neg( $K->( type => $i64, value => 9 ), $nm->() ), $nm->() );
    $chk->( $builder->build_mul( $a9, $K->( type => $i64, value => 2 ), $nm->() ), $i64, 18 );
    # abs feeding a signed comparison: the result is positive, so 0 < abs(x).
    push @checks, $builder->build_icmp( 'slt', $K->( type => $i64, value => 0 ), $abs->( $K->( type => $i64, value => -3 ), $nm->() ), $nm->() );


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
    ok( length($bytes) > 0, 'Generated integer abs bytes for ' . $platform->friendly );

    SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $out = $brocken->tmpdir . '/int_abs' . $brocken->ext;
        $brocken->linker->write_executable( $out, $bytes, $platform );
        ok( -e $out, 'Integer abs binary exists' );
        my $ret = system $out;
        SKIP: {
            skip "system() failed to spawn ($!)", 1 if $ret == -1;
            is( $? >> 8, 42, 'Integer abs returned 42 on ' . $platform->friendly );
        }
        unlink $out;
    }
};

done_testing;
