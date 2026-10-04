use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro;
use Brocken::Jenny::Linker::ELF64;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);

# The linker asks the compiler where it keeps libpthread before it records a DT_NEEDED for it. That query used to be
# backticks with a `2>/dev/null`
# redirect:
#
#     my $out = `$cc -pthread -print-file-name=libpthread.so 2>/dev/null`;
#
# `2>/dev/null` is a POSIX-ism. cmd.exe has no idea what to do with the path /dev/null, so the shell never got as far as
# running the compiler: the probe came back empty on every platform, the soname was never resolved, and every link
# printed three "The system cannot find the path specified." lines.
#
# The replacement runs the compiler through a pipe with no shell in between.
# The compiler here is a stub, because what is under test is the plumbing and
# not any particular toolchain: if this subtest leaned on whatever gcc happens to have installed, it would skip on the
# very machines where the bug lives and pass vacuously against the broken code.
my $probe = \&Brocken::Jenny::Linker::ELF64::_cc_print_file_name;
is ref($probe), 'CODE', 'the shell-free query helper is available';
my $host = Brocken::Katsuro::Platform::parse();

# A stub compiler that prints whatever BROCKEN_STUB_OUT names, which is how a
# real compiler answers -print-file-name: an existing path when it has the library, the bare name back when it does not.
my $stub = temp_path('stub_cc') . ( $host->is_windows ? '.bat' : '' );
{
    my $body = $host->is_windows ? '@echo off' . "\n" . 'echo %BROCKEN_STUB_OUT%' . "\n" : '#!/bin/sh' . "\n" . 'echo "$BROCKEN_STUB_OUT"' . "\n";
    open my $fh, '>', $stub or die "cannot write stub compiler $stub: $!";
    print {$fh} $body;
    close $fh;
    chmod 0755, $stub unless $host->is_windows;
}

# Somewhere real for the stub to point at, so the caller's own "-e $out" check
# has something to agree with.
my $target = temp_path('libpthread_stub.so');
{
    open my $fh, '>', $target or die "cannot write $target: $!";
    close $fh;
}
subtest 'the query reaches the compiler and its answer comes back' => sub {
    local $ENV{BROCKEN_STUB_OUT} = $target;

    # With the old backticks form this was the empty string on Windows: the shell died on the /dev/null redirect before
    # the compiler ever ran.
    my $out = $probe->( $stub, 'libpthread.a' );
    ok defined $out && length $out, 'the compiler actually ran and answered';
    is $out, $target, 'the answer arrived intact, with the trailing newline stripped';
    ok -e $out, 'the answer is a path that exists on disk';
};
subtest 'the answer survives the caller-side accept test' => sub {
    plan skip_all => 'stub compiler did not run' unless -e $target;
    local $ENV{BROCKEN_STUB_OUT} = $target;
    my $lib = 'libpthread.a';
    my $out = $probe->( $stub, $lib );

    # The call loop accepts an answer only when it is defined, is not the bare
    # name echoed back, and is on disk. Walk that exact triple.
    ok $out && $out ne $lib && -e $out, 'the caller would accept this answer';
};
subtest 'a library the compiler lacks is echoed back and rejected' => sub {
    my $lib = 'libbrocken_no_such_library.so';
    local $ENV{BROCKEN_STUB_OUT} = $lib;
    my $out = $probe->( $stub, $lib );
    is $out, $lib, 'the bare name came back verbatim';
    ok !$out || !-e $out, 'and it is not on disk, so the caller treats it as not found';
};
subtest 'a missing compiler falls through quietly' => sub {

    # The old form ran this through cmd.exe, which printed "not recognized as an internal or external command". The pipe
    # form has no shell, so a program that is not installed is simply an empty answer.
    my $out = eval { $probe->( 'brocken_no_such_compiler_xyz', 'libpthread.so' ) };
    ok !$@, 'probing for a compiler that is not installed does not die';
    is $out, undef, 'and reports that it found nothing';
};
subtest 'no shell or redirect text is mixed into the answer' => sub {
    plan skip_all => 'stub compiler did not run' unless -e $target;
    local $ENV{BROCKEN_STUB_OUT} = $target;
    my $out = $probe->( $stub, 'libpthread.a' );
    unlike $out, qr{[\\/]dev[\\/]null}i,  'no /dev/null path leaks into the answer';
    unlike $out, qr{system cannot find}i, 'no shell error text leaks into the answer';
    unlike $out, qr{not recognized}i,     'no shell error text leaks into the answer';
};
unlink $stub, $target if -e $stub && -e $target;
done_testing;
