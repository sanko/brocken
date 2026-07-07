use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
use Brocken::Jenny::Codegen::ARM64;
use Brocken::Jenny::Linker::ELF64;
use Brocken::Jenny::Linker::MachO;
use Brocken::Jenny::Linker::PE;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

my $brocken = Brocken->new();
my $host    = $brocken->platform;
SKIP: {
    skip 'ARM64 f32/f64 width comparison requires ARM64 host', 24 unless $host->is_arm64;

    sub make_binary($func) {
        my $codegen = Brocken::Jenny::Codegen::ARM64->new(platform => $host);
        my $bytes   = $codegen->emit_function($func);
        my $linker  = $host->is_macos  ? Brocken::Jenny::Linker::MachO->new() :
                      $host->is_windows ? Brocken::Jenny::Linker::PE->new() :
                                          Brocken::Jenny::Linker::ELF64->new();
        my $file    = $brocken->tmpdir . '/width_diag_' . $$ . $brocken->ext;
        $linker->write_executable($file, $bytes, $host);
        return $file;
    }

    sub run_check($name, $expected, $func) {
        my $file = make_binary($func);
        system $file;
        my $exit = $? >> 8;
        my $sig  = $? & 127;
        unlink $file;
        note "RAW STATUS: \$?=$? (exit=$exit, sig=$sig) for $name";
        is($sig, 0, "$name — no crash (signal=0)");
        is($exit, $expected, "$name — exit code $expected");
    }

    # ------------------------------------------------------------------
    # 1. Baseline integer returns (both widths)
    # ------------------------------------------------------------------
    subtest 'Baseline integer return' => sub {
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i32());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            $b->build_ret(Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::i32(), value => 31));
            run_check('i32 return 31', 31, $func);
        }
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            $b->build_ret(Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::i64(), value => 31));
            run_check('i64 return 31', 31, $func);
        }
    };

    # ------------------------------------------------------------------
    # 2. sitofp + fptosi: integer constant -> float -> integer
    # ------------------------------------------------------------------
    subtest 'sitofp + fptosi (f32 vs f64)' => sub {
        # f32 path: i32 -> f32 -> i32
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i32());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            my $iv = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::i32(), value => 31);
            my $fv = $b->build_sitofp($iv, Brocken::Lindsay::IR::Type::f32(), '%fv');
            my $rv = $b->build_fptosi($fv, Brocken::Lindsay::IR::Type::i32(), '%rv');
            $b->build_ret($rv);
            run_check('i32 sitofp f32 + fptosi 31', 31, $func);
        }
        # f64 path: i64 -> f64 -> i64
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            my $iv = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::i64(), value => 31);
            my $fv = $b->build_sitofp($iv, Brocken::Lindsay::IR::Type::f64(), '%fv');
            my $rv = $b->build_fptosi($fv, Brocken::Lindsay::IR::Type::i64(), '%rv');
            $b->build_ret($rv);
            run_check('i64 sitofp f64 + fptosi 31', 31, $func);
        }
    };

    # ------------------------------------------------------------------
    # 3. Direct float constant fptosi (no alloca, no sitofp)
    # ------------------------------------------------------------------
    subtest 'float constant fptosi (f32 vs f64)' => sub {
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i32());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            my $iv = $b->build_fptosi(
                Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f32(), value => 31.0),
                Brocken::Lindsay::IR::Type::i32(), '%iv');
            $b->build_ret($iv);
            run_check('f32 const fptosi 31.0 -> 31', 31, $func);
        }
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            my $iv = $b->build_fptosi(
                Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 31.0),
                Brocken::Lindsay::IR::Type::i64(), '%iv');
            $b->build_ret($iv);
            run_check('f64 const fptosi 31.0 -> 31', 31, $func);
        }
    };

    # ------------------------------------------------------------------
    # 4. fadd via alloca store/load (tests fload + fstr + fadd + fcvtzs)
    # ------------------------------------------------------------------
    subtest 'fadd via alloca (f32 vs f64)' => sub {
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i32());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            my $fa = $b->build_alloca(Brocken::Lindsay::IR::Type::f32(), '%fa');
            $b->build_store(Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f32(), value => 10.5), $fa);
            my $fva = $b->build_load(Brocken::Lindsay::IR::Type::f32(), $fa, '%fva');
            my $fb = $b->build_alloca(Brocken::Lindsay::IR::Type::f32(), '%fb');
            $b->build_store(Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f32(), value => 20.5), $fb);
            my $fvb = $b->build_load(Brocken::Lindsay::IR::Type::f32(), $fb, '%fvb');
            my $fres = $b->build_add($fva, $fvb, '%fres');
            my $iret = $b->build_fptosi($fres, Brocken::Lindsay::IR::Type::i32(), '%iret');
            $b->build_ret($iret);
            run_check('f32 alloca 10.5 + 20.5 -> 31', 31, $func);
        }
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            my $fa = $b->build_alloca(Brocken::Lindsay::IR::Type::f64(), '%fa');
            $b->build_store(Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 10.5), $fa);
            my $fva = $b->build_load(Brocken::Lindsay::IR::Type::f64(), $fa, '%fva');
            my $fb = $b->build_alloca(Brocken::Lindsay::IR::Type::f64(), '%fb');
            $b->build_store(Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 20.5), $fb);
            my $fvb = $b->build_load(Brocken::Lindsay::IR::Type::f64(), $fb, '%fvb');
            my $fres = $b->build_add($fva, $fvb, '%fres');
            my $iret = $b->build_fptosi($fres, Brocken::Lindsay::IR::Type::i64(), '%iret');
            $b->build_ret($iret);
            run_check('f64 alloca 10.5 + 20.5 -> 31', 31, $func);
        }
    };

    # ------------------------------------------------------------------
    # 5. fadd register-to-register (tests fmov_gp2f + fadd + fcvtzs)
    # ------------------------------------------------------------------
    subtest 'fadd register (f32 vs f64)' => sub {
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i32());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            my $a = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f32(), value => 10.5);
            my $b_c = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f32(), value => 20.5);
            my $fres = $b->build_add($a, $b_c, '%fres');
            my $iret = $b->build_fptosi($fres, Brocken::Lindsay::IR::Type::i32(), '%iret');
            $b->build_ret($iret);
            run_check('f32 reg add 10.5 + 20.5 -> 31', 31, $func);
        }
        {
            my $func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
            my $b = Brocken::Lindsay::IR::Builder->new();
            $b->position_at_end($func->append_block('entry'));
            my $a = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 10.5);
            my $b_c = Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::f64(), value => 20.5);
            my $fres = $b->build_add($a, $b_c, '%fres');
            my $iret = $b->build_fptosi($fres, Brocken::Lindsay::IR::Type::i64(), '%iret');
            $b->build_ret($iret);
            run_check('f64 reg add 10.5 + 20.5 -> 31', 31, $func);
        }
    };
}

done_testing;
