use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
use Brocken::Jenny::Codegen::ARM64::Inst;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
use Config;
my $brocken    = Brocken->new();
my $platform   = $brocken->platform;
my $is_arm64   = $platform->is_arm64;
my $is_riscv64 = $platform->is_riscv64;
my $is_x64     = $platform->is_x64;
my $is_windows = $platform->is_windows;
my $is_posix   = $platform->is_posix;

# Build shared library
my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_lib' );
my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
$module->add_function($func_ext);
my $builder = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func_ext->append_block('entry') );
$builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
my $codegen       = $brocken->codegen;
my $machine_bytes = $codegen->emit_function($func_ext);
my $ext           = $platform->lib_ext;
my $lib_file      = './libtest_prog' . $ext;

if ($is_windows) {
    my $shared_linker = Brocken::Jenny::Linker::PE->new( type => 'shared' );
    $shared_linker->set_exported_funcs( ['my_func'] );
    $shared_linker->set_labels( { E_my_func => 0 } );
    $shared_linker->write_shared_library( $lib_file, $machine_bytes, $platform );
}
elsif ( $platform->is_macos ) {
    my $shared_linker = Brocken::Jenny::Linker::MachO->new( type => 'shared' );
    $shared_linker->set_exported_funcs( ['my_func'] );
    $shared_linker->set_labels( { E_my_func => 0 } );
    $shared_linker->write_executable( $lib_file, $machine_bytes, $platform, 1 );
}
else {
    my $shared_linker = Brocken::Jenny::Linker::ELF64->new( type => 'shared' );
    $shared_linker->set_exported_funcs( ['my_func'] );
    $shared_linker->set_labels( { E_my_func => 0 } );
    $shared_linker->write_executable( $lib_file, $machine_bytes, $platform, 1 );
}
ok -e $lib_file, 'Shared library compiled at ' . $lib_file;

# nm check
my $nm_out;
if ( $^O eq 'MSWin32' ) {
    if ( open my $fh, '-|', 'objdump', '-p', $lib_file ) {
        $nm_out = do { local $/; <$fh> };
        close $fh;
    }
}
else {
    if ( open my $fh, '-|', 'nm', $lib_file ) {
        $nm_out = do { local $/; <$fh> };
        close $fh;
    }
}
if ( $? == 0 && defined $nm_out && $nm_out ne '' ) {
    my $expected_sym = 'my_func';
    like $nm_out, qr/\b_?$expected_sym\b/, "Verified via 'nm' that '$expected_sym' is present in $lib_file";
}
else {
    note 'nm is not available or failed; skipping symbol table extraction check';
}

# x86_64 wrapper generator
my $make_x64_wrapper = sub ( $ext_str, $dlopen_rva, $dlsym_rva, $text, $macho, $exit_syscall //= $macho ? 0x2000001 : 60 ) {
    my $lib_path         = "./libtest_prog$ext_str\0";
    my $func_name        = "my_func\0";
    my $lib_path_offset  = 128;
    my $func_name_offset = $lib_path_offset + length($lib_path);
    my $entry_stub_len   = $macho ? 21 : 20;
    my $main_rva         = $text + $entry_stub_len;
    my $disp_libpath     = $lib_path_offset - 12;
    my $disp_dlopen      = $dlopen_rva - ( $main_rva + 23 );
    my $disp_funcname    = $func_name_offset - 41;
    my $disp_dlsym       = $dlsym_rva - ( $main_rva + 47 );
    my $code             = pack( 'C', 0x53 );
    $code .= pack( 'C4',    0x48, 0x83, 0xEC, 0x10 );
    $code .= pack( 'C3 l<', 0x48, 0x8D, 0x3D, $disp_libpath );
    $code .= pack( 'C5',    0xBE, 0x02, 0x00, 0x00, 0x00 );
    $code .= pack( 'C2 l<', 0xFF, 0x15, $disp_dlopen );
    $code .= pack( 'C3',    0x48, 0x85, 0xC0 );
    $code .= pack( 'C2',    0x74, 0x1C );
    $code .= pack( 'C3',    0x48, 0x89, 0xC3 );
    $code .= pack( 'C3',    0x48, 0x89, 0xDF );
    $code .= pack( 'C3 l<', 0x48, 0x8D, 0x35, $disp_funcname );
    $code .= pack( 'C2 l<', 0xFF, 0x15, $disp_dlsym );
    $code .= pack( 'C3',    0x48, 0x85, 0xC0 );
    $code .= pack( 'C2',    0x74, 0x0F );
    $code .= pack( 'C2',    0xFF, 0xD0 );
    $code .= pack( 'C4',    0x48, 0x83, 0xC4, 0x10 );
    $code .= pack( 'C',     0x5B );
    $code .= pack( 'C',     0xC3 );
    $code .= pack( 'C5',    0xBF, 0x01, 0x00, 0x00, 0x00 );
    $code .= pack( 'C2',    0xEB, 0x05 );
    $code .= pack( 'C5',    0xBF, 0x02, 0x00, 0x00, 0x00 );
    $code .= pack( 'C5', 0xB8, $exit_syscall & 0xFF, ( $exit_syscall >> 8 ) & 0xFF, ( $exit_syscall >> 16 ) & 0xFF, ( $exit_syscall >> 24 ) & 0xFF );
    $code .= pack( 'C2', 0x0F, 0x05 );
    $code .= pack( 'C2', 0x0F, 0x0B );
    $code .= "\x00" while length($code) < $lib_path_offset;
    $code .= $lib_path . $func_name;
    return $code;
};

# ARM64 wrapper generator
my $make_arm64_wrapper = sub {
    my ( $ext_str, $dlopen_rva, $dlsym_rva, $text, $macho ) = @_;
    my $lib_path         = "./libtest_prog$ext_str\0";
    my $func_name        = "my_func\0";
    my $lib_path_offset  = 64;
    my $func_name_offset = $lib_path_offset + length($lib_path);
    my $entry_stub_len   = 20;
    my $main_rva         = $text + $entry_stub_len;
    my $disp_libpath     = $lib_path_offset - 8;
    my $disp_funcname    = $func_name_offset - 32;
    my $offset_dlopen    = $dlopen_rva - ( $main_rva + 16 );
    my $offset_dlsym     = $dlsym_rva - ( $main_rva + 36 );
    my $imm19_dlopen     = ( $offset_dlopen / 4 ) & 0x7FFFF;
    my $imm19_dlsym      = ( $offset_dlsym / 4 ) & 0x7FFFF;
    my $code             = pack(
        'V*', stp_pre( X29, X30, SP, -16 ),    # save FP, LR
        str_64( X3, SP, 16 ),                  # save X3
        adr( X0, $disp_libpath ),              # X0 = lib path addr
        movz_64( X1, 2 ),                      # X1 = RTLD_LAZY
        ldr_lit_64( X8, $offset_dlopen ),      # X8 = dlopen function
        blr(X8),                               # call dlopen
        mov_64( X19, X0 ),                     # save handle in X19
        mov_64( X0,  X19 ),                    # restore handle for dlsym
        adr( X1, $disp_funcname ),             # X1 = func name addr
        ldr_lit_64( X8, $offset_dlsym ),       # X8 = dlsym function
        blr(X8),                               # call dlsym
        blr(X0),                               # call resolved function
        ldr_64( X3, SP, 16 ),                  # restore X3
        ldp_post( X29, X30, SP, 16 ),          # restore FP, LR
        ret(),                                 # return
    );
    $code .= "\x00" while length($code) < 64;
    $code .= $lib_path . $func_name;
    return $code;
};

# RISC-V 64 wrapper generator
my $make_riscv64_wrapper = sub {
    my ( $ext_str, $dlopen_rva, $dlsym_rva, $text, $macho ) = @_;
    my $lib_path         = "./libtest_prog$ext_str\0";
    my $func_name        = "my_func\0";
    my $lib_path_offset  = 96;
    my $func_name_offset = $lib_path_offset + length($lib_path);
    my $entry_stub_len   = 20;
    my $main_rva         = $text + $entry_stub_len;
    my $off_libpath      = $lib_path_offset - 16;
    my $off_funcname     = $func_name_offset - 48;
    my $off_dlopen       = $dlopen_rva - ( $main_rva + 28 );
    my $off_dlsym        = $dlsym_rva - ( $main_rva + 56 );
    my $hi_lib           = ( $off_libpath + 0x800 ) >> 12;
    my $lo_lib           = $off_libpath & 0xFFF;
    my $auipc_a0         = ( ( $hi_lib & 0xFFFFF ) << 12 ) | ( 10 << 7 ) | 0x17;
    my $addi_a0          = ( ( $lo_lib & 0xFFF ) << 20 ) | ( 10 << 15 ) | ( 0 << 12 ) | ( 10 << 7 ) | 0x13;
    my $hi_fn            = ( $off_funcname + 0x800 ) >> 12;
    my $lo_fn            = $off_funcname & 0xFFF;
    my $auipc_a1         = ( ( $hi_fn & 0xFFFFF ) << 12 ) | ( 11 << 7 ) | 0x17;
    my $addi_a1          = ( ( $lo_fn & 0xFFF ) << 20 ) | ( 11 << 15 ) | ( 0 << 12 ) | ( 11 << 7 ) | 0x13;
    my $hi_dl            = ( $off_dlopen + 0x800 ) >> 12;
    my $lo_dl            = $off_dlopen & 0xFFF;
    my $auipc_dl         = ( ( $hi_dl & 0xFFFFF ) << 12 ) | ( 5 << 7 ) | 0x17;
    my $ld_dl            = ( ( $lo_dl & 0xFFF ) << 20 ) | ( 5 << 15 ) | ( 3 << 12 ) | ( 5 << 7 ) | 0x03;
    my $hi_ds            = ( $off_dlsym + 0x800 ) >> 12;
    my $lo_ds            = $off_dlsym & 0xFFF;
    my $auipc_ds         = ( ( $hi_ds & 0xFFFFF ) << 12 ) | ( 5 << 7 ) | 0x17;
    my $ld_ds            = ( ( $lo_ds & 0xFFF ) << 20 ) | ( 5 << 15 ) | ( 3 << 12 ) | ( 5 << 7 ) | 0x03;
    my $code             = pack( 'V*',
        0xFE010113, 0x00113C23, 0x00813423, 0x00913423, $auipc_a0,  $addi_a0,   0x00200593, $auipc_dl,
        $ld_dl,     0x000280E7, 0x00050413, 0x00040513, $auipc_a1,  $addi_a1,   $auipc_ds,  $ld_ds,
        0x000280E7, 0x000500E7, 0x00813483, 0x01013403, 0x01813083, 0x02010113, 0x00008067, );
    $code .= "\x00" while length($code) < $lib_path_offset;
    $code .= $lib_path . $func_name;
    return $code;
};
SKIP: {
    if ($is_windows) {
        skip 'Win32::API loader skipped due to emulation mismatch', 2 if $platform->is_arm64 && $Config{archname} =~ /x86_64|x64/i;
        require File::Spec;
        my $abs_path = File::Spec->rel2abs($lib_file);
        eval {
            require Win32::API;
            my $func = Win32::API->new( $abs_path, 'int my_func()' );
            ok $func, 'Natively bound my_func from compiled DLL with exports';
            if ($func) {
                my $ret = $func->Call();
                is $ret, 42, 'Invoked DLL export successfully via Win32::API, returned 42';
            }
        };
        if ($@) {
            skip 'Win32::API loader failure: ' . $@, 2;
        }
    }
    elsif ( $is_posix && ( $is_x64 || $is_arm64 || $is_riscv64 ) ) {
        my $wrapper_file = './test_wrapper';
        my $wrapper_linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new( type => 'exe' ) : Brocken::Jenny::Linker::ELF64->new( type => 'exe' );
        $wrapper_linker->set_has_ffi(1) if $platform->is_macos;
        my $code_sz     = ( $is_arm64 || $is_riscv64 ) ? 128 : 160;
        my $dummy_bytes = "\x00" x $code_sz;
        $wrapper_linker->write_executable( $wrapper_file, $dummy_bytes, $platform );
        my $got_rva    = $wrapper_linker->layout->get('.got')->{rva};
        my $dlopen_rva = $wrapper_linker->import_rva('dlopen');
        my $dlsym_rva  = $wrapper_linker->import_rva('dlsym');
        my $text_rva   = $wrapper_linker->layout->get('.text')->{rva};
        my $text_off   = $wrapper_linker->layout->get('.text')->{off};
        my $wrapper_bytes
            = $is_arm64 ? $make_arm64_wrapper->( $ext, $dlopen_rva, $dlsym_rva, $text_rva, $platform->is_macos ) :
            $is_riscv64 ? $make_riscv64_wrapper->( $ext, $dlopen_rva, $dlsym_rva, $text_rva, $platform->is_macos ) :
            $make_x64_wrapper->( $ext, $dlopen_rva, $dlsym_rva, $text_rva, $platform->is_macos, $platform->syscall('exit') );
        my $entry_stub_len = $platform->is_arm64 ? 20 : ( $platform->is_macos ? 21 : 20 );
        open my $fh, '+<:raw', $wrapper_file or die $!;
        seek( $fh, $text_off + $entry_stub_len, 0 );
        print $fh $wrapper_bytes;
        close $fh;
        system( 'codesign', '-f', '-s', '-', $wrapper_file ) if $platform->is_macos;
        ok -e $wrapper_file, 'POSIX wrapper compiled at ' . $wrapper_file;
        ok -x $wrapper_file, 'POSIX wrapper has execution permissions';
        local $ENV{LD_LIBRARY_PATH}   = join( ':', '.', $ENV{LD_LIBRARY_PATH}   // () );
        local $ENV{DYLD_LIBRARY_PATH} = join( ':', '.', $ENV{DYLD_LIBRARY_PATH} // () );
        system('./test_wrapper');
        my $status    = $?;
        my $exit_code = $status >> 8;
        my $signal    = $status & 127;
        is $signal,    0,  'Native wrapper ran cleanly without crash/segfault signals';
        is $exit_code, 42, 'Native wrapper loaded library, resolved symbol via GOT table FFI, and returned 42';
        unlink $wrapper_file;
    }
    else {
        skip 'No native FFI wrapper assembly available for ' . $platform->friendly, 2;
    }
}
unlink $lib_file;
done_testing;
