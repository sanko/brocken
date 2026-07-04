use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
use Brocken::Lindsay::IR;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'String constant compiles and produces RodataRef in IR' => sub {
    my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $x = "hello";
return 42;
BROCKEN
    my $rodata = $module->rodata;
    ok( defined $rodata, 'module has rodata hash' );
    is( scalar( keys $rodata->%* ), 1, 'one string constant in rodata' );
    my ( $label, $bytes ) = each $rodata->%*;
    like( $label, qr/^__str_\d+$/, 'label matches __str_N pattern' );
    is( $bytes, "hello\0", 'bytes include null terminator' );
    my $funcs = $module->functions;
    ok( scalar $funcs->@* > 0, 'at least one function in module' );
    my $func = $funcs->[0];
    ok( defined $func->name, 'entry function has a name' );
    my $blocks = $func->blocks;
    ok( scalar $blocks->@* > 0, 'entry function has blocks' );
};
subtest 'String constant through codegen and linker' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $module  = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $x = "Hello, world!";
say($x);
return 0;
BROCKEN
    my $rodata = $module->rodata;
    ok( defined $rodata, 'module has rodata before codegen' );
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    ok( scalar $funcs->@* > 0, 'at least one function emitted' );
    my @rodata_fixups = grep { $_->{type} eq 'lea_rodata_rel32' } map { $_->{fixups}->@* } $funcs->@*;
    ok scalar @rodata_fixups > 0, 'at least one lea_rodata_rel32 fixup generated';
SKIP: {
        if ( $host->is_native ) {
            $brocken->linker->set_rodata($rodata);
            my $file = $brocken->tmpdir . '/str_rodata_test' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $host );
            my $peek = do {
                open my $fh, '<:raw', $file or die "Cannot open $file: $!";
                my $data;
                read $fh, $data, -s $file;
                close $fh;
                $data;
            };
            ok( index( $peek, "Hello, world!\0" ) >= 0, 'linked binary contains the string constant with null terminator' );
            chmod 0755, $file;
            like `$file`, qr[^Hello, world!$], 'say(...) works with static strings';
            unlink $file;
        }
        else {
            skip 'skip native execution test (not native host)', 3;
        }
    }
};
done_testing;
