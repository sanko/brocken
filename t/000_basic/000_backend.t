use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', 'blib/lib', '../blib/lib';
use Brocken;
use Brocken::Katsuro::Platform;
#
# The constructor picks its back end from the platform rather than from a table
# of its own, so this checks that every target resolves to the code generator
# for its architecture and the linker for its binary format.
#
subtest 'constructor builds the back end the platform names' => sub {
    my @targets = (
        [ 'x86_64-unknown-linux-gnu',  'Brocken::Jenny::Codegen::X86_64',  'Brocken::Jenny::Linker::ELF64', '' ],
        [ 'aarch64-unknown-linux-gnu', 'Brocken::Jenny::Codegen::ARM64',   'Brocken::Jenny::Linker::ELF64', '' ],
        [ 'riscv64-unknown-linux-gnu', 'Brocken::Jenny::Codegen::RISCV64', 'Brocken::Jenny::Linker::ELF64', '' ],
        [ 'x86_64-pc-windows-msvc',    'Brocken::Jenny::Codegen::X86_64',  'Brocken::Jenny::Linker::PE',    '.exe' ],
        [ 'aarch64-pc-windows-msvc',   'Brocken::Jenny::Codegen::ARM64',   'Brocken::Jenny::Linker::PE',    '.exe' ],
        [ 'x86_64-apple-darwin',       'Brocken::Jenny::Codegen::X86_64',  'Brocken::Jenny::Linker::MachO', '' ],
        [ 'aarch64-apple-darwin',      'Brocken::Jenny::Codegen::ARM64',   'Brocken::Jenny::Linker::MachO', '' ],
        [ 'x86_64-unknown-freebsd',    'Brocken::Jenny::Codegen::X86_64',  'Brocken::Jenny::Linker::ELF64', '' ],
        [ 'wasm32-unknown-wasi',       'Brocken::Jenny::Codegen::Wasm',    'Brocken::Jenny::Linker::Wasm',  '.wasm' ],
    );
    for my $target (@targets) {
        my ( $triple, $codegen, $linker, $ext ) = @$target;
        subtest $triple => sub {
            my $brocken = eval { Brocken->new( platform => Brocken::Katsuro::Platform::parse($triple) ) };
            ok $brocken, 'constructor returns a compiler' or diag $@;
            isa_ok $brocken->codegen, [$codegen];
            isa_ok $brocken->linker,  [$linker];
            is $brocken->ext, $ext, 'output extension';
        };
    }
};
#
subtest 'an architecture with no code generator is still refused' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('i386-pc-linux-gnu');
    my $brocken  = eval { Brocken->new( platform => $platform ) };
    ok !$brocken, 'constructor dies';
    like $@, qr/Unsupported platform/, 'and says why';
    like $@, qr/i386/,                 'naming the architecture';
};
#
done_testing;
