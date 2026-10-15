use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use IPC::Open3 ();
use Symbol      qw[gensym];
use Test2::Tools::Brocken qw[answers executable_targets temp_path];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# `warn(@msgs)` writes a diagnostic to stderr and keeps going. `die(@msgs)` raises an exception: with a `try`/`catch`
# in scope it unwinds to the handler exactly as `throw` does, and with none it reports the message on stderr and ends
# the process with status 255, Perl's status for an uncaught `die`. Both build their text from the argument list the
# way `say` stringifies -- numbers in decimal, `Bool` as `1`/`""`, a dynamic box through its tag -- and the empty list
# falls back to Perl's own wording ("Warning: something's wrong" / "Died"). There is no runtime source location, so
# Perl's " at FILE line N." suffix is absent.
#
# `die` needs setjmp/longjmp, which the Wasm backend does not provide, so the status cases run native-only. `warn`
# writes through libc `write`, so its output is read from a host-only run.

my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();

sub native_case { answers( $_[0], $_[1], $_[2], targets => [@native_targets] ) }

# Compile a snippet, link it for the host, and return the executable's path; the caller removes it. The rodata map has
# to be handed to the linker or a string literal is read from a dangling address.
sub link_host ($src) {
    my $brocken = Brocken->new;
    my $module  = $brocken->compile($src);
    my $funcs   = $brocken->codegen->emit_functions( $module->functions );
    $brocken->linker->set_rodata( $module->rodata ) if $module->rodata && keys %{ $module->rodata };
    my $file = temp_path('warn_die') . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    return $file;
}

# Run a snippet on the host and return its stdout, stderr, and exit status. `answers` compares the process status only,
# so the `warn` cases -- whose whole effect is text on stderr -- read the streams through a pipe here.
sub host_run ($src) {
    my $file = link_host($src);
    my $err  = gensym;
    my $pid  = IPC::Open3::open3( my $in, my $out, $err, $file );
    close $in;
    my $stdout = do { local $/; <$out> } // '';
    my $stderr = do { local $/; <$err> } // '';
    waitpid $pid, 0;
    my $status = $? >> 8;
    unlink $file if -e $file;
    return ( $stdout, $stderr, $status );
}

subtest 'an uncaught die ends the process with status 255' => sub {
    native_case( 'die("boom"); return 0;', 255, 'die("boom") exits 255' );
    native_case( 'die; return 0;',         255, 'bare die exits 255' );
    native_case( 'my i64 $x = 0; die("no"); $x = 1; return $x;', 255, 'no statement after die runs' );
};

subtest 'die unwinds to an enclosing catch' => sub {
    native_case( 'my i64 $x = 0; try { die "x"; $x = 1; } catch ($e) { $x = 9; } return $x;', 9,
        'the rest of the try body is skipped once die raises' );
    native_case( 'my i64 $x = 0; try { die "a"; } catch ($e) { $x = 1; } finally { $x = $x + 41; } return $x;', 42,
        'finally runs after a caught die' );
};

subtest 'die from a callee' => sub {
    native_case( 'sub f() : returns(i64) { die "in f"; return 0; } return f() + 1;', 255,
        'a die in a callee ends the process' );
    native_case(
        'sub f() : returns(i64) { die "x"; return 0; } my i64 $r = 0; try { $r = f(); } catch ($e) { $r = 5; } return $r;',
        5, 'a die in a callee unwinds to the caller catch' );
};

subtest 'die takes a postfix modifier' => sub {
    native_case( 'die("no") if true; return 4;',      255, 'die(...) if true fires' );
    native_case( 'die("no") if false; return 4;',     4,   'die(...) if false is skipped' );
    native_case( 'die("no") unless false; return 4;', 255, 'die(...) unless false fires' );
};

subtest 'warn writes its message to stderr and continues' => sub {
    my ( $out, $err, $status ) = host_run('warn "hello"; return 7;');
    is( $out,    '',       'warn writes nothing to stdout' );
    is( $err,    "hello\n", 'the message and a newline reach stderr' );
    is( $status, 7,        'execution continues past warn' );
};

subtest 'warn stringifies its arguments the way say does' => sub {
    my ( undef, $err ) = host_run('warn 42; return 0;');
    is( $err, "42\n", 'a number is rendered as its decimal text' );

    ( undef, $err ) = host_run('warn "a", "b", 7; return 0;');
    is( $err, "ab7\n", 'a list of arguments is concatenated in order' );

    ( undef, $err ) = host_run('warn true; return 0;');
    is( $err, "1\n", 'true renders as 1' );

    ( undef, $err ) = host_run('warn false; return 0;');
    is( $err, "\n", 'false renders as the empty string' );
};

subtest 'the bare forms use Perl wording' => sub {
    my ( undef, $err ) = host_run('warn; return 0;');
    is( $err, "Warning: something's wrong\n", 'bare warn uses Perl\'s default text' );

    my ( undef, $die_err, $status ) = host_run('die; return 0;');
    is( $die_err, "Died\n", 'bare die reports "Died"' );
    is( $status,  255,      'bare die exits 255' );
};

subtest 'an uncaught die reports its message before exiting' => sub {
    my ( $out, $err, $status ) = host_run('die "BOOM"; return 0;');
    is( $out,    '',       'die writes nothing to stdout' );
    is( $err,    "BOOM\n", 'the message reaches stderr' );
    is( $status, 255,      'and the status is 255' );
};

subtest 'output written before an uncaught die still reaches the terminal' => sub {
    my ( $out, undef, $status ) = host_run('say("before"); die "after"; return 0;');
    is( $out,    "before\n", 'the earlier say is flushed before the process ends' );
    is( $status, 255,        'the die status wins' );
};

subtest 'a buffered say cannot overtake a later warn' => sub {
SKIP: {
        skip 'merging the streams needs a POSIX shell', 1 if $^O eq 'MSWin32';
        my $file   = link_host('say("out"); warn "W"; return 0;');
        my $merged = qx{"$file" 2>&1};
        unlink $file if -e $file;
        is( $merged, "out\nW\n", 'stdout is flushed before the warn reaches stderr' );
    }
};

done_testing;
