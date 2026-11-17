use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use IPC::Open3            ();
use Symbol                qw[gensym];
use Test2::Tools::Brocken qw[answers executable_targets temp_path];

# `return` at the top level has no subroutine to return from. The value it carries still becomes the entry function's
# return value -- the process exit code -- but that is an easy thing to reach for by mistake, so the compiler emits a
# runtime warning the first time such a `return` executes. A `return` inside a sub or method is ordinary and silent.
#
# The diagnostic goes through the same `write(2, ...)` path `warn`/`die` use, so the cases read stderr from a host-only
# run (the Wasm backend cannot link that path; see `11200_empty_sub.t`). The message carries no source location, like
# the other runtime diagnostics.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
sub native_case { answers( $_[0], $_[1], $_[2], targets => [@native_targets] ) }

# Compile a snippet, link it for the host, and return the executable's path; the caller removes it. The rodata map has
# to be handed to the linker or a string literal is read from a dangling address.
sub link_host ($src) {
    my $brocken = Brocken->new;
    my $module  = $brocken->compile($src);
    my $funcs   = $brocken->codegen->emit_functions( $module->functions );
    $brocken->linker->set_rodata( $module->rodata ) if $module->rodata && keys %{ $module->rodata };
    my $file = temp_path('return_outside') . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    return $file;
}

# Run a snippet on the host and return its stdout, stderr, and exit status.
sub host_run ($src) {
    my $file = link_host($src);
    my $err  = gensym;
    my $pid  = IPC::Open3::open3( my $in, my $out, $err, $file );
    close $in;
    my $stdout = do { local $/; <$out> }
        // '';
    my $stderr = do { local $/; <$err> }
        // '';
    waitpid $pid, 0;
    my $status = $? >> 8;
    unlink $file if -e $file;

    # The CRT writes a pipe in text mode, so a "\n" the program emits arrives as "\r\n" on Windows. These tests state
    # the newline the program intended, so fold the platform line ending back to "\n".
    if ( $^O eq 'MSWin32' ) {
        for ( $stdout, $stderr ) {s/\r\n/\n/g}
    }
    return ( $stdout, $stderr, $status );
}
my $WARNING = "Brocken: return outside of a subroutine\n";
subtest 'a top-level return warns and still sets the exit code' => sub {
    my ( $out, $err, $status ) = host_run('return 7;');
    is $out,    '',       'nothing is written to stdout';
    is $err,    $WARNING, 'the warning reaches stderr';
    is $status, 7,        'the returned value is still the process status';
};
subtest 'the warning does not depend on the returned value' => sub {
    my ( undef, $err, $status ) = host_run('return 0;');
    is $err,    $WARNING, 'a return of 0 warns too';
    is $status, 0,        'and exits 0';
    ( undef, $err, $status ) = host_run('return 42;');
    is $err,    $WARNING, 'a return of 42 warns';
    is $status, 42,       'and exits 42';
};
subtest 'a return inside a sub is silent' => sub {
    my ( undef, $err, $status ) = host_run('sub f() :returns(i64) { return 3; } my i64 $x = f();');
    is $err,    '', 'a return in a sub does not warn';
    is $status, 0,  'the entry falls through to its default status';
    ( undef, $err, $status ) = host_run('sub f() :returns(i64) { return 3; } exit(f());');
    is $err,    '', 'a sub return feeding exit stays silent';
    is $status, 3,  'and the value still reaches the process status';
};
subtest 'a return inside a method is silent' => sub {
    my ( undef, $err, $status ) = host_run('class C { method m() :returns(i64) { return 3; } } my $c = C->new(); my i64 $x = $c->m();');
    is $err,    '', 'a return in a method does not warn';
    is $status, 0,  'the entry falls through to its default status';
};
subtest 'an implicit return in a sub is silent' => sub {
    my ( undef, $err, $status ) = host_run('sub f() :returns(i64) { 5; } my i64 $x = f();');
    is $err,    '', 'a body that falls off its end does not warn';
    is $status, 0,  'the entry still falls through to its default status';
};
#
done_testing;
