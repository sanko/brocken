# NAME

Brocken - Compiler for a small, perl inspired, statically typed systems language

# SYNOPSIS

Compiling a program is four calls. This is the whole path, start to finish:

```perl
use Brocken;

my $brocken = Brocken->new;

my $module = $brocken->compile(<<'BROCKEN');
sub fib( i64 $n ) -> i64 {
    if ( $n < 2 ) { return $n; }
    return fib( $n - 1 ) + fib( $n - 2 );
}

return fib( 10 );
BROCKEN

my $funcs = $brocken->codegen->emit_functions( $module->functions );
my $file  = $brocken->tmpdir . '/fib' . $brocken->ext;
$brocken->linker->write_executable( $file, $funcs, $brocken->platform );

system $file;    # exits 55, which is fib(10)
```

The program compiled there is a recursive function, a conditional, and a return value. The compiled program returns 55,
which is its exit status.

`Brocken->new` takes no arguments to get the host platform, and the other three calls never change. A caller that
wants an executable in a temporary directory rather than a named one uses the `tmpdir` method, which is where `$file`
above comes from.

# DESCRIPTION

Brocken is a compiler that reads source written in Brocken and writes a native executable. The language is a statically
typed, C-flavored language with Perl-like sigils, integer and floating-point types, classes with typed fields,
fixed-size arrays, and explicit control flow. The compiler is written in Perl and needs Perl 5.42 or later, but its
output is machine code, not Perl.

Compiling is three stages, each a separate namespace:

- [Brocken::Katsuro](https://metacpan.org/pod/Brocken%3A%3AKatsuro) is the front end and contains both the lexer and parser which turn source text into an AST and then onto a target-independent IR.
- [Brocken::Lindsay](https://metacpan.org/pod/Brocken%3A%3ALindsay) is that IR: its types, values, instructions, blocks, and functions, plus the builder that constructs them.
- [Brocken::Jenny](https://metacpan.org/pod/Brocken%3A%3AJenny) is the backend: it lowers the IR to MIR, assigns registers, encodes for each architecture, and emits the object file, in ELF, PE, Mach-O, or Wasm form as the platform requires.

The architecture and the binary format are chosen from the host platform, so a plain `Brocken->new` produces an
executable for the machine it ran on. [Brocken::Katsuro::Platform](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3APlatform) is the layer that knows the register sets, the
calling conventions, and the file naming rules for each target, and passing a platform to the constructor is how a
cross compile is asked for.

## The runtime is compiled in

`src/runtime/core.brocken` is not an optional library. `compile` reads it, parses it, and merges its statements ahead
of the caller's before anything is lowered, so every program carries the allocator, the collector, the fiber machinery,
and the exception support with it.

That is why a program does not have to ask for memory. `new` on a class, `alloca`, an array, and a list all allocate
out of the same Immix heap, and the collector is what reclaims them. The heap base is the first argument to the entry
point, and the runtime publishes it in a module global so that any function can allocate and not only the entry.

Two runtime limits are configurable and one is a capability mask:

- **Fuel** bounds the instruction budget, so a runaway loop fails rather than hanging. It defaults to 1,000,000.
- **Memory limit** bounds heap bytes per isolate. Zero, the default, means no limit.
- **Capabilities** is a bitmask of what a compiled program is allowed to do. It defaults to all of them.

They are set per compiler rather than per platform, through the three package variables below, or through the
`set_default_policy` method on [Brocken](https://metacpan.org/pod/Brocken) for everything compiled afterwards.

# THE LANGUAGE

All of this is subject to change. I am building from the back end first, so...

Types are named and explicit. Integers are signed or unsigned, at the widths `i8`, `i16`, `i32`, `i64`, `u8`,
`u16`, `u32`, and `u64`, and floats are `f32` or `f64`. There is also `Bool` and `ptr`:

```perl
my i64 $count = 7;
my f64 $ratio = 1.5;
my Bool $ready = false;
my u32 $n = 3;
```

A declaration can leave the value out, which makes it a zero value:

```perl
my i64 $total;
```

Arrays are fixed-size and written as a type and a length, with the length a constant expression:

```perl
my [i64; 4] $a;
$a[0] = 10;
$a[2] = 30;
return $a[2] + 5;    # 35
```

Control flow is `if` and `while`. Both take a braced block, and `elsif` chains on `if`:

```perl
my i64 $i = 0;
my i64 $sum = 0;
while ( $i < 10 ) {
    $sum = $sum + $i;
    $i = $i + 1;
}
return $sum;    # 45
```

Functions are declared with `sub`, and the return type follows the parameter list:

```perl
sub classify( i64 $n ) -> i64 {
    if ( $n < 0 ) { return -1; }
    if ( $n == 0 ) { return 0; }
    return 1;
}
```

`say` and `print` are calls, so they take a parenthesized argument list and a semicolon:

```
say( "hello " . 42 );
print( 42 );
```

Errors are `throw` and a `try` block that catches them, with an optional `finally` that runs either way:

```perl
sub parse_port( i64 $raw ) -> i64 {
    my i64 $n = 0;
    try {
        if ( $raw < 0 ) { throw 1; }
        $n = $raw * 2;
        return $n;
    }
    catch {
        return -1;
    }
    finally {
        # runs after the catch, including when the try returned
    }
}
```

The `catch` block receives the thrown value, and a `try` with no `catch` is a `try`-`finally` that only cleans up.
The `setjmp` and `longjmp` behind this live in the runtime, not in generated code, which is what lets a `return` out
of a `try` still run the `finally`.

Classes hold typed fields and methods, and the runtime generates a constructor, a reader, and a writer for each field.
A `: param` field becomes a constructor argument. A class value is a `ptr`, and construction is a call on the class
name with named arguments:

```perl
class Point {
    field i64 $x : param;
    field i64 $y : param;

    method sum() -> i64 {
        return $x + $y;
    }
}

my ptr $p = Point->new(x => 30, y => 12);
return $p->x + $p->y;    # 42
```

Inside a method, a field is a bare `$name` with no sigil-pair and no `->`, because the method is already in the
class. Outside one, a field read is `$p->x`, and there is a writer for it too.

# PACKAGE VARIABLES

These are the runtime defaults, read by [Brocken](https://metacpan.org/pod/Brocken) and [Brocken::Katsuro::Lowerer](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3ALowerer) when they construct themselves.
Setting one changes every compiler built afterwards:

- `$Brocken::default_fuel`

    The instruction budget given to the entry function. Defaults to `1000000`.

- `$Brocken::default_mem_limit`

    Maximum heap bytes per isolate. Defaults to `0`, which is no limit.

- `$Brocken::default_capabilities`

    The capability bitmask a compiled program starts with. Defaults to `~0`, all capabilities enabled.

The bits in that mask are:

- `$Brocken::CAP_FS_READ` - file system read
- `$Brocken::CAP_FS_WRITE` - file system write
- `$Brocken::CAP_NET` - network access
- `$Brocken::CAP_SYSTEM` - `system()` and process spawn
- `$Brocken::CAP_FFI` - syscall, libc, and raw FFI

# METHODS

## `compile( $source, $filename )`

```perl
my $module = $brocken->compile( $source, $filename );
```

Parses and lowers `$source` for this instance's platform, merging the runtime in ahead of the caller's own statements.
The optional `$filename` defaults to `(eval)` and is the name reported in diagnostics. Returns a
[Brocken::Lindsay::IR::Module](https://metacpan.org/pod/Brocken%3A%3ALindsay%3A%3AIR%3A%3AModule) with class info and read-only data attached, ready to hand to `codegen`.

## `parse( $source, $filename )`

```perl
my $ast = $brocken->parse( $source, $filename );
```

The parse half of `compile` on its own, returning the raw [Brocken::Katsuro::AST::Program](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3AAST%3A%3AProgram) without lowering. Useful
for introspection and for testing the front end against the back end. The runtime is not merged in.

## `set_default_policy( %opts )`

```perl
Brocken->set_default_policy( fuel => 100_000 );
```

Sets the runtime default for every compiler built afterwards. Accepts `fuel`, `mem_limit`, and `capabilities`, and
leaves the ones not named alone. Each can still be overridden per instance through the constructor.

## `fuel( ... )`, `mem_limit( ... )`, `capabilities( ... )`

```perl
my $fuel = $brocken->fuel;
```

The limits in force for this instance. Each falls back to the matching package variable described above when the
constructor was not given one.

## `platform( ... )`

```
$brocken->platform
```

Returns the [Brocken::Katsuro::Platform](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3APlatform) this instance targets. It is the host platform unless one was passed to the
constructor.

## `codegen( ... )`

```
$brocken->codegen
```

Returns the code generator chosen for the platform, one of [Brocken::Jenny::Codegen::X86\_64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AX86_64),
[Brocken::Jenny::Codegen::ARM64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AARM64), or [Brocken::Jenny::Codegen::RISCV64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3ARISCV64). Its `emit_functions` method takes the
functions from a compiled module and returns the machine code for them.

## `linker( ... )`

```
$brocken->linker
```

Returns the linker chosen for the platform, one of [Brocken::Jenny::Linker::ELF64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AELF64), [Brocken::Jenny::Linker::MachO](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AMachO),
or [Brocken::Jenny::Linker::PE](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3APE). Its `write_executable` method takes a path, the emitted code, and the platform, and
writes the file.

## `ext( ... )`

```perl
my $ext = $brocken->ext;
```

Returns the file extension the output needs on this platform: `.exe` on Windows and an empty string everywhere else.

Note that this is a method, so it cannot be interpolated into a string directly. `"$brocken->ext"` is the class,
the object and the letters `-`ext>, while `"$brocken->{ext}"` or `$brocken->ext` in a concatenation is the
extension.

## `tmpdir( ... )`

```
$brocken->tmpdir
```

Returns a [File::Temp::Dir](https://metacpan.org/pod/File%3A%3ATemp%3A%3ADir) object for a temporary directory created for this instance and removed when it goes out of
scope. It stringifies to a path, which is why `$brocken->tmpdir . '/fib'` is the way to build a filename. It is
where the output goes when the caller does not want to name a path.

## `os( ... )`

```perl
my $os = $brocken->os;
```

Returns the operating system this instance targets, as a normalized name. See `is_windows`, `is_macos`, `is_linux`,
and the rest on [Brocken::Katsuro::Platform](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3APlatform) for the predicates to ask with.

## `arch( ... )`

```perl
my $arch = $brocken->arch;
```

Returns the architecture this instance targets, as a normalized name: `x86_64`, `aarch64`, or `riscv64`.

# CROSS COMPILING

A cross compile is a platform passed to the constructor and then the same four calls:

```perl
my $brocken = Brocken->new(
    platform => Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu')
);
```

The result is a real executable for the other architecture, written by the same linker call. It is not run by the
compiler, and running it needs an emulator of the sort [Test2::Tools::Brocken](https://metacpan.org/pod/Test2%3A%3ATools%3A%3ABrocken) knows about.

# STATUS

Expect breakage.

The language surface is narrower than it looks, and the gap between what the lexer knows and what the parser accepts is
worth knowing about. The lexer carries a long keyword list, borrowed from Perl, but the parser implements only
declarations, `if`, `while`, `return`, `say`, `print`, `throw`, `try`, class and sub declarations, and
expressions. Several of the things the lexer recognizes are not usable yet:

- A class-typed value cannot be held in a local variable, because a variable declaration accepts only builtin type
names. A class value is a `ptr`:

    ```perl
    my ptr $p = Point->new(x => 3, y => 4);
    ```

- `i128` and `u128` are known to [Brocken::Layout](https://metacpan.org/pod/Brocken%3A%3ALayout) and rejected by the parser, and the register allocator has
no notion of them, so 128-bit values do not work at all yet. Stick to 64-bit integers.
- Array literals are parsed as a declaration form rather than as an expression, so
`my [i64; 3] $a = [ 1, 2, 3 ]` is not accepted. Declare the array and assign to it instead.
- There is no `for` loop, and `str` is not a usable parameter type, so a `str` signature does not parse.
- `alloca` is not a keyword you can call. The lowerer emits an alloca per parameter, which is what makes a
parameter's address takeable, but there is no source form for it.

`say` and `print` compile and link, and are exercised natively, but the test suite only runs them on the host target.

There are three code generators here: x86-64, AArch64, and RISC-V. The test suite exercises the native one and runs a
foreign one under `qemu` when a sysroot is configured, skipping it when there is none. `Brocken->new` asks the
platform for its back end rather than carrying a table of its own, so the WebAssembly modules --
[Brocken::Jenny::Codegen::Wasm](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AWasm), [Brocken::Jenny::Linker::Wasm](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AWasm), and [Brocken::Jenny::Lowerer::Wasm](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALowerer%3A%3AWasm) -- are now
reachable: a wasm32 triple parses into a [Brocken::Katsuro::Platform::Wasm](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3APlatform%3A%3AWasm) and returns a compiler. The generated
module is valid bytecode, and `wasmtime` validates it and runs it as a WASI command. An architecture with no code
generator is still refused with `Unsupported platform`. The isolated-thread and fiber runtimes are ahead of this.

The default fuel budget is what keeps a runaway loop from hanging a test run, and it is a wall, not a debugging tool: a
program that legitimately needs more has to be compiled with a larger `fuel`.

# LICENSE & LEGAL

This software is Copyright (c) 2026 by Sanko Robinson.

This is free software. You may use, copy, modify, and distribute it under the terms of either of the following
licenses, at your option:

```
The Artistic License 2.0 (GPL Compatible) - see F<LICENSE-A2>

The MIT License (GPL Compatible) - see F<LICENSE-MIT>
```

The documentation, including the code examples in it, is licensed under the Creative Commons Attribution 4.0
International license, see `LICENSE-CC`, when it is used apart from the code.

# AUTHOR

Sanko Robinson - [https://github.com/sanko](https://github.com/sanko)
