# NAME

Brocken - Compiler for a small, perl inspired, statically typed systems language

# DESCRIPTION

Brocken is a compiler that reads source written in Brocken and writes a native executable. The language is a statically
typed, C-flavored language with Perl-like sigils, integer and floating-point types, classes with typed fields,
fixed-size arrays, and explicit control flow. The compiler is self-hosted in the sense that it is written in Perl and
runs on Perl 5.42 or later, but its output is machine code, not Perl.

Compiling is four stages, each a separate module:

- 1. [Brocken::Katsuro::Lexer](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3ALexer) and [Brocken::Katsuro::Parser](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3AParser) turn source text into an AST.
- 2. [Brocken::Katsuro::Lowerer](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3ALowerer) turns the AST into [Brocken::Lindsay::IR](https://metacpan.org/pod/Brocken%3A%3ALindsay%3A%3AIR), a target-independent IR built out
of values, types, instructions, basic blocks, and functions.
- 3. [Brocken::Jenny](https://metacpan.org/pod/Brocken%3A%3AJenny) lowers that IR to [Brocken::Jenny::MIR](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3AMIR), assigns registers with
[Brocken::Jenny::RegAlloc](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ARegAlloc), and encodes the result. One code generator exists per architecture, for x86\_64, AArch64,
and RISC-V.
- 4. [Brocken::Jenny::Linker](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker) emits the object file, in ELF, PE, or Mach-O form as the platform requires.

The architecture and the binary format are chosen from the host platform by default, so a plain compile produces an
executable for the machine it ran on. [Brocken::Katsuro::Platform](https://metacpan.org/pod/Brocken%3A%3AKatsuro%3A%3APlatform) is the layer that knows the register sets, the
calling conventions, and the file naming rules for each target.

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
[Brocken::Jenny::Codegen::ARM64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3AARM64), or [Brocken::Jenny::Codegen::RISCV64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ACodegen%3A%3ARISCV64). Its `emit_functions` method takes the
functions from a compiled module and returns the machine code for them.

## `linker( ... )`

```
$brocken->linker()
```

Returns the linker chosen for the platform, one of [Brocken::Jenny::Linker::ELF64](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AELF64), [Brocken::Jenny::Linker::MachO](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3AMachO),
or [Brocken::Jenny::Linker::PE](https://metacpan.org/pod/Brocken%3A%3AJenny%3A%3ALinker%3A%3APE). Its `write_executable` method takes a path, the emitted code, and the platform, and
writes the file.

## `ext( ... )`

```
$brocken->ext()
```

Returns the file extension the output needs on this platform: `.exe` on Windows and an empty string elsewhere.

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

Only the x86\_64, AArch64, and RISC-V code generators exist, and the test suite exercises the native one; a cross
compile produces an image but has not been run against a target of the other architectures. The isolated-thread and
fiber runtimes are ahead of this.

# LICENSE & LEGAL

This software is Copyright (c) 2026 by Sanko Robinson.

This is free software, licensed under:

```
The Artistic License 2.0 (GPL Compatible)
```

# AUTHOR

Sanko Robinson - [https://github.com/sanko](https://github.com/sanko)
