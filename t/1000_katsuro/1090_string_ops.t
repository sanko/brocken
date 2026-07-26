use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Compiler;
use Brocken::Lindsay::IR;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'Parser accepts eq/ne/lt/gt/le/ge/cmp as binary operators' => sub {
    for my $op (qw(eq ne lt gt le ge cmp)) {
        my $ast = Brocken::Compiler->new->parse_only(<<BROCKEN);
my String \$a = "x";
my String \$b = "y";
my \$r = \$a $op \$b;
return 0;
BROCKEN
        my $assign = $ast->statements->[2];
        ok( defined $assign,                                      "$op: third statement exists" );
        ok( $assign->isa('Brocken::Katsuro::AST::Stmt::VarDecl'), "$op: is VarDecl" );
        my $binop = $assign->init;
        ok( defined $binop,                                    "$op: init expression exists" );
        ok( $binop->isa('Brocken::Katsuro::AST::Expr::BinOp'), "$op: expression is BinOp" );
        is( $binop->op, $op, "$op: operator is $op" );
    }
};
subtest 'Parser accepts length() as function call' => sub {
    my $ast = Brocken::Compiler->new->parse_only(<<'BROCKEN');
my String $s = "hello";
my $len = length($s);
return 0;
BROCKEN
    my $assign = $ast->statements->[1];
    ok( defined $assign,                                      'second statement exists' );
    ok( $assign->isa('Brocken::Katsuro::AST::Stmt::VarDecl'), 'is VarDecl' );
    my $call = $assign->init;
    ok( defined $call,                                   'init expression exists' );
    ok( $call->isa('Brocken::Katsuro::AST::Expr::Call'), 'expression is Call' );
    is( $call->func_name,       'length', 'function name is length' );
    is( scalar $call->args->@*, 1,        'one argument' );
};
subtest 'String eq produces strcmp + icmp eq in IR' => sub {
    my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $a = "hello";
my String $b = "hello";
my $r = $a eq $b;
return $r;
BROCKEN
    my $funcs = $module->functions;
    ok( scalar $funcs->@* > 0, 'at least one function' );
    my $found_strcmp = 0;
    for my $fn ( $funcs->@* ) {
        for my $block ( $fn->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                if ( $inst->isa('Brocken::Lindsay::IR::Instruction::Call') && $inst->callee ) {
                    $found_strcmp = 1 if $inst->callee->name eq 'strcmp' || $inst->callee->name eq '_strcmp';
                }
            }
        }
    }
    ok( $found_strcmp, 'strcmp call found in IR' );
};
subtest 'String eq through codegen and native execution (constant strings)' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'skip native execution test (not native host)', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $a = "hello";
my String $b = "hello";
my String $c = "world";
if ($a eq $b) {
    say("match");
} else {
    say("nomatch");
}
if ($a eq $c) {
    say("match");
} else {
    say("nomatch");
}
return 0;
BROCKEN
        my $rodata = $module->rodata;
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        $brocken->linker->set_rodata($rodata) if $rodata && keys %$rodata;
        my $file = $brocken->tmpdir . '/str_eq_test' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        chmod 0755, $file;
        my $output = `$file`;
        like( $output, qr/^match\nnomatch\n$/m, 'eq comparison works natively' );
        unlink $file;
    }
};
subtest 'String ne through native execution' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'skip native execution test (not native host)', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $a = "abc";
my String $b = "def";
if ($a ne $b) {
    say("different");
} else {
    say("same");
}
return 0;
BROCKEN
        my $rodata = $module->rodata;
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        $brocken->linker->set_rodata($rodata) if $rodata && keys %$rodata;
        my $file = $brocken->tmpdir . '/str_ne_test' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        chmod 0755, $file;
        my $output = `$file`;
        like( $output, qr/^different\n$/, 'ne comparison works natively' );
        unlink $file;
    }
};
subtest 'String lt/gt/le/ge through native execution' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'skip native execution test (not native host)', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $a = "aaa";
my String $b = "zzz";
if ($a lt $b) { say("lt-yes"); } else { say("lt-no"); }
if ($a gt $b) { say("gt-yes"); } else { say("gt-no"); }
if ($a le $a) { say("le-yes"); } else { say("le-no"); }
if ($a ge $a) { say("ge-yes"); } else { say("ge-no"); }
return 0;
BROCKEN
        my $rodata = $module->rodata;
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        $brocken->linker->set_rodata($rodata) if $rodata && keys %$rodata;
        my $file = $brocken->tmpdir . '/str_order_test' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        chmod 0755, $file;
        my $output = `$file`;
        like( $output, qr/^lt-yes\ngt-no\nle-yes\nge-yes\n$/m, 'lt/gt/le/ge work natively' );
        unlink $file;
    }
};
subtest 'String cmp through native execution' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'skip native execution test (not native host)', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $a = "aaa";
my String $b = "zzz";
my i64 $r1 = $a cmp $b;
say("" . $r1);
my i64 $r2 = $a cmp $a;
say("" . $r2);
return 0;
BROCKEN
        my $rodata = $module->rodata;
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        $brocken->linker->set_rodata($rodata) if $rodata && keys %$rodata;
        my $file = $brocken->tmpdir . '/str_cmp_test' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        chmod 0755, $file;
        my $output = `$file`;
        like( $output, qr/^-1\n0\n$/m, 'cmp returns strcmp values natively' );
        unlink $file;
    }
};
subtest 'length() returns string length in IR' => sub {
    my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $s = "hello";
my $len = length($s);
return $len;
BROCKEN
    my $funcs = $module->functions;
    ok( scalar $funcs->@* > 0, 'at least one function' );
    my $found_strlen = 0;
    for my $fn ( $funcs->@* ) {
        for my $block ( $fn->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                if ( $inst->isa('Brocken::Lindsay::IR::Instruction::Call') && $inst->callee ) {
                    $found_strlen = 1 if $inst->callee->name eq 'strlen' || $inst->callee->name eq '_strlen';
                }
            }
        }
    }
    ok( $found_strlen, 'strlen call found in IR' );
};
subtest 'length() through native execution' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'skip native execution test (not native host)', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $s = "hello";
my i64 $len = length($s);
say("" . $len);
return 0;
BROCKEN
        my $rodata = $module->rodata;
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        $brocken->linker->set_rodata($rodata) if $rodata && keys %$rodata;
        my $file = $brocken->tmpdir . '/str_length_test' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        chmod 0755, $file;
        my $output = `$file`;
        like( $output, qr/^5\n$/, 'length returns 5 for "hello"' );
        unlink $file;
    }
};
subtest 'eq with empty strings' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'skip native execution test (not native host)', 1 unless $host->is_native;
        my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
my String $a = "";
my String $b = "";
if ($a eq $b) { say("empty-eq"); } else { say("empty-ne"); }
if ($a eq "x") { say("empty-ne2"); } else { say("empty-ne3"); }
return 0;
BROCKEN
        my $rodata = $module->rodata;
        my $funcs  = $brocken->codegen->emit_functions( $module->functions );
        $brocken->linker->set_rodata($rodata) if $rodata && keys %$rodata;
        my $file = $brocken->tmpdir . '/str_empty_test' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        chmod 0755, $file;
        my $output = `$file`;
        like( $output, qr/^empty-eq\nempty-ne3\n$/m, 'empty string eq works' );
        unlink $file;
    }
};
done_testing;
