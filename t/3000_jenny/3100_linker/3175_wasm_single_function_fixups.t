use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::Wasm;

# Parses out the raw payload of a named Wasm section.
sub wasm_section {
    my ( $bin, $want ) = @_;
    my $pos = 8;
    while ( $pos < length($bin) ) {
        my $id   = ord substr $bin, $pos++, 1;
        my $size = 0;
        my $sh   = 0;
        do { $size += ( ord( substr $bin, $pos, 1 ) & 0x7F ) << $sh; $sh += 7 } while ( ord( substr $bin, $pos++, 1 ) & 0x80 );
        my $payload = substr $bin, $pos, $size;
        return $payload if $id == $want;
        $pos += $size;
    }
    return undef;
}
subtest 'a single-function module resolves its call placeholders' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-unknown');

    # Body = `call <5-byte LEB placeholder>`.  The placeholder fixup points past the 0x10 opcode.
    my $codegen_output = {
        body           => "\x10\x80\x80\x80\x80\x00",
        locals         => "\x00",
        name           => '_BROCKEN_ENTRY',
        return_valtype => 0x7F,
        fixups         => [ { type => 'call_idx', target => '_BROCKEN_ENTRY', offset => 1 } ],
    };
    my $brocken     = Brocken->new();
    my $output_file = $brocken->tmpdir . '/single_call.wasm';
    my $linker      = Brocken::Jenny::Linker::Wasm->new();
    $linker->write_executable( $output_file, $codegen_output, $platform );
    open my $fh, '<:raw', $output_file or die "open $output_file: $!";
    my $bin = do { local $/; <$fh> };
    close $fh;
    is index( $bin, "\x10\x80\x80\x80\x80\x00" ), -1, 'no 5-byte call placeholder survives in the module';
    my $code = wasm_section( $bin, 10 );
    ok defined($code),                  'code section present';
    ok index( $code, "\x10\x00" ) >= 0, 'the single function calls index 0 (patched LEB128)' if defined $code;
    unlink $output_file;
};
done_testing;
