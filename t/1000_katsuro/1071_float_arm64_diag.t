use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
use Brocken::Jenny::Codegen::ARM64;
use Brocken::Jenny::Linker::ELF64;
use Brocken::Jenny::Linker::MachO;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

my $brocken = Brocken->new();
my $host    = $brocken->platform;
SKIP: {
    skip 'ARM64 diagnostic tests require ARM64 host', 7 unless $host->is_arm64;

    # Helper: build an ARM64 binary from a Lindsay IR function
    sub make_binary($func) {
        my $codegen = Brocken::Jenny::Codegen::ARM64->new(platform => $host);
        my $bytes   = $codegen->emit_function($func);
        my $linker  = $host->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                                       Brocken::Jenny::Linker::ELF64->new();
        my $file    = $brocken->tmpdir . '/float_diag_' . $$ . $brocken->ext;
        $linker->write_executable($file, $bytes, $host);
        return $file;
    }

    # Helper: run a binary and check exit code
    sub run_check($name, $expected, $func) {
        my $file = make_binary($func);
        system $file;
        unlink $file;
        is($? >> 8, $expected, $name);
    }

    # ------------------------------------------------------------------
    # 1. Baseline: return integer constant (no float at all)
    # ------------------------------------------------------------------
    subtest 'Baseline integer return' => sub {
        my $func    = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end($func->append_block('entry'));
        $builder->build_ret(Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::i64(), value => 31));
        run_check('return 31', 31, $func);
    };

    # ------------------------------------------------------------------
    # 2. f64 constant via alloca load + fptosi (tests fload + fcvtzs)
    # ------------------------------------------------------------------
    subtest 'f64 alloca load + fptosi' => sub {
        my $func    = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end($func->append_block('entry'));
        my $fptr = $builder->build_alloca(Brocken::Lindsay::IR::Type::f64(), '%fptr');
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 31.0), $fptr);
        my $fv = $builder->build_load(Brocken::Lindsay::IR::Type::f64(), $fptr, '%fv');
        my $iv = $builder->build_fptosi($fv, Brocken::Lindsay::IR::Type::i64(), '%iv');
        $builder->build_ret($iv);
        run_check('store/load 31.0 + fptosi -> 31', 31, $func);
    };

    # ------------------------------------------------------------------
    # 3. f64 constant direct fptosi (no alloca) — tests fmov_gp2f + fcvtzs
    # ------------------------------------------------------------------
    subtest 'f64 constant direct fptosi' => sub {
        my $func    = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end($func->append_block('entry'));
        my $fptr = $builder->build_alloca(Brocken::Lindsay::IR::Type::f64(), '%fptr');
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 31.0), $fptr);
        my $fv = $builder->build_fptosi(
            Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 31.0),
            Brocken::Lindsay::IR::Type::i64(), '%iv');
        $builder->build_ret($fv);
        run_check('fptosi of const 31.0 -> 31', 31, $func);
    };

    # ------------------------------------------------------------------
    # 4. f64 constant -> fadd -> fptosi (full pipeline, what 1070 fails on)
    # ------------------------------------------------------------------
    subtest 'f64 fadd + fptosi' => sub {
        my $func    = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end($func->append_block('entry'));
        # Alloca + store + load for each operand
        my $fa = $builder->build_alloca(Brocken::Lindsay::IR::Type::f64(), '%fa');
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 10.5), $fa);
        my $fva = $builder->build_load(Brocken::Lindsay::IR::Type::f64(), $fa, '%fva');
        my $fb = $builder->build_alloca(Brocken::Lindsay::IR::Type::f64(), '%fb');
        $builder->build_store(
            Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 20.5), $fb);
        my $fvb = $builder->build_load(Brocken::Lindsay::IR::Type::f64(), $fb, '%fvb');
        my $fres = $builder->build_add($fva, $fvb, '%fres');
        my $iret = $builder->build_fptosi($fres, Brocken::Lindsay::IR::Type::i64(), '%iret');
        $builder->build_ret($iret);
        run_check('f64 10.5 + 20.5 -> 31', 31, $func);
    };

    # ------------------------------------------------------------------
    # 5. f64 fadd of values from register (no memory) — tests fmov_gp2f + fadd + fcvtzs
    # ------------------------------------------------------------------
    subtest 'f64 register add (no alloca)' => sub {
        my $func    = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end($func->append_block('entry'));
        my $a = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 10.5);
        my $b = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 20.5);
        my $fres = $builder->build_add($a, $b, '%fres');
        my $iret = $builder->build_fptosi($fres, Brocken::Lindsay::IR::Type::i64(), '%iret');
        $builder->build_ret($iret);
        run_check('f64 reg add 10.5 + 20.5 -> 31', 31, $func);
    };

    # ------------------------------------------------------------------
    # 6. f64 sitofp (integer->float) + fptosi — tests scvtf + fcvtzs
    # ------------------------------------------------------------------
    subtest 'f64 sitofp + fptosi' => sub {
        my $func    = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end($func->append_block('entry'));
        my $iconst = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::i64(), value => 31);
        my $fval   = $builder->build_sitofp($iconst, Brocken::Lindsay::IR::Type::f64(), '%fval');
        my $iret   = $builder->build_fptosi($fval, Brocken::Lindsay::IR::Type::i64(), '%iret');
        $builder->build_ret($iret);
        run_check('sitofp 31 + fptosi -> 31', 31, $func);
    };

    # ------------------------------------------------------------------
    # 7. f64 fadd with integer constant LHS (tests sink of int->float->add)
    # ------------------------------------------------------------------
    subtest 'f64 add int const + float const' => sub {
        my $func    = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end($func->append_block('entry'));
        my $iconst = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::i64(), value => 10);
        my $fval   = $builder->build_sitofp($iconst, Brocken::Lindsay::IR::Type::f64(), '%fval');
        my $fres   = $builder->build_add($fval,
            Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 20.5), '%fres');
        my $iret   = $builder->build_fptosi($fres, Brocken::Lindsay::IR::Type::i64(), '%iret');
        $builder->build_ret($iret);
        run_check('sitofp 10 + 20.5 -> 30', 30, $func);
    };
}

done_testing;
