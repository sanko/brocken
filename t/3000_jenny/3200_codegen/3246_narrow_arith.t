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

my $i64 = Brocken::Lindsay::IR::Type::i64();
my %TYPE = (
    i8  => Brocken::Lindsay::IR::Type::i8(),
    i16 => Brocken::Lindsay::IR::Type::i16(),
    i32 => Brocken::Lindsay::IR::Type::i32(),
    i64 => Brocken::Lindsay::IR::Type::i64(),
);

# A REX prefix is always 0x40-0x4F. The load, store and store_imm encoders
# computed theirs as "(bits == 64 ? 0x48 : 0) | rex_bits", so a narrow-width
# access to a high register emitted the bare REX bit 0x04 instead of 0x44. 0x04
# is not a REX prefix at all: it is the ADD AL, imm8 opcode, so the decoder
# derailed, ran off into a CLI and the process died. Every arithmetic operation
# that read a narrow value out of memory was affected.

sub build {
    my ( $tname, @spec ) = @_;
    my $t       = $TYPE{$tname};
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $seq     = 0;
    my $nm      = sub { sprintf '%%v%d', $seq++ };
    my $K       = sub { Brocken::Lindsay::IR::Constant->new( @_ ) };
    $builder->position_at_end( $func->append_block('entry') );

    my $ld = sub {    # round-trip through memory, which is what hit the bad REX byte
        my ( $value ) = @_;
        my $slot = $builder->build_alloca( $t, $nm->() );
        $builder->build_store( $K->( type => $t, value => $value ), $slot );
        return $builder->build_load( $t, $slot, $nm->() );
    };
    my $C = sub { $K->( type => $t, value => $_[0] ) };

    my @checks;
    for my $case (@spec) {
        my ( $got, $want ) = @$case;
        my $wide = $builder->build_sext( $got, $i64, $nm->() );
        push @checks, $builder->build_icmp( 'eq', $wide, $K->( type => $i64, value => $want ), $nm->() );
    }
    my $all = $checks[0];
    $all = $builder->build_and( $all, $checks[$_], $nm->() ) for 1 .. $#checks;

    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->build_cond_br( $all, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( $K->( type => $i64, value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( $K->( type => $i64, value => 0 ) );

    return $brocken->codegen->emit_function($func);
}

# Values stay small enough to be exact in every width, including i8.
my @cases = (
    [ 'add(6,5)'   => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_add( $ld->(6),  $ld->(5),  $nm->() ) } ],
    [ 'sub(9,4)'   => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_sub( $ld->(9),  $ld->(4),  $nm->() ) } ],
    [ 'mul(6,5)'   => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_mul( $ld->(6),  $ld->(5),  $nm->() ) } ],
    [ 'and(12,10)' => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_and( $ld->(12), $ld->(10), $nm->() ) } ],
    [ 'or(12,3)'   => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_or(  $ld->(12), $ld->(3),  $nm->() ) } ],
    [ 'xor(12,10)' => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_xor( $ld->(12), $ld->(10), $nm->() ) } ],
    [ 'shl(3,2)'   => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_shl(  $ld->(3),  $C->(2),  $nm->() ) } ],
    [ 'lshr(12,2)' => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_lshr( $ld->(12), $C->(2),  $nm->() ) } ],
    [ 'neg(7)'     => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_neg(  $ld->(7),  $nm->() ) } ],
    [ 'abs(-7)'    => sub { my ( $b, $nm, $K, $ld, $C ) = @_; $b->build_abs(  $ld->(-7), $nm->() ) } ],
);
my %want = (
    'add(6,5)' => 11, 'sub(9,4)' => 5,  'mul(6,5)' => 30, 'and(12,10)' => 8,
    'or(12,3)' => 15, 'xor(12,10)' => 6, 'shl(3,2)' => 12, 'lshr(12,2)' => 3,
    'neg(7)' => -7,  'abs(-7)' => 7,
);

for my $tname (qw(i8 i16 i32 i64)) {
    my $t       = $TYPE{$tname};
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $seq     = 0;
    my $nm      = sub { sprintf '%%v%d', $seq++ };
    my $K       = sub { Brocken::Lindsay::IR::Constant->new( @_ ) };
    $builder->position_at_end( $func->append_block('entry') );
    my $ld = sub {
        my ( $value ) = @_;
        my $slot = $builder->build_alloca( $t, $nm->() );
        $builder->build_store( $K->( type => $t, value => $value ), $slot );
        return $builder->build_load( $t, $slot, $nm->() );
    };
    my $C = sub { $K->( type => $t, value => $_[0] ) };

    my @checks;
    for my $case (@cases) {
        my $got  = $case->[1]->( $builder, $nm, $K, $ld, $C );
        my $wide = $builder->build_sext( $got, $i64, $nm->() );
        push @checks, $builder->build_icmp( 'eq', $wide, $K->( type => $i64, value => $want{ $case->[0] } ), $nm->() );
    }

    # Enough values live at once that the allocator has to reach for r8-r11, which
    # is the REX.R case that was being encoded without its base bit.
    # (1..16 mod 7) sums to 21 + 21 + 3 = 45.
    my @live = map { $ld->( $_ % 7 ) } 1 .. 16;
    my $acc  = $live[0];
    $acc = $builder->build_add( $acc, $live[$_], $nm->() ) for 1 .. $#live;
    push @checks, $builder->build_icmp( 'eq', $acc, $K->( type => $i64, value => 45 ), $nm->() );

    my $all = $checks[0];
    $all = $builder->build_and( $all, $checks[$_], $nm->() ) for 1 .. $#checks;
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->build_cond_br( $all, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( $K->( type => $i64, value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( $K->( type => $i64, value => 0 ) );

    my $bytes = $brocken->codegen->emit_function($func);
    ok( length($bytes) > 0, "Generated $tname bytes" );

    SKIP: {
        skip "Execution test only supported on $platform->friendly", 2 unless $platform->is_native;
        my $out = $brocken->tmpdir . "/narrow_$tname" . $brocken->ext;
        $brocken->linker->write_executable( $out, $bytes, $platform );
        ok( -e $out, "$tname binary exists" );
        my $ret = system $out;
        SKIP: {
            skip "system() failed to spawn ($!)", 1 if $ret == -1;
            is( $? >> 8, 42, "$tname arithmetic returned 42" );
        }
        unlink $out;
    }
}

subtest 'narrow load uses a real REX prefix' => sub {
    # Pin the encoding itself. The second load lands in r8, so it needs REX.R, and
    # the prefix byte has to carry the 0x40 base: 44 for i32, not 04.
    for my $tname (qw(i8 i16 i32)) {
        my $t       = $TYPE{$tname};
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64 );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        my $seq     = 0;
        my $nm      = sub { sprintf '%%v%d', $seq++ };
        my $K       = sub { Brocken::Lindsay::IR::Constant->new( @_ ) };
        $builder->position_at_end( $func->append_block('entry') );
        my $ld = sub {
            my ( $value ) = @_;
            my $slot = $builder->build_alloca( $t, $nm->() );
            $builder->build_store( $K->( type => $t, value => $value ), $slot );
            return $builder->build_load( $t, $slot, $nm->() );
        };
        $builder->build_add( $ld->(6), $ld->(5), $nm->() );
        $builder->build_ret( $K->( type => $i64, value => 0 ) );
        my $bytes = $brocken->codegen->emit_function($func);
        unlike( $bytes, qr/\x04\x8b/, "$tname load does not emit a bare REX.R" );
        like( $bytes, qr/[\x40-\x4f]\x8b/, "$tname load emits a proper REX prefix" );
    }
};

done_testing;
