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
my $i32      = Brocken::Lindsay::IR::Type::i32();
my $i64      = Brocken::Lindsay::IR::Type::i64();

# IDIV divides the 128-bit sign extension of RAX, so RDX has to repeat RAX's sign
# bit. The lowering used to emit the unsigned sequence (XOR RDX,RDX + DIV) for both,
# which is only right when neither operand is negative: a negative dividend then
# looks like a huge unsigned value. These all returned garbage before the fix.
# Build a function that ANDs a list of (value, expected) comparisons together and
# returns 42 only if every one of them holds.
sub build_checks {
    my (@spec)  = @_;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $seq     = 0;
    my $nm      = sub { sprintf '%%v%d', $seq++ };
    my $K       = sub { Brocken::Lindsay::IR::Constant->new(@_) };
    $builder->position_at_end( $func->append_block('entry') );
    my $C      = sub { $K->( type => $i64, value => $_[0] ) };
    my $loaded = sub {                                           # a value that is not itself an immediate operand
        my ($value) = @_;
        my $slot = $builder->build_alloca( $i64, $nm->() );
        $builder->build_store( $C->($value), $slot );
        return $builder->build_load( $i64, $slot, $nm->() );
    };
    my @checks;
    for my $case (@spec) {
        my ( $got, $want ) = @$case;
        push @checks, $builder->build_icmp( 'eq', $got, $C->($want), $nm->() );
    }
    my $all = $checks[0];
    $all = $builder->build_and( $all, $checks[$_], $nm->() ) for 1 .. $#checks;
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->build_cond_br( $all, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( $K->( type => $i32, value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( $K->( type => $i32, value => 0 ) );
    return $brocken->codegen->emit_function($func);
}
subtest 'signed division truncates toward zero' => sub {
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $seq     = 0;
    my $nm      = sub { sprintf '%%v%d', $seq++ };
    my $K       = sub { Brocken::Lindsay::IR::Constant->new(@_) };
    $builder->position_at_end( $func->append_block('entry') );
    my $C = sub { $K->( type => $i64, value => $_[0] ) };

    # Immediate dividend, immediate divisor.
    my @cases = (
        [ 'div( 7,  2)' => $builder->build_div( $C->(7), $C->(2), $nm->() ),    3 ],
        [ 'div(-7,  2)' => $builder->build_div( $C->(-7), $C->(2), $nm->() ),  -3 ],
        [ 'div( 7, -2)' => $builder->build_div( $C->(7), $C->(-2), $nm->() ),  -3 ],
        [ 'div(-7, -2)' => $builder->build_div( $C->(-7), $C->(-2), $nm->() ),  3 ],
        [ 'rem( 7,  2)' => $builder->build_rem( $C->(7), $C->(2), $nm->() ),    1 ],
        [ 'rem(-7,  2)' => $builder->build_rem( $C->(-7), $C->(2), $nm->() ),  -1 ],
        [ 'rem( 7, -2)' => $builder->build_rem( $C->(7), $C->(-2), $nm->() ),   1 ],
        [ 'rem(-7, -2)' => $builder->build_rem( $C->(-7), $C->(-2), $nm->() ), -1 ],
    );

    # The remainder takes the sign of the dividend, the quotient the sign of the
    # operands, and both round toward zero rather than toward negative infinity.
    my $all = $builder->build_icmp( 'eq', $cases[0][1], $C->( $cases[0][2] ), $nm->() );
    for my $case (@cases) {
        $all = $builder->build_and( $all, $builder->build_icmp( 'eq', $case->[1], $C->( $case->[2] ), $nm->() ), $nm->() );
    }

    # Register dividend, register divisor.
    my $reg = sub {
        my ($value) = @_;
        my $slot = $builder->build_alloca( $i64, $nm->() );
        $builder->build_store( $C->($value), $slot );
        return $builder->build_load( $i64, $slot, $nm->() );
    };
    my $rdiv = $builder->build_div( $reg->(-12), $reg->(5), $nm->() );
    my $rrem = $builder->build_rem( $reg->(-12), $reg->(5), $nm->() );
    for my $pair ( [ $rdiv, -2 ], [ $rrem, -2 ] ) {
        $all = $builder->build_and( $all, $builder->build_icmp( 'eq', $pair->[0], $C->( $pair->[1] ), $nm->() ), $nm->() );
    }
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->build_cond_br( $all, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( $K->( type => $i32, value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( $K->( type => $i32, value => 0 ) );
    my $bytes = $brocken->codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated signed divide bytes for ' . $platform->friendly );
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $out = $brocken->tmpdir . '/signed_div' . $brocken->ext;
        $brocken->linker->write_executable( $out, $bytes, $platform );
        ok( -e $out, 'Signed divide binary exists' );
        my $ret = system $out;
    SKIP: {
            skip "system() failed to spawn ($!)", 1 if $ret == -1;
            is( $? >> 8, 42, 'Signed div/rem returned 42 on ' . $platform->friendly );
        }
        unlink $out;
    }
};
subtest 'unsigned division is unaffected' => sub {
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    my $seq     = 0;
    my $nm      = sub { sprintf '%%v%d', $seq++ };
    my $K       = sub { Brocken::Lindsay::IR::Constant->new(@_) };
    $builder->position_at_end( $func->append_block('entry') );
    my $C     = sub { $K->( type => $i64, value => $_[0] ) };
    my @cases = (
        [ 'udiv(7, 2)'     => $builder->build_udiv( $C->(7), $C->(2), $nm->() ),                    3 ],
        [ 'urem(7, 2)'     => $builder->build_urem( $C->(7), $C->(2), $nm->() ),                    1 ],
        [ 'udiv(-7, 2)'    => $builder->build_udiv( $C->(-7), $C->(2), $nm->() ),                   9223372036854775804 ],
        [ 'urem(-7, 2)'    => $builder->build_urem( $C->(-7), $C->(2), $nm->() ),                   1 ],
        [ 'udiv(12e9,1e9)' => $builder->build_udiv( $C->(12000000000), $C->(1000000000), $nm->() ), 12 ],
    );
    my $all = $builder->build_icmp( 'eq', $cases[0][1], $C->( $cases[0][2] ), $nm->() );

    for my $case (@cases) {
        $all = $builder->build_and( $all, $builder->build_icmp( 'eq', $case->[1], $C->( $case->[2] ), $nm->() ), $nm->() );
    }
    my $t_block = $func->append_block('if.then');
    my $f_block = $func->append_block('if.else');
    $builder->build_cond_br( $all, $t_block, $f_block );
    $builder->position_at_end($t_block);
    $builder->build_ret( $K->( type => $i32, value => 42 ) );
    $builder->position_at_end($f_block);
    $builder->build_ret( $K->( type => $i32, value => 0 ) );
    my $bytes = $brocken->codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated unsigned divide bytes' );
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $out = $brocken->tmpdir . '/unsigned_div' . $brocken->ext;
        $brocken->linker->write_executable( $out, $bytes, $platform );
        ok( -e $out, 'Unsigned divide binary exists' );
        my $ret = system $out;
    SKIP: {
            skip "system() failed to spawn ($!)", 1 if $ret == -1;
            is( $? >> 8, 42, 'Unsigned div/rem returned 42 on ' . $platform->friendly );
        }
        unlink $out;
    }
};
subtest 'signed divide sign-extends RDX' => sub {

    # A structural check on the encoding: the signed form has to sign-extend RAX
    # into RDX (REX.W CQTO = 48 99) and use the /7 group, while the unsigned form
    # zeroes RDX and uses /6. Guards the fix independently of the runtime results.
    # These are x86-64 encodings, so the subtest is meaningless on other hosts.
SKIP: {
        skip 'x86-64 encoding check only applies to x86_64 hosts', 1 unless $platform->is_x64;
        my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $builder = Brocken::Lindsay::IR::Builder->new();
        my $seq     = 0;
        my $nm      = sub { sprintf '%%v%d', $seq++ };
        my $K       = sub { Brocken::Lindsay::IR::Constant->new(@_) };
        $builder->position_at_end( $func->append_block('entry') );
        my $C = sub { $K->( type => $i64, value => $_[0] ) };
        $builder->build_div( $C->(7), $C->(2), $nm->() );
        my $bytes = $brocken->codegen->emit_function($func);
        like( $bytes, qr/\x48\x99/,            'signed div emits REX.W CQTO' );
        like( $bytes, qr/\x48\xf7[\xf8-\xff]/, 'signed div uses the IDIV group' );
    }
};
done_testing;
