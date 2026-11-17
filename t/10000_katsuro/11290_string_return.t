use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[answers executable_targets];

# A `String`-returning sub may return a string literal. The literal reaches the lowerer as a rodata reference -- it
# carries a label but no register name -- and the return path has to materialise that reference into the return
# register. It used to hand the reference to `_lower_opnd`, which built a virtual register named from the (missing)
# `name`, so the codegen warned "Use of uninitialized value in hash element" and the caller received a garbage pointer
# (a `say` of it crashed). The `_materialize` path already handled rodata for a float return and for arguments; the
# integer/pointer return now uses it too, on all three native backends.
#
# Native-only: the Wasm backend has no data segment for rodata yet, so a string literal cannot be linked there.
my @native_targets = grep { $_->[0] ne 'wasm32-unknown-wasi' } executable_targets();
sub native_case { answers( $_[0], $_[1], $_[2], targets => [@native_targets] ) }

# The returned pointer has to be usable, not merely non-null: reading its length proves it points at the literal.
subtest 'a String sub may return a string literal' => sub {
    native_case( q{sub a() :returns(String) { return 'x'; } exit(length(a()));},     1, 'length of a returned literal' );
    native_case( q{sub a() :returns(String) { return 'hello'; } exit(length(a()));}, 5, 'a longer literal' );
};
subtest 'a returned literal survives a nested call' => sub {
    native_case( q{sub a() :returns(String) { return 'x'; } sub b() :returns(String) { return a(); } exit(length(b()));},
        1, 'returned through another String sub' );
};
subtest 'a returned literal concatenates' => sub {
    native_case( q{sub a() :returns(String) { return 'ab'; } exit(length(a() . 'c'));}, 3, 'concatenated with another literal' );
};
subtest 'a method may return a string literal' => sub {
    native_case( q{class C { method m() :returns(String) { return 'hello'; } } my $c = C->new(); exit(length($c->m()));},
        5, 'method returning a literal' );
};

# The content itself, on the native host. `answers` only sees the exit code, so a wrong-but-NUL-terminated pointer of
# the right length would slip past the length checks above.
subtest 'a returned literal holds the right bytes' => sub {
    my $brocken = Brocken->new();
    plan skip_all => 'not a native host' unless $brocken->platform->is_native;
    my $src
        = q{sub a() :returns(String) { return 'blah'; } sub b(String $n) :returns(String) { return 'Hi, ' . $n; } say(a(), a(), b('Alex')); return 0;};
    my $module = $brocken->compile($src);
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    $brocken->linker->set_rodata( $module->rodata ) if $module->rodata && keys %{ $module->rodata };
    my $file = $brocken->tmpdir . '/string_return' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
    chmod 0755, $file;
    my $out = `$file`;
    unlink $file;
    is $out, "blahblahHi, Alex\n", 'say of returned literals prints the concatenated text';
};
done_testing;
