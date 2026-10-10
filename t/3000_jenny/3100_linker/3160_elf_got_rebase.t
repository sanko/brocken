use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::ELF64;

# The entrance stub bakes a `call [rip + rel32]` to the exit GOT slot.  The stub is built before the inline
# setjmp/longjmp and import stubs are appended to .text, which grows the section and moves .got.  A program that
# forces one of those stubs used to ship an exit call pointed at the slot where .got used to be.
subtest 'the entrance stub exit displacement tracks the final .got rva' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu');

    # A large blob with a call to setjmp at its tail.  setjmp is undefined in the compiled code, so the linker emits
    # its inline stub at the end of .text.  The blob is sized so that appended stub pushes .text across a 0x1000 page
    # boundary, which relocates .got and would leave a stale displacement in the entrance stub.
    my $call_at = 4043;
    my $blob    = ( "\x90" x $call_at ) . pack( 'C5', 0xE8, 0, 0, 0, 0 );
    my @funcs   = ( { name => '_BROCKEN_ENTRY', bytes => $blob, fixups => [ { type => 'call_rel32', target => 'setjmp', offset => $call_at } ] } );
    my $brocken = Brocken->new();
    my $output_file = $brocken->tmpdir . '/got_rebase_test';
    my $linker      = Brocken::Jenny::Linker::ELF64->new();
    $linker->write_executable( $output_file, \@funcs, $platform );
    open my $fh, '<:raw', $output_file or die "open $output_file: $!";
    my $bin = do { local $/; <$fh> };
    close $fh;
    my $text_sec = $linker->layout->get('.text');
    my $got_sec  = $linker->layout->get('.got');
    is( substr( $bin, $text_sec->{off}, 4 ), "\x48\x83\xE4\xF0", '.text starts with the entrance stub' );
    my $stub_len = $linker->entry_stub_len($platform);

    # The exit call is `FF 15 <rel32>` immediately before the trailing ud2 of the stub, so the rip at the end of the
    # instruction sits stub_len-2 bytes into .text and the displacement four bytes earlier.
    my $exit_rip = $text_sec->{rva} + $stub_len - 2;
    my $disp     = unpack( 'l<', substr( $bin, $text_sec->{off} + $stub_len - 6, 4 ) );
    my $exit_got = $linker->import_rva('exit');
    is $disp, $exit_got - $exit_rip, 'the exit call still reaches the final exit GOT slot after .text grew';

    # The dynamic loader only populates the slot named by the .rela.dyn relocation, so that r_offset has to track the
    # same final .got the entrance stub calls.  When it lagged one page behind, the exit slot stayed zero and the
    # process jumped to address 0 as soon as a program ran off the end of main.  exit is the fourth fixed entry
    # (dlopen, dlsym, pthread_create, exit).
    my $rela_sec  = $linker->layout->get('.rela.dyn');
    my $exit_roff = unpack( 'Q<', substr( $bin, $rela_sec->{off} + 3 * 24, 8 ) );
    is $exit_roff, $linker->image_base + $exit_got, '.rela.dyn exit relocation names the final exit GOT slot';
    unlink $output_file;
};
done_testing;
