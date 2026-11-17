use v5.42;
use Test2::V0;
use blib;
use Brocken;

# Compiles a snippet and returns the module's rodata map (label -> bytes). `Brocken->compile` seeds it from the lowerer,
# so this is exactly the map the linker will place and the back end's `lea_rodata` fixups will resolve against.
sub rodata_for ($src) {
    my $brocken = Brocken->new;
    my $module  = $brocken->compile($src);
    return $module->rodata;
}
subtest 'rodata labels are content-derived and stable across compiles' => sub {

    # Two different programs, each of which lowers a different slice of the core runtime. The back end caches the
    # emitted core blobs for the whole process, keyed only by target, so those blobs embed rodata labels that must keep
    # meaning the same bytes in every later compilation. A per-compile counter (`__str_0`, `__str_1`, ...) broke that:
    # the same label named different bytes in different compiles, and a cached core blob then read the wrong literal.
    my $a = rodata_for(<<'BROCKEN');
my ptr $hb = Brocken::heap_base();
my ptr $s  = "Hello World";
say( Brocken::Runtime::str_len($s) );
say( Brocken::Runtime::str_substr_rest( $hb, $s, 6 ) );
return 0;
BROCKEN
    my $b = rodata_for(<<'BROCKEN');
my $dyn = "Brocken";
say( length($dyn) );
say( lc($dyn) );
say( ucfirst("brocken") );
return 0;
BROCKEN
    my @conflicts;
    for my $label ( sort keys %$a ) {
        next unless exists $b->{$label};
        push @conflicts, $label if $a->{$label} ne $b->{$label};
    }
    is \@conflicts, [], 'a shared label never names different bytes in another compile';

    # The same literal must intern to the same label no matter what surrounds it or in which order programs are built.
    my ($label_hello_a) = grep { $a->{$_} eq "Hello World\0" } keys %$a;
    ok defined $label_hello_a, 'the first compile interned "Hello World"';
    my $c = rodata_for(<<'BROCKEN');
my ptr $s = "Hello World";
return Brocken::Runtime::str_len($s);
BROCKEN
    my ($label_hello_c) = grep { $c->{$_} eq "Hello World\0" } keys %$c;
    is $label_hello_c, $label_hello_a, 'the same literal interns to the same label regardless of surrounding code';
};
subtest 'compiling the same program twice is byte-for-byte deterministic' => sub {
    my $src = <<'BROCKEN';
my $dyn = "Brocken";
say( length($dyn) );
return 0;
BROCKEN
    my $first  = rodata_for($src);
    my $second = rodata_for($src);
    is $second, $first, 'repeated compilation yields an identical rodata map';
};
subtest 'a second program in one process still runs with correct string output' => sub {

    # Exercised end to end: the first compile warms the core codegen cache, and the second must still print its own
    # literals. This is the user-visible face of the label-drift bug.
    my $run = sub ($src) {
        my $brocken = Brocken->new;
        my $module  = $brocken->compile($src);
        my $funcs   = $brocken->codegen->emit_functions( $module->functions );
        my $exe     = $brocken->tmpdir . '/test' . $brocken->ext;
        $brocken->linker->write_executable( $exe, $funcs, $brocken->platform );
        my $out = `$exe`;
        return ( $? >> 8, $out );
    };
    my ( $rc1, $out1 ) = $run->("say(\"first program\");\nreturn 0;\n");
    is $rc1,  0,                 'the first program exits cleanly';
    is $out1, "first program\n", 'the first program prints its literal';
    my ( $rc2, $out2 ) = $run->("my \$s = \"second program\";\nsay(\$s);\nsay( uc(\$s) );\nreturn 0;\n");
    is $rc2,  0,                                  'the second program exits cleanly';
    is $out2, "second program\nSECOND PROGRAM\n", 'the second program prints its own literals, not the cached ones';
};
done_testing;
__END__
# perl t/40000_runtime/40160_runtime_core_cache.t
