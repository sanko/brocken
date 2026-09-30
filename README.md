# NAME

Brocken - Compiler for a small, perl inspired, statically typed systems language

# SYNOPSIS

Compiling a program is four calls. This is the whole path, start to finish:

```perl
use Brocken;
use Brocken::Compiler;

my $brocken = Brocken->new;

my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
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

The program being compiled there is a recursive function, a conditional, and a return value. The compiled program
returns 55, which is its exit status.

# DESCRIPTION

Brocken is a compiler that reads source written in Brocken and writes a native executable. The language is a statically
typed, C-flavored language with Perl-like sigils, integer and floating-point types, classes with typed fields,
fixed-size arrays, and explicit control flow. The compiler is self-hosted in the sense that it is written in Perl and
runs on Perl 5.42 or later, but its output is machine code, not Perl.

Compiling is four stages, each a separate module:

- 1. [Brocken::Katsuro::Lexer](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3ALexer) and [Brocken::Katsuro::Parser](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3AParser) turn source text into an AST.
- 2. [Brocken::Katsuro::Lowerer](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3ALowerer) turns the AST into [Brocken::Lindsay::IR](https://metacpan.org/pod/Brocken%3A%3ALindsay%3A%3AIR), a target-independent IR built out of values, types, instructions, basic blocks, and functions.
- 3. [Brocken::Jenny](https://metacpan.org/pod/Brocken%3A%3AJenny) lowers that IR to [Brocken::Jenny::MIR](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3AMIR), assigns registers with [Brocken::Jenny::RegAlloc](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ARegAlloc), and encodes the result. One code generator exists per target: [Brocken::Jenny::Codegen::X86\_64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AX86_64), [Brocken::Jenny::Codegen::ARM64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AARM64), [Brocken::Jenny::Codegen::RISCV64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3ARISCV64), and [Brocken::Jenny::Codegen::Wasm](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AWasm).
- 4. [Brocken::Jenny::Linker](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker) emits the object file, in ELF, PE, Mach-O, or WebAssembly form as the platform requires.

The architecture and the binary format are chosen from the host platform by default, so a plain compile produces an
executable for the machine it ran on. [Brocken::Katsuro::Platform](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3APlatform) is the layer that knows the register sets, the
calling conventions, and the file naming rules for each target.

# WEBASSEMBLY

WebAssembly is a target like any other, and it is selected by passing a wasm32 triple to the constructor rather than by
being the host:

```perl
use Brocken;
use Brocken::Compiler;
use Brocken::Katsuro::Platform;

my $brocken = Brocken->new(
    platform => Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi'),
);

my $module = Brocken::Compiler->new->compile(<<'BROCKEN');
sub add( i64 $a, i64 $b ) -> i64 { return $a + $b; }
return add( 40, 10 );
BROCKEN

my $file = $brocken->tmpdir . '/add' . $brocken->ext;
$brocken->linker->write_executable(
    $file, $brocken->codegen->emit_functions( $module->functions ), $brocken->platform,
);
```

The rest of the path is the same four calls as for a native target. Only the two things that vary differ: the platform,
and the `ext` of `.wasm` rather than an empty string or `.exe`.

A wasm32 triple is any triple whose architecture begins with `wasm` or whose environment or operating system mentions
`wasi`, so `wasm32-unknown-wasi`, `wasm32-wasi`, and `wasm32-unknown-unknown` all resolve to
[Brocken::Katsuro::Platform::Wasm](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3APlatform%3A%3AWasm).

The output is a standard `.wasm` module, not an executable, so something else has to run it. The entry point is
`_BROCKEN_ENTRY` and its first argument is the heap base, which the runtime is expected to supply:

```
wasmtime run --invoke _BROCKEN_ENTRY add.wasm 1024
```

That prints `50` for the program above. Under `node`, the same module is instantiated and the export called directly,
which is what the test suite does when `wasmtime` is not installed.

## What the WebAssembly target supports

Integer and floating-point arithmetic, comparison, loads and stores, structured control flow, calls, recursion, and
`i128` are all implemented. `alloca` is supported by allocating from the same runtime bump allocator that objects
use, so a slot escapes its function the way a field does. The heap base is published in a module global rather than
kept in each frame, which is what lets any function allocate.

Two things are not implemented: floating-point `min` and `max` are absent from WebAssembly itself and are rejected
rather than approximated, and `write_shared_library` does not exist on [Brocken::Jenny::Linker::Wasm](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AWasm), so a wasm32
target can only produce a module.

# THE LANGUAGE

All of this is subject to change. I'm building things from the back end first so...

Types are named and explicit. Integers come in signed and unsigned widths, and floats have `f32` and `f64` widths:

```perl
my i64 $count = 0;
my f64 $ratio = 1.5;
my Bool $ready = false;
```

A declaration can leave the value uninitialized, which is a zero value:

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

Classes hold typed fields and methods, and the runtime generates a constructor, a reader, and a writer for each field.
A `: param` field becomes a constructor argument, and `: pack(N)` sets the field's alignment to a power of two:

```python
class Point {
    field i64 $x : param = 30;
    field i64 $y : param = 12;

    method sum() -> i64 {
        return $x + $y;
    }
}
```

# METHODS

## `platform( ... )`

```
$brocken->platform()
```

Returns the [Brocken::Katsuro::Platform](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3APlatform) this instance targets. It is the host platform unless one was passed to the
constructor.

## `codegen( ... )`

```
$brocken->codegen()
```

Returns the code generator chosen for the platform, one of [Brocken::Jenny::Codegen::X86\_64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AX86_64),
[Brocken::Jenny::Codegen::ARM64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AARM64), [Brocken::Jenny::Codegen::RISCV64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3ARISCV64), or [Brocken::Jenny::Codegen::Wasm](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AWasm). Its
`emit_functions` method takes the functions from a compiled module and returns the machine code for them.

## `linker( ... )`

```
$brocken->linker()
```

Returns the linker chosen for the platform, one of [Brocken::Jenny::Linker::ELF64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AELF64), [Brocken::Jenny::Linker::MachO](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AMachO),
[Brocken::Jenny::Linker::PE](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3APE), or [Brocken::Jenny::Linker::Wasm](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AWasm). Its `write_executable` method takes a path, the
emitted code, and the platform, and writes the file.

## `ext( ... )`

```
$brocken->ext()
```

Returns the file extension the output needs on this platform: `.exe` on Windows, `.wasm` on WebAssembly, and an empty
string everywhere else.

## `tmpdir( ... )`

```
$brocken->tmpdir()
```

Returns the path of a temporary directory created for this instance and removed when it goes out of scope. It is where
the output goes when the caller does not want to name a path.

## `os( ... )`

```perl
my $os = $brocken->os;
```

Returns the operating system this instance targets, as a normalized name.

## `arch( ... )`

```perl
my $arch = $brocken->arch;
```

Returns the architecture this instance targets, as a normalized name.

# STATUS

Expect breakage.

The language surface is narrower than it looks, and the gap between what the lexer knows and what the parser accepts is
worth knowing about. The lexer carries a long keyword list, but the parser only implements declarations, `if`,
`while`, `return`, `print`, `say`, and expressions. A class can be declared and its methods compiled, but a
class-typed value cannot currently be held in a local variable, because variable declarations accept only builtin type
names. Array literals are parsed as a declaration form rather than as an expression, so `my [i64; 3] $a = [ 1, 2, 3 ]`
is not accepted; declare the array and assign to it instead. `print` and `say` parse but do not yet reach the back
ends correctly.

There are four code generators: x86\_64, AArch64, RISC-V, and WebAssembly. The test suite exercises the native one, and
runs the WebAssembly one under `wasmtime` or `node` when either is installed, skipping it when neither is. A native
cross compile to AArch64 or RISC-V produces an image but has not been run against a target of those architectures. The
wasm32 target has no shared-library output. The isolated-thread and fiber runtimes are ahead of this.

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
