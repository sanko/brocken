use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $brocken  = Brocken->new();
my $platform = $brocken->platform;

# x86 has no immediate form for idiv/div, so the lowerer has to materialise
# constants into registers first. The umulh/udiv/div128_64 encodings also use
# rax and rdx as scratch, so the allocator has to keep virtual registers out
# of those two. Both are easy to regress silently, so check the values.
subtest 'immediate operands' => sub {
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $i8  = Brocken::Lindsay::IR::Type->new( kind => 'int', bits => 8,  signed => 1 );
    my $i16 = Brocken::Lindsay::IR::Type->new( kind => 'int', bits => 16, signed => 1 );
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # The lowerer resolves operands by IR value name, so every value needs its own.
    my $seq = 0;
    my $nm  = sub { sprintf '%%v%d', $seq++ };
    my $K   = sub { Brocken::Lindsay::IR::Constant->new(@_) };
    my @checks;
    my $chk = sub {
        my ( $got, $type, $want ) = @_;
        push @checks, $builder->build_icmp( 'eq', $got, $K->( type => $type, value => $want ), $nm->() );
    };

    # Read $value back out of memory so the dividend is a real register rather
    # than a constant, isolating the immediate on the divisor side.
    my $loaded = sub {
        my ( $type, $value ) = @_;
        my $slot = $builder->build_alloca( $type, $nm->() );
        $builder->build_store( $K->( type => $type, value => $value ), $slot );
        $builder->build_load( $type, $slot, $nm->() );
    };

    # Quotient and remainder with an immediate divisor. The remainders are all
    # non-zero: a rem that silently returns 0 would still pass 12 % 3.
    $chk->( $builder->build_udiv( $loaded->( $i64, 100 ), $K->( type => $i64, value => 7 ), $nm->() ),          $i64, 14 );
    $chk->( $builder->build_urem( $loaded->( $i64, 100 ), $K->( type => $i64, value => 7 ), $nm->() ),          $i64, 2 );
    $chk->( $builder->build_div( $loaded->( $i64, 100 ), $K->( type => $i64, value => 7 ), $nm->() ),           $i64, 14 );
    $chk->( $builder->build_rem( $loaded->( $i64, 100 ), $K->( type => $i64, value => 7 ), $nm->() ),           $i64, 2 );
    $chk->( $builder->build_udiv( $loaded->( $i64, 1000000 ), $K->( type => $i64, value => 100000 ), $nm->() ), $i64, 10 );
    $chk->( $builder->build_urem( $loaded->( $i64, 1000001 ), $K->( type => $i64, value => 100000 ), $nm->() ), $i64, 1 );

    # Both operands immediate.
    $chk->( $builder->build_udiv( $K->( type => $i64, value => 12 ), $K->( type => $i64, value => 3 ), $nm->() ), $i64, 4 );
    $chk->( $builder->build_urem( $K->( type => $i64, value => 13 ), $K->( type => $i64, value => 3 ), $nm->() ), $i64, 1 );
    $chk->( $builder->build_div( $K->( type => $i64, value => 12 ), $K->( type => $i64, value => 3 ), $nm->() ),  $i64, 4 );
    $chk->( $builder->build_rem( $K->( type => $i64, value => 13 ), $K->( type => $i64, value => 3 ), $nm->() ),  $i64, 1 );

    # An immediate divisor too large for the imm32 form used by the plain
    # arithmetic encoders; it has to be materialised via movabs. The dividend
    # stays under 2**32 because store_imm cannot hold a wider constant.
    $chk->( $builder->build_udiv( $loaded->( $i64, 100 ), $K->( type => $i64, value => 3000000000 ), $nm->() ), $i64, 0 );
    $chk->( $builder->build_urem( $loaded->( $i64, 100 ), $K->( type => $i64, value => 3000000000 ), $nm->() ), $i64, 100 );
    $chk->( $builder->build_udiv( $loaded->( $i64, 100 ), $K->( type => $i64, value => 5000000000 ), $nm->() ), $i64, 0 );
    $chk->( $builder->build_urem( $loaded->( $i64, 100 ), $K->( type => $i64, value => 5000000000 ), $nm->() ), $i64, 100 );

    # Keep several values live across the divide: the quotient and remainder
    # write-ups must not land in the rax/rdx the divide sequence overwrites.
    my $keep = sub {
        my $acc = $loaded->( $i64, 5 );
        $acc = $builder->build_add( $acc, $loaded->( $i64, $_ ), $nm->() ) for 1 .. 8;
        $acc;
    };
    my $q = $builder->build_udiv( $keep->(), $K->( type => $i64, value => 3 ), $nm->() );
    my $r = $builder->build_urem( $keep->(), $K->( type => $i64, value => 3 ), $nm->() );
    $chk->( $q, $i64, 13 );    # 5 + (1..8) == 41, 41 / 3
    $chk->( $r, $i64, 2 );

    # zext / sext of a bare constant.
    $chk->( $builder->build_zext( $K->( type => $i8, value => 7 ), $i64, $nm->() ),     $i64,  7 );
    $chk->( $builder->build_zext( $K->( type => $i16, value => 300 ), $i64, $nm->() ),  $i64,  300 );
    $chk->( $builder->build_sext( $K->( type => $i8, value => -7 ), $i64, $nm->() ),    $i64, -7 );
    $chk->( $builder->build_sext( $K->( type => $i16, value => -300 ), $i64, $nm->() ), $i64, -300 );
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
    ok( length($bytes) > 0, 'Generated immediate-operand bytes for ' . $platform->friendly );
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $out = $brocken->tmpdir . '/int_imm' . $brocken->ext;
        $brocken->linker->write_executable( $out, $bytes, $platform );
        ok( -e $out, 'Immediate-operand binary exists' );
        my $ret = system $out;
    SKIP: {
            skip "system() failed to spawn ($!)", 1 if $ret == -1;
            is( $? >> 8, 42, 'Immediate operands returned 42 on ' . $platform->friendly );
        }
        unlink $out;
    }
};

# The user-visible symptom: constant folding in the front end leaves both
# operands as literals, which is the case that used to die outright.
subtest 'constant folding in source' => sub {
    my %cases = ( 'return 12 / 3;' => 4, 'return 13 / 3;' => 4, 'return 13 % 3;' => 1, 'return 100 / 7;' => 14, 'return 100 % 7;' => 2, );
SKIP: {
        skip 'Execution test only supported on native hosts', scalar keys %cases unless $platform->is_native;
        for my $src ( sort keys %cases ) {
            my $module = Brocken::Compiler->new->compile($src);
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $out    = $brocken->tmpdir . '/imm_src' . $brocken->ext;
            $brocken->linker->write_executable( $out, $funcs, $platform );
            my $ret = system $out;
        SKIP: {
                skip "system() failed to spawn ($!) for $src", 1 if $ret == -1;
                is( $? >> 8, $cases{$src}, "$src returned $cases{$src}" );
            }
            unlink $out;
        }
    }
};
done_testing;
