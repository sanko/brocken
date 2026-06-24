use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Lindsay;
use Brocken::Jenny::Codegen::Wasm;
use Brocken::Jenny::Linker::Wasm;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'Jenny::Codegen Multi-Function Calls' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $b       = Brocken::Lindsay::IR::Builder->new();
    my $p       = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => 'x' );
    my $helper  = Brocken::Lindsay::IR::Function->new( name => 'helper', return_type => Brocken::Lindsay::IR::Type::i32(), params => [$p] );
    $b->position_at_end( $helper->append_block('entry') );
    $b->build_ret( $b->build_add( $p, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ) ) );
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $b->position_at_end( $main->append_block('entry') );
    $b->build_ret( $b->build_call( $helper, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 41 ) ] ) );

    # Test native (ELF/MachO/PE) backends when running on a supported platform
SKIP: {
        skip 'Multi-function native test only on native hosts', 8 unless $host->is_native;
        my $funcs = $brocken->codegen->emit_functions( [ $main, $helper ] );

        # DEBUG: hex dump on ARM64
        if ( $host->is_arm64 ) {
            for my $f ( $funcs->@* ) {
                warn "\n### DEBUG: Function '$f->{name}' (" . length( $f->{bytes} ) . " bytes) ###\n";
                my $bytes = $f->{bytes};
                for ( my $i = 0; $i < length $bytes; $i += 16 ) {
                    my $chunk = substr( $bytes, $i, 16 );
                    my $hex   = join( ' ', map { sprintf '%02X', ord $_ } split( //, $chunk ) );
                    my $pad   = 16 - length($chunk);
                    $hex .= '   ' x $pad if $pad;
                    my $ascii = join( '', map { ord $_ >= 32 && ord $_ < 127 ? $_ : '.' } split( //, $chunk ) );
                    warn sprintf( '  %08x: %-48s %s', $i, $hex, $ascii ) . "\n";
                }
                for my $fix ( $f->{fixups}->@* ) {
                    warn "  fixup: offset=$fix->{offset} type=$fix->{type} target=$fix->{target}\n";
                }
            }
        }
        is( ref $funcs,        'ARRAY', 'emit_functions returned array ref' );
        is( scalar $funcs->@*, 2,       'emit_functions returned 2 entries' );
        my $output_file = 'multi_func_native' . $brocken->ext;
        $brocken->linker->write_executable( $output_file, $funcs, $host );

        # DEBUG: disassemble on ARM64 Linux
        if ( $host->is_arm64 && $host->is_linux ) {
            warn "\n### DEBUG: objdump output ###\n";
            system("objdump -d --architecture=aarch64 $output_file 2>&1");
        }
        ok( -e $output_file, 'Multi-function binary exists' );

        # DEBUG: post-link hex dump + disassembly on ARM64
        if ( $host->is_arm64 ) {
            warn "\n### DEBUG: post-link binary '$output_file' ###\n";
            open my $fh, '<:raw', $output_file or warn "  can't open $output_file: $!";
            if ($fh) {
                my $bin;
                read $fh, $bin, 4096;
                close $fh;
                for ( my $i = 0; $i < length $bin; $i += 16 ) {
                    my $chunk = substr( $bin, $i, 16 );
                    my $hex   = join( ' ', map { sprintf '%02X', ord $_ } split( //, $chunk ) );
                    my $pad   = 16 - length($chunk);
                    $hex .= '   ' x $pad if $pad;
                    my $ascii = join( '', map { ord $_ >= 32 && ord $_ < 127 ? $_ : '.' } split( //, $chunk ) );
                    warn sprintf( '%08x: %-48s %s', $i, $hex, $ascii ) . "\n";
                }
            }
            warn "\n### DEBUG: disassembly ###\n";
            if ( $host->is_macos ) {
                system("otool -v -t $output_file 2>&1");
                system("llvm-objdump -d --arch=aarch64 $output_file 2>&1");
            }
            else {
                system("objdump -d --architecture=aarch64 $output_file 2>&1");
                system("llvm-objdump-19 -d --arch=aarch64 $output_file 2>&1");
            }
        }
        run_exec( $output_file, expected_exit => 42, platform => $host, name => 'Multi-function helper(41) returned 42 on ' . $host->friendly );
    }

    # Test Wasm backend (when wasmtime is available)
SKIP: {
        my $null          = $host->is_windows ? 'NUL'                  : '/dev/null';
        my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        skip 'wasmtime not available', 4 unless $wasmtime_path && -f $wasmtime_path;
        my $wasm_platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $codegen       = Brocken::Jenny::Codegen::Wasm->new( platform => $wasm_platform );
        my $funcs         = $codegen->emit_functions( [ $main, $helper ] );
        is( ref $funcs,        'ARRAY', 'Wasm emit_functions returned array ref' );
        is( scalar $funcs->@*, 2,       'Wasm emit_functions returned 2 entries' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'multi_func_wasm.wasm';
        $linker->write_executable( $output_file, $funcs, $wasm_platform );
        ok( -e $output_file, 'Wasm multi-function binary exists' );
        my $output = qx["$wasmtime_path" run --invoke main $output_file 2>$null];
        chomp $output;
        is( $output, 42, 'Wasm multi-function helper(41) returned 42' );
        unlink $output_file if -e $output_file;
    }
};
subtest 'Jenny::Codegen Multi-Function Shared Library' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
SKIP: {
        skip 'Multi-function shared lib test only on native hosts', 6 unless $host->is_native;
        my $b      = Brocken::Lindsay::IR::Builder->new();
        my $func_a = Brocken::Lindsay::IR::Function->new( name => 'func_a', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $b->position_at_end( $func_a->append_block('entry') );
        $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $func_b = Brocken::Lindsay::IR::Function->new( name => 'func_b', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $b->position_at_end( $func_b->append_block('entry') );
        $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 100 ) );
        my $linker = ( ref $brocken->linker )->new( type => 'shared' );
        my $output_file;
        if    ( $host->is_macos )   { $output_file = 'multi_func_shared.dylib' }
        elsif ( $host->is_windows ) { $output_file = 'multi_func_shared.dll' }
        else                        { $output_file = 'multi_func_shared.so' }
        my $funcs = $brocken->codegen->emit_functions( [ $func_a, $func_b ] );
        is( ref $funcs,        'ARRAY', 'emit_functions returned array ref' );
        is( scalar $funcs->@*, 2,       'emit_functions returned 2 entries' );
        $linker->set_exported_funcs( [ 'func_a', 'func_b' ] );

        if ( $linker->isa('Brocken::Jenny::Linker::PE') ) {
            $linker->write_shared_library( $output_file, $funcs, $host );
        }
        else {
            $linker->write_executable( $output_file, $funcs, $host, 1 );
        }
        ok -e $output_file, 'Multi-function shared library exists';
    SKIP: {
            use Config;
            my $dl_avail = eval { require DynaLoader; 1 };
            skip 'DynaLoader not available', 3 unless $dl_avail;
            skip 'Shared library loading test requires native execution support (no emulation mismatch)', 3
                unless $host->is_native && ( $host->is_arm64 ? ( $Config{archname} !~ /x86_64|x64/i ) : 1 );
            require File::Spec;
            my $abs_path = File::Spec->rel2abs($output_file);
            my $libref   = DynaLoader::dl_load_file($abs_path);
            ok $libref, 'Loaded shared library via DynaLoader' or skip 'dl_load_file failed', 2;
            my $sym_a = DynaLoader::dl_find_symbol( $libref, 'func_a' );
            ok $sym_a, 'Resolved exported symbol "func_a"';
            my $sym_b = DynaLoader::dl_find_symbol( $libref, 'func_b' );
            ok $sym_b, 'Resolved exported symbol "func_b"';
            DynaLoader::dl_unload_file($libref);
        }
        unlink $output_file if -e $output_file;
    }
};
done_testing;
