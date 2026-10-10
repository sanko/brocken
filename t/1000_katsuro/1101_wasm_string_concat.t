use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Lindsay::IR;
use Test2::Tools::Brocken qw(temp_path wasm_platform wasm_runner wasm_validates);
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Dynamic string concatenation used to lower to strlen + malloc + strcpy + strcat. A Wasm module emits no import
# section, so the linker died on the undefined libc symbols. Section 5.4 routes `.` through the managed
# Brocken::Runtime::str_concat instead.
subtest 'Dynamic concat lowers to a single str_concat runtime call, no libc' => sub {
    my $platform = wasm_platform();
    my $brocken  = Brocken->new( platform => $platform );
    my $module   = $brocken->compile(<<'BROCKEN');
my String $s = 42 . " hello";
return 0;
BROCKEN
    my %callees;
    for my $fn ( $module->functions->@* ) {
        for my $block ( $fn->blocks->@* ) {
            for my $inst ( $block->instructions->@* ) {
                next unless $inst->isa('Brocken::Lindsay::IR::Instruction::Call') && $inst->callee;
                $callees{ $inst->callee->name }++;
            }
        }
    }
    is( $callees{'Brocken::Runtime::str_concat'} // 0, 1, 'concat routed through the managed allocator' );
    for my $libc (qw(strlen malloc strcpy strcat)) {
        is( ( $callees{$libc} // 0 ) + ( $callees{ '_' . $libc } // 0 ), 0, "no $libc call in the module" );
    }
};
subtest 'Wasm module with dynamic concat links and validates' => sub {
    my $platform = wasm_platform();
    my $brocken  = Brocken->new( platform => $platform );

    # Two integer operands make both routes dynamic: i64_to_str for each side, then str_concat. On the old lowering the
    # module linked with calls to strlen/malloc/strcpy/strcat, and the Wasm linker died: "undefined function 'strlen'".
    my $module = $brocken->compile(<<'BROCKEN');
my String $s = 5 . 10;
return 0;
BROCKEN
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    my $file   = temp_path('wasm_str_concat') . '.wasm';
    my $linked = eval {
        $brocken->linker->write_executable( $file, $funcs, $platform );
        1;
    };
    ok( $linked,  'linker accepts the concat module' ) or diag($@);
    ok( -e $file, 'wasm file produced' ) if $linked;
    SRUN: {
        SKIP: {
            skip 'no Wasm runner is available', 1 unless wasm_runner();
            ok( $linked && -e $file, 'module written before validation' ) or last SRUN;
            my $status = wasm_validates($file);
            is( $status, 0, 'concat module validates' ) or diag('the module did not validate');
        }
    }
    unlink $file if -e $file;
};
subtest 'str_concat output is correct natively' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    return skip 'skip native execution test (not native host)', 1 unless $host->is_native;
    my $module = Brocken->new->compile(<<'BROCKEN');
say(42 . " hello");
say("hello " . 42);
say("x" . "");
say("" . "y");
say(5 . 10);
return 0;
BROCKEN
    my $rodata = $module->rodata;
    my $funcs  = $brocken->codegen->emit_functions( $module->functions );
    $brocken->linker->set_rodata($rodata) if $rodata && keys %$rodata;
    my $file = $brocken->tmpdir . '/str_concat_runtime' . $brocken->ext;
    $brocken->linker->write_executable( $file, $funcs, $host );
    chmod 0755, $file;
    like `$file`, qr[^42 hello\nhello 42\nx\ny\n510$], 'managed allocator concatenates and NUL-terminates';
    unlink $file;
};
done_testing;
