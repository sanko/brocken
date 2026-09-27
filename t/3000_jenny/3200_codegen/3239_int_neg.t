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

subtest 'integer neg' => sub {
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
    my $K   = sub { Brocken::Lindsay::IR::Constant->new( @_ ) };

    my @checks;
    my $chk = sub {
        my ( $got, $want_type, $want_value ) = @_;
        push @checks, $builder->build_icmp( 'eq', $got, $K->( type => $want_type, value => $want_value ), $nm->() );
    };

    my $neg_const = sub {
        my ( $type, $value ) = @_;
        $builder->build_neg( $K->( type => $type, value => $value ), $nm->() );
    };

    # Wide i64 constants are round-tripped through memory: comparing two bare
    # constants above 2**31 is a separate, pre-existing icmp bug.
    my $wide = sub {
        my ( $value ) = @_;
        my $slot = $builder->build_alloca( $i64, $nm->() );
        $builder->build_store( $K->( type => $i64, value => $value ), $slot );
        $builder->build_load( $i64, $slot, $nm->() );
    };

    # Widths: REX.W is only set for the 64-bit form.
    $chk->( $neg_const->( $i64, 42 ),            $i64, -42 );
    $chk->( $neg_const->( $i8,  7 ),             $i8,  -7 );
    $chk->( $neg_const->( $i16, 300 ),           $i16, -300 );
    $chk->( $neg_const->( $i32, 1234 ),          $i32, -1234 );

    # Wider than 32 bits, so a truncating lowering would be caught.
    my $neg_wide = $builder->build_neg( $wide->( 4294967297 ), $nm->() );
    push @checks, $builder->build_icmp( 'eq', $neg_wide, $wide->( -4294967297 ), $nm->() );
    push @checks, $builder->build_icmp( 'ne', $neg_wide, $wide->( 1 ),           $nm->() );

    # neg of a computed value
    my $diff = $builder->build_sub( $K->( type => $i64, value => 10 ), $K->( type => $i64, value => 3 ), $nm->() );
    my $nd   = $builder->build_neg( $diff, $nm->() );
    $chk->( $nd, $i64, -7 );

    # double neg
    $chk->( $builder->build_neg( $nd, $nm->() ), $i64, 7 );

    # neg of a value that arrives through memory
    my $slot = $builder->build_alloca( $i64, $nm->() );
    $builder->build_store( $K->( type => $i64, value => 99 ), $slot );
    my $ld  = $builder->build_load( $i64, $slot, $nm->() );
    $chk->( $builder->build_neg( $ld, $nm->() ), $i64, -99 );

    # Enough simultaneously live values that the allocator reaches the r8-r15
    # banks and spills; the emitted NEG there carries REX.W|REX.B.
    my @live = map { $builder->build_add( $K->( type => $i64, value => $_ ), $K->( type => $i64, value => 1 ), $nm->() ) } 1 .. 14;
    my $acc  = $live[0];
    $acc = $builder->build_add( $acc, $live[$_], $nm->() ) for 1 .. $#live;
    $chk->( $builder->build_neg( $acc, $nm->() ), $i64, -( ( 2 + 15 ) * 14 / 2 ) );

    # neg feeding a comparison, so NEG's result is consumed as a signed value
    my $n5 = $neg_const->( $i64, 5 );
    push @checks, $builder->build_icmp( 'slt', $n5, $K->( type => $i64, value => 0 ), $nm->() );

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
    ok( length($bytes) > 0, 'Generated integer neg bytes for ' . $platform->friendly );

    SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $out = $brocken->tmpdir . '/int_neg' . $brocken->ext;
        $brocken->linker->write_executable( $out, $bytes, $platform );
        ok( -e $out, 'Integer neg binary exists' );
        my $ret = system $out;
        SKIP: {
            skip "system() failed to spawn ($!)", 1 if $ret == -1;
            is( $? >> 8, 42, 'Integer neg returned 42 on ' . $platform->friendly );
        }
        unlink $out;
    }
};

done_testing;
