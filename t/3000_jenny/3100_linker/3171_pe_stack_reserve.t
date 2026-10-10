use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
use Brocken::Jenny::Linker;
use Brocken::Katsuro::Platform;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# SizeOfStackReserve/SizeOfStackCommit sit at 0x48/0x50 of a PE32+ optional header, which starts 24 bytes past the PE
# signature (a 4-byte signature plus a 20-byte COFF header). Reading them straight out of the linked image is enough
# to prove the linker honoured the option; the image does not have to be runnable here to be inspected.
sub pe_stack_sizes ($file) {
    open my $fh, '<:raw', $file or die "open $file: $!";
    read $fh, my $head, 0x1000 or die "read $file: $!";
    close $fh;
    my $pe    = unpack 'V', substr $head, 0x3C, 4;
    my $magic = unpack 'v', substr $head, $pe + 24, 2;
    die "not PE32+" unless $magic == 0x020b;
    my ( $reserve, $commit ) = unpack 'Q< Q<', substr $head, $pe + 24 + 0x48, 16;
    return ( $reserve, $commit );
}

my $windows = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');

sub link_exe ( $brocken, $name ) {
    my $module = $brocken->compile("use feature 'brocken_native_types';\nreturn 7;\n");
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = $brocken->tmpdir . "/$name.exe";
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    return $file;
}

subtest 'PE optional header carries the default stack sizes' => sub {
    my $brocken = Brocken->new( platform => $windows );
    is $brocken->stack_reserve, Brocken::Jenny::Linker::DEFAULT_STACK_RESERVE(), 'reserve defaults to the linker constant';
    is $brocken->stack_commit,  Brocken::Jenny::Linker::DEFAULT_STACK_COMMIT(),  'commit defaults to the linker constant';

    my $file = link_exe( $brocken, 'stk_default' );
    my ( $reserve, $commit ) = pe_stack_sizes($file);
    is $reserve, 0x400000, 'default SizeOfStackReserve is 4 MiB';
    is $commit,  0x200000, 'default SizeOfStackCommit is 2 MiB';
    unlink $file;
};

subtest 'stack_reserve and stack_commit are configurable' => sub {
    my $brocken = Brocken->new( platform => $windows, stack_reserve => 8 * 1024 * 1024, stack_commit => 1024 * 1024 );
    my $file = link_exe( $brocken, 'stk_custom' );
    my ( $reserve, $commit ) = pe_stack_sizes($file);
    is $reserve, 8 * 1024 * 1024, 'custom SizeOfStackReserve reaches the header';
    is $commit,  1024 * 1024,     'custom SizeOfStackCommit reaches the header';
    unlink $file;
};

subtest 'every linker accepts the sizes, not just PE' => sub {
    for my $triple ( 'x86_64-unknown-linux-gnu', 'aarch64-apple-darwin', 'wasm32-unknown-wasi' ) {
        my $brocken = eval { Brocken->new( platform => Brocken::Katsuro::Platform::parse($triple), stack_reserve => 6 * 1024 * 1024, stack_commit => 3 * 1024 * 1024 ) };
        ok !$@, "$triple constructs with a stack reserve" or diag($@);
        is $brocken->linker->stack_reserve, 6 * 1024 * 1024, "$triple linker keeps the reserve" if $brocken;
    }
};

subtest 'a configured reserve still produces a runnable program' => sub {
SKIP: {
        skip 'requires a native x86_64 Windows host', 1 unless $windows->is_native;
        my $brocken = Brocken->new( platform => $windows, stack_reserve => 16 * 1024 * 1024, stack_commit => 2 * 1024 * 1024 );
        my $file    = link_exe( $brocken, 'stk_run' );
        run_exec( $file, expected_exit => 7, name => 'custom-reserve PE runs and returns its value', platform => $windows );
        unlink $file;
    }
};

done_testing;
