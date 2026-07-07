use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken;
use Brocken::Jenny::Codegen::ARM64;
use Brocken::Jenny::Linker::ELF64;
use Brocken::Jenny::Linker::MachO;
use feature qw[class];
no warnings qw[experimental::class experimental::builtin portable];

my $brocken = Brocken->new();
my $host    = $brocken->platform;
SKIP: {
    skip 'ARM64 raw-byte test requires ARM64 host', 12 unless $host->is_arm64;

    sub make_and_run_raw($name, $body_bytes) {
        my $codegen = Brocken::Jenny::Codegen::ARM64->new(platform => $host);
        my $dummy_func = Brocken::Lindsay::IR::Function->new(name => 'main', return_type => Brocken::Lindsay::IR::Type::i64());
        my $b = Brocken::Lindsay::IR::Builder->new();
        $b->position_at_end($dummy_func->append_block('entry'));
        $b->build_ret(Brocken::Lindsay::IR::Constant->new(type => Brocken::Lindsay::IR::Type::i64(), value => 0));
        my $full_bytes = $codegen->emit_function($dummy_func);

        my $prologue = substr($full_bytes, 0, 12);
        my $epilogue = substr($full_bytes, -12);
        my $new_bytes = $prologue . $body_bytes . $epilogue;

        note "  prologue(" . length($prologue) . "): " . unpack('H*', $prologue);
        note "  body(" . length($body_bytes) . "): " . unpack('H*', $body_bytes);
        note "  epilogue(" . length($epilogue) . "): " . unpack('H*', $epilogue);

        my $linker = $host->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                                       Brocken::Jenny::Linker::ELF64->new();
        my $file = $brocken->tmpdir . '/raw_test_' . $$ . $brocken->ext;
        $linker->write_executable($file, [{ name => 'main', bytes => $new_bytes, fixups => [], alloca_map => {} }], $host);
        system $file;
        my $exit = $? >> 8;
        my $sig  = $? & 127;
        unlink $file;
        note "  RESULT: \$?=$? (exit=$exit, sig=$sig)";
        is($sig, 0, "$name — no crash");
        is($exit, 31, "$name — exit 31");
    }

    # ==================================================================
    # Test 1: Baseline - MOVZ x0, #31 + RET
    # ==================================================================
    subtest 'baseline movz 31 ret' => sub {
        make_and_run_raw('baseline', pack('V', 0xD28003E0));
    };

    # ==================================================================
    # Test 2: SCVTF D0, X9 + FCVTZS X0, D0
    # SCVTF D0, X9 = 0x9E244000 | (9<<5) | 0 = 0x9E244120
    # FCVTZS X0, D0 = 0x9EE80000 | (0<<5) | 0 = 0x9EE80000
    # ==================================================================
    subtest 'scvtf + fcvtzs' => sub {
        my $body = '';
        $body .= pack('V', 0xD28003E9);   # MOVZ x9, #31
        $body .= pack('V', 0x9E244120);   # SCVTF D0, X9
        $body .= pack('V', 0x9EE80000);   # FCVTZS X0, D0
        make_and_run_raw('scvtf d0,x9 + fcvtzs x0,d0', $body);
    };

    # ==================================================================
    # Test 3: FMOV D0, X9 + FCVTZS X0, D0
    # FMOV D0, X9 = 0x9E670000 | (9<<5) | 0 = 0x9E670120
    # ==================================================================
    subtest 'fmov_gp2f + fcvtzs' => sub {
        my $body = '';
        $body .= pack('V', 0xD28003E9);   # MOVZ x9, #31
        $body .= pack('V', 0x9E670120);   # FMOV D0, X9
        $body .= pack('V', 0x9EE80000);   # FCVTZS X0, D0
        make_and_run_raw('fmov d0,x9 + fcvtzs x0,d0', $body);
    };

    # ==================================================================
    # Test 4: Bit pattern 31.0 → FMOV D0, X9 + FCVTZS X0, D0
    # 31.0 double = 0x403F000000000000
    # MOVK x9, #0x403F, LSL #48 = 0xF2800000 | (3<<21) | (0x403F<<5) | 9 = 0xF2E807E9
    # ==================================================================
    subtest 'bit pattern 31.0 + fcvtzs' => sub {
        my $body = '';
        $body .= pack('V', 0xD2800009);   # MOVZ x9, #0 (clear)
        $body .= pack('V', 0xF2E807E9);   # MOVK x9, #0x403F, LSL #48
        $body .= pack('V', 0x9E670120);   # FMOV D0, X9
        $body .= pack('V', 0x9EE80000);   # FCVTZS X0, D0
        make_and_run_raw('bitpattern+fmov+fcvtzs', $body);
    };
}

done_testing;
