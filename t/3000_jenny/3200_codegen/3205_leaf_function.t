use v5.42;
use Test2::V0;
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# ──────────────────────────────────────────────────────
# Leaf function optimization test
# A leaf function (no calls) with no frame should skip
# all prologue/epilogue - just mov + ret.
# ──────────────────────────────────────────────────────
my $brocken  = Brocken->new();
my $platform = $brocken->platform;
SKIP: {
    skip 'Leaf optimization only tested on X86_64', 5 unless $platform->is_x64;

    # Build a leaf function: ret i32 42
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'leaf_test', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen = $brocken->codegen;
    my $bytes   = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Leaf function produced bytes' );

    # Leaf optimization should skip push rbp (0x55)
    my $first_byte = unpack 'C', substr( $bytes, 0, 1 );
    isnt( $first_byte, 0x55, 'First byte is NOT push rbp (leaf optimized)' );

    # The emitted bytes should be: mov eax, 42 ; ret  (6 bytes total)
    # mov eax, imm32 = 0xB8 + 0 (for eax) = 0xB8, followed by 42 as V
    # ret = 0xC3
    my $last_byte = unpack 'C', substr( $bytes, -1 );
    is( $last_byte, 0xC3, 'Last byte is ret' );

    # Codegen uses 64-bit mov (REX.W + MOV_IMM_RM): 48 C7 C0 <imm32>; ret
    my $expected = pack( 'CCCVC', 0x48, 0xC7, 0xC0, 42, 0xC3 );
    is( $bytes, $expected, 'Leaf function bytes match expected: mov rax, 42; ret' );

    # Run the binary to verify correctness
    my $linker      = $brocken->linker;
    my $output_file = $brocken->tmpdir . '/leaf_test' . $brocken->ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -x $output_file || $platform->is_windows, 'Leaf binary exists' );
    system $output_file;
    my $exit_code = $? >> 8;
    is( $exit_code, 42, 'Leaf binary returned 42' );
    unlink $output_file;
}
done_testing;
