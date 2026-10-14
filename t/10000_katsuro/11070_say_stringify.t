use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Test2::Tools::Brocken qw[executable_targets];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# `say`/`print` both lower to `puts`, which takes a String pointer, so a non-string argument has to be stringified
# before it is passed -- an integer handed over unchanged becomes an address and faults. Running the same snippet on
# the host and on every cross target whose emulator is present keeps the check off one backend's argument-passing
# quirks. Wasm is left out because its linker still has no data segment for the rodata strings.
sub output_of ($src) {
    my %out;
    for my $target ( executable_targets() ) {
        my ( $tag, $platform ) = @$target;
        next if $platform && $platform->arch =~ /^wasm/;
        my $brocken = $platform ? Brocken->new( platform => $platform ) : Brocken->new();
        my $module  = eval { $brocken->compile($src) };
        if ($@) { $out{ $platform ? $tag : 'host' } = "compile died: $@"; next }
        my $funcs   = $brocken->codegen->emit_functions( $module->functions );
        $brocken->linker->set_rodata( $module->rodata ) if $module->rodata && keys %{ $module->rodata };
        my $file = $brocken->tmpdir . '/say_stringify_' . $tag . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
        chmod 0755, $file;
        my $cmd = Test2::Tools::Brocken::cross_command( $file, $platform, [] );
        $out{ $platform ? $tag : 'host' } = $cmd ? scalar `@$cmd` : '(no emulator)';
        unlink $file;
    }
    return %out;
}

sub check_say ($src, $want, $name) {
    my %out = output_of($src);
    is( $out{$_}, $want, "$name [$_]" ) for sort keys %out;
    ok( keys %out, "$name: ran on at least one target" );
}

subtest 'say/print stringify an integer argument' => sub {
    check_say( "say(42);\nreturn 0;\n",                     "42\n", 'say integer literal' );
    check_say( "say(-7);\nreturn 0;\n",                     "-7\n", 'say negative literal' );
    check_say( "say(0);\nreturn 0;\n",                      "0\n",  'say zero' );
    check_say( "print(42);\nreturn 0;\n",                   "42\n", 'print integer literal' );
    check_say( "my i64 \$i = 7;\nsay(\$i);\nreturn 0;\n",   "7\n",  'say i64 variable' );
    check_say( "my u64 \$u = 5;\nsay(\$u);\nreturn 0;\n",   "5\n",  'say u64 variable' );
    check_say( "my i8 \$b = -3;\nsay(\$b);\nreturn 0;\n",   "-3\n", 'say i8 variable' );
};

subtest 'say/print pass a String through unchanged' => sub {
    check_say( "say(\"hello\");\nreturn 0;\n",                     "hello\n", 'say string literal' );
    check_say( "my String \$s = \"str\";\nsay(\$s);\nreturn 0;\n", "str\n",   'say String variable' );
    check_say( "say(\"n=\");\nsay(7);\nreturn 0;\n",               "n=\n7\n", 'two say calls' );
};

subtest 'say stringifies a boxed Any through its tag' => sub {
    check_say( "my Any \$v = 42;\nsay(\$v);\nreturn 0;\n",     "42\n",   'boxed int' );
    check_say( "my Any \$v = \"text\";\nsay(\$v);\nreturn 0;\n", "text\n", 'boxed String' );
    check_say( "my Any \$v = true;\nsay(\$v);\nreturn 0;\n",   "1\n",    'boxed true' );

    # A boxed bool does not keep its bool-ness: the box tag for a narrow integer is the same whether the value was a
    # bool or an int, so a boxed `false` renders through its integer payload as "0" rather than the "" of spec 4.2.
    check_say( "my Any \$v = false;\nsay(\$v);\nreturn 0;\n", "0\n", 'boxed false (integer payload)' );
};

subtest 'a bool stringifies as 1 or the empty string (spec 4.2)' => sub {
    check_say( "say(true);\nreturn 0;\n",  "1\n", 'say(true)' );
    check_say( "say(false);\nreturn 0;\n", "\n",  'say(false)' );
    check_say( "say(1 < 2);\nreturn 0;\n", "1\n", 'say(computed true)' );
    check_say( "say(1 > 2);\nreturn 0;\n", "\n",  'say(computed false)' );
};

subtest 'undef stringifies as the empty string' => sub {
    check_say( "my Any \$v;\nsay(\$v);\nreturn 0;\n",        "\n", 'say undefined Any' );
    check_say( "my %h;\nsay(%h{\"missing\"});\nreturn 0;\n", "\n", 'say missing hash value' );
};

subtest 'say() with no argument prints an empty line' => sub {
    check_say( "say();\nreturn 0;\n", "\n", 'say()' );
};

done_testing;
