use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro::AST;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'list return and unpack produces correct values' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
sub make_list() -> ptr {
    return (3, 4);
}
my ($a, $b) = make_list();
return $a + $b;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_return' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 7, 'list return + unpack gives 3+4=7' );
        unlink $file;
    }
};
subtest 'list return with three elements' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
sub make_list() -> ptr {
    return (10, 20, 30);
}
my ($x, $y, $z) = make_list();
return $x + $y + $z;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_return_3' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 60, 'three-element list return gives 10+20+30=60' );
        unlink $file;
    }
};
subtest 'list return with single element' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
sub make_one() -> ptr {
    return (42);
}
my ($v) = make_one();
return $v;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_one' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 42, 'single-element list return gives 42' );
        unlink $file;
    }
};
subtest 'list return with expression elements' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 1 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
sub make_list() -> ptr {
    my $x = 5;
    return ($x * 2, $x + 3);
}
my ($a, $b) = make_list();
return $a + $b;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_expr_elems' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 18, 'list with expression elements: (10, 8) sum = 18' );
        unlink $file;
    }
};

# A list slot is one untagged eight-byte cell, so a list could not carry a float
# at all: the bits of 1.5 read back as an integer are 4607182418800017408. Every
# element is now boxed on the way in, which is the representation `gc_scan_list`
# and the `Any` incref on the reading side already assumed.
subtest 'list elements keep their own kind' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 4 unless $host->is_native;

        # An untyped element is boxed on the way into the slot and the box has to
        # survive the return of the function that built the list. It is increfed
        # when it is stored, so the exit decref of the local `$u` no longer leaves
        # the slot pointing at a freed box (it used to read back as whatever was
        # left in that memory -- 58 before the list-slot ownership fix, 0 after it).
        my @cases = (
            [ <<'BROCKEN', 4, 'a list of floats' ],
sub make_list() -> ptr {
    return (1.5, 2.5);
}
my ($a, $b) = make_list();
return $a + $b;
BROCKEN
            [ <<'BROCKEN', 5, 'a list of an integer and a float' ],
sub make_list() -> ptr {
    return (3, 2.5);
}
my ($a, $b) = make_list();
return $a + $b;
BROCKEN
            [ <<'BROCKEN', 4, 'a float list unpacked into f64 targets' ],
sub make_list() -> ptr {
    return (1.5, 2.5);
}
my (f64 $a, f64 $b) = make_list();
return $a + $b;
BROCKEN
            [ <<'BROCKEN', 9, 'an untyped element survives the return of its maker' ],
sub make_list() -> ptr {
    my $u = 7;
    return ($u, 2);
}
my ($a, $b) = make_list();
return $a + $b;
BROCKEN
        );
        my $i = 0;
        for my $case (@cases) {
            my ( $src, $want, $name ) = @$case;
            my $module = Brocken->new->compile($src);
            my $file   = $brocken->tmpdir . "/list_kind_$i" . $brocken->ext;
            $brocken->linker->write_executable( $file, $brocken->codegen->emit_functions( $module->functions ), $host );
            system $file;
            is( $? >> 8, $want, $name );
            unlink $file;
            $i++;
        }
    }
};
subtest 'a float element is not read back as its bit pattern' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Not native', 2 unless $host->is_native;
        my $module = Brocken->new->compile(<<'BROCKEN');
sub make_list() -> ptr {
    return (2.5);
}
my ($a) = make_list();
return $a == 2.5 ? 1 : 0;
BROCKEN
        my $funcs = $brocken->codegen->emit_functions( $module->functions );
        my $file  = $brocken->tmpdir . '/list_float_eq' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        system $file;
        is( $? >> 8, 1, 'a float element compares equal to itself' );
        unlink $file;
        my $again = Brocken->new->compile(<<'BROCKEN');
sub make_list() -> ptr {
    return (2.5);
}
my ($a) = make_list();
return $a == 4611686018427387904 ? 1 : 0;
BROCKEN
        my $file2 = $brocken->tmpdir . '/list_float_bits' . $brocken->ext;
        $brocken->linker->write_executable( $file2, $brocken->codegen->emit_functions( $again->functions ), $host );
        system $file2;
        is( $? >> 8, 0, 'and not equal to its own bit pattern' );
        unlink $file2;
    }
};
done_testing;
