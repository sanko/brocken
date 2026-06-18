use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', 'blib/lib', '../../blib/lib';
use Test2::Tools::Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
$|++;
#
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;

my $compiler = Brocken::Compiler->new();
subtest Katsuro => sub {
    subtest 'platform parsing' => sub {
        my $raw_triple = Brocken::Katsuro::Platform::gen_triple();
        diag 'Host raw triple: ' . $raw_triple;
        my $platform = Brocken::Katsuro::Platform::parse($raw_triple);
        diag 'Host: ' . $platform->os . '/' . $platform->arch;
        diag 'File: app' . $platform->bin_ext . ' / lib' . $platform->lib_ext;
        isa_ok $platform, ['Brocken::Katsuro::Platform'], 'parsed host platform';
        my $linux = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        is $linux->arch,    'x86_64', 'linux arch';
        is $linux->vendor,  'pc',     'linux vendor';
        is $linux->os,      'linux',  'linux os';
        is $linux->env,     'gnu',    'linux env';
        is $linux->bin_ext, '',       'linux bin_ext';
        is $linux->lib_ext, '.so',    'linux lib_ext';
        is $linux->format,  'elf',    'linux format';
        ok $linux->is_linux,    'is_linux';
        ok $linux->is_posix,    'is_posix';
        ok !$linux->is_windows, 'not windows';
        ok !$linux->is_bsd,     'not bsd';
        ok !$linux->is_haiku,   'not haiku';
        my $win = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');
        is $win->bin_ext, '.exe', 'windows bin_ext';
        is $win->lib_ext, '.dll', 'windows lib_ext';
        is $win->format,  'pe',   'windows format';
        ok $win->is_windows, 'is_windows';
        ok !$win->is_posix,  'not posix';
        my $mac = Brocken::Katsuro::Platform::parse('aarch64-apple-darwin-macho');
        is $mac->bin_ext, '',       'macos bin_ext';
        is $mac->lib_ext, '.dylib', 'macos lib_ext';
        is $mac->format,  'macho',  'macos format';
        ok $mac->is_macos, 'is_macos';
        ok $mac->is_posix, 'is_posix';
        my $openbsd = Brocken::Katsuro::Platform::parse('x86_64-unknown-openbsd-elf');
        is $openbsd->bin_ext, '',    'openbsd bin_ext';
        is $openbsd->lib_ext, '.so', 'openbsd lib_ext';
        is $openbsd->format,  'elf', 'openbsd format';
        ok $openbsd->is_bsd,    'is_bsd';
        ok $openbsd->is_posix,  'is_posix';
        ok !$openbsd->is_linux, 'not linux';
        my $haiku = Brocken::Katsuro::Platform::parse('x86_64-pc-haiku-elf');
        is $haiku->bin_ext, '',    'haiku bin_ext';
        is $haiku->lib_ext, '.so', 'haiku lib_ext';
        is $haiku->format,  'elf', 'haiku format';
        ok $haiku->is_haiku, 'is_haiku';
        ok $haiku->is_posix, 'is_posix';
        ok !$haiku->is_bsd,  'not bsd';
        my $wasm = Brocken::Katsuro::Platform::parse('wasm32-unknown-unknown');
        is $wasm->bin_ext, '.wasm', 'wasm bin_ext';
        is $wasm->format,  'wasm',  'wasm format';
        ok $wasm->is_wasm,   'is_wasm';
        ok !$wasm->is_posix, 'wasm-unknown-unknown is not posix';
        my $wasi = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        ok $wasi->is_wasm,  'wasi is_wasm';
        ok $wasi->is_posix, 'wasi is_posix';
        my $netbsd = Brocken::Katsuro::Platform::parse('aarch64--netbsd');
        is $netbsd->os, 'netbsd', 'netbsd os identified from empty-vendor triple';
        ok $netbsd->is_bsd, 'is_bsd for netbsd';
    };
    subtest 'friendly names' => sub {
        my $linux = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        is $linux->friendly, 'Linux on x64', 'linux friendly name';
        my $win = Brocken::Katsuro::Platform::parse('aarch64-pc-windows-msvc');
        is $win->friendly, 'Windows on ARM64', 'windows friendly name';
        my $mac = Brocken::Katsuro::Platform::parse('aarch64-apple-darwin');
        is $mac->friendly, 'macOS on Apple Silicon', 'macos apple silicon friendly name';
        my $mac_intel = Brocken::Katsuro::Platform::parse('x86_64-apple-darwin');
        is $mac_intel->friendly, 'macOS on Intel', 'macos intel friendly name';
        my $freebsd = Brocken::Katsuro::Platform::parse('riscv64-unknown-freebsd');
        is $freebsd->friendly, 'FreeBSD on RISC-V', 'freebsd friendly name';
        my $wasm = Brocken::Katsuro::Platform::parse('wasm32-unknown-unknown');
        is $wasm->friendly, 'WebAssembly (Wasm)', 'wasm friendly name';
        my $unknown = Brocken::Katsuro::Platform::parse('unknown-unknown-unknown-unknown');
        is $unknown->friendly, 'sand that does math', 'fallback friendly name';
    };
    subtest 'platform naming' => sub {
        subtest 'Linux (ELF)' => sub {
            my $linux = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
            is $linux->bin_name('foo'),                 'foo',           'linux bin_name';
            is $linux->static_lib_name('foo'),          'libfoo.a',      'linux static_lib_name';
            is $linux->shared_lib_name('foo'),          'libfoo.so',     'linux shared_lib_name';
            is $linux->shared_lib_name( 'foo', '1.2' ), 'libfoo.so.1.2', 'linux shared_lib_name with version';
        };
        subtest 'Windows (PE)' => sub {
            subtest 'MSVC style' => sub {
                my $win = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');
                is $win->bin_name('foo'),                 'foo.exe',     'windows bin_name';
                is $win->static_lib_name('foo'),          'foo.lib',     'windows static_lib_name';
                is $win->shared_lib_name('foo'),          'foo.dll',     'windows shared_lib_name';
                is $win->shared_lib_name( 'foo', '1.2' ), 'foo-1.2.dll', 'windows shared_lib_name with version';
            };
            subtest 'GNU style' => sub {
                my $win = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-gnu');
                is $win->bin_name('foo'),                 'foo.exe',     'windows bin_name';
                is $win->static_lib_name('foo'),          'foo.a',       'windows static_lib_name';
                is $win->shared_lib_name('foo'),          'foo.dll',     'windows shared_lib_name';
                is $win->shared_lib_name( 'foo', '1.2' ), 'foo-1.2.dll', 'windows shared_lib_name with version';
            };
        };
        subtest 'MacOS (Mach-O)' => sub {
            my $mac = Brocken::Katsuro::Platform::parse('aarch64-apple-darwin');
            is $mac->bin_name('foo'),                 'foo',              'macos bin_name';
            is $mac->static_lib_name('foo'),          'libfoo.a',         'macos static_lib_name';
            is $mac->shared_lib_name('foo'),          'libfoo.dylib',     'macos shared_lib_name';
            is $mac->shared_lib_name( 'foo', '1.2' ), 'libfoo.1.2.dylib', 'macos shared_lib_name with version';
        };
        subtest 'Wasm' => sub {
            my $wasm = Brocken::Katsuro::Platform::parse('wasm32-unknown-unknown');
            is $wasm->bin_name('foo'),        'foo.wasm', 'wasm bin_name';
            is $wasm->static_lib_name('foo'), 'foo.a',    'wasm static_lib_name';
            is $wasm->shared_lib_name('foo'), 'foo.wasm', 'wasm shared_lib_name';
        }
    };
    subtest 'OS syscall numbers' => sub {
        my $bsd = Brocken::Katsuro::Platform::parse('x86_64-pc-freebsd-elf');
        is $bsd->syscall('write'), 4,     'bsd x86_64 write';
        is $bsd->syscall('exit'),  1,     'bsd x86_64 exit';
        is $bsd->syscall('fork'),  2,     'bsd x86_64 fork';
        is $bsd->syscall_num_reg,  'rax', 'bsd x86_64 syscall_num_reg';
        is $bsd->syscall_ret_reg,  'rax', 'bsd x86_64 syscall_ret_reg';
        my $lnx = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        is $lnx->syscall('write'), 1,   'linux x86_64 write';
        is $lnx->syscall('exit'),  60,  'linux x86_64 exit';
        is $lnx->syscall('fork'),  57,  'linux x86_64 fork';
        is $lnx->syscall('futex'), 202, 'linux x86_64 futex';
        my $lnx64 = Brocken::Katsuro::Platform::parse('aarch64-pc-linux-gnu');
        is $lnx64->syscall('write'), 64, 'linux aarch64 write';
        is $lnx64->syscall('exit'),  93, 'linux aarch64 exit';
        my $mac = Brocken::Katsuro::Platform::parse('x86_64-apple-darwin-macho');
        is $mac->syscall('write'), 0x2000004, 'macos x86_64 write (with offset)';
        is $mac->syscall('exit'),  0x2000001, 'macos x86_64 exit (with offset)';
        ok $mac->syscall('write') != 4, 'macos write != bsd write';
    };
    subtest 'Haiku syscall numbers (fallback)' => sub {
        my $haiku = Brocken::Katsuro::Platform::parse('x86_64-pc-haiku-elf');
        is $haiku->syscall('write'),  144, 'haiku x86_64 write fallback';
        is $haiku->syscall('exit'),   38,  'haiku x86_64 exit fallback';
        is $haiku->syscall('fork'),   47,  'haiku x86_64 fork fallback';
        is $haiku->syscall('getpid'), 46,  'haiku x86_64 getpid fallback';
        is $haiku->syscall('read'),   148, 'haiku x86_64 read fallback';
    };
    subtest 'ABI register sets' => sub {
        my $p     = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        my @avail = $p->registers('available')->@*;
        ok grep( /^rax$/,  @avail ), 'x86_64 has rax';
        ok grep( /^r15$/,  @avail ), 'x86_64 has r15';
        ok !grep( /^rsp$/, @avail ), 'x86_64 excludes rsp';
        my @caller = $p->caller_saved->@*;
        ok grep( /^rax$/,  @caller ), 'x86_64 caller rax';
        ok !grep( /^rbx$/, @caller ), 'x86_64 caller excludes rbx';
        my @callee = $p->callee_saved->@*;
        ok grep( /^rbx$/, @callee ), 'x86_64 callee rbx';
        ok grep( /^r12$/, @callee ), 'x86_64 callee r12';
        is $p->frame_reg, 'rbp', 'x86_64 frame = rbp';
        is $p->stack_reg, 'rsp', 'x86_64 stack = rsp';
        my $aarch    = Brocken::Katsuro::Platform::parse('aarch64-pc-linux-gnu');
        my @a_caller = $aarch->caller_saved->@*;
        ok grep( /^x0$/,   @a_caller ), 'aarch64 caller x0';
        ok grep( /^x15$/,  @a_caller ), 'aarch64 caller x15';
        ok !grep( /^x19$/, @a_caller ), 'aarch64 caller excludes x19';
        ok !grep( /^x20$/, @a_caller ), 'aarch64 caller excludes x20';
        my @a_callee = $aarch->callee_saved->@*;
        ok grep( /^x20$/, @a_callee ), 'aarch64 callee x20';
        ok grep( /^x28$/, @a_callee ), 'aarch64 callee x28';
        is $aarch->frame_reg, 'x29', 'aarch64 frame = x29';
        my $riscv    = Brocken::Katsuro::Platform::parse('riscv64-pc-linux-gnu');
        my @r_caller = $riscv->caller_saved->@*;
        ok grep( /^a0$/, @r_caller ), 'riscv64 caller a0';
        ok grep( /^t6$/, @r_caller ), 'riscv64 caller t6';
        my @r_callee = $riscv->callee_saved->@*;
        ok grep( /^s1$/,  @r_callee ), 'riscv64 callee s1';
        ok grep( /^s11$/, @r_callee ), 'riscv64 callee s11';
        is $riscv->frame_reg, 's0', 'riscv64 frame = s0';
    };
    subtest 'triple normalization' => sub {
        my $norm = Brocken::Katsuro::Platform::normalize_triple('x86_64-apple-darwin21.0.0');
        is $norm, 'x86_64-apple-darwin21.0.0-macho', '3-field apple triple';
        $norm = Brocken::Katsuro::Platform::normalize_triple('x86_64-linux-gnu');
        is $norm, 'x86_64-pc-linux-gnu', '3-field linux triple';
        $norm = Brocken::Katsuro::Platform::normalize_triple('x86_64-w64-mingw32');
        is $norm, 'x86_64-pc-windows-gnu', '3-field mingw triple';
        $norm = Brocken::Katsuro::Platform::normalize_triple('x86_64-unknown-openbsd-elf');
        is $norm, 'x86_64-unknown-openbsd-elf', '4-field openbsd triple unchanged';
    };
    subtest 'known target triples' => sub {
        my @targets = <DATA>;
        chomp @targets;
        my $ok      = 0;
        my %arch_64 = map { $_ => 1 } qw[x86_64
            aarch64 aarch64_be arm64e
            riscv64
            powerpc64 powerpc64le
            mips64 mips64el
            loongarch64
            s390x sparc64
            wasm64
            nvptx64];
        my %count;

        for my $raw (@targets) {
            next if $raw =~ /^\s*#/ || $raw =~ /^\s*$/;
            my $p = Brocken::Katsuro::Platform::parse($raw);
            ok defined $p && $p->isa('Brocken::Katsuro::Platform'), "parse($raw)";
            $ok++;
            my $arch = $p->arch;
            $count{ $arch_64{$arch} ? '64' : ( $arch =~ /64/ ? '64' : 'other' ) }++;
        }
        diag "$ok targets parsed (" . ( $count{64} // 0 ) . ' 64-bit, ' . ( $count{other} // 0 ) . ' other)';
    };
};
subtest Lindsay => sub {
    subtest 'Lindsay::IR Types & Singletons' => sub {
        my $i1   = Brocken::Lindsay::IR::Type::i1();
        my $i8   = Brocken::Lindsay::IR::Type::i8();
        my $i16  = Brocken::Lindsay::IR::Type::i16();
        my $i32  = Brocken::Lindsay::IR::Type::i32();
        my $i64  = Brocken::Lindsay::IR::Type::i64();
        my $i128 = Brocken::Lindsay::IR::Type::i128();
        my $f32  = Brocken::Lindsay::IR::Type::f32();
        my $f64  = Brocken::Lindsay::IR::Type::f64();
        my $ptr  = Brocken::Lindsay::IR::Type::ptr();
        my $void = Brocken::Lindsay::IR::Type::void();
        my $dyn  = Brocken::Lindsay::IR::Type::dynamic();
        is $i1->as_string,   'i1',      'i1 renders correctly';
        is $i8->as_string,   'i8',      'i8 renders correctly';
        is $i16->as_string,  'i16',     'i16 renders correctly';
        is $i32->as_string,  'i32',     'i32 renders correctly';
        is $i64->as_string,  'i64',     'i64 renders correctly';
        is $i128->as_string, 'i128',    'i128 renders correctly';
        is $f32->as_string,  'f32',     'f32 renders correctly';
        is $f64->as_string,  'f64',     'f64 renders correctly';
        is $ptr->as_string,  'ptr',     'ptr renders correctly';
        is $void->as_string, 'void',    'void renders correctly';
        is $dyn->as_string,  'dynamic', 'dynamic renders correctly';

        # Prove they are singletons
        ref_is $i32,  Brocken::Lindsay::IR::Type::i32(),     'i32 singleton';
        ref_is $i1,   Brocken::Lindsay::IR::Type::i1(),      'i1 singleton';
        ref_is $i8,   Brocken::Lindsay::IR::Type::i8(),      'i8 singleton';
        ref_is $i16,  Brocken::Lindsay::IR::Type::i16(),     'i16 singleton';
        ref_is $i64,  Brocken::Lindsay::IR::Type::i64(),     'i64 singleton';
        ref_is $i128, Brocken::Lindsay::IR::Type::i128(),    'i128 singleton';
        ref_is $f32,  Brocken::Lindsay::IR::Type::f32(),     'f32 singleton';
        ref_is $f64,  Brocken::Lindsay::IR::Type::f64(),     'f64 singleton';
        ref_is $ptr,  Brocken::Lindsay::IR::Type::ptr(),     'ptr singleton';
        ref_is $void, Brocken::Lindsay::IR::Type::void(),    'void singleton';
        ref_is $dyn,  Brocken::Lindsay::IR::Type::dynamic(), 'dynamic singleton';
    };
    subtest 'Lindsay::IR Values & Constants' => sub {
        my $val = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%my_var' );
        is $val->as_string, '%my_var', 'Value renders its name';
        my $const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => '42' );
        is $const->as_string, '42', 'Constant renders its underlying value';
    };
    subtest 'Lindsay::IR Builder' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'test_mod' );

        # Setup Parameters
        my $param_a = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%a' );
        my $param_b = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%b' );

        # Setup Function
        my $func = Brocken::Lindsay::IR::Function->new(
            name        => 'add_nums',
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => [ $param_a, $param_b ]
        );
        $module->add_function($func);

        # Use Builder
        my $builder = Brocken::Lindsay::IR::Builder->new();
        my $entry   = $func->append_block('entry');
        $builder->position_at_end($entry);

        # Generate instructions
        my $sum = $builder->build_add( $param_a, $param_b );    # Should assign %0 automatically
        $builder->build_ret($sum);

        # Verify Internal State
        is $sum->name,                         '%0', 'Builder assigned correct auto-incremented SSA id';
        is scalar( $entry->instructions->@* ), 2,    'Two instructions appended to basic block';

        # Verify Stringified IR Output
        my $expected_ir = <<~'IR';
    ; ModuleID = 'test_mod'

    define i32 @add_nums(i32 %a, i32 %b) {
    entry:
      %0 = add i32 %a, %b
      ret i32 %0
    }

    IR
        is $module->as_string, $expected_ir, 'Generated IR matches LLVM-style expected output';
    };
    subtest 'Lindsay::IR Memory Operations' => sub {
        my $module      = Brocken::Lindsay::IR::Module->new( name => 'mem_test' );
        my $param_input = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%input' );
        my $func
            = Brocken::Lindsay::IR::Function->new( name => 'copy_val', return_type => Brocken::Lindsay::IR::Type::void(), params => [$param_input] );
        $module->add_function($func);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # Allocate an i32 on the stack (yields a ptr)
        my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%my_ptr' );

        # Store the input parameter into the pointer
        $builder->build_store( $param_input, $ptr );

        # Load the value back out
        my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%loaded_val' );

        # Return
        $builder->build_ret();
        my $expected_ir = <<~'IR';
    ; ModuleID = 'mem_test'

    define void @copy_val(i32 %input) {
    entry:
      %my_ptr = alloca i32
      store i32 %input, ptr %my_ptr
      %loaded_val = load i32, ptr %my_ptr
      ret void
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Memory IR matches expected LLVM-style output';
    };
    subtest 'Lindsay::IR Gradual Typing (Boxing/Unboxing)' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'gradual_typing' );

        # Input is a dynamic (Perl-like) scalar
        my $param_dyn = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::dynamic(), name => '%input_dyn' );

        # Returns a dynamic scalar
        my $func = Brocken::Lindsay::IR::Function->new( name => 'double_it', return_type => Brocken::Lindsay::IR::Type::dynamic(),
            params => [$param_dyn] );
        $module->add_function($func);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # Unbox the dynamic variable into a native 64-bit integer
        my $native_i64 = $builder->build_unbox( $param_dyn, Brocken::Lindsay::IR::Type::i64(), '%native_val' );

        # Perform native math (zero GC overhead)
        my $doubled = $builder->build_add( $native_i64, $native_i64, '%doubled' );

        # Box it back into a dynamic variable to return it
        my $boxed_result = $builder->build_box( $doubled, '%boxed_res' );

        # Return the dynamic value
        $builder->build_ret($boxed_result);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'gradual_typing'

    define dynamic @double_it(dynamic %input_dyn) {
    entry:
      %native_val = unbox dynamic %input_dyn to i64
      %doubled = add i64 %native_val, %native_val
      %boxed_res = box i64 %doubled to dynamic
      ret dynamic %boxed_res
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Boxing IR matches expected output';
    };
    subtest 'Lindsay::IR Control Flow (If/Else)' => sub {
        my $module  = Brocken::Lindsay::IR::Module->new( name => 'control_flow' );
        my $param_a = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%a' );
        my $param_b = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%b' );
        my $func    = Brocken::Lindsay::IR::Function->new(
            name        => 'max_val',
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => [ $param_a, $param_b ]
        );
        $module->add_function($func);

        # Create the basic blocks
        my $entry_blk = $func->append_block('entry');
        my $then_blk  = $func->append_block('if.then');
        my $else_blk  = $func->append_block('if.else');
        my $builder   = Brocken::Lindsay::IR::Builder->new();

        # Entry Block
        $builder->position_at_end($entry_blk);

        # check if %a > %b (sgt = signed greater than)
        my $cond = $builder->build_icmp( 'sgt', $param_a, $param_b, '%cmp' );
        $builder->build_cond_br( $cond, $then_blk, $else_blk );

        # Then Block
        $builder->position_at_end($then_blk);
        $builder->build_ret($param_a);

        # Else Block
        $builder->position_at_end($else_blk);
        $builder->build_ret($param_b);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'control_flow'

    define i32 @max_val(i32 %a, i32 %b) {
    entry:
      %cmp = icmp sgt i32 %a, %b
      br i1 %cmp, label %if.then, label %if.else
    if.then:
      ret i32 %a
    if.else:
      ret i32 %b
    }

    IR
        is $module->as_string, $expected_ir, 'Generated If/Else IR matches expected output';
    };
    subtest 'Lindsay::IR Function Calls and FFI' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'call_test' );

        # Declare an external FFI function (e.g., C's puts)
        # int puts(char *str);
        my $ffi_param = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() );
        my $ffi_puts
            = Brocken::Lindsay::IR::Function->new( name => 'puts', return_type => Brocken::Lindsay::IR::Type::i32(), params => [$ffi_param] );
        $module->add_function($ffi_puts);

        # Define our local main function
        my $func_main = Brocken::Lindsay::IR::Function->new(
            name        => 'main',
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => []                                   # no args
        );
        $module->add_function($func_main);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_main->append_block('entry') );

        # Simulate a global string pointer being passed in
        my $str_ptr = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '@hello_str' );

        # Call the external FFI function
        my $puts_res = $builder->build_call( $ffi_puts, [$str_ptr], '%puts_res' );

        # Return the result
        $builder->build_ret($puts_res);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'call_test'

    declare i32 @puts(ptr)

    define i32 @main() {
    entry:
      %puts_res = call i32 @puts(ptr @hello_str)
      ret i32 %puts_res
    }

    IR
        is $module->as_string, $expected_ir, 'Generated IR supports FFI declarations and calls';
    };
    subtest 'Lindsay::IR Binary Operators' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'binops' );
        my $a      = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%a' );
        my $b      = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%b' );
        my $func   = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::void(), params => [ $a, $b ] );
        $module->add_function($func);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        $builder->build_sub( $a, $b );
        $builder->build_mul( $a, $b );
        $builder->build_and( $a, $b );
        $builder->build_or( $a, $b );
        $builder->build_xor( $a, $b );
        $builder->build_shl( $a, $b );
        $builder->build_lshr( $a, $b );
        $builder->build_ashr( $a, $b );
        $builder->build_ret();
        my $expected_ir = <<~'IR';
    ; ModuleID = 'binops'

    define void @math(i32 %a, i32 %b) {
    entry:
      %0 = sub i32 %a, %b
      %1 = mul i32 %a, %b
      %2 = and i32 %a, %b
      %3 = or i32 %a, %b
      %4 = xor i32 %a, %b
      %5 = shl i32 %a, %b
      %6 = lshr i32 %a, %b
      %7 = ashr i32 %a, %b
      ret void
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Binary Operators IR matches expected output';
    };
    subtest 'Lindsay::IR Select & GEP' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'select_gep' );
        my $func   = Brocken::Lindsay::IR::Function->new(
            name        => 'test',
            return_type => Brocken::Lindsay::IR::Type::ptr(),
            params      => [
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i1(),  name => '%cond' ),
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%base' )
            ]
        );
        $module->add_function($func);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $c1  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 );
        my $c2  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 20 );
        my $val = $builder->build_select( $func->params->[0], $c1, $c2, '%val' );
        my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $func->params->[1], [$val], '%element_ptr' );
        $builder->build_ret($gep);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'select_gep'

    define ptr @test(i1 %cond, ptr %base) {
    entry:
      %val = select i1 %cond, i32 10, i32 20
      %element_ptr = getelementptr i32, ptr %base, i32 %val
      ret ptr %element_ptr
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Select and GEP IR matches expected output';
    };
    subtest 'Lindsay::IR Loops' => sub {
        my $module = Brocken::Lindsay::IR::Module->new( name => 'loop_test' );
        my $func   = Brocken::Lindsay::IR::Function->new(
            name        => 'sum_to_n',
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%n' ) ]
        );
        $module->add_function($func);
        my $entry   = $func->append_block('entry');
        my $loop    = $func->append_block('loop');
        my $exit    = $func->append_block('exit');
        my $builder = Brocken::Lindsay::IR::Builder->new();

        # Entry
        $builder->position_at_end($entry);
        $builder->build_br($loop);

        # Loop
        $builder->position_at_end($loop);
        my $i   = $builder->build_phi( Brocken::Lindsay::IR::Type::i32(), '%i' );
        my $sum = $builder->build_phi( Brocken::Lindsay::IR::Type::i32(), '%sum' );
        my $next_i
            = $builder->build_add( $i, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ), '%next_i' );
        my $next_sum = $builder->build_add( $sum, $i, '%next_sum' );
        my $cond     = $builder->build_icmp( 'slt', $i, $func->params->[0], '%cond' );
        $builder->build_cond_br( $cond, $loop, $exit );
        $i->add_incoming( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), $entry );
        $i->add_incoming( $next_i,                                                                                      $loop );
        $sum->add_incoming( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), $entry );
        $sum->add_incoming( $next_sum,                                                                                    $loop );

        # Exit
        $builder->position_at_end($exit);
        $builder->build_ret($sum);
        my $expected_ir = <<~'IR';
    ; ModuleID = 'loop_test'

    define i32 @sum_to_n(i32 %n) {
    entry:
      br label %loop
    loop:
      %i = phi i32 [ 0, %entry ], [ %next_i, %loop ]
      %sum = phi i32 [ 0, %entry ], [ %next_sum, %loop ]
      %next_i = add i32 %i, 1
      %next_sum = add i32 %sum, %i
      %cond = icmp slt i32 %i, %n
      br i1 %cond, label %loop, label %exit
    exit:
      ret i32 %sum
    }

    IR
        is $module->as_string, $expected_ir, 'Generated Loop IR with PHI nodes matches expected output';
    };
};
subtest Jenny => sub {
    subtest 'Jenny::Linker Pure ELF-64 Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();

        # Build the IR: int main() { return 42; }
        my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_elf' );
        my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_main);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_main->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );

        # Compile IR to native machine code based on host architecture
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_main);

        # Link and Write to raw ELF executable file
        my $output_file = './test_prog';
        my $linker      = Brocken::Jenny::Linker::ELF64->new();
        $linker->write_executable( $output_file, $machine_bytes, $platform );

        # Ensure the file was actually written
        ok -e $output_file, 'Binary executable file created successfully';

        # We can only execute this test on x86_64 Linux hosts
    SKIP: {
            skip 'ELF binary execution test requires Linux' unless $platform->is_linux || $platform->is_bsd || $platform->is_haiku;

            # Diagnostic: check executable bit and dump header bytes
            ok -x $output_file, 'Binary is executable';
            open my $diag_fh, '<:raw', $output_file or warn "Can't open $output_file: $!";
            if ($diag_fh) {
                read( $diag_fh, my $magic, 16 );
                close $diag_fh;
                note 'Binary magic hex: ' . unpack( 'H*', $magic );
            }

            # Execute the binary and inspect its exit code!
            system($output_file);
            my $exit_code = $? >> 8;
            my $signal    = $? & 127;
            my $core      = $? & 128;
            note "raw \$?=$? exit=$exit_code signal=$signal core=$core";
            is $exit_code, 42, 'Standalone binary executed natively and returned the correct exit code!';
        }

        # Clean up
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure ELF-64 Shared Library Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_elf' );
        my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_ext);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_ext->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_ext);
        my $output_file   = './libtest_prog.so';
        my $linker        = Brocken::Jenny::Linker::ELF64->new( type => 'shared' );
        $linker->set_exported_funcs( ['my_func'] );
        $linker->set_labels( { E_my_func => 0 } );
        $linker->write_executable( $output_file, $machine_bytes, $platform, 1 );
        ok -e $output_file, 'ELF Shared library created successfully';
    SKIP: {
            skip 'Shared library loading test requires Linux/BSD/Haiku native host', 1
                unless ( $platform->is_linux || $platform->is_bsd || $platform->is_haiku ) && $platform->is_native;
            require DynaLoader;
            require File::Spec;
            my $abs_path = File::Spec->rel2abs($output_file);
            my $libref   = DynaLoader::dl_load_file($abs_path);
            diag `nm $abs_path`;
            diag "dl_error: " . ( DynaLoader::dl_error() || $! || 'unknown' ) unless $libref;
            ok $libref, 'Loaded ELF shared library natively via DynaLoader';

            if ($libref) {
                my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
                ok $symref, 'Successfully resolved exported symbol "my_func"';
                DynaLoader::dl_unload_file($libref);
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure PE-64 Generation' => sub {
        my $platform  = Brocken::Katsuro::Platform::parse();
        my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_win' );
        my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_main);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_main->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );

        # Compile IR to native machine code based on host architecture
        my $codegen       = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() : Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_main);

        # Link and Write to raw PE executable file (.exe)
        my $output_file = 'test_prog.exe';
        my $linker      = Brocken::Jenny::Linker::PE->new();

        #~ $linker->link_executable( $output_file, $machine_bytes );
        $linker->write_executable( $output_file, $machine_bytes, $platform );
        ok -e $output_file, 'Windows executable file created successfully';
    SKIP: {
            skip 'PE binary execution test requires x86_64 Windows', 1 unless $platform->is_windows;

            # Execute the binary natively and inspect its exit code!
            run_exec(
                $output_file,
                expected_exit => 42,
                platform      => $platform,
                name          => 'Standalone Windows binary executed natively and returned the correct exit code!'
            );
        }

        # Clean up
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure PE-64 Shared Library Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_pe' );
        my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_ext);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_ext->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen       = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() : Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_ext);
        my $output_file   = './libtest_prog.dll';

        # The main PE Linker now supports symbol exporting natively
        my $linker = Brocken::Jenny::Linker::PE->new( type => 'shared' );
        $linker->set_exported_funcs( ['my_func'] );
        $linker->set_labels( { E_my_func => 0 } );
        $linker->write_shared_library( $output_file, $machine_bytes, $platform );
        ok -e $output_file, 'PE Shared library (DLL) created successfully';
    SKIP: {
            use Config;

            # Skip native loading test under emulation mismatch to prevent crash errors
            skip 'Shared library loading test requires native execution support (no emulation mismatch)', 1
                unless $platform->is_windows && $platform->is_native && ( $platform->is_arm64 ? ( $Config{archname} !~ /x86_64|x64/i ) : 1 );
            require DynaLoader;
            require File::Spec;
            my $abs_path = File::Spec->rel2abs($output_file);
            my $libref   = DynaLoader::dl_load_file($abs_path);
            ok $libref, 'Loaded PE DLL natively via DynaLoader';
            if ($libref) {
                my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
                ok $symref, 'Successfully resolved exported symbol "my_func" natively via DynaLoader';
                DynaLoader::dl_unload_file($libref);
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure Mach-O Generation' => sub {
        my $platform  = Brocken::Katsuro::Platform::parse();
        my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_macho' );
        my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_main);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_main->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );

        # Compile IR to native machine code based on host architecture
        my $codegen       = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() : Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_main);

        # Link and Write to raw Mach-O executable
        my $output_file = './test_prog';
        my $linker      = Brocken::Jenny::Linker::MachO->new();
        $linker->write_executable( $output_file, $machine_bytes, $platform );

        # Ensure the file was actually written
        ok -e $output_file, 'Mach-O executable created successfully';
    SKIP: {
            skip 'Mach-O binary execution test requires macOS (x64 or ARM64)', 1 unless $platform->is_macos;

            # Execute natively and inspect the exit code!
            system($output_file);
            my $exit_code = $? >> 8;
            is $exit_code, 42, 'Standalone Mach-O binary executed natively and returned the correct exit code!';
            note $?;
            note $exit_code;

            # Diagnostic: compile reference binary and dump both for comparison
            if ( $exit_code != 42 ) {
                my $ref_src = 'ref_prog.c';
                my $ref_bin = 'ref_prog';
                open my $rfh, '>', $ref_src or warn "Can't write $ref_src: $!";
                print $rfh "int main(void) { return 42; }\n";
                close $rfh;
                my $rc = system( 'clang', '-o', $ref_bin, $ref_src );
                if ( ( $rc >> 8 ) == 0 ) {
                    note '=== Generated: otool -l ===';
                    note scalar `otool -l "$output_file" 2>&1`;
                    note '=== Reference: otool -l ===';
                    note scalar `otool -l "$ref_bin" 2>&1`;
                    note '=== Generated: od -A x -t x1 -c (first 1KB) ===';
                    note scalar `od -A x -t x1 -c -v -N 1024 "$output_file" 2>&1`;
                    note '=== Reference: od -A x -t x1 -c (first 1KB) ===';
                    note scalar `od -A x -t x1 -c -v -N 1024 "$ref_bin" 2>&1`;
                }
                else {
                    note 'clang compilation failed, exit: ' . ( $rc >> 8 );
                }
            }
        }

        # Clean up
        unlink $output_file;
    };
    subtest 'Jenny::Linker Pure Mach-O Shared Library Generation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_macho' );
        my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_ext);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_ext->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen       = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new() : Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_ext);
        my $output_file   = './libtest_prog.dylib';
        my $linker        = Brocken::Jenny::Linker::MachO->new( type => 'shared' );
        $linker->set_exported_funcs( ['my_func'] );
        $linker->set_labels( { E_my_func => 0 } );
        $linker->write_executable( $output_file, $machine_bytes, $platform );
        ok -e $output_file, 'Mach-O Shared library created successfully';
    SKIP: {
            skip 'Shared library loading test requires macOS native host', 1 unless $platform->is_macos && $platform->is_native;
            require DynaLoader;
            require File::Spec;
            my $abs_path = File::Spec->rel2abs($output_file);
            my $libref   = DynaLoader::dl_load_file($abs_path);
            ok $libref, 'Loaded Mach-O shared library natively via DynaLoader';
            if ($libref) {
                my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
                ok $symref, 'Successfully resolved exported symbol "my_func"';
                diag $symref;
                DynaLoader::dl_unload_file($libref);
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Linker Early FFI Integration Test' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();

        # Determine platform properties
        my $is_arm64   = $platform->is_arm64;
        my $is_riscv64 = $platform->is_riscv64;
        my $is_x64     = $platform->is_x64;
        my $is_windows = $platform->is_windows;
        my $is_posix   = $platform->is_posix;

        # Build the shared library IR: int my_func() { return 42; }
        my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_lib' );
        my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $module->add_function($func_ext);
        my $builder = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func_ext->append_block('entry') );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen
            = $is_arm64           ? Brocken::Jenny::Codegen::ARM64->new() :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new();
        my $machine_bytes = $codegen->emit_function($func_ext);
        my $ext           = $platform->lib_ext;
        my $lib_file      = './libtest_prog' . $ext;

        # Build and write shared library
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

        # Verify that the expected symbol is physically exported in the binary via nm
        my $nm_out = $^O eq 'MSWin32' ? `objdump -p $lib_file` : `nm "$lib_file"`;
        diag $nm_out;
        diag `dumpbin /headers $lib_file`;
        diag `dumpbin /exports $lib_file`;
        diag `llvm-readobj --coff-exports $lib_file`;
        if ( $? == 0 && defined $nm_out && $nm_out ne '' ) {
            my $expected_sym = $platform->is_macos ? '_my_func' : 'my_func';
            like $nm_out, qr/\b$expected_sym\b/, "Verified via 'nm' that '$expected_sym' is present in $lib_file";
        }
        else {
            note 'nm is not available or failed; skipping symbol table extraction check';
        }

        # POSIX x86_64 Wrapper Generator with null checks and 16-byte Stack Alignment Fix
        my $make_x64_wrapper = sub ( $ext_str, $dlopen_rva, $dlsym_rva, $text, $macho, $exit_syscall //= $macho ? 0x2000001 : 60 ) {
            my $lib_path         = "./libtest_prog$ext_str\0";
            my $func_name        = "my_func\0";
            my $lib_path_offset  = 128;
            my $func_name_offset = $lib_path_offset + length($lib_path);
            my $entry_stub_len   = $macho ? 21 : 20;
            my $main_rva         = $text + $entry_stub_len;
            my $disp_libpath     = $lib_path_offset - 12;                  # RIP at offset 12
            my $disp_dlopen      = $dlopen_rva - ( $main_rva + 23 );       # RIP at offset 23
            my $disp_funcname    = $func_name_offset - 41;                 # RIP at offset 41
            my $disp_dlsym       = $dlsym_rva - ( $main_rva + 47 );        # RIP at offset 47
            my $code             = pack( 'C', 0x53 );                      # push rbx
            $code .= pack( 'C4',    0x48, 0x83, 0xEC, 0x10 );              # sub rsp, 16
            $code .= pack( 'C3 l<', 0x48, 0x8D, 0x3D, $disp_libpath );     # lea rdi, [rip + lib_path]
            $code .= pack( 'C5',    0xBE, 0x02, 0x00, 0x00, 0x00 );        # mov esi, 2 (RTLD_NOW)
            $code .= pack( 'C2 l<', 0xFF, 0x15, $disp_dlopen );            # call [rip + dlopen]
            $code .= pack( 'C3',    0x48, 0x85, 0xC0 );                    # test rax, rax
            $code .= pack( 'C2',    0x74, 0x1C );                          # jz fail_dlopen (to offset 60)
            $code .= pack( 'C3',    0x48, 0x89, 0xC3 );                    # mov rbx, rax
            $code .= pack( 'C3',    0x48, 0x89, 0xDF );                    # mov rdi, rbx
            $code .= pack( 'C3 l<', 0x48, 0x8D, 0x35, $disp_funcname );    # lea rsi, [rip + func_name]
            $code .= pack( 'C2 l<', 0xFF, 0x15, $disp_dlsym );             # call [rip + dlsym]
            $code .= pack( 'C3',    0x48, 0x85, 0xC0 );                    # test rax, rax
            $code .= pack( 'C2',    0x74, 0x0F );                          # jz fail_dlsym (to offset 67)
            $code .= pack( 'C2',    0xFF, 0xD0 );                          # call rax
            $code .= pack( 'C4',    0x48, 0x83, 0xC4, 0x10 );              # add rsp, 16
            $code .= pack( 'C',     0x5B );                                # pop rbx
            $code .= pack( 'C',     0xC3 );                                # ret

            # fail_dlopen (offset 60):
            $code .= pack( 'C5', 0xBF, 0x01, 0x00, 0x00, 0x00 );           # mov edi, 1
            $code .= pack( 'C2', 0xEB, 0x05 );                             # jmp exit_via_syscall (to offset 72)

            # fail_dlsym (offset 67):
            $code .= pack( 'C5', 0xBF, 0x02, 0x00, 0x00, 0x00 );           # mov edi, 2

            # exit_via_syscall (offset 72):
            $code .= pack( 'C5',
                0xB8,
                $exit_syscall & 0xFF,
                ( $exit_syscall >> 8 ) & 0xFF,
                ( $exit_syscall >> 16 ) & 0xFF,
                ( $exit_syscall >> 24 ) & 0xFF );    # mov eax, exit_syscall
            $code .= pack( 'C2', 0x0F, 0x05 );       # syscall
            $code .= pack( 'C2', 0x0F, 0x0B );       # ud2
            $code .= "\x00" while length($code) < $lib_path_offset;
            $code .= $lib_path . $func_name;
            return $code;
        };

        # POSIX ARM64 Wrapper Generator
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
            my $adr_x0           = 0x10000000 | ( ( $disp_libpath & 3 ) << 29 ) | ( ( ( $disp_libpath >> 2 ) & 0x7FFFF ) << 5 ) | 0;
            my $adr_x1           = 0x10000000 | ( ( $disp_funcname & 3 ) << 29 ) | ( ( ( $disp_funcname >> 2 ) & 0x7FFFF ) << 5 ) | 1;
            my $ldr_dlopen       = 0x58000008 | ( $imm19_dlopen << 5 );
            my $ldr_dlsym        = 0x58000008 | ( $imm19_dlsym << 5 );
            my $code             = pack(
                'V*', 0xA9BF7BFD,    # stp x29, x30, [sp, #-32]!
                0xF9000BE3,          # str x19, [sp, #16]
                $adr_x0,             # adr x0, lib_path
                0xD2800041,          # mov x1, #2 (RTLD_NOW)
                $ldr_dlopen,         # ldr x8, got_slot_dlopen
                0xD63F0100,          # blr x8
                0xAA0003F3,          # mov x19, x0
                0xAA1303E0,          # mov x0, x19
                $adr_x1,             # adr x1, func_name
                $ldr_dlsym,          # ldr x8, got_slot_dlsym
                0xD63F0100,          # blr x8
                0xD63F0000,          # blr x0
                0xF9400BE3,          # ldr x19, [sp, #16]
                0xA8C27BFD,          # ldp x29, x30, [sp], #32
                0xD65F03C0,          # ret
            );
            $code .= "\x00" while length($code) < 64;
            $code .= $lib_path . $func_name;
            return $code;
        };

        # POSIX RISC-V 64-bit Wrapper Generator
        my $make_riscv64_wrapper = sub {
            my ( $ext_str, $dlopen_rva, $dlsym_rva, $text, $macho ) = @_;
            my $lib_path         = "./libtest_prog$ext_str\0";
            my $func_name        = "my_func\0";
            my $lib_path_offset  = 96;
            my $func_name_offset = $lib_path_offset + length($lib_path);
            my $entry_stub_len   = 20;
            my $main_rva         = $text + $entry_stub_len;

            # PC-relative offsets for auipc instructions (where PC = instruction address itself)
            my $off_libpath  = $lib_path_offset - 16;               # auipc at $main_rva + 16
            my $off_funcname = $func_name_offset - 48;              # auipc at $main_rva + 48
            my $off_dlopen   = $dlopen_rva - ( $main_rva + 28 );    # auipc at $main_rva + 28
            my $off_dlsym    = $dlsym_rva - ( $main_rva + 56 );     # auipc at $main_rva + 56

            # Encode auipc + addi pair for PC-relative address load: rd = PC + imm20<<12 + imm12
            my $hi_lib   = ( $off_libpath + 0x800 ) >> 12;
            my $lo_lib   = $off_libpath & 0xFFF;
            my $auipc_a0 = ( ( $hi_lib & 0xFFFFF ) << 12 ) | ( 10 << 7 ) | 0x17;                              # auipc a0, hi(off)
            my $addi_a0  = ( ( $lo_lib & 0xFFF ) << 20 ) | ( 10 << 15 ) | ( 0 << 12 ) | ( 10 << 7 ) | 0x13;
            my $hi_fn    = ( $off_funcname + 0x800 ) >> 12;
            my $lo_fn    = $off_funcname & 0xFFF;
            my $auipc_a1 = ( ( $hi_fn & 0xFFFFF ) << 12 ) | ( 11 << 7 ) | 0x17;                               # auipc a1, hi(off)
            my $addi_a1  = ( ( $lo_fn & 0xFFF ) << 20 ) | ( 11 << 15 ) | ( 0 << 12 ) | ( 11 << 7 ) | 0x13;

            # Encode auipc + ld for GOT indirection: rd = *(PC + imm20<<12 + imm12)
            my $hi_dl    = ( $off_dlopen + 0x800 ) >> 12;
            my $lo_dl    = $off_dlopen & 0xFFF;
            my $auipc_dl = ( ( $hi_dl & 0xFFFFF ) << 12 ) | ( 5 << 7 ) | 0x17;                                # auipc t0, hi(off)
            my $ld_dl    = ( ( $lo_dl & 0xFFF ) << 20 ) | ( 5 << 15 ) | ( 3 << 12 ) | ( 5 << 7 ) | 0x03;
            my $hi_ds    = ( $off_dlsym + 0x800 ) >> 12;
            my $lo_ds    = $off_dlsym & 0xFFF;
            my $auipc_ds = ( ( $hi_ds & 0xFFFFF ) << 12 ) | ( 5 << 7 ) | 0x17;                                # auipc t0, hi(off)
            my $ld_ds    = ( ( $lo_ds & 0xFFF ) << 20 ) | ( 5 << 15 ) | ( 3 << 12 ) | ( 5 << 7 ) | 0x03;
            my $code     = pack(
                'V*', 0xFE010113,    # addi sp, sp, -32
                0x00113C23,          # sd ra, 24(sp)
                0x00813423,          # sd s0, 16(sp)
                0x00913423,          # sd s1, 8(sp)
                $auipc_a0,           # auipc a0, hi(lib_path)
                $addi_a0,            # addi a0, a0, lo(lib_path)
                0x00200593,          # addi a1, x0, 2 (RTLD_NOW)
                $auipc_dl,           # auipc t0, hi(got_dlopen)
                $ld_dl,              # ld t0, lo(got_dlopen)(t0)
                0x000280E7,          # jalr ra, t0 (call dlopen)
                0x00050413,          # mv s0, a0
                0x00040513,          # mv a0, s0
                $auipc_a1,           # auipc a1, hi(func_name)
                $addi_a1,            # addi a1, a1, lo(func_name)
                $auipc_ds,           # auipc t0, hi(got_dlsym)
                $ld_ds,              # ld t0, lo(got_dlsym)(t0)
                0x000280E7,          # jalr ra, t0 (call dlsym)
                0x000500E7,          # jalr ra, a0 (call my_func)
                0x00813483,          # ld s1, 8(sp)
                0x01013403,          # ld s0, 16(sp)
                0x01813083,          # ld ra, 24(sp)
                0x02010113,          # addi sp, sp, 32
                0x00008067,          # ret
            );
            $code .= "\x00" while length($code) < $lib_path_offset;
            $code .= $lib_path . $func_name;
            return $code;
        };
    SKIP: {
            if ($is_windows) {

                # Load the compiled PE DLL natively via the standard Win32::API module
                # On Windows ARM64, an emulated x64 Perl process cannot load native ARM64 DLLs.
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

                # Compile native POSIX binary wrapper
                my $wrapper_file = './test_wrapper';
                my $wrapper_linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new( type => 'exe' ) : Brocken::Jenny::Linker::ELF64->new( type => 'exe' );
                $wrapper_linker->set_has_ffi(1) if $platform->is_macos;

                # Pass a dummy byte array first to allow the linker to calculate
                # the exact metadata structures and final section tables.
                my $code_sz     = ( $is_arm64 || $is_riscv64 ) ? 128 : 160;
                my $dummy_bytes = "\x00" x $code_sz;
                $wrapper_linker->write_executable( $wrapper_file, $dummy_bytes, $platform );

                # Extract stabilized, correct section RVAs and text file offset
                my $got_rva    = $wrapper_linker->layout->get('.got')->{rva};
                my $dlopen_rva = $wrapper_linker->import_rva('dlopen');
                my $dlsym_rva  = $wrapper_linker->import_rva('dlsym');
                my $text_rva   = $wrapper_linker->layout->get('.text')->{rva};
                my $text_off   = $wrapper_linker->layout->get('.text')->{off};

                # Assemble the actual FFI machine code referencing the real RVAs
                my $wrapper_bytes
                    = $is_arm64 ? $make_arm64_wrapper->( $ext, $dlopen_rva, $dlsym_rva, $text_rva, $platform->is_macos ) :
                    $is_riscv64 ? $make_riscv64_wrapper->( $ext, $dlopen_rva, $dlsym_rva, $text_rva, $platform->is_macos ) :
                    $make_x64_wrapper->( $ext, $dlopen_rva, $dlsym_rva, $text_rva, $platform->is_macos, $platform->syscall('exit') );

                # Patch the binary file at its physical entry offset directly
                my $entry_stub_len = $platform->is_arm64 ? 20 : ( $platform->is_macos ? 21 : 20 );
                open my $fh, '+<:raw', $wrapper_file or die $!;
                seek( $fh, $text_off + $entry_stub_len, 0 );
                print $fh $wrapper_bytes;
                close $fh;

                # Re-apply ad-hoc code signature required strictly on macOS ARM64
                system("codesign -f -s - \"$wrapper_file\" 2>/dev/null") if $platform->is_macos;
                ok -e $wrapper_file, 'POSIX wrapper compiled at ' . $wrapper_file;
                ok -x $wrapper_file, 'POSIX wrapper has execution permissions';

                # Diagnostic: verify FFI shared library is loadable via dlopen
                if ( $platform->is_macos && $platform->is_native ) {
                    require DynaLoader;
                    require File::Spec;
                    my $abs_path = File::Spec->rel2abs($lib_file);
                    my $libref   = DynaLoader::dl_load_file($abs_path);
                    diag 'FFI lib loadable via dlopen: ' . ( $libref ? 'yes' : 'no' );
                    if ($libref) {
                        my $sym1 = DynaLoader::dl_find_symbol( $libref, 'my_func' );
                        my $sym2 = DynaLoader::dl_find_symbol( $libref, '_my_func' );
                        diag "dlsym 'my_func': " . ( $sym1 ? 'yes' : 'no' ) . "  dlsym '_my_func': " . ( $sym2 ? 'yes' : 'no' );
                        DynaLoader::dl_unload_file($libref);
                    }
                    else {
                        diag 'dl_error: ' . DynaLoader::dl_error();
                    }
                }

                # Diagnostic: dump wrapper binary structure and verify patching
                if ( $platform->is_macos ) {
                    diag 'Wrapper hex (first 64B after entry stub):';
                    open my $fh2, '<:raw', $wrapper_file or die $!;
                    seek( $fh2, $text_off + $entry_stub_len, 0 );
                    my $buf;
                    read( $fh2, $buf, 64 );
                    close $fh2;
                    diag join( ' ', map { sprintf '%02x', ord($_) } split //, $buf );
                    diag `otool -l "$wrapper_file" 2>&1 | head -200`;
                    diag `otool -tV "$wrapper_file" 2>&1 | head -40`;
                    diag `otool -L "$wrapper_file" 2>&1`;
                }
                elsif ( $platform->format eq 'elf' ) {
                    diag 'Wrapper hex (first 64B after entry stub):';
                    open my $fh2, '<:raw', $wrapper_file or die $!;
                    seek( $fh2, $text_off + $entry_stub_len, 0 );
                    my $buf;
                    read( $fh2, $buf, 64 );
                    close $fh2;
                    diag join( ' ', map { sprintf '%02x', ord($_) } split //, $buf );
                    diag `readelf -h "$wrapper_file" 2>&1 | head -20`;
                    diag `readelf -l "$wrapper_file" 2>&1 | head -40`;
                    diag `readelf -d "$wrapper_file" 2>&1 | head -20`;
                    diag `readelf -S "$wrapper_file" 2>&1 | head -20`;
                }

                # Execute POSIX native executable
                local $ENV{LD_LIBRARY_PATH}   = join( ':', '.', $ENV{LD_LIBRARY_PATH}   // () );
                local $ENV{DYLD_LIBRARY_PATH} = join( ':', '.', $ENV{DYLD_LIBRARY_PATH} // () );
                system('./test_wrapper');
                my $status    = $?;
                my $exit_code = $status >> 8;
                my $signal    = $status & 127;
                diag "raw \$?=$status exit=$exit_code signal=$signal core=" .
                    ( $status & 128 ? 1 : 0 ) .
                    ' host=' .
                    $platform->arch .
                    " e_stub_len=$entry_stub_len";
                is $signal,    0,  'Native wrapper ran cleanly without crash/segfault signals';
                is $exit_code, 42, 'Native wrapper loaded library, resolved symbol via GOT table FFI, and returned 42';
                unlink $wrapper_file;
            }
            else {
                skip 'No native FFI wrapper assembly available for ' . $platform->friendly, 2;
            }
        }
        unlink $lib_file;
    };
    subtest 'Jenny::Codegen Arithmetic (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # %v1 = 40 + 10 (50)
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 ),
            '%v1'
        );

        # %v2 = %v1 - 8 (42)
        my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 8 ), '%v2' );
        $builder->build_ret($v2);

        # Choose Codegen
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated math bytes for ' . $platform->friendly );

        # Choose Linker
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();

        # Standalone execution test if native
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'math_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -x $output_file || $platform->is_windows, 'Math binary exists' );

            # Execute and check exit code
            # system returns exit code shifted left by 8 in Perl's $?
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            if ( $platform->is_riscv64 ) {
                diag 'Math bytes: ' . unpack( 'H*', $bytes );
                open my $efh, '<:raw', $output_file or die $!;
                my $elf_data;
                read( $efh, $elf_data, 128 ) or die $!;
                close $efh;
                diag 'Math ELF header + phdrs: ' . unpack( 'H*', $elf_data );
            }
            system {$cmd} $cmd;
            my $exit_code = $? >> 8;
            is( $exit_code, 42, 'Math binary returned 42 on ' . $platform->friendly );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen ICmp result-only (RISC-V diagnostic)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
    SKIP: {
            skip 'Only for RISC-V', 2 unless $platform->is_riscv64 && $platform->is_native;
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'icmp_only', return_type => Brocken::Lindsay::IR::Type::i32() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            my $entry   = $func->append_block('entry');
            $builder->position_at_end($entry);
            my $cond = $builder->build_icmp(
                'sgt',
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
            );
            $builder->build_ret($cond);
            my $codegen = Brocken::Jenny::Codegen::RISCV64->new();
            my $bytes   = $codegen->emit_function($func);
            diag 'ICmp body (result-only): ' . unpack( 'H*', $bytes );
            diag 'ICmp body length: ' . length($bytes);
            my $linker      = Brocken::Jenny::Linker::ELF64->new();
            my $output_file = 'icmp_only_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            my $cmd = "./$output_file";
            system {$cmd} $cmd;
            my $exit_code = $? >> 8;
            diag "icmp_result_only raw \$?=$? exit=$exit_code";
            is( $exit_code, 1, 'ICmp result (42 sgt 0 = 1) returned 1' );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen JMP only (RISC-V diagnostic)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
    SKIP: {
            skip 'Only for RISC-V', 2 unless $platform->is_riscv64 && $platform->is_native;
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'jmp_only', return_type => Brocken::Lindsay::IR::Type::i32() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            my $entry   = $func->append_block('entry');
            my $t_block = $func->append_block('if.then');
            my $f_block = $func->append_block('if.else');
            $builder->position_at_end($entry);
            $builder->build_br($t_block);
            $builder->position_at_end($t_block);
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
            $builder->position_at_end($f_block);
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
            my $codegen = Brocken::Jenny::Codegen::RISCV64->new();
            my $bytes   = $codegen->emit_function($func);
            diag 'JMP body: ' . unpack( 'H*', $bytes );
            diag 'JMP body length: ' . length($bytes);
            my $linker      = Brocken::Jenny::Linker::ELF64->new();
            my $output_file = 'jmp_only_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            my $cmd = "./$output_file";
            system {$cmd} $cmd;
            my $exit_code = $? >> 8;
            diag "jmp_only raw \$?=$? exit=$exit_code";
            is( $exit_code, 42, 'JMP (unconditional branch to if.then) returned 42' );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen CondBr constant condition (RISC-V diagnostic)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
    SKIP: {
            skip 'Only for RISC-V', 2 unless $platform->is_riscv64 && $platform->is_native;
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'condbr_const', return_type => Brocken::Lindsay::IR::Type::i32() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            my $entry   = $func->append_block('entry');
            my $t_block = $func->append_block('if.then');
            my $f_block = $func->append_block('if.else');
            $builder->position_at_end($entry);
            $builder->build_cond_br( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
                $t_block, $f_block );
            $builder->position_at_end($t_block);
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
            $builder->position_at_end($f_block);
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
            my $codegen = Brocken::Jenny::Codegen::RISCV64->new();
            my $bytes   = $codegen->emit_function($func);
            diag 'CondBr constant body: ' . unpack( 'H*', $bytes );
            diag 'CondBr constant body length: ' . length($bytes);

            for my $i ( 0 .. ( length($bytes) / 4 ) - 1 ) {
                my $inst_bytes = substr( $bytes, $i * 4, 4 );
                diag sprintf( '  inst[%d] = %s', $i, unpack( 'H*', $inst_bytes ) );
            }
            my $linker      = Brocken::Jenny::Linker::ELF64->new();
            my $output_file = 'condbr_const_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            my $cmd = "./$output_file";
            system {$cmd} $cmd;
            my $exit_code = $? >> 8;
            diag "condbr_const raw \$?=$? exit=$exit_code";
            is( $exit_code, 42, 'CondBr constant condition (1 = true) returned 42' );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen ICmp (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_signed', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp(
            'sgt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated signed icmp bytes for ' . $platform->friendly );

        if ( $platform->is_arm64 ) {
            diag 'ARM64 ICmp bytes: ' . unpack( 'H*', $bytes );
            diag 'ARM64 ICmp length: ' . length($bytes);
        }
        if ( $platform->is_riscv64 ) {
            diag 'ICmp bytes: ' . unpack( 'H*', $bytes );
            diag 'ICmp length: ' . length($bytes);
            for my $i ( 0 .. ( length($bytes) / 4 ) - 1 ) {
                my $inst_bytes = substr( $bytes, $i * 4, 4 );
                diag sprintf( '  inst[%d] = %s', $i, unpack( 'H*', $inst_bytes ) );
            }
        }
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'icmp_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file || $platform->is_windows, 'ICmp binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            if ( $platform->is_riscv64 ) {
                open my $efh, '<:raw', $output_file or die $!;
                my $elf_data;
                read( $efh, $elf_data, 128 ) or die $!;
                close $efh;
                diag 'ELF header + phdrs: ' . unpack( 'H*', $elf_data );
            }
            system {$cmd} $cmd;
            my $exit_code = $? >> 8;
            diag "icmp_signed raw \$?=$? exit=$exit_code" if $? & 127 || $exit_code != 42;
            is( $exit_code, 42, 'ICmp signed (42 sgt 0 = true) returned 42 on ' . $platform->friendly );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen ICmp Unsigned (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_unsigned', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp(
            'ugt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated unsigned icmp bytes for ' . $platform->friendly );
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'icmp_unsigned_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file || $platform->is_windows, 'ICmp unsigned binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            if ( $platform->is_riscv64 ) {
                open my $efh, '<:raw', $output_file or die $!;
                my $elf_data;
                read( $efh, $elf_data, 128 ) or die $!;
                close $efh;
                diag 'Unsigned ELF header + phdrs: ' . unpack( 'H*', $elf_data );
                diag 'Unsigned ICmp bytes: ' . unpack( 'H*', $bytes );
            }
            system {$cmd} $cmd;
            my $exit_code = $? >> 8;
            diag "icmp_unsigned raw \$?=$? exit=$exit_code" if $? & 127 || $exit_code != 42;
            is( $exit_code, 42, 'ICmp unsigned (42 ugt 0 = true) returned 42 on ' . $platform->friendly );
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen ICmp (Wasm)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_wasm', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp(
            'sgt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm icmp bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'icmp_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm icmp file exists' );
        my $wasmtime_path = `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Wasm icmp (42 sgt 0 = true) returned 42';
            }
            else {
                skip 'wasmtime not available', 1;
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Codegen ICmp Unsigned (Wasm)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_unsigned_wasm', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp(
            'ugt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ), '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm unsigned icmp bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'icmp_unsigned_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm unsigned icmp file exists' );
        my $wasmtime_path = `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Wasm unsigned icmp (42 ugt 0 = true) returned 42';
            }
            else {
                skip 'wasmtime not available', 1;
            }
        }
        unlink $output_file;
    };
    subtest 'Jenny::Codegen Arithmetic (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # %v1 = 40 + 10 (50)
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 ),
            '%v1'
        );

        # %v2 = %v1 - 8 (42)
        my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 8 ), '%v2' );
        $builder->build_ret($v2);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm math bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'math_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm math file exists' );

        # Execute using wasmtime or node if available
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Math Wasm returned 42 via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js = sprintf <<~'', $output_file;
                    const fs = require('fs'); const buf = fs.readFileSync('%s');
                    WebAssembly.instantiate(buf)
                        .then(res => { process.exit(res.instance.exports.main()); })
                        .catch(e => { console.error(e); process.exit(1); });

                system( 'node', '-e', $js );
                is $? >> 8, 42, 'Math Wasm returned 42 via node';
            }
            else {
                skip 'Neither wesmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen i64 Arithmetic (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i64() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 4000000000 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1000000000 ),
            '%v1'
        );
        my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 8 ), '%v2' );
        $builder->build_ret($v2);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i64 math bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i64_math_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i64 math file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 4999999992, 'i64 math (4000000000+1000000000-8=4999999992) via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js = sprintf <<~'', $output_file;
                    const fs = require('fs'); const buf = fs.readFileSync('%s');
                    WebAssembly.instantiate(buf)
                        .then(res => {
                            const result = res.instance.exports.main();
                            const big = BigInt(result);
                            process.exit(big === 4999999992n ? 0 : 1);
                        })
                        .catch(e => { console.error(e); process.exit(1); });

                system( 'node', '-e', $js );
                is $? >> 8, 0, 'i64 math (4000000000+1000000000-8=4999999992) via node';
            }
            else {
                skip 'Neither wasmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen i64 Memory (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i64() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%ptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 5000000000 ), $ptr );
        my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $ptr, '%val' );
        $builder->build_ret($val);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm i64 memory bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'i64_mem_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm i64 memory file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 5000000000, 'i64 memory store/load 5000000000 via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js = sprintf <<~'', $output_file;
                    const fs = require('fs'); const buf = fs.readFileSync('%s');
                    WebAssembly.instantiate(buf)
                        .then(res => {
                            const result = res.instance.exports.main();
                            const big = BigInt(result);
                            process.exit(big === 5000000000n ? 0 : 1);
                        })
                        .catch(e => { console.error(e); process.exit(1); });

                system( 'node', '-e', $js );
                is $? >> 8, 0, 'i64 memory store/load 5000000000 via node';
            }
            else {
                skip 'Neither wasmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen f32 Arithmetic (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::f32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ),
            '%v1'
        );
        $builder->build_ret($v1);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm f32 math bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'f32_math_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm f32 math file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                ok( abs( $output - 31.0 ) < 0.001, "f32 math (10.5+20.5=31.0) via wasmtime (got $output)" );
            }
            else {
                skip 'wasmtime not available', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen f64 Arithmetic (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::f64() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $v1 = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 100.5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 200.25 ),
            '%v1'
        );
        $builder->build_ret($v1);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm f64 math bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'f64_math_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm f64 math file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                ok( abs( $output - 300.75 ) < 0.001, "f64 math (100.5+200.25=300.75) via wasmtime (got $output)" );
            }
            else {
                skip 'wasmtime not available', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen Float ICmp (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $c1 = $builder->build_icmp(
            'eq',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c1'
        );
        my $c2 = $builder->build_icmp(
            'ne',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 0.0 ), '%c2'
        );
        my $c3 = $builder->build_icmp(
            'lt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ), '%c3'
        );
        my $c4 = $builder->build_icmp(
            'gt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ), '%c4'
        );
        my $c5 = $builder->build_icmp(
            'le',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c5'
        );
        my $c6 = $builder->build_icmp(
            'ge',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ), '%c6'
        );
        my $all = $builder->build_and( $c1, $c2, '%a' );
        $all = $builder->build_and( $all, $c3, '%b' );
        $all = $builder->build_and( $all, $c4, '%c' );
        $all = $builder->build_and( $all, $c5, '%d' );
        $all = $builder->build_and( $all, $c6, '%e' );
        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->build_cond_br( $all, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        print STDERR "\n=== FLOAT ICMP BODY HEX ===\n" . unpack( 'H*', $res->{body} ) . "\n===\n";
        print STDERR "\n=== FLOAT ICMP LOCALS ===\n" . unpack( 'H*', $res->{locals} ) . "\n===\n";
        open my $dbg, '>>', './wasm_hex_dbg.txt' or warn "can't open debug $!";
        print $dbg "\n=== FLOAT ICMP BODY HEX ===\n" . unpack( 'H*', $res->{body} ) . "\n===\n";
        print $dbg "\n=== FLOAT ICMP LOCALS ===\n" . unpack( 'H*', $res->{locals} ) . "\n===\n";
        close $dbg;
        ok( length( $res->{body} ) > 0, 'Generated Wasm float icmp bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'ficmp_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm float icmp file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is( $output, 42, 'Float icmp Wasm returned 42 via wasmtime' );
            }
            else {
                skip 'wasmtime not available', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen Float Unary MinMax (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $neg = $builder->build_neg( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ), '%neg' );
        my $c1  = $builder->build_icmp( 'eq', $neg, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c1' );
        my $abs = $builder->build_abs( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ), '%abs' );
        my $c2  = $builder->build_icmp( 'eq', $abs, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c2' );
        my $sqrt = $builder->build_sqrt( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 1764.0 ), '%sqrt' );
        my $c3   = $builder->build_icmp( 'eq', $sqrt, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c3' );
        my $min = $builder->build_min(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 99.0 ),
            '%min'
        );
        my $c4 = $builder->build_icmp( 'eq', $min, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c4' );
        my $max = $builder->build_max(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -1.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%max'
        );
        my $c5 = $builder->build_icmp( 'eq', $max, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c5' );
        my $all = $builder->build_and( $c1, $c2, '%a' );
        $all = $builder->build_and( $all, $c3, '%b' );
        $all = $builder->build_and( $all, $c4, '%c' );
        $all = $builder->build_and( $all, $c5, '%d' );
        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->build_cond_br( $all, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm float unary/minmax bytes' );
        open my $dbg2, '>>', './wasm_hex_dbg.txt' or warn "can't open debug $!";
        print $dbg2 "\n=== FLOAT UNARY BODY HEX ===\n" . unpack( 'H*', $res->{body} ) . "\n===\n";
        print $dbg2 "\n=== FLOAT UNARY LOCALS ===\n" . unpack( 'H*', $res->{locals} ) . "\n===\n";
        close $dbg2;
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'fum_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm float unary/minmax file exists' );
        my $wasmtime_path = $host->is_windows ? `which wasmtime` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            if ( $wasmtime_path && -x $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is( $output, 42, 'Float unary/minmax Wasm returned 42 via wasmtime' );
            }
            else {
                skip 'wasmtime not available', 1;
            }
        }
        if ( -e $output_file ) {
            open my $fh2, '<:raw', $output_file or die $!;
            my $data;
            read( $fh2, $data, 999999 );
            close $fh2;
            print STDERR "\n=== FULL WASM HEX ===\n" . unpack( 'H*', $data ) . "\n===\n";
        }

        # unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen Memory Operations (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%ptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ), $ptr );
        my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%val' );
        $builder->build_ret($val);
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated memory op bytes for ' . $platform->friendly );
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'mem_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -x $output_file || $platform->is_windows, 'Memory binary exists' );
            run_exec( $output_file, expected_exit => 42, platform => $platform, name => 'Memory binary returned 42 on  on ' . $platform->friendly );
        }
    };
    subtest 'Jenny::Codegen Box/Unbox (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $boxed = $builder->build_box( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ), '%boxed' );
        my $val   = $builder->build_unbox( $boxed, Brocken::Lindsay::IR::Type::i32(), '%val' );
        $builder->build_ret($val);
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated box/unbox bytes for ' . $platform->friendly );
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'box_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -x $output_file || $platform->is_windows, 'Box/unbox binary exists' );
            run_exec(
                $output_file,
                expected_exit => 42,
                platform      => $platform,
                name          => 'Box/unbox binary returned 42 on  on ' . $platform->friendly
            );
        }
    };
    subtest 'Jenny::Codegen Float Arithmetic (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ), $fptr );
        my $fv = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr, '%fv' );
        my $fres
            = $builder->build_add( $fv, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ), '%fres' );
        $builder->build_store( $fres, $fptr );
        my $ret = $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
            '%ret'
        );
        $builder->build_ret($ret);
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated float math bytes for ' . $platform->friendly );
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'float_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file, 'Float math binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            my $ret = system {$cmd} $cmd;
        SKIP: {
                skip "system() failed to spawn ($!)", 1 if $ret == -1;
                my $exit_code = $? >> 8;
                is( $exit_code, 42, 'Float math binary returned 42 on ' . $platform->friendly );
            }
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Float ICmp (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'icmp_float', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        my $entry    = $func->append_block('entry');
        my $t_block  = $func->append_block('if.then');
        my $f_block  = $func->append_block('if.else');
        $builder->position_at_end($entry);
        my $cond = $builder->build_icmp(
            'lt',
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ), '%cmp'
        );
        $builder->build_cond_br( $cond, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated float icmp bytes for ' . $platform->friendly );

        if ( $platform->is_arm64 ) {
            diag 'ARM64 Float ICmp bytes: ' . unpack( 'H*', $bytes );
            diag 'ARM64 Float ICmp length: ' . length($bytes);
        }
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'ficmp_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file, 'Float icmp binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            if ( $platform->is_riscv64 ) {
                open my $efh, '<:raw', $output_file or die $!;
                my $elf_data;
                read( $efh, $elf_data, 128 ) or die $!;
                close $efh;
                diag 'Float ICmp ELF header + phdrs: ' . unpack( 'H*', $elf_data );
                diag 'Float ICmp bytes: ' . unpack( 'H*', $bytes );
            }
            my $ret = system {$cmd} $cmd;
        SKIP: {
                skip "system() failed to spawn ($!)", 1 if $ret == -1;
                my $exit_code = $? >> 8;
                diag "ficmp raw \$?=$? exit=$exit_code" if $? & 127 || $exit_code != 42;
                is( $exit_code, 42, 'Float icmp returned 42 on ' . $platform->friendly );
            }
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Float Arithmetic Battery (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # f32 sub: 42.0 - 0.0 = 42.0, stored/loaded
        my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), $fptr );
        my $fv = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr, '%fv' );
        $builder->build_sub( $fv, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 0.0 ), '%fres' );

        # f32 mul: 21.0 * 2.0 = 42.0
        my $fptr2 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr2' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 21.0 ), $fptr2 );
        my $fv2 = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr2, '%fv2' );
        $builder->build_mul( $fv2, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 2.0 ), '%fres2' );

        # f32 div: 84.0 / 2.0 = 42.0
        my $fptr3 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr3' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 84.0 ), $fptr3 );
        my $fv3 = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr3, '%fv3' );
        $builder->build_div( $fv3, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 2.0 ), '%fres3' );

        # f64 add: 21.25 + 20.75 = 42.0
        my $fptr4 = $builder->build_alloca( Brocken::Lindsay::IR::Type::f64(), '%fptr4' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 21.25 ), $fptr4 );
        my $fv4 = $builder->build_load( Brocken::Lindsay::IR::Type::f64(), $fptr4, '%fv4' );
        $builder->build_add( $fv4, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => 20.75 ), '%fres4' );
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated float battery bytes for ' . $platform->friendly );

        if ( $platform->is_arm64 ) {
            diag 'ARM64 Float Battery bytes: ' . unpack( 'H*', $bytes );
            diag 'ARM64 Float Battery length: ' . length($bytes);
        }
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'fbat_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file, 'Float battery binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            my $ret = system {$cmd} $cmd;
        SKIP: {
                skip "system() failed to spawn ($!)", 1 if $ret == -1;
                my $exit_code = $? >> 8;
                is( $exit_code, 42, 'Float battery returned 42 on ' . $platform->friendly );
            }
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Float Unary MinMax (Cross-Platform)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );

        # f32 neg: neg(-42.0) == 42.0
        my $neg = $builder->build_neg( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ), '%neg' );
        my $c1  = $builder->build_icmp( 'eq', $neg, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c1' );

        # f32 abs: abs(-42.0) == 42.0
        my $abs = $builder->build_abs( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ), '%abs' );
        my $c2  = $builder->build_icmp( 'eq', $abs, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c2' );

        # f32 sqrt: sqrt(1764.0) == 42.0
        my $sqrt = $builder->build_sqrt( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 1764.0 ), '%sqrt' );
        my $c3   = $builder->build_icmp( 'eq', $sqrt, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c3' );

        # f32 min: min(42.0, 99.0) == 42.0
        my $min = $builder->build_min(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 99.0 ),
            '%min'
        );
        my $c4 = $builder->build_icmp( 'eq', $min, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c4' );

        # f32 max: max(-1.0, 42.0) == 42.0
        my $max = $builder->build_max(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -1.0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%max'
        );
        my $c5 = $builder->build_icmp( 'eq', $max, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
            '%c5' );

        # Combine all conditions with AND
        my $all = $builder->build_and( $c1, $c2, '%a' );
        $all = $builder->build_and( $all, $c3, '%b' );
        $all = $builder->build_and( $all, $c4, '%c' );
        $all = $builder->build_and( $all, $c5, '%d' );
        my $t_block = $func->append_block('if.then');
        my $f_block = $func->append_block('if.else');
        $builder->build_cond_br( $all, $t_block, $f_block );
        $builder->position_at_end($t_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
        $builder->position_at_end($f_block);
        $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
        my $codegen
            = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
            $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
            Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
        my $bytes = $codegen->emit_function($func);
        ok( length($bytes) > 0, 'Generated float unary/minmax bytes for ' . $platform->friendly );

        if ( $platform->is_arm64 ) {
            diag 'ARM64 Float Unary bytes: ' . unpack( 'H*', $bytes );
            diag 'ARM64 Float Unary length: ' . length($bytes);
        }
        my $linker
            = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
            $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
            Brocken::Jenny::Linker::ELF64->new();
    SKIP: {
            skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
            my $output_file = 'fum_test' . $platform->bin_ext;
            $linker->write_executable( $output_file, $bytes, $platform );
            ok( -e $output_file, 'Float unary/minmax binary exists' );
            my $cmd = $platform->is_windows ? $output_file : "./$output_file";
            if ( $platform->is_riscv64 ) {
                open my $efh, '<:raw', $output_file or die $!;
                my $elf_data;
                read( $efh, $elf_data, 128 ) or die $!;
                close $efh;
                diag 'Float Unary ELF header + phdrs: ' . unpack( 'H*', $elf_data );
                diag 'Float Unary bytes: ' . unpack( 'H*', $bytes );
            }
            my $ret = system {$cmd} $cmd;
        SKIP: {
                skip "system() failed to spawn ($!)", 1 if $ret == -1;
                my $exit_code = $? >> 8;
                diag "fum raw \$?=$? exit=$exit_code" if $? & 127 || $exit_code != 42;
                is( $exit_code, 42, 'Float unary/minmax returned 42 on ' . $platform->friendly );
            }
            unlink $output_file;
        }
    };
    subtest 'Jenny::Codegen Memory Operations (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%ptr' );
        $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ), $ptr );
        my $val = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%val' );
        $builder->build_ret($val);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm memory bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'mem_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm memory file exists' );
        my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -f $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Memory Wasm returned 42 via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js
                    = 'const fs=require("fs");const buf=fs.readFileSync("' .
                    $output_file . '");' .
                    'WebAssembly.instantiate(buf)' .
                    '.then(res=>{process.exit(res.instance.exports.main());})' .
                    '.catch(e=>{console.error(e);process.exit(1);});';
                system( 'node', '-e', $js );
                is $? >> 8, 42, 'Memory Wasm returned 42 via node';
            }
            else {
                skip 'Neither wasmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen Box/Unbox (Wasm)' => sub {
        my $host     = Brocken::Katsuro::Platform::parse();
        my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
        my $builder  = Brocken::Lindsay::IR::Builder->new();
        $builder->position_at_end( $func->append_block('entry') );
        my $boxed = $builder->build_box( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ), '%boxed' );
        my $val   = $builder->build_unbox( $boxed, Brocken::Lindsay::IR::Type::i32(), '%val' );
        $builder->build_ret($val);
        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $res     = $codegen->emit_function($func);
        ok( length( $res->{body} ) > 0, 'Generated Wasm box/unbox bytes' );
        my $linker      = Brocken::Jenny::Linker::Wasm->new();
        my $output_file = 'box_test.wasm';
        $linker->write_executable( $output_file, $res, $platform );
        ok( -e $output_file, 'Wasm box/unbox file exists' );
        my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
        my $node_path = `which node 2>/dev/null`;
        chomp $node_path if $node_path;
    SKIP: {
            if ( $wasmtime_path && -f $wasmtime_path ) {
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                is $output, 42, 'Box/unbox Wasm returned 42 via wasmtime';
            }
            elsif ( $node_path && -x $node_path ) {
                my $js
                    = 'const fs=require("fs");const buf=fs.readFileSync("' .
                    $output_file . '");' .
                    'WebAssembly.instantiate(buf)' .
                    '.then(res=>{process.exit(res.instance.exports.main());})' .
                    '.catch(e=>{console.error(e);process.exit(1);});';
                system( 'node', '-e', $js );
                is $? >> 8, 42, 'Box/unbox Wasm returned 42 via node';
            }
            else {
                skip 'Neither wasmtime nor node are installed', 1;
            }
        }
        unlink $output_file if -e $output_file;
    };
    subtest 'Jenny::Codegen GEP Lowering' => sub {
        my $host = Brocken::Katsuro::Platform::parse();
        {
            # x86_64 GEP: constant index -> lea with disp
            my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
            my $func     = Brocken::Lindsay::IR::Function->new( name => 'gep_const', return_type => Brocken::Lindsay::IR::Type::ptr() );
            my $builder  = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
            my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(),
                $ptr, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) ], '%elem' );
            $builder->build_ret($gep);
            my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
            my $mf      = $lowerer->lower($func);
            my $ops     = $mf->blocks->[0]->instructions;
            my ($lea)   = grep { $_->opcode eq 'lea' } $ops->@*;
            ok( defined $lea, 'x86_64 const GEP: lea produced' );

            if ($lea) {
                my $mem = $lea->operands->[1];
                is( $mem->kind,          'mem',  'x86_64 const GEP: second operand is mem' );
                is( $mem->value->{base}, '%arr', 'x86_64 const GEP: base = %arr' );
                is( $mem->value->{disp}, 168,    'x86_64 const GEP: disp = 42*4' );
                ok( !defined $mem->value->{index}, 'x86_64 const GEP: no index for const' );
            }
        }
        {
            # x86_64 GEP: variable index -> lea with index+scale
            my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
            my $func     = Brocken::Lindsay::IR::Function->new( name => 'gep_var', return_type => Brocken::Lindsay::IR::Type::ptr() );
            my $builder  = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
            my $idx = $builder->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
                '%idx'
            );
            my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $ptr, [$idx], '%elem' );
            $builder->build_ret($gep);
            my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
            my $mf      = $lowerer->lower($func);
            my $ops     = $mf->blocks->[0]->instructions;
            my ($lea)   = grep { $_->opcode eq 'lea' } $ops->@*;
            ok( defined $lea, 'x86_64 var GEP: lea produced' );

            if ($lea) {
                my $mem = $lea->operands->[1];
                is( $mem->kind,           'mem',  'x86_64 var GEP: second operand is mem' );
                is( $mem->value->{base},  '%arr', 'x86_64 var GEP: base = %arr' );
                is( $mem->value->{index}, '%idx', 'x86_64 var GEP: index = %idx' );
                is( $mem->value->{scale}, 4,      'x86_64 var GEP: scale = 4 (i32)' );
                is( $mem->value->{disp},  0,      'x86_64 var GEP: disp = 0' );
            }
        }
        {
            # ARM64 GEP: constant index -> mv ptr; add offset
            my $platform = Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu');
            my $func     = Brocken::Lindsay::IR::Function->new( name => 'gep_const', return_type => Brocken::Lindsay::IR::Type::ptr() );
            my $builder  = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
            my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(),
                $ptr, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) ], '%elem' );
            $builder->build_ret($gep);
            my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
            my $mf      = $lowerer->lower($func);
            my $ops     = $mf->blocks->[0]->instructions;
            my @adds    = grep { $_->opcode eq 'add' } $ops->@*;
            ok( scalar @adds >= 1, 'ARM64 const GEP: add produced' );

            if (@adds) {
                my $gep_add = ( grep { $_->operands->[1]->kind eq 'imm' } @adds )[0];
                ok( defined $gep_add, 'ARM64 const GEP: add with imm' );
                if ($gep_add) {
                    is( $gep_add->operands->[1]->value, 168, 'ARM64 const GEP: offset = 42*4' );
                }
            }
        }
        {
            # ARM64 GEP: variable index -> mv ptr; add index
            my $platform = Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu');
            my $func     = Brocken::Lindsay::IR::Function->new( name => 'gep_var', return_type => Brocken::Lindsay::IR::Type::ptr() );
            my $builder  = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
            my $idx = $builder->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
                '%idx'
            );
            my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $ptr, [$idx], '%elem' );
            $builder->build_ret($gep);
            my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
            my $mf      = $lowerer->lower($func);
            my $ops     = $mf->blocks->[0]->instructions;
            my @adds    = grep { $_->opcode eq 'add' } $ops->@*;
            ok( scalar @adds >= 1, 'ARM64 var GEP: add produced' );

            if (@adds) {
                my $gep_add = ( grep { $_->operands->[1]->kind eq 'virt_reg' } @adds )[0];
                ok( defined $gep_add, 'ARM64 var GEP: add with vreg operand' );
                if ($gep_add) {
                    is( $gep_add->operands->[1]->value, '%idx', 'ARM64 var GEP: index = %idx' );
                }
            }
        }
        {
            # RISCV64 GEP: constant index -> mv ptr; add offset
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'gep_const', return_type => Brocken::Lindsay::IR::Type::ptr() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
            my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(),
                $ptr, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) ], '%elem' );
            $builder->build_ret($gep);
            my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
            my $mf      = $lowerer->lower($func);
            my $ops     = $mf->blocks->[0]->instructions;
            my @mvs     = grep { $_->opcode eq 'mv' } $ops->@*;
            my @adds    = grep { $_->opcode eq 'add' } $ops->@*;
            ok( scalar @mvs >= 1,  'RISCV64 const GEP: mv produced' );
            ok( scalar @adds >= 1, 'RISCV64 const GEP: add produced' );

            if (@adds) {
                my $add_imm = $adds[0]->operands->[1];
                is( $add_imm->kind,  'imm', 'RISCV64 const GEP: add with imm' );
                is( $add_imm->value, 168,   'RISCV64 const GEP: offset = 42*4' );
            }
        }
        {
            # RISCV64 GEP: variable index -> mv idx; (shl); add ptr
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'gep_var', return_type => Brocken::Lindsay::IR::Type::ptr() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
            my $idx = $builder->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
                '%idx'
            );
            my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $ptr, [$idx], '%elem' );
            $builder->build_ret($gep);
            my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
            my $mf      = $lowerer->lower($func);
            my $ops     = $mf->blocks->[0]->instructions;
            my @adds    = grep { $_->opcode eq 'add' } $ops->@*;
            ok( scalar @adds >= 1, 'RISCV64 var GEP: add produced' );

            if (@adds) {
                my $gep_add = ( grep { $_->operands->[1]->kind eq 'virt_reg' } @adds )[0];
                ok( defined $gep_add, 'RISCV64 var GEP: add with vreg' );
                if ($gep_add) {
                    is( $gep_add->operands->[1]->value, '%arr', 'RISCV64 var GEP: add base = %arr' );
                }
            }
        }
        {
            # Wasm GEP: constant index -> push ptr, push offset, i32_add, local_set
            my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
            my $func     = Brocken::Lindsay::IR::Function->new( name => 'gep_const', return_type => Brocken::Lindsay::IR::Type::ptr() );
            my $builder  = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
            my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(),
                $ptr, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) ], '%elem' );
            $builder->build_ret($gep);
            my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
            my $mf      = $lowerer->lower($func);
            my $ops     = $mf->blocks->[0]->instructions;
            my @consts  = grep { $_->opcode eq 'i32_const' } $ops->@*;
            my @adds    = grep { $_->opcode eq 'i32_add' } $ops->@*;
            my @sets    = grep { $_->opcode eq 'local_set' } $ops->@*;
            ok( scalar @consts >= 1, 'Wasm const GEP: i32_const produced' );
            ok( scalar @adds >= 1,   'Wasm const GEP: i32_add produced' );
            ok( scalar @sets >= 1,   'Wasm const GEP: local_set produced' );

            if (@consts) {
                is( $consts[-1]->operands->[0]->value, 168, 'Wasm const GEP: offset = 42*4' );
            }
        }
        {
            # Wasm GEP: variable index -> push ptr, push idx, (push scale, i32_mul), i32_add, local_set
            my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
            my $func     = Brocken::Lindsay::IR::Function->new( name => 'gep_var', return_type => Brocken::Lindsay::IR::Type::ptr() );
            my $builder  = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%arr' );
            my $idx = $builder->build_add(
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ),
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
                '%idx'
            );
            my $gep = $builder->build_gep( Brocken::Lindsay::IR::Type::i32(), $ptr, [$idx], '%elem' );
            $builder->build_ret($gep);
            my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
            my $mf      = $lowerer->lower($func);
            my $ops     = $mf->blocks->[0]->instructions;
            my @consts  = grep { $_->opcode eq 'i32_const' } $ops->@*;
            my @muls    = grep { $_->opcode eq 'i32_mul' } $ops->@*;
            my @adds    = grep { $_->opcode eq 'i32_add' } $ops->@*;
            my @sets    = grep { $_->opcode eq 'local_set' } $ops->@*;
            ok( scalar @consts >= 1, 'Wasm var GEP: i32_const produced (scale)' );
            ok( scalar @muls >= 1,   'Wasm var GEP: i32_mul produced (scale=4)' );
            ok( scalar @adds >= 1,   'Wasm var GEP: i32_add produced' );
            ok( scalar @sets >= 1,   'Wasm var GEP: local_set produced' );
        }
    };
    subtest 'RegAlloc::LinearScan basic allocation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        my $mf       = Brocken::Jenny::MIR::MachineFunction->new(
            name   => 'test',
            blocks => [
                Brocken::Jenny::MIR::MachineBasicBlock->new(
                    name         => 'entry',
                    instructions => [
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%0' ),
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm',      value => 1 ),
                            ]
                        ),
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%1' ),
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm',      value => 2 ),
                            ]
                        ),
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ),
                    ]
                ),
            ]
        );
        my $alloc  = Brocken::Jenny::RegAlloc::LinearScan->new();
        my $result = $alloc->allocate( $mf, $platform );
        ok defined $result->{assignment},      'assignment map returned';
        ok exists $result->{assignment}{'%0'}, '%0 allocated';
        ok exists $result->{assignment}{'%1'}, '%1 allocated';
        is scalar( $result->{used_callee}->@* ),      0, 'no callee regs used with 2 vregs on x86_64';
        is scalar( keys $result->{spill_slots}->%* ), 0, 'no spills needed';
        ok defined $result->{spill_temp}, 'spill temp defined';
    };
    subtest 'RegAlloc::LinearScan callee-saved allocation' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        my $alloc    = Brocken::Jenny::RegAlloc::LinearScan->new();
        my @intervals;
        for my $i ( 0 .. 10 ) {
            push @intervals, Brocken::Jenny::RegAlloc::LiveInterval->new( name => "%$i", start => 0, end => 10 );
        }
        my $result = $alloc->_linear_scan( \@intervals, $platform, 0 );
        ok( scalar( $result->{used_callee}->@* ) > 0 ), 'callee registers used when 11 overlapping vregs on x86_64';
    };
    subtest 'RegAlloc::LinearScan spilling' => sub {
        my $platform = Brocken::Katsuro::Platform::parse('x86_64-pc-linux-gnu');
        my $alloc    = Brocken::Jenny::RegAlloc::LinearScan->new();
        my @intervals;
        for my $i ( 0 .. 19 ) {
            push @intervals, Brocken::Jenny::RegAlloc::LiveInterval->new( name => "%$i", start => 0, end => 10 );
        }
        my $result = $alloc->_linear_scan( \@intervals, $platform, 0 );
        ok( scalar( keys $result->{spill_slots}->%* ) > 0 ), 'spill slots created with 20 overlapping vregs';
    };
    subtest 'RegAlloc::LinearScan insert_spill_code' => sub {
        my $mf = Brocken::Jenny::MIR::MachineFunction->new(
            name   => 'test',
            blocks => [
                Brocken::Jenny::MIR::MachineBasicBlock->new(
                    name         => 'entry',
                    instructions => [
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%v0' ),
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'imm',      value => 1 ),
                            ]
                        ),
                        Brocken::Jenny::MIR::MachineInstruction->new(
                            opcode   => 'mov',
                            operands => [
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%v1' ),
                                Brocken::Jenny::MIR::MachineOperand->new( kind => 'virt_reg', value => '%v0' ),
                            ]
                        ),
                        Brocken::Jenny::MIR::MachineInstruction->new( opcode => 'ret', operands => [] ),
                    ]
                ),
            ]
        );
        my $spill_slots = { '%v0' => 0, '%v1' => 8 };
        my $alloc       = Brocken::Jenny::RegAlloc::LinearScan->new();
        $alloc->insert_spill_code( $mf, $spill_slots, 'r9', 'rsp' );
        my @all_ops;
        for my $bb ( $mf->blocks->@* ) {
            for my $inst ( $bb->instructions->@* ) {
                push @all_ops, $inst->opcode;
            }
        }
        ok grep( /^load$/,  @all_ops ), 'spill-reload loads inserted';
        ok grep( /^store$/, @all_ops ), 'spill-store stores inserted';
    };
    subtest 'Jenny::Codegen i128 Lowering' => sub {
        my $check = sub {
            my ( $lowerer_class, $ir_name, $ir_body, %checks ) = @_;
            my $func    = Brocken::Lindsay::IR::Function->new( name => $ir_name, return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            $ir_body->($builder);
            my $lowerer = $lowerer_class->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;

            for my ( $opcode, $label )(%checks) {
                ok( grep( { $_->opcode eq $opcode } @insts ), $label );
            }
        };
        my $X = 'Brocken::Jenny::Lowerer::X86_64';
        my $A = 'Brocken::Jenny::Lowerer::ARM64';
        my $R = 'Brocken::Jenny::Lowerer::RISCV64';
        my $W = 'Brocken::Jenny::Lowerer::Wasm';
        $check->(
            $X,
            'i128_add',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        '%r'
                    )
                );
            },
            adc => 'x86_64 i128 add: adc produced',
            add => 'x86_64 i128 add: add for lo'
        );
        $check->(
            $X,
            'i128_sub',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_sub(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        '%r'
                    )
                );
            },
            sbb => 'x86_64 i128 sub: sbb produced'
        );
        $check->(
            $X,
            'i128_and',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_and(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xFFFFFFFFFFFFFFFF ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        '%r'
                    )
                );
            },
            and => 'x86_64 i128 and: and produced'
        );
        $check->(
            $X,
            'i128_or',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_or(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xFFFFFFFFFFFFFFFF ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        '%r'
                    )
                );
            },
            or => 'x86_64 i128 or: or produced'
        );
        $check->(
            $X,
            'i128_xor',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_xor(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xFFFFFFFFFFFFFFFF ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        '%r'
                    )
                );
            },
            xor => 'x86_64 i128 xor: xor produced'
        );
        $check->(
            $A,
            'i128_add',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        '%r'
                    )
                );
            },
            sltu => 'ARM64 i128 add: sltu carry produced'
        );
        $check->(
            $A,
            'i128_sub',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_sub(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        '%r'
                    )
                );
            },
            sltu => 'ARM64 i128 sub: sltu borrow produced'
        );
        $check->(
            $R,
            'i128_add',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        '%r'
                    )
                );
            },
            sltu => 'RISCV64 i128 add: sltu carry produced'
        );
        $check->(
            $R,
            'i128_sub',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_sub(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        '%r'
                    )
                );
            },
            sltu => 'RISCV64 i128 sub: sltu borrow produced'
        );
        $check->(
            $W,
            'i128_add',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        '%r'
                    )
                );
            },
            i64_gt_u => 'Wasm i128 add: i64_gt_u carry produced'
        );
        $check->(
            $W,
            'i128_sub',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_sub(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        '%r'
                    )
                );
            },
            i64_lt_u => 'Wasm i128 sub: i64_lt_u borrow produced'
        );
        $check->(
            $W,
            'i128_and',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_and(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xFFFFFFFFFFFFFFFF ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        '%r'
                    )
                );
            },
            i64_and => 'Wasm i128 and: i64_and produced'
        );

        # x86_64 i128 store/load: two stores (lo+hi) and two loads (lo+hi) with offset
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_load_store', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
            my $val = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xDEADBEEFCAFEBABE );
            $builder->build_store( $val, $ptr );
            my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i128(), $ptr, '%loaded' );
            $builder->build_ret($loaded);
            my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @stores  = grep { $_->opcode =~ /^store/ && $_->comment =~ /i128/ } @insts;
            ok( scalar @stores == 2, 'x86_64 i128 store: two stores (lo+hi)' );
            my @loads = grep { $_->opcode eq 'load' && $_->comment =~ /i128/ } @insts;
            ok( scalar @loads == 2, 'x86_64 i128 load: two loads (lo+hi)' );
        }

        # x86_64 i128 ret: mov to rax and rdx
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_ret', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
            my $lowerer = Brocken::Jenny::Lowerer::X86_64->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @rax     = grep { $_->opcode eq 'mov' && $_->comment =~ /rax/ } @insts;
            ok( scalar @rax == 1, 'x86_64 i128 ret: mov to rax' );
            my @rdx = grep { $_->opcode eq 'mov' && $_->comment =~ /rdx/ } @insts;
            ok( scalar @rdx == 1, 'x86_64 i128 ret: mov to rdx' );
        }

        # ARM64 i128 store/load: two stores (lo+hi) and two loads (lo+hi) with offset
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_load_store', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
            my $val = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xDEADBEEFCAFEBABE );
            $builder->build_store( $val, $ptr );
            my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i128(), $ptr, '%loaded' );
            $builder->build_ret($loaded);
            my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @stores  = grep { $_->opcode =~ /^store/ && $_->comment =~ /i128/ } @insts;
            ok( scalar @stores == 2, 'ARM64 i128 store: two stores (lo+hi)' );
            my @loads = grep { $_->opcode eq 'load' && $_->comment =~ /i128/ } @insts;
            ok( scalar @loads == 2, 'ARM64 i128 load: two loads (lo+hi)' );
        }

        # ARM64 i128 ret: mov to x0 and x1
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_ret', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
            my $lowerer = Brocken::Jenny::Lowerer::ARM64->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @x0      = grep { $_->opcode eq 'mov' && $_->comment =~ /x0/ } @insts;
            ok( scalar @x0 == 1, 'ARM64 i128 ret: mov to x0' );
            my @x1 = grep { $_->opcode eq 'mov' && $_->comment =~ /x1/ } @insts;
            ok( scalar @x1 == 1, 'ARM64 i128 ret: mov to x1' );
        }

        # RISCV64 i128 store/load: two stores (lo+hi) and two loads (lo+hi) with offset
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_load_store', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
            my $val = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0xDEADBEEFCAFEBABE );
            $builder->build_store( $val, $ptr );
            my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i128(), $ptr, '%loaded' );
            $builder->build_ret($loaded);
            my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @stores  = grep { $_->opcode =~ /^store/ && $_->comment =~ /i128 store/ } @insts;
            ok( scalar @stores == 2, 'RISCV64 i128 store: two stores (lo+hi)' );
            my @loads = grep { $_->opcode eq 'load' && $_->comment =~ /i128 load/ } @insts;
            ok( scalar @loads == 2, 'RISCV64 i128 load: two loads (lo+hi)' );
        }

        # RISCV64 i128 ret: mv to a0 and a1
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_ret', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
            my $lowerer = Brocken::Jenny::Lowerer::RISCV64->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @a0      = grep { $_->comment =~ /i128 lo/ } @insts;
            ok( scalar @a0 == 1, 'RISCV64 i128 ret: mv to a0' );
            my @a1 = grep { $_->comment =~ /i128 hi/ } @insts;
            ok( scalar @a1 == 1, 'RISCV64 i128 ret: mv to a1' );
        }

        # Wasm i128 store: two i64_store (lo+hi) with ptr arithmetic
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_store', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
            $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ), $ptr );
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ) );
            my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @stores  = grep { $_->opcode eq 'i64_store' && $_->comment =~ /store lo/ } @insts;
            ok( scalar @stores == 1, 'Wasm i128 store: i64_store lo' );
            my @stores_hi = grep { $_->opcode eq 'i64_store' && $_->comment =~ /store hi/ } @insts;
            ok( scalar @stores_hi == 1, 'Wasm i128 store: i64_store hi' );
        }

        # Wasm i128 load: two i64_load (lo+hi) with ptr arithmetic
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_load', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i128(), '%ptr' );
            $builder->build_ret( $builder->build_load( Brocken::Lindsay::IR::Type::i128(), $ptr, '%loaded' ) );
            my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @loads   = grep { $_->opcode eq 'i64_load' && $_->comment =~ /load lo/ } @insts;
            ok( scalar @loads == 1, 'Wasm i128 load: i64_load lo' );
            my @loads_hi = grep { $_->opcode eq 'i64_load' && $_->comment =~ /load hi/ } @insts;
            ok( scalar @loads_hi == 1, 'Wasm i128 load: i64_load hi' );
        }

        # Wasm i128 ret: push retval lo and retval hi
        {
            my $func    = Brocken::Lindsay::IR::Function->new( name => 'i128_ret', return_type => Brocken::Lindsay::IR::Type::i128() );
            my $builder = Brocken::Lindsay::IR::Builder->new();
            $builder->position_at_end( $func->append_block('entry') );
            $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
            my $lowerer = Brocken::Jenny::Lowerer::Wasm->new();
            my $mf      = $lowerer->lower($func);
            my @insts   = $mf->blocks->[0]->instructions->@*;
            my @ret_lo  = grep { $_->comment =~ /retval lo/ } @insts;
            ok( scalar @ret_lo == 1, 'Wasm i128 ret: push retval lo' );
            my @ret_hi = grep { $_->comment =~ /retval hi/ } @insts;
            ok( scalar @ret_hi == 1, 'Wasm i128 ret: push retval hi' );
        }

        # x86_64 i128 shl lowering (constant amt=1)
        $check->(
            $X,
            'i128_shl_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_shl(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            shl  => 'x86_64 i128 shl/1: shl produced',
            lshr => 'x86_64 i128 shl/1: lshr carry produced',
            or   => 'x86_64 i128 shl/1: or carry merge'
        );

        # x86_64 i128 lshr lowering (constant amt=1)
        $check->(
            $X,
            'i128_lshr_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_lshr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            lshr => 'x86_64 i128 lshr/1: lshr produced',
            shl  => 'x86_64 i128 lshr/1: shl carry produced',
            or   => 'x86_64 i128 lshr/1: or carry merge'
        );

        # x86_64 i128 ashr lowering (constant amt=1)
        $check->(
            $X,
            'i128_ashr_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_ashr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            ashr => 'x86_64 i128 ashr/1: ashr produced',
            shl  => 'x86_64 i128 ashr/1: shl carry produced',
            or   => 'x86_64 i128 ashr/1: or carry merge'
        );

        # ARM64 i128 shl lowering (constant amt=1)
        $check->(
            $A,
            'i128_shl_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_shl(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            shl  => 'ARM64 i128 shl/1: shl produced',
            lshr => 'ARM64 i128 shl/1: lshr carry produced',
            or   => 'ARM64 i128 shl/1: or carry merge'
        );

        # ARM64 i128 lshr lowering (constant amt=1)
        $check->(
            $A,
            'i128_lshr_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_lshr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            lshr => 'ARM64 i128 lshr/1: lshr produced',
            shl  => 'ARM64 i128 lshr/1: shl carry produced',
            or   => 'ARM64 i128 lshr/1: or carry merge'
        );

        # ARM64 i128 ashr lowering (constant amt=1)
        $check->(
            $A,
            'i128_ashr_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_ashr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            ashr => 'ARM64 i128 ashr/1: ashr produced',
            shl  => 'ARM64 i128 ashr/1: shl carry produced',
            or   => 'ARM64 i128 ashr/1: or carry merge'
        );

        # RISCV64 i128 shl lowering (constant amt=1)
        $check->(
            $R,
            'i128_shl_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_shl(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            shl  => 'RISCV64 i128 shl/1: shl produced',
            lshr => 'RISCV64 i128 shl/1: lshr carry produced',
            or   => 'RISCV64 i128 shl/1: or carry merge'
        );

        # RISCV64 i128 lshr lowering (constant amt=1)
        $check->(
            $R,
            'i128_lshr_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_lshr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            lshr => 'RISCV64 i128 lshr/1: lshr produced',
            shl  => 'RISCV64 i128 lshr/1: shl carry produced',
            or   => 'RISCV64 i128 lshr/1: or carry merge'
        );

        # RISCV64 i128 ashr lowering (constant amt=1)
        $check->(
            $R,
            'i128_ashr_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_ashr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            ashr => 'RISCV64 i128 ashr/1: ashr produced',
            shl  => 'RISCV64 i128 ashr/1: shl carry produced',
            or   => 'RISCV64 i128 ashr/1: or carry merge'
        );

        # Wasm i128 shl lowering (constant amt=1)
        $check->(
            $W,
            'i128_shl_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_shl(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            i64_shl   => 'Wasm i128 shl/1: i64_shl produced',
            i64_shr_u => 'Wasm i128 shl/1: i64_shr_u carry produced',
            i64_or    => 'Wasm i128 shl/1: i64_or carry merge'
        );

        # Wasm i128 lshr lowering (constant amt=1)
        $check->(
            $W,
            'i128_lshr_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_lshr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            i64_shr_u => 'Wasm i128 lshr/1: i64_shr_u produced',
            i64_shl   => 'Wasm i128 lshr/1: i64_shl carry produced',
            i64_or    => 'Wasm i128 lshr/1: i64_or carry merge'
        );

        # Wasm i128 ashr lowering (constant amt=1)
        $check->(
            $W,
            'i128_ashr_1',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_ashr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0x123456789ABCDEF0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
            },
            i64_shr_s => 'Wasm i128 ashr/1: i64_shr_s produced',
            i64_shl   => 'Wasm i128 ashr/1: i64_shl carry produced',
            i64_or    => 'Wasm i128 ashr/1: i64_or carry merge'
        );

        # x86_64 i128 mul lowering
        $check->(
            $X,
            'i128_mul',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_mul(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            mul   => 'x86_64 i128 mul: mul produced',
            umulh => 'x86_64 i128 mul: umulh produced'
        );

        # ARM64 i128 mul lowering
        $check->(
            $A,
            'i128_mul',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_mul(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            mul   => 'ARM64 i128 mul: mul produced',
            umulh => 'ARM64 i128 mul: umulh produced'
        );

        # RISCV64 i128 mul lowering
        $check->(
            $R,
            'i128_mul',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_mul(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            mul   => 'RISCV64 i128 mul: mul produced',
            mulhu => 'RISCV64 i128 mul: mulhu produced'
        );

        # Wasm i128 mul lowering
        $check->(
            $W,
            'i128_mul',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_mul(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            i64_mul   => 'Wasm i128 mul: i64_mul produced',
            i64_and   => 'Wasm i128 mul: i64_and produced',
            i64_shr_u => 'Wasm i128 mul: i64_shr_u produced'
        );

        # x86_64 i128 div lowering
        $check->(
            $X,
            'i128_div',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_div(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            seta  => 'x86_64 i128 div: seta produced',
            setae => 'x86_64 i128 div: setae produced'
        );

        # x86_64 i128 rem lowering
        $check->(
            $X,
            'i128_rem',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_rem(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            setb => 'x86_64 i128 rem: setb produced',
            seta => 'x86_64 i128 rem: seta produced'
        );

        # ARM64 i128 div lowering
        $check->(
            $A,
            'i128_div',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_div(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            cset_hi => 'ARM64 i128 div: cset_hi produced',
            cset_cs => 'ARM64 i128 div: cset_cs produced'
        );

        # ARM64 i128 rem lowering
        $check->(
            $A,
            'i128_rem',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_rem(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            cset_hi => 'ARM64 i128 rem: cset_hi produced',
            cset_cc => 'ARM64 i128 rem: cset_cc produced'
        );

        # RISCV64 i128 div lowering
        $check->(
            $R,
            'i128_div',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_div(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            sltu => 'RISCV64 i128 div: sltu produced'
        );

        # RISCV64 i128 rem lowering
        $check->(
            $R,
            'i128_rem',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_rem(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            sltu => 'RISCV64 i128 rem: sltu produced'
        );

        # Wasm i128 div lowering
        $check->(
            $W,
            'i128_div',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_div(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            i64_sub => 'Wasm i128 div: i64_sub produced'
        );

        # Wasm i128 rem lowering
        $check->(
            $W,
            'i128_rem',
            sub {
                my $b = shift;
                $b->build_ret(
                    $b->build_rem(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
            },
            i64_sub => 'Wasm i128 rem: i64_sub produced'
        );
    };
    subtest 'Jenny::Codegen i128 Arithmetic (Cross-Platform)' => sub {
        my $host          = Brocken::Katsuro::Platform::parse();
        my $platform      = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            skip 'wasmtime not available', 2 unless $wasmtime_path && -f $wasmtime_path;

            # Test 1: constant i128 return (42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 constant bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_const.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 constant file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( scalar @vals, 2,  'Wasm i128 constant returns two i64 values' );
                is( $vals[0],     42, 'Wasm i128 constant lo = 42' );
                is( $vals[1],     0,  'Wasm i128 constant hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 2: i128 add (40 + 2 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 40 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 add bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_add.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 add file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 add (40+2): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 add (40+2): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 3: i128 sub (100 - 58 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_sub(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 100 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 58 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 sub bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_sub.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 sub file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 sub (100-58): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 sub (100-58): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 4: i128 and (63 & 42 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_and(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 63 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 and bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_and.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 and file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 and (63&42): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 and (63&42): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 5: i128 or (40 | 2 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_or(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 40 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 or bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_or.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 or file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 or (40|2): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 or (40|2): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 6: i128 xor (40 ^ 2 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_xor(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 40 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 xor bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_xor.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 xor file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 xor (40^2): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 xor (40^2): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 7: i128 shl (21 << 1 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_shl(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 shl bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_shl.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 shl file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 shl (21<<1): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 shl (21<<1): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 8: i128 lshr (84 >> 1 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_lshr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 84 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 lshr bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_lshr.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 lshr file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 lshr (84>>1): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 lshr (84>>1): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 9: i128 ashr (84 >> 1 = 42, positive)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_ashr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 84 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 ashr bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_ashr.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 ashr file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 ashr (84>>1): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 ashr (84>>1): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 10: i128 mul (21 * 2 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_mul(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 mul bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_mul.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 mul file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], 42, 'Wasm i128 mul (21*2): lo = 42' );
                is( $vals[1], 0,  'Wasm i128 mul (21*2): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 11: i128 div (42 / 2 = 21)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_div(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 div bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_div.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 div file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0] + 0, 21, 'Wasm i128 div (42/2): lo = 21' );
                is( $vals[1] + 0, 0,  'Wasm i128 div (42/2): hi = 0' );
                unlink $output_file if -e $output_file;
            }

            # Test 12: i128 rem (21 % 10 = 1)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_rem(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        '%r'
                    )
                );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, 'Generated Wasm i128 rem bytes' );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = 'i128_rem.wasm';
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, 'Wasm i128 rem file exists' );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0] + 0, 1, 'Wasm i128 rem (21%10): lo = 1' );
                is( $vals[1] + 0, 0, 'Wasm i128 rem (21%10): hi = 0' );
                unlink $output_file if -e $output_file;
            }
        }
    };
    subtest 'Jenny::Codegen i128 Arithmetic (Native)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
    SKIP: {
            skip 'Execution test only supported on native hosts', 57 unless $platform->is_native;

            # Test 1: constant i128 return (42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 constant bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_const_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 constant file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 constant returned 42 on ' . $platform->friendly
                );
            }

            # Test 2: i128 add (40 + 2 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 40 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 add bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_add_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 add file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 add (40+2) returned 42 on ' . $platform->friendly
                );
            }

            # Test 3: i128 shl (21 << 1 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_shl(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 shl bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_shl_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 shl file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 shl (21<<1) returned 42 on ' . $platform->friendly
                );
            }

            # Test 3b: i128 mul (21 * 2 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_mul(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 mul bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_mul_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 mul file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 mul (21*2) returned 42 on ' . $platform->friendly
                );
            }

            # Test 4: i128 lshr (84 >> 1 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_lshr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 84 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 lshr bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_lshr_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 lshr file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 lshr (84>>1) returned 42 on ' . $platform->friendly
                );
            }

            # Test 5: i128 ashr (84 >> 1 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_ashr(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 84 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 ashr bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_ashr_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 ashr file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 ashr (84>>1) returned 42 on ' . $platform->friendly
                );
            }

            # Test 6: i128 div (42 / 2 = 21)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_div(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 div bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_div_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 div file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 21,
                    platform      => $platform,
                    name          => 'Native i128 div (42/2) returned 21 on ' . $platform->friendly
                );
            }

            # Test 7: i128 rem (21 % 10 = 1)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_rem(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 rem bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_rem_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 rem file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 1,
                    platform      => $platform,
                    name          => 'Native i128 rem (21%10) returned 1 on ' . $platform->friendly
                );
            }

            # Test 8: i128 add with carry chain (-1 + 43 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -1 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 43 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 carry add bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_carry_add_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 carry add file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 carry add (-1+43) returned 42 on ' . $platform->friendly
                );
            }

            # Test 9: i128 sub with borrow (0 - 1 = -1)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_sub(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 3 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 sub (5-3) bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_sub_5_3_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 sub (5-3) file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 2,
                    platform      => $platform,
                    name          => 'Native i128 sub (5-3) returned 2 on ' . $platform->friendly
                );
            }

            # Test 9b: i128 sub with borrow (0 - 1 = -1)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_sub(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 1 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 borrow sub bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_borrow_sub_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 borrow sub file exists' );
                my $cmd = $platform->is_windows ? '.\\' . $output_file : "./$output_file";
                system {$cmd} $cmd;
                my $exit_code = $? >> 8;
                is( $exit_code, 255, 'Native i128 borrow sub (0-1) returned 255 on ' . $platform->friendly );

                #~ unlink $output_file if -e $output_file;
            }

            # Test 10: i128 mul (7 * 6 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_mul(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 7 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 6 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 edge mul bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_edge_mul_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 edge mul file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 edge mul (7*6) returned 42 on ' . $platform->friendly
                );
            }

            # Test 11: i128 div (100 / 3 = 33)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_div(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 100 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 3 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 edge div bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_edge_div_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 edge div file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 33,
                    platform      => $platform,
                    name          => 'Native i128 edge div (100/3) returned 33 on ' . $platform->friendly
                );
            }

            # Test 12: i128 rem (100 % 7 = 2)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_rem(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 100 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 7 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 edge rem bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_edge_rem_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 edge rem file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 2,
                    platform      => $platform,
                    name          => 'Native i128 edge rem (100%7) returned 2 on ' . $platform->friendly
                );
            }

            # Test 13: i128 sub with negative rhs (5 - (-1) = 6)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_sub(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value =>  5 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -1 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 sub negative rhs bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_sub_neg_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 sub negative rhs file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 6,
                    platform      => $platform,
                    name          => 'Native i128 sub (5 - (-1)) returned 6 on ' . $platform->friendly
                );
            }

            # Test 14: i128 add with carry through hi ((-1) + 2 = 1)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_add(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -1 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value =>  2 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 add carry hi bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_add_carry_hi_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 add carry hi file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 1,
                    platform      => $platform,
                    name          => 'Native i128 add ((-1) + 2) returned 1 on ' . $platform->friendly
                );
            }

            # Test 15: i128 and ((-1) & 42 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_and(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -1 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 and bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_and_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 and file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 and (-1 & 42) returned 42 on ' . $platform->friendly
                );
            }

            # Test 16: i128 or (0 | 42 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_or(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 or bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_or_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 or file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 or (0 | 42) returned 42 on ' . $platform->friendly
                );
            }

            # Test 17: i128 xor (42 xor 0 = 42)
            {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret(
                    $builder->build_xor(
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
                        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ),
                        '%r'
                    )
                );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, 'Generated native i128 xor bytes for ' . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = 'i128_xor_native' . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, 'Native i128 xor file exists' );
                run_exec(
                    $output_file,
                    expected_exit => 42,
                    platform      => $platform,
                    name          => 'Native i128 xor (42 xor 0) returned 42 on ' . $platform->friendly
                );
            }
        }
    };
    subtest 'Jenny::Codegen i128 ICmp (Cross-Platform)' => sub {
        my $host          = Brocken::Katsuro::Platform::parse();
        my $platform      = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
        my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
        chomp $wasmtime_path if $wasmtime_path;
    SKIP: {
            skip 'wasmtime not available', 30 unless $wasmtime_path && -f $wasmtime_path;
            for my $tc (
                [ eq  => 42, 42, 1, '42 eq 42' ],
                [ eq  => 42, 0,  0, '42 eq 0' ],
                [ ne  => 42, 0,  1, '42 ne 0' ],
                [ ne  => 42, 42, 0, '42 ne 42' ],
                [ ult => 0,  42, 1, '0 ult 42' ],
                [ ult => 42, 0,  0, '42 ult 0' ],
                [ ugt => 42, 0,  1, '42 ugt 0' ],
                [ ugt => 0,  42, 0, '0 ugt 42' ],
                [ ule => 0,  42, 1, '0 ule 42' ],
                [ ule => 42, 0,  0, '42 ule 0' ],
                [ uge => 42, 0,  1, '42 uge 0' ],
                [ uge => 0,  42, 0, '0 uge 42' ],
                [ slt => 0,  42, 1, '0 slt 42' ],
                [ slt => 42, 0,  0, '42 slt 0' ],
                [ sgt => 42, 0,  1, '42 sgt 0' ],
                [ sgt => 0,  42, 0, '0 sgt 42' ],
                [ sle => 0,  42, 1, '0 sle 42' ],
                [ sle => 42, 0,  0, '42 sle 0' ],
                [ sge => 42, 0,  1, '42 sge 0' ],
                [ sge => 0,  42, 0, '0 sge 42' ],
            ) {
                my ( $pred, $a, $b, $expected, $desc ) = @$tc;
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                my $entry   = $func->append_block('entry');
                my $t_block = $func->append_block('if.then');
                my $f_block = $func->append_block('if.else');
                $builder->position_at_end($entry);
                my $cond = $builder->build_icmp(
                    $pred,
                    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $a ),
                    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $b ), '%cmp'
                );
                $builder->build_cond_br( $cond, $t_block, $f_block );
                $builder->position_at_end($t_block);
                $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
                $builder->position_at_end($f_block);
                $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ) );
                my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
                my $res     = $codegen->emit_function($func);
                ok( length( $res->{body} ) > 0, "Generated Wasm i128 icmp $desc bytes" );
                my $linker      = Brocken::Jenny::Linker::Wasm->new();
                my $output_file = "i128_icmp_$pred.wasm";
                $linker->write_executable( $output_file, $res, $platform );
                ok( -e $output_file, "Wasm i128 icmp $desc file exists" );
                my $output = qx["$wasmtime_path" run --invoke main $output_file];
                chomp $output;
                my @vals = split /\n/, $output;
                is( $vals[0], $expected ? 42 : 0, "Wasm i128 icmp $desc: lo = " . ( $expected ? 42 : 0 ) );
                is( $vals[1], 0,                  "Wasm i128 icmp $desc: hi = 0" );
                unlink $output_file if -e $output_file;
            }
        }
    };
    subtest 'Jenny::Codegen i128 ICmp (Native)' => sub {
        my $platform = Brocken::Katsuro::Platform::parse();
    SKIP: {
            skip 'Execution test only supported on native hosts', 30 unless $platform->is_native;
            for my $tc (
                [ eq  => 42, 42, 1, '42 eq 42' ],
                [ eq  => 42, 0,  0, '42 eq 0' ],
                [ ne  => 42, 0,  1, '42 ne 0' ],
                [ ne  => 42, 42, 0, '42 ne 42' ],
                [ ult => 0,  42, 1, '0 ult 42' ],
                [ ult => 42, 0,  0, '42 ult 0' ],
                [ ugt => 42, 0,  1, '42 ugt 0' ],
                [ ugt => 0,  42, 0, '0 ugt 42' ],
                [ ule => 0,  42, 1, '0 ule 42' ],
                [ ule => 42, 0,  0, '42 ule 0' ],
                [ uge => 42, 0,  1, '42 uge 0' ],
                [ uge => 0,  42, 0, '0 uge 42' ],
                [ slt => 0,  42, 1, '0 slt 42' ],
                [ slt => 42, 0,  0, '42 slt 0' ],
                [ sgt => 42, 0,  1, '42 sgt 0' ],
                [ sgt => 0,  42, 0, '0 sgt 42' ],
                [ sle => 0,  42, 1, '0 sle 42' ],
                [ sle => 42, 0,  0, '42 sle 0' ],
                [ sge => 42, 0,  1, '42 sge 0' ],
                [ sge => 0,  42, 0, '0 sge 42' ],
            ) {
                my ( $pred, $a, $b, $expected, $desc ) = @$tc;
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                my $entry   = $func->append_block('entry');
                my $t_block = $func->append_block('if.then');
                my $f_block = $func->append_block('if.else');
                $builder->position_at_end($entry);
                my $cond = $builder->build_icmp(
                    $pred,
                    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $a ),
                    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => $b ), '%cmp'
                );
                $builder->build_cond_br( $cond, $t_block, $f_block );
                $builder->position_at_end($t_block);
                $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
                $builder->position_at_end($f_block);
                $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ) );
                my $codegen
                    = $platform->is_arm64 ? Brocken::Jenny::Codegen::ARM64->new( platform => $platform ) :
                    $platform->is_riscv64 ? Brocken::Jenny::Codegen::RISCV64->new() :
                    Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                my $bytes = $codegen->emit_function($func);
                ok( length($bytes) > 0, "Generated native i128 icmp $desc bytes for " . $platform->friendly );
                my $linker
                    = $platform->is_macos ? Brocken::Jenny::Linker::MachO->new() :
                    $platform->is_windows ? Brocken::Jenny::Linker::PE->new() :
                    Brocken::Jenny::Linker::ELF64->new();
                my $output_file = "i128_icmp_${pred}_native" . $platform->bin_ext;
                $linker->write_executable( $output_file, $bytes, $platform );
                ok( -e $output_file, "Native i128 icmp $desc file exists" );
                my $cmd = $platform->is_windows ? $output_file : "./$output_file";
                system {$cmd} $cmd;
                my $exit_code = $? >> 8;
                is( $exit_code, $expected ? 42 : 0, "Native i128 icmp $desc returned " . ( $expected ? 42 : 0 ) . " on " . $platform->friendly );
                unlink $output_file if -e $output_file;
            }
        }
    };
    subtest 'Jenny::Codegen Multi-Function Calls' => sub {
        my $host   = Brocken::Katsuro::Platform::parse();
        my $b      = Brocken::Lindsay::IR::Builder->new();
        my $p      = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => 'x' );
        my $helper = Brocken::Lindsay::IR::Function->new( name => 'helper', return_type => Brocken::Lindsay::IR::Type::i32(), params => [$p] );
        $b->position_at_end( $helper->append_block('entry') );
        $b->build_ret( $b->build_add( $p, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ) ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
        $b->position_at_end( $main->append_block('entry') );
        $b->build_ret( $b->build_call( $helper, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 41 ) ] ) );

        # Test native (ELF/MachO/PE) backends when running on a supported platform
    SKIP: {
            skip 'Multi-function native test only on native hosts', 8 unless $host->is_native;
            my ( $codegen, $linker );
            if ( $host->is_arm64 && $host->is_macos ) {
                $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
                $linker  = Brocken::Jenny::Linker::MachO->new();
            }
            elsif ( $host->is_arm64 && $host->is_windows ) {
                $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
                $linker  = Brocken::Jenny::Linker::PE->new();
            }
            elsif ( $host->is_arm64 && $host->is_linux ) {
                $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
                $linker  = Brocken::Jenny::Linker::ELF64->new();
            }
            elsif ( $host->is_arm64 ) {
                $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
                $linker  = Brocken::Jenny::Linker::ELF64->new();
            }
            elsif ( $host->is_riscv64 ) {
                $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $host );
                $linker  = Brocken::Jenny::Linker::ELF64->new();
            }
            elsif ( $host->is_x64 && $host->is_macos ) {
                $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
                $linker  = Brocken::Jenny::Linker::MachO->new();
            }
            elsif ( $host->is_x64 && $host->is_windows ) {
                $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
                $linker  = Brocken::Jenny::Linker::PE->new();
            }
            else {
                # Default: ELF on x86_64
                $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
                $linker  = Brocken::Jenny::Linker::ELF64->new();
            }
            my $funcs = $codegen->emit_functions( [ $main, $helper ] );
            is( ref $funcs,        'ARRAY', 'emit_functions returned array ref' );
            is( scalar $funcs->@*, 2,       'emit_functions returned 2 entries' );
            my $output_file = 'multi_func_native' . $host->bin_ext;
            $linker->write_executable( $output_file, $funcs, $host );
            ok( -e $output_file, 'Multi-function binary exists' );
            run_exec( $output_file, expected_exit => 42, platform => $host, name => 'Multi-function helper(41) returned 42 on ' . $host->friendly );
        }

        # Test Wasm backend (when wasmtime is available)
    SKIP: {
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
            my $output = qx["$wasmtime_path" run --invoke main $output_file];
            chomp $output;
            is( $output, 42, 'Wasm multi-function helper(41) returned 42' );
            unlink $output_file if -e $output_file;
        }
    };
    subtest 'Jenny::Codegen Multi-Function Shared Library' => sub {
        my $host = Brocken::Katsuro::Platform::parse();
    SKIP: {
            skip 'Multi-function shared lib test only on native hosts', 6 unless $host->is_native;
            my $b      = Brocken::Lindsay::IR::Builder->new();
            my $func_a = Brocken::Lindsay::IR::Function->new( name => 'func_a', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
            $b->position_at_end( $func_a->append_block('entry') );
            $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
            my $func_b = Brocken::Lindsay::IR::Function->new( name => 'func_b', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
            $b->position_at_end( $func_b->append_block('entry') );
            $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 100 ) );
            my ( $codegen, $linker, $output_file );

            if ( $host->is_arm64 && $host->is_macos ) {
                $codegen     = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
                $linker      = Brocken::Jenny::Linker::MachO->new( type => 'shared' );
                $output_file = 'multi_func_shared.dylib';
            }
            elsif ( $host->is_arm64 && $host->is_windows ) {
                $codegen     = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
                $linker      = Brocken::Jenny::Linker::PE->new( type => 'shared' );
                $output_file = 'multi_func_shared.dll';
            }
            elsif ( $host->is_arm64 ) {
                $codegen     = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
                $linker      = Brocken::Jenny::Linker::ELF64->new( type => 'shared' );
                $output_file = 'multi_func_shared.so';
            }
            elsif ( $host->is_riscv64 ) {
                $codegen     = Brocken::Jenny::Codegen::RISCV64->new( platform => $host );
                $linker      = Brocken::Jenny::Linker::ELF64->new( type => 'shared' );
                $output_file = 'multi_func_shared.so';
            }
            elsif ( $host->is_x64 && $host->is_macos ) {
                $codegen     = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
                $linker      = Brocken::Jenny::Linker::MachO->new( type => 'shared' );
                $output_file = 'multi_func_shared.dylib';
            }
            elsif ( $host->is_x64 && $host->is_windows ) {
                $codegen     = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
                $linker      = Brocken::Jenny::Linker::PE->new( type => 'shared' );
                $output_file = 'multi_func_shared.dll';
            }
            else {
                $codegen     = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
                $linker      = Brocken::Jenny::Linker::ELF64->new( type => 'shared' );
                $output_file = 'multi_func_shared.so';
            }
            my $funcs = $codegen->emit_functions( [ $func_a, $func_b ] );
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
    }
};
done_testing;
__DATA__
# GitHub runner triples
x86_64-pc-dragonflybsd
x86_64-pc-freebsd14.1
aarch64-pc-freebsd14.1
i86pc-unknown-solaris
x86_64-unknown-freebsd13.4
aarch64-unknown-netbsd
aarch64--netbsd
x86_64--netbsd
i386--netbsd
sparc64--netbsd
# Rust/LLVM triples from `rustc --print target-list` plus extra LLVM/Zig OS types
aarch64-apple-darwin
aarch64-apple-ios
aarch64-apple-ios-macabi
aarch64-apple-ios-sim
aarch64-apple-tvos
aarch64-apple-tvos-sim
aarch64-apple-visionos
aarch64-apple-visionos-sim
aarch64-apple-watchos
aarch64-apple-watchos-sim
aarch64-kmc-solid_asp3
aarch64-linux-android
aarch64-nintendo-switch-freestanding
aarch64-pc-windows-gnullvm
aarch64-pc-windows-msvc
aarch64-unknown-freebsd
aarch64-unknown-fuchsia
aarch64-unknown-helenos
aarch64-unknown-hermit
aarch64-unknown-illumos
aarch64-unknown-linux-gnu
aarch64-unknown-linux-gnu_ilp32
aarch64-unknown-linux-musl
aarch64-unknown-linux-ohos
aarch64-unknown-managarm-mlibc
aarch64-unknown-netbsd
aarch64-unknown-none
aarch64-unknown-none-softfloat
aarch64-unknown-nto-qnx700
aarch64-unknown-nto-qnx710
aarch64-unknown-nto-qnx710_iosock
aarch64-unknown-nto-qnx800
aarch64-unknown-nuttx
aarch64-unknown-openbsd
aarch64-unknown-redox
aarch64-unknown-teeos
aarch64-unknown-trusty
aarch64-unknown-uefi
aarch64-uwp-windows-msvc
aarch64-wrs-vxworks
aarch64_be-unknown-hermit
aarch64_be-unknown-linux-gnu
aarch64_be-unknown-linux-gnu_ilp32
aarch64_be-unknown-linux-musl
aarch64_be-unknown-netbsd
aarch64_be-unknown-none-softfloat
amdgcn-amd-amdhsa
arm-linux-androideabi
arm-unknown-linux-gnueabi
arm-unknown-linux-gnueabihf
arm-unknown-linux-musleabi
arm-unknown-linux-musleabihf
arm64_32-apple-watchos
arm64e-apple-darwin
arm64e-apple-ios
arm64e-apple-tvos
arm64ec-pc-windows-msvc
armeb-unknown-linux-gnueabi
armebv7r-none-eabi
armebv7r-none-eabihf
armv4t-none-eabi
armv4t-unknown-linux-gnueabi
armv5te-none-eabi
armv5te-unknown-linux-gnueabi
armv5te-unknown-linux-musleabi
armv5te-unknown-linux-uclibceabi
armv6-unknown-freebsd
armv6-unknown-netbsd-eabihf
armv6k-nintendo-3ds
armv7-linux-androideabi
armv7-rtems-eabihf
armv7-sony-vita-newlibeabihf
armv7-unknown-freebsd
armv7-unknown-linux-gnueabi
armv7-unknown-linux-gnueabihf
armv7-unknown-linux-musleabi
armv7-unknown-linux-musleabihf
armv7-unknown-linux-ohos
armv7-unknown-linux-uclibceabi
armv7-unknown-linux-uclibceabihf
armv7-unknown-netbsd-eabihf
armv7-unknown-trusty
armv7-wrs-vxworks-eabihf
armv7a-kmc-solid_asp3-eabi
armv7a-kmc-solid_asp3-eabihf
armv7a-none-eabi
armv7a-none-eabihf
armv7a-nuttx-eabi
armv7a-nuttx-eabihf
armv7a-vex-v5
armv7k-apple-watchos
armv7r-none-eabi
armv7r-none-eabihf
armv7s-apple-ios
armv8r-none-eabihf
avr-none
bpfeb-unknown-none
bpfel-unknown-none
csky-unknown-linux-gnuabiv2
csky-unknown-linux-gnuabiv2hf
hexagon-unknown-linux-musl
hexagon-unknown-none-elf
hexagon-unknown-qurt
i386-apple-ios
i586-unknown-linux-gnu
i586-unknown-linux-musl
i586-unknown-netbsd
i586-unknown-redox
i686-apple-darwin
i686-linux-android
i686-pc-nto-qnx700
i686-pc-windows-gnu
i686-pc-windows-gnullvm
i686-pc-windows-msvc
i686-unknown-freebsd
i686-unknown-haiku
i686-unknown-helenos
i686-unknown-hurd-gnu
i686-unknown-linux-gnu
i686-unknown-linux-musl
i686-unknown-netbsd
i686-unknown-openbsd
i686-unknown-uefi
i686-uwp-windows-gnu
i686-uwp-windows-msvc
i686-win7-windows-gnu
i686-win7-windows-msvc
i686-wrs-vxworks
loongarch32-unknown-none
loongarch32-unknown-none-softfloat
loongarch64-unknown-linux-gnu
loongarch64-unknown-linux-musl
loongarch64-unknown-linux-ohos
loongarch64-unknown-none
loongarch64-unknown-none-softfloat
m68k-unknown-linux-gnu
m68k-unknown-none-elf
mips-mti-none-elf
mips-unknown-linux-gnu
mips-unknown-linux-musl
mips-unknown-linux-uclibc
mips64-openwrt-linux-musl
mips64-unknown-linux-gnuabi64
mips64-unknown-linux-muslabi64
mips64el-unknown-linux-gnuabi64
mips64el-unknown-linux-muslabi64
mipsel-mti-none-elf
mipsel-sony-psp
mipsel-sony-psx
mipsel-unknown-linux-gnu
mipsel-unknown-linux-musl
mipsel-unknown-linux-uclibc
mipsel-unknown-netbsd
mipsel-unknown-none
mipsisa32r6-unknown-linux-gnu
mipsisa32r6el-unknown-linux-gnu
mipsisa64r6-unknown-linux-gnuabi64
mipsisa64r6el-unknown-linux-gnuabi64
msp430-none-elf
nvptx64-nvidia-cuda
powerpc-unknown-freebsd
powerpc-unknown-helenos
powerpc-unknown-linux-gnu
powerpc-unknown-linux-gnuspe
powerpc-unknown-linux-musl
powerpc-unknown-linux-muslspe
powerpc-unknown-netbsd
powerpc-unknown-openbsd
powerpc-wrs-vxworks
powerpc-wrs-vxworks-spe
powerpc64-ibm-aix
powerpc64-unknown-freebsd
powerpc64-unknown-linux-gnu
powerpc64-unknown-linux-musl
powerpc64-unknown-openbsd
powerpc64-wrs-vxworks
powerpc64le-unknown-freebsd
powerpc64le-unknown-linux-gnu
powerpc64le-unknown-linux-musl
riscv32-wrs-vxworks
riscv32e-unknown-none-elf
riscv32em-unknown-none-elf
riscv32emc-unknown-none-elf
riscv32gc-unknown-linux-gnu
riscv32gc-unknown-linux-musl
riscv32i-unknown-none-elf
riscv32im-risc0-zkvm-elf
riscv32im-unknown-none-elf
riscv32ima-unknown-none-elf
riscv32imac-esp-espidf
riscv32imac-unknown-none-elf
riscv32imac-unknown-nuttx-elf
riscv32imac-unknown-xous-elf
riscv32imafc-esp-espidf
riscv32imafc-unknown-none-elf
riscv32imafc-unknown-nuttx-elf
riscv32imc-esp-espidf
riscv32imc-unknown-none-elf
riscv32imc-unknown-nuttx-elf
riscv64-linux-android
riscv64-wrs-vxworks
riscv64a23-unknown-linux-gnu
riscv64gc-unknown-freebsd
riscv64gc-unknown-fuchsia
riscv64gc-unknown-hermit
riscv64gc-unknown-linux-gnu
riscv64gc-unknown-linux-musl
riscv64gc-unknown-managarm-mlibc
riscv64gc-unknown-netbsd
riscv64gc-unknown-none-elf
riscv64gc-unknown-nuttx-elf
riscv64gc-unknown-openbsd
riscv64gc-unknown-redox
riscv64im-unknown-none-elf
riscv64imac-unknown-none-elf
riscv64imac-unknown-nuttx-elf
s390x-unknown-linux-gnu
s390x-unknown-linux-musl
sparc-unknown-linux-gnu
sparc-unknown-none-elf
sparc64-unknown-helenos
sparc64-unknown-linux-gnu
sparc64-unknown-netbsd
sparc64-unknown-openbsd
sparcv9-sun-solaris
thumbv4t-none-eabi
thumbv5te-none-eabi
thumbv6m-none-eabi
thumbv6m-nuttx-eabi
thumbv7a-nuttx-eabi
thumbv7a-nuttx-eabihf
thumbv7a-pc-windows-msvc
thumbv7a-uwp-windows-msvc
thumbv7em-none-eabi
thumbv7em-none-eabihf
thumbv7em-nuttx-eabi
thumbv7em-nuttx-eabihf
thumbv7m-none-eabi
thumbv7m-nuttx-eabi
thumbv7neon-linux-androideabi
thumbv7neon-unknown-linux-gnueabihf
thumbv7neon-unknown-linux-musleabihf
thumbv8m.base-none-eabi
thumbv8m.base-nuttx-eabi
thumbv8m.main-none-eabi
thumbv8m.main-none-eabihf
thumbv8m.main-nuttx-eabi
thumbv8m.main-nuttx-eabihf
wasm32-unknown-emscripten
wasm32-unknown-unknown
wasm32-wali-linux-musl
wasm32-wasip1
wasm32-wasip1-threads
wasm32-wasip2
wasm32-wasip3
wasm32v1-none
wasm64-unknown-unknown
x86_64-apple-darwin
x86_64-apple-ios
x86_64-apple-ios-macabi
x86_64-apple-tvos
x86_64-apple-watchos-sim
x86_64-fortanix-unknown-sgx
x86_64-linux-android
x86_64-lynx-lynxos178
x86_64-pc-cygwin
x86_64-pc-nto-qnx710
x86_64-pc-nto-qnx710_iosock
x86_64-pc-nto-qnx800
x86_64-pc-solaris
x86_64-pc-windows-gnu
x86_64-pc-windows-gnullvm
x86_64-pc-windows-msvc
x86_64-unikraft-linux-musl
x86_64-unknown-dragonfly
x86_64-unknown-freebsd
x86_64-unknown-fuchsia
x86_64-unknown-haiku
x86_64-unknown-helenos
x86_64-unknown-hermit
x86_64-unknown-hurd-gnu
x86_64-unknown-illumos
x86_64-unknown-l4re-uclibc
x86_64-unknown-linux-gnu
x86_64-unknown-linux-gnux32
x86_64-unknown-linux-musl
x86_64-unknown-linux-none
x86_64-unknown-linux-ohos
x86_64-unknown-managarm-mlibc
x86_64-unknown-motor
x86_64-unknown-netbsd
x86_64-unknown-none
x86_64-unknown-openbsd
x86_64-unknown-redox
x86_64-unknown-trusty
x86_64-unknown-uefi
x86_64-uwp-windows-gnu
x86_64-uwp-windows-msvc
x86_64-win7-windows-gnu
x86_64-win7-windows-msvc
x86_64-wrs-vxworks
x86_64h-apple-darwin
xtensa-esp32-espidf
xtensa-esp32-none-elf
xtensa-esp32s2-espidf
xtensa-esp32s2-none-elf
xtensa-esp32s3-espidf
xtensa-esp32s3-none-elf
# Extra LLVM/Zig OS types not in Rust's target list
aarch64-apple-bridgeos
aarch64-apple-driverkit
arm-unknown-contiki
s390x-ibm-zos
x86_64-unknown-plan9
x86_64-unknown-rtems
x86_64-pc-serenity