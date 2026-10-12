use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Lindsay;
use Brocken::Jenny::Codegen::ARM64;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Apple's ARM64 ABI diverges from AAPCS64 for calls to variadic functions: the fixed arguments are
# placed in registers as usual, but every variadic argument is written to 8-byte stack slots instead
# of being read back out of the argument registers. Brocken's own routines never take a variable number
# of arguments, so the only place this arises is a call whose argument list is longer than the callee's
# fixed parameter list -- a call into a C variadic such as printf. The lowering records the number of
# fixed and variadic arguments on the call, and the encoder materialises the register save area
# (rounded up to 16 bytes) around the branch.
#
# These assertions pin the caller-side encoding. The macOS CI matrix runs the whole suite on Apple
# Silicon (macos-15, aarch64), so this is exercised on the real target there; the encoding itself is
# platform-independent once the macOS platform object is in hand, so it also runs on the Linux hosts.

sub sub_sp_imm {
    my ($w) = @_;
    return undef unless ( $w & 0xFFC003FF ) == 0xD10003FF;    # sub sp, sp, #imm  (imm12, shift 0)
    return ( $w >> 10 ) & 0xFFF;
}

sub add_sp_imm {
    my ($w) = @_;
    return undef unless ( $w & 0xFFC003FF ) == 0x910003FF;    # add sp, sp, #imm
    return ( $w >> 10 ) & 0xFFF;
}

sub str_64_sp {
    my ($w) = @_;
    return undef unless ( $w & 0xFFC00000 ) == 0xF9000000;    # str Xt, [sp, #imm12*8]
    my $rt = $w & 0x1F;
    my $rn = ( $w >> 5 ) & 0x1F;
    return undef unless $rn == 31;                            # base is sp, not fp or a general register
    return ( ( $w >> 10 ) & 0xFFF, $rt );
}

sub word_at {
    my ( $func, $off ) = @_;
    return unpack( 'V', substr( $func->{bytes}, $off, 4 ) );
}

# Build a module whose main calls a one-parameter function with $total arguments, so there are
# ($total - 1) variadic arguments. Only main is inspected; the callee exists so the call resolves.
sub build_main {
    my ($total) = @_;
    my $i64 = Brocken::Lindsay::IR::Type::i64();
    my $b   = Brocken::Lindsay::IR::Builder->new();
    my $p   = Brocken::Lindsay::IR::Value->new( type => $i64, name => 'a' );
    my $callee = Brocken::Lindsay::IR::Function->new( name => 'variadic_c', return_type => $i64, params => [$p] );
    $b->position_at_end( $callee->append_block('entry') );
    $b->build_ret($p);
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64, params => [] );
    $b->position_at_end( $main->append_block('entry') );
    my @args = map { Brocken::Lindsay::IR::Constant->new( type => $i64, value => $_ ) } 1 .. $total;
    $b->build_ret( $b->build_call( $callee, \@args, '%r' ) );
    return $main;
}

sub emit_main {
    my ( $triple, $total ) = @_;
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $codegen  = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
    my $funcs    = $codegen->emit_functions( [ build_main($total) ] );
    my ($main) = grep { $_->{name} eq 'main' } $funcs->@*;
    my ($fixup) = grep { $_->{type} eq 'call_bl' && $_->{target} eq 'variadic_c' } $main->{fixups}->@*;
    return ( $main, $fixup, $platform );
}

subtest 'macOS saves seven variadic arguments into a 64-byte register save area' => sub {
    my ( $main, $fixup, $platform ) = emit_main( 'aarch64-apple-darwin', 8 );
    ok $platform->is_macos, 'the parsed platform reports macOS';
    ok $fixup, 'the call to the variadic callee is recorded as a BL fixup';
    my $o = $fixup->{offset};
    is $o % 4, 0, 'the branch lands on an instruction boundary';

    # sub sp, sp, #64 -- eight 8-byte slots, 16-byte aligned.
    is sub_sp_imm( word_at( $main, $o - 32 ) ), 64, 'the prologue reserves a 64-byte save area';

    # The seven variadic arguments (the callee's one fixed parameter stays in x0) are stored, in order,
    # into the low end of the save area.
    for my $j ( 0 .. 6 ) {
        my ( $imm12, $rt ) = str_64_sp( word_at( $main, $o - 28 + 4 * $j ) );
        is( $imm12, $j,     "variant slot $j stores to [sp, #" . ( $j * 8 ) . ']' );
        is( $rt,    1 + $j, "variant slot $j captures x" . ( 1 + $j ) );
    }

    is word_at( $main, $o ) & 0xFC000000, 0x94000000, 'the branch itself is a BL';
    is add_sp_imm( word_at( $main, $o + 4 ) ), 64, 'the save area is released straight after the call';
};

subtest 'a non-Apple ARM64 target passes variadic arguments without a save area' => sub {
    my ( $main, $fixup, $platform ) = emit_main( 'aarch64-unknown-linux-gnu', 8 );
    ok !$platform->is_macos, 'the parsed platform is not macOS';
    ok $fixup, 'the call is still recorded as a BL fixup';
    my $o = $fixup->{offset};

    # AAPCS64 leaves the extra values in the argument registers; the caller writes nothing to the stack
    # for them, so the instruction immediately before the branch is not a save-area store and none of
    # the register slots precede the call.
    ok !defined str_64_sp( word_at( $main, $o - 4 ) ), 'no variadic store sits before the branch';
    ok !defined sub_sp_imm( word_at( $main, $o - 8 ) ),  'no save-area reservation sits before the branch';
    ok !defined add_sp_imm( word_at( $main, $o + 4 ) ),  'no save-area release follows the branch';
};
#
done_testing;
