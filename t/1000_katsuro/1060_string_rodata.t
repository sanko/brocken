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
    my @rodata_fixups = grep { $_->{type} eq 'lea_rodata_rel32' || $_->{type} eq 'lea_rodata_adr' } map { $_->{fixups}->@* } $funcs->@*;
    ok scalar @rodata_fixups > 0, 'at least one rodata fixup generated';
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
subtest 'String concat folds two RodataRef strings' => sub {
    my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $x = "hello " . "world";
return 0;
BROCKEN
    my $rodata = $module->rodata;
    ok( defined $rodata, 'module has rodata' );
    my $found = 0;
    for my $bytes ( values $rodata->%* ) {
        $found = 1 if $bytes eq "hello world\0";
    }
    ok( $found, 'found folded concatenated string in rodata' );
};
subtest 'Parser accepts . as binary operator' => sub {
    my $ast = Brocken::Compiler->new->parse_only(<<'BROCKEN');
my String $x = "a" . "b";
return 0;
BROCKEN
    my $decl = $ast->statements->[0];
    ok( defined $decl,                                      'first statement is decl' );
    ok( $decl->isa('Brocken::Katsuro::AST::Stmt::VarDecl'), 'var decl' );
    my $expr = $decl->init;
    ok( defined $expr,                                    'decl has init expression' );
    ok( $expr->isa('Brocken::Katsuro::AST::Expr::BinOp'), 'expression is BinOp' );
    is( $expr->op, '.', 'operator is .' );
};
subtest 'String concat through codegen and linker (constant fold)' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $module  = Brocken::Compiler->new->compile(<<'BROCKEN');
say("Hello " . "world!");
return 0;
BROCKEN
    my $rodata = $module->rodata;
    ok( defined $rodata, 'module has rodata' );
    my $found = 0;
    for my $bytes ( values $rodata->%* ) {
        $found = 1 if $bytes eq "Hello world!\0";
    }
    ok( $found, 'found folded concatenated string in rodata' );
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    ok( scalar $funcs->@* > 0, 'at least one function emitted' );
SKIP: {
        if ( $host->is_native ) {
            $brocken->linker->set_rodata($rodata);
            my $file = $brocken->tmpdir . '/str_concat_test' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $host );
            chmod 0755, $file;
            like `$file`, qr[^Hello world!$], 'say(...) works with concat strings';
            unlink $file;
        }
        else {
            skip 'skip native execution test (not native host)', 1;
        }
    }
};
subtest 'String . integer runtime concat (say "hello " . 42)' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $module  = Brocken::Compiler->new->compile(<<'BROCKEN');
say("hello " . 42);
return 0;
BROCKEN
    my $rodata = $module->rodata;
    ok( defined $rodata, 'module has rodata' );
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    ok( scalar $funcs->@* > 0, 'at least one function emitted' );
SKIP: {
        if ( $host->is_native ) {
            $brocken->linker->set_rodata($rodata);
            my $file = $brocken->tmpdir . '/str_int_concat_test' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $host );
            chmod 0755, $file;
            like `$file`, qr[^hello 42$], 'say("hello " . 42) works';
            unlink $file;
        }
        else {
            skip 'skip native execution test (not native host)', 1;
        }
    }
};
subtest 'Integer . string runtime concat (say 42 . " hello")' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $module  = Brocken::Compiler->new->compile(<<'BROCKEN');
say(42 . " hello");
return 0;
BROCKEN
    my $rodata = $module->rodata;
    ok( defined $rodata, 'module has rodata' );
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    ok( scalar $funcs->@* > 0, 'at least one function emitted' );
SKIP: {
        if ( $host->is_native ) {
            $brocken->linker->set_rodata($rodata);
            my $file = $brocken->tmpdir . '/int_str_concat_test' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $host );
            chmod 0755, $file;
            like `$file`, qr[^42 hello$], 'say(42 . " hello") works';
            unlink $file;
        }
        else {
            skip 'skip native execution test (not native host)', 1;
        }
    }
};
subtest 'Integer . integer runtime concat (say 5 . 10)' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $module  = Brocken::Compiler->new->compile(<<'BROCKEN');
say(5 . 10);
return 0;
BROCKEN
    my $rodata = $module->rodata;
    ok( defined $rodata, 'module has rodata' );
    my $funcs = $brocken->codegen->emit_functions( $module->functions );
    ok( scalar $funcs->@* > 0, 'at least one function emitted' );
SKIP: {
        if ( $host->is_native ) {
            $brocken->linker->set_rodata($rodata);
            my $file = $brocken->tmpdir . '/int_int_concat_test' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $host );
            chmod 0755, $file;
            like `$file`, qr[^510$], 'say(5 . 10) works';
            unlink $file;
        }
        else {
            skip 'skip native execution test (not native host)', 1;
        }
    }
};
done_testing;
