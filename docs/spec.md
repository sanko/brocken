# The Brocken Language Specification

**Author:** Sanko Robinson

**Version:** 0.1

**Status:** Active Development

---

## 0. About

This is the unified specification for the Brocken programming language, a modernized Perl-like syntax compiled directly to standalone native  executables (x86_64, ARM64, RISC-V, WebAssembly) with a self-hosted runtime, deterministic memory management, and CSP-style concurrency. No GCC, no LLVM, no libc.

---

## 1. Philosophy & Overview

### 1.1 What This Compiler Does

Brocken takes Brocken source code, chews through several phases, and spits out a native executable. The supported output formats are Windows PE, Linux ELF, WebAssembly, or macOS Mach-O, for x64, ARM64, or RISCV64.

This project serves two kinds of readers:
- **Perl programmers** curious about how compilers work.
- **Compiler devs** who want to contribute new features, ports, or optimizations.

### 1.2 Goals

- **AOT Compilation:** Compile Perl-like syntax directly to zero-dependency standalone native executables.
- **Self-Hosted Runtime:** The GC, fiber scheduler, I/O layers, and channel runtime are written in Brocken, using compiler intrinsics.
- **Modern Concurrency:** M:N concurrency using Fibers (green threads) multiplexed across Isolates (OS threads with independent heaps), communicating safely via Channels.
- **Memory Management:** RC Immix system - deterministic reference counting backed by a tracing cycle-detector.
- **Modernization:** UTF-8 by default, zero-cost exceptions (`try/catch/finally`), `defer` blocks, `match` statement, native SIMD via typed arrays.

### 1.3 Non-Goals

- **100% bug-for-bug Perl 5 compatibility:** Break compatibility where it conflicts with AOT compilation, safe concurrency, or modern semantics.
- **C Library Dependency (libc):** No dependency on glibc, musl, or msvcrt for core runtime. The linker emits standalone binaries using OS syscalls directly.
- **Interpreted execution as default:** Brocken is AOT-first. JIT compilation is strictly reserved for dynamic `eval` and some regex.
- **General-purpose malloc/free:** The RC Immix allocator replaces malloc entirely.

### 1.4 Constraints

- No libc dependency; all synchronization, memory, and I/O primitives must use raw OS syscalls or linker-resolved dynamic imports.
- Wasm backends cannot create OS threads (sandboxed); isolate/channel operations are stubs until the threads proposal stabilizes.
- Each Isolate has an independent Immix heap; no shared mutable state between OS threads.
- The compiler is currently written in Perl 5 and must eventually bootstrap into self-hosting.

### 1.5 Key Design Decisions

**Self-Hosted Runtime (`libbrocken`).** We do not link against an external C runtime. The runtime (GC, Fibers, I/O) is written in a subset of Brocken itself (`core.brocken`). The Katsuro frontend silently parses this file and prepends its AST to the user's code before lowering.

**Share-Nothing Isolates & Cooperative Fibers.** Because an Isolate shares absolutely no memory with other Isolates, the heap is completely thread-local. This means Garbage Collection and Reference Counting require zero atomic locks, ensuring massive performance gains.

**Deterministic RC + Immix Allocation.** Brocken relies on Immediate Reference Counting to guarantee deterministic scope-based destruction (`DESTROY`). To solve the circular reference problem, it uses the Bacon & Rajan Trial Deletion algorithm. Memory is allocated using an Immix Bump-Allocator (32KB blocks) for C-like allocation speeds.

**Unsafe Native Subset.** To self-host the runtime, Brocken exposes raw machine types (`i64`, `f64`, `ptr`) and the `Brocken::` pseudo-namespace. Calling `Brocken::load_i64($ptr)` bypasses function overhead entirely and emits a raw `load` IR instruction.

**Tagged Variants for Gradual Typing.** `my $x` without a type gets `Any`, a 16-byte Fat Scalar containing the Reference Count, GC Flags, a Type Tag, and a Payload. `my i64 $x` gets a raw, unboxed machine integer.

---

## 2. Language Specification

### 2.1 Lexical Structure & Core Types

#### 2.1.1 Variables & Invariant Sigils

| Sigil | Meaning | Example |
|-------|---------|---------|
| `$` | Scalar/Object - a single value, reference, or object | `my $x = 42` |
| `@` | Array/List - indexed as `@items[0]` | `my @arr` |
| `%` | Hash/Dictionary - accessed as `%map{"key"}` | `my %map` |

Sigils are invariant - they never change based on context (unlike Perl 5).

#### 2.1.2 Built-in Types (Gradual Typing)

If a type is omitted, it defaults to `Any` (a 16-byte Fat Scalar).

| Type | Maps To | Description |
|------|---------|-------------|
| `Any` | `dynamic` | 16-byte fat scalar with refcount, GC flags, type tag, payload |
| `Int` | `int` | Shorthand for the native `int` type (alias) |
| `Bool` | `bool` | Shorthand for the native `bool` type (alias) |
| `String` | `ptr` | Immutable, UTF-8 encoded text (pointer to bytes) |
| `Array` | - | Collection (planned) |
| `Hash` | - | Key-value dictionary (planned) |
| `Class` | - | Object blueprint |

`Int` and `Bool` are not dynamic types - they are aliases for the native `int` and `bool` types declared in §2.1.3. A variable written as `my Int $x` or `my Bool $flag` gets a raw, unboxed machine value with no fat-scalar overhead.

Valid type keywords: `Any`, `Int`, `Bool`, `String`, `int`, `bool`,
`i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `i128`, `u128`,
`f32`, `f64`, `ptr`.

#### 2.1.3 Native Types (Unsafe Subset)

To allow Brocken's runtime and Garbage Collector to be written in Brocken itself, the compiler exposes raw, unboxed machine types. These types bypass the Fat Scalar tagging, carry zero runtime overhead, and are strictly ignored by the Reference Counting engine.

##### Architecture-Independent Types

| Type | IR Kind | Width | Description |
|------|---------|-------|-------------|
| `i8` | `int` | 8 | Signed byte |
| `u8` | `int` | 8 | Unsigned byte |
| `i16` | `int` | 16 | Signed short |
| `u16` | `int` | 16 | Unsigned short |
| `i32` | `int` | 32 | Signed int |
| `u32` | `int` | 32 | Unsigned int |
| `i64` | `int` | 64 | Signed long |
| `u64` | `int` | 64 | Unsigned long |
| `i128` | `int` | 128 | Signed 128-bit integer (feature `brocken_native_types`) |
| `u128` | `int` | 128 | Unsigned 128-bit integer (feature `brocken_native_types`) |
| `f32` | `float` | 32 | IEEE 754 single-precision |
| `f64` | `float` | 64 | IEEE 754 double-precision |
| `ptr` | `ptr` | 64 | Opaque memory address |

##### Architecture-Native Shorthands

| Type | Maps To | Description |
|------|---------|-------------|
| `int` | `i64` on all current targets | Native signed integer (word size) |
| `bool` | `i1` | Native boolean (`true` = 1, `false` = 0) |

`int` and `bool` exist so generic algorithms can be written without hard-coding a width. On all current targets (x86_64, ARM64, RISCV64, Wasm) `int` maps to `i64`. `Int` and `Bool` are user-facing aliases for `int` and `bool` respectively (see §2.1.2).

##### Signed vs Unsigned Semantics

Signedness is encoded in the type name (`i` prefix = signed, `u` prefix = unsigned) and affects:

| Operation | Signed | Unsigned |
|-----------|--------|----------|
| Division | `div` | `udiv` |
| Remainder | `rem` | `urem` |
| Right shift | `ashr` (arithmetic) | `lshr` (logical) |
| Extension (widening) | `sext` (sign-extend) | `zext` (zero-extend) |
| Comparison predicates | `sgt`, `slt`, `sge`, `sle` | `ugt`, `ult`, `uge`, `ule` |

Addition, subtraction, multiplication, and bitwise logical ops (`and`, `or`, `xor`) are identical for signed and unsigned at the machine level - they produce the same bit pattern. Signedness only matters for the operations above.

Left shift (`<<`) is also identical for signed and unsigned at the machine level
- it maps to `shl` regardless. Right shift (`>>`) differs by signedness: signed
right shift uses `ashr` (arithmetic, sign-extending), unsigned right shift uses
`lshr` (logical, zero-extending). The IR records signedness on the `Type` object
(`signed` field) and the lowerer selects the correct shift opcode based on it.

The lowerer's `maybe_convert_type` (§3.4) uses signedness to choose the correct extension opcode when widening. The backend encoder selects the correct instruction form based on the IR opcode (e.g., x86_64 `idiv` vs `div`, `sar` vs `shr`).

**The `Brocken::` Pseudo-Namespace.** Instead of writing inline assembly, Brocken exposes raw IR instructions via the `Brocken::` pseudo-namespace. The parser recognizes these and translates them directly into single Lindsay IR instructions:

```perl
use feature 'brocken_native_types';
my ptr $heap_cursor;
my i64 $size = 32;
my ptr $next = Brocken::ptr_add($heap_cursor, $size);
```

#### 2.1.4 Struct Types

User-defined compound types with named fields, declared via the `class` keyword
(or the `struct` keyword, planned). Struct layout is tracked at the IR level via
a `struct` kind on the `Type` object with field names and offsets. Field access
is lowered to `GetElementPtr` (GEP) with struct-aware offset computation.

```perl
struct Point {
    i64 $x;
    i64 $y;
}
```

Struct types retain field names at the IR level for debug info and reflection. Field access uses named lookup (`$p->x`), lowered to a `GetElementPtr` instruction with struct-aware byte offset computation. The IR `Type` carries a `struct` kind with field metadata (name, type, offset). Layout respects alignment requirements:

| Field Type | Alignment | Size |
|------------|-----------|------|
| `i8` / `u8` | 1 | 1 |
| `i16` / `u16` | 2 | 2 |
| `i32` / `u32` | 4 | 4 |
| `i64` / `u64` / `int` | 8 | 8 |
| `i128` / `u128` | 16 | 16 |
| `f32` | 4 | 4 |
| `f64` | 8 | 8 |
| `ptr` | 8 | 8 |

Fields are laid out with natural alignment padding between members. The total struct size is rounded up to the alignment of the most-aligned member. Example:

```perl
struct Packed {
    i8   $a;       # offset 0,  size 1
    i32  $b;       # offset 4,  size 4  (3 bytes padding after $a)
    ptr  $c;       # offset 8,  size 8
    i8   $d;       # offset 16, size 1
    # total: 24 (rounded up to alignment of ptr=8)
}
```

Structs can nest:

```perl
struct Line {
    Point $start;
    Point $end;
    f64   $length;  # cached length
}
```

A struct variable declared without `new` lives on the stack:

```perl
my Point $pt;           # 16 bytes on stack, zero-initialized
my Point $pt = { x: 10, y: 20 };  # struct literal
my i64 $x = $pt.x;      # field read - compile-time offset
$pt.y = 30;             # field write
```

Structs declared with `my` on the heap (via `new`) get RC treatment:

```perl
my Point $pt = Point->new(x => 10, y => 20);  # heap-allocated, RC'd
```

##### Relation to Classes

Classes (§2.6) are structs with methods, auto-generated accessors, constructors, and lifecycle hooks (`ADJUST`, `DESTROY`). A `class` without methods is structurally identical to a `struct`. The difference is semantic: classes are always heap-allocated and RC-managed; structs can live on the stack.

During code generation (`emit_functions`), every `alloca` instruction associated
with a struct type is annotated with field offsets. The four backends (X86_64,
ARM64, RISCV64, Wasm) all support struct-aware GEP lowering.

Classes (§2.6) are compiled to struct-typed memory regions with the same field
layout, allocation, and access machinery.

#### 2.1.5 Static Data & .rodata Section

Compile-time constant data (string literals, const-initialized arrays, struct literals) is emitted into the `.rodata` section of the output binary.

```perl
say("Hello, World!");
```

The string `"Hello, World!"` is stored as a length-prefixed UTF-8 byte sequence in `.rodata`:

```
Offset  Content
0-4     Length (32-bit little-endian): 13
5-17    UTF-8 bytes: "Hello, World!"
18      0x00 (null terminator for C interop)
```

The `say`/`print` builtins receive a pointer to this structure. The lowerer emits a `.rodata` entry and passes its link-time-resolved address as an immediate operand.

Compound constant data follows the same pattern:

```perl
const HEX_DIGITS = "0123456789ABCDEF";   # in .rodata
```

The linker places `.rodata` after `.text` but before `.data`:

```
.text      (code)
.rodata    (read-only data - strings, const arrays)
.data      (read-write data - mutable globals)
```

On ELF64 this maps to `PT_LOAD` segments with appropriate page permissions (R-X for text, R-- for rodata, RW- for data).

#### 2.1.6 References (Planned)

A reference is a non-null pointer that participates in reference counting. Declared with `ref(T)`:

```perl
my $x = 42;
my ref(Int) $r = \$x;    # reference to $x
say($$r);                # dereference → 42
```

References are lowered to `ptr` in the IR but carry additional semantics:

- **Non-null**: A reference always points to a valid object. No null-check needed before dereference.
- **RC participation**: Creating a reference increments the target's refcount. Dropping a reference decrements it.
- **No ownership**: The referent is not deallocated when the reference goes out of scope - only when all owning pointers do.

The optimizer can use the non-null guarantee to elide null checks and the RC guarantee to elide early frees.

In the IR, references are opaque pointers (`ptr` type) with `incref` emitted at creation and `decref` emitted at scope exit, wired into the same Perceus RC elision pass that handles class instances.

#### 2.1.7 Typed Pointers (Planned)

A typed pointer carries the type of the pointed-to value at the source level, but lowers to the same opaque `ptr` in the IR:

```perl
my ptr(i64) $p = ...;       # pointer to an i64
my i64 $val = $p[0];        # load i64 through typed pointer - no cast needed
$p[0] = 42;                 # store i64 through typed pointer
```

The difference between `ptr` and `ptr(T)` is purely a source-level annotation:

| Expression | Untyped `ptr` | Typed `ptr(T)` |
|------------|---------------|----------------|
| Declaration | `my ptr $p` | `my ptr(i64) $p` |
| Load | `Brocken::load_i64($p)` | `$p[0]` |
| Store | `Brocken::store_i64($p, 42)` | `$p[0] = 42` |
| Arithmetic | `Brocken::ptr_add($p, 8)` | `$p + 1` (element-scaled) |

Typed pointers support element-scaled arithmetic: `$p + n` advances by `n * sizeof(T)` bytes, not `n` raw bytes. This mirrors C's pointer arithmetic semantics.

In the IR, both typed and untyped pointers use opaque `ptr`. The element type `T` is stored as an annotation on the `getelementptr` instruction for the optimizer's use but is ignored by the backend encoder.

#### 2.1.8 Type Aliases (Planned)

The `type` keyword creates compile-time type aliases:

```perl
type Byte = u8;
type Word = u16;
type DWord = u32;

my Byte $b = 255;
```

Type aliases are resolved at parse time and do not create new types. They are purely syntactic sugar.

### 2.2 Variable Scoping & Declarations

- `my` - lexical variable declaration
- `our` - package-scoped variable
- `state` - persistent lexical variable
- `const` - compile-time constant
- `type` - type alias declaration

Array declarations use the syntax `my [TYPE; SIZE] @name`:

```perl
my [i64; 10] @arr;      # fixed-size array of 10 i64s
my i64 @arr = [1,2,3];  # sized from literal count
```

### 2.3 Operators

**Numeric:** `==`, `!=`, `<`, `>`, `<=`, `>=`, `<=>`

**Logical:** `&&`, `||`, `!`, `//` (Defined-OR)

**Bitwise:** `&`, `|`, `^`, `~`

**Shift:** `<<` (left shift), `>>` (right shift - arithmetic for signed, logical for unsigned)

String comparison (`eq`, `ne`, `lt`, `gt`, `le`, `ge`, `cmp`) is deferred - see §2.17.

### 2.4 Control Flow

```perl
if ($x > 0) {
    ...
} elsif ($x == 0) {
    ...
} else {
    ...
}

while ($cursor < $limit) {
    ...
}

foreach my $item (@arr) {
    ...
}

return $value;
return;        # void return
```

- No statement modifiers (`say "hi" if $x`)
- No `unless`, `until` in v0.1

#### 2.4.1 `foreach` / `for` Loop

`foreach` (or its alias `for`) iterates over a list, binding each element to a loop variable. The loop variable is lexically scoped to the loop body.

```perl
# Single variable iteration
foreach my $x (@arr) {
    say($x);
}

# Multi-variable iteration (consumes N items per step)
foreach my ($key, $value) (%map) {
    say("$key = $value");
}

# C-style for loop (also supported)
for (my i64 $i = 0; $i < 10; $i = $i + 1) {
    say($i);
}
```

**Reference aliasing:** A loop variable declared with `\` creates a reference alias to the iterated element, allowing in-place mutation:

```perl
foreach my \@item (@arr) {
    # \@item aliases each element; modifying \$item modifies the array
    $item = $item * 2;
}
```

**Lowering:** `foreach my $var (EXPR)` is lowered to:

1. Evaluate `EXPR` into a temporary list value
2. Initialize an iterator (index = 0)
3. Loop header: compare index against list count
4. Loop body: load element at index, bind to `$var`, execute body, increment index
5. Loop exit: jump past the loop

Multi-variable `foreach my ($k, $v) (EXPR)` consumes N elements per iteration (where N = number of loop variables). The iterator advances by N each step.

`next` jumps to the loop increment; `last` exits the loop; `redo` re-executes the current iteration without incrementing.

#### 2.4.2 `next`, `last`, `redo`

| Keyword | Behaviour |
|---------|-----------|
| `next` | Jump to the next iteration (skip remaining body) |
| `last` | Exit the loop immediately |
| `redo` | Re-execute the current iteration without incrementing the iterator |

These work in both `while` and `foreach` loops:

```perl
foreach my $x (@arr) {
    next if $x < 0;     # skip negative values
    last if $x == 100;   # stop at 100
    redo if $x == 0;     # re-try zero
    say($x);
}
```

### 2.5 Subroutines

Strict signatures with arity, named parameters, and optional return type.

```perl
sub allocate_block(i64 $size) -> ptr {
    my ptr $cursor = $heap_ptr;
    $heap_ptr = Brocken::ptr_add($cursor, $size);
    return $cursor;
}

sub greet(i64 $n) {
    # implicit void return
}
```

- Parameters are `(TYPE $name, ...)`
- Return type is `-> TYPE`; omitted means void
- Last expression is NOT implicitly returned - must use `return`

#### 2.5.1 Named Parameters (Perl 5.44-style)

Named parameters allow callers to pass arguments by name rather than position. Named parameters are declared with a `:` prefix and are passed as `name => value` pairs after all positional arguments.

```perl
# Positional only
sub create_point(i64 $x, i64 $y) -> ptr { ... }

# Positional + named
sub create_point(i64 $x, i64 $y, :i64 $color = 0, :bool $visible = true) -> ptr { ... }

# Call site: positional args first, then named as key-value pairs
my ptr $p = create_point(10, 20, color => 0xFF0000, visible => false);
```

**Syntax rules:**

| Form | Meaning |
|------|---------|
| `:TYPE $name` | Required named parameter (no default) |
| `:TYPE $name = DEFAULT` | Optional named parameter with default value |
| `name => value` | Named argument at call site (fat comma auto-quotes bareword) |

- Named parameters must appear **after** all positional parameters in the signature
- Named parameters are passed in any order at the call site
- Omitted named parameters use their declared default value
- If no default is declared, the parameter defaults to a zero-initialized value of its type

**Lowering:**

Named parameters are lowered as regular positional parameters in the IR. The compiler generates a **named parameter matcher prologue** at the function entry:

1. Positional parameters are bound first (in declaration order)
2. Remaining arguments are consumed in pairs: `(name_ptr, value, name_ptr, value, ...)`
3. Each name pointer is compared against declared named parameter names (string comparison at runtime)
4. Matched values are assigned to the corresponding parameter
5. Unmatched parameters retain their default (or zero-init)

```
# Source:
sub f(i64 $x, :i64 $alpha = 0, :i64 $beta = 0) -> i64 { ... }
f(42, alpha => 10);

# Lowered IR equivalent:
sub @f(i64 $x, i64 $alpha, i64 $beta, ptr $__named_args, i64 $__named_count) -> i64 {
    # prologue: bind positional
    $x = arg0
    # prologue: zero-init named params
    $alpha = 0
    $beta = 0
    # prologue: match named args (pairs)
    for i in 0..$__named_count step 2:
        $key = load_ptr($__named_args + i * 8)
        $val = load_i64($__named_args + (i+1) * 8)
        if $key == "alpha": $alpha = $val
        elif $key == "beta": $beta = $val
    # body:
    ...
}
```

**Interaction with `want`:** Named parameters do not affect `want` context. The `want` builtin operates on the function's return context, not its argument handling.

### 2.6 Object-Oriented Programming

Corinna-style `class` with `field`, `method`, and `ADJUST` block.

```perl
class Point {
    field i64 $x :param;
    field i64 $y :param;

    ADJUST {
        $x = 10 if $x < 10;    # clamp minimum
    }

    method sum() -> i64 {
        return $x + $y;
    }
}
```

#### 2.6.1 Fields

Each `field` has an explicit type and optional attributes:

| Attribute | Effect |
|-----------|--------|
| `:param` | Auto-generates a constructor (`Point->new($x, $y)`) |
| `:reader` | Auto-generates a getter (`$p->x`) |
| `:writer` | Auto-generates a setter (`$p->set_x(42)`) |
| `:default(N)` | Default value when omitted from constructor |

Fields are laid out sequentially in memory (order-defined, no padding guarantees in v0.1).

#### 2.6.2 Methods

Methods are functions that receive `$self` (a `ptr`) as the first parameter.

Method calls use `->` syntax:

```perl
my ptr $p = Point->new(10, 20);
my i64 $s = $p->sum();
```

#### 2.6.3 ADJUST

The `ADJUST` block inside a class runs after the constructor assigns `:param` fields. It can enforce invariants (e.g., clamp values).

#### 2.6.4 Direct Field Access

Fields can be read and written directly without a reader/writer:

```perl
my i64 $x = $p->x;
$p->x = 42;
```

#### 2.6.5 Lifecycle Hooks

- `new` - constructor
- `ADJUST` - post-construction invariant enforcement
- `DESTROY` - deterministic destructor (due to Immediate RC)

### 2.7 Intrinsics (`Brocken::*`)

The `Brocken::` pseudo-namespace maps directly to MIR instructions:

```perl
my ptr $next = Brocken::ptr_add($cursor, $size);
if (Brocken::ptr_cmp_gt($next, $limit)) { ... }
my i64 $val = Brocken::load_i64($addr);
Brocken::store_i64($addr, $val);
```

Known intrinsics:

| Intrinsic | MIR output |
|-----------|------------|
| `Brocken::ptr_add(p, off)` | `add` (pointer arithmetic) |
| `Brocken::ptr_sub(p, off)` | `sub` (pointer arithmetic) |
| `Brocken::ptr_cmp_gt(a, b)` | `icmp sgt` |
| `Brocken::ptr_cmp_lt(a, b)` | `icmp slt` |
| `Brocken::ptr_cmp_eq(a, b)` | `icmp eq` |
| `Brocken::load_i64(ptr)` | `load i64` |
| `Brocken::store_i64(ptr, val)` | `store i64` |
| `Brocken::load_i32(ptr)` | `load i32` |
| `Brocken::store_i32(ptr, val)` | `store i32` |
| `Brocken::band(a, b)` | `and` (bitwise AND) |
| `Brocken::bor(a, b)` | `or` (bitwise OR) |
| `Brocken::bxor(a, b)` | `xor` (bitwise XOR) |
| `Brocken::shl(a, b)` | `shl` (shift left) |
| `Brocken::shr(a, b)` | `lshr` (logical shift right) |
| `Brocken::syscall(n, ...)` | syscall instruction |
| `Brocken::syscall_by_name(name, ...)` | syscall instruction (number resolved from platform by name) |
| `Brocken::libc(name, ...)` | call libc function by name (resolved at link time) |

### 2.8 Built-in Functions

| Function | Behaviour |
|----------|-----------|
| `say(...)` | Print (newline-terminated) - lowered to `write(1)` syscall |
| `print(...)` | Print (no newline) - lowered to `write(1)` syscall |

### 2.9 Entry Point

There is no special `sub main`. Top-level code is automatically compiled into an implicit entry function that receives a heap-base pointer from the OS entry stub. `sub main` defined explicitly is just a regular function it is not automatically called.

```perl
# This program:
my i64 $x = 42;
return $x;

# Is equivalent to:
sub _BROCKEN_ENTRY(i64 $__heap_base) -> i64 {
    my i64 $x = 42;
    return $x;
}
```

### 2.10 Feature Flags

Experimental features are gated behind `use feature`:

```perl
use feature 'brocken_native_types';   # enables i128, i16, f32, f64 types
```

### 2.11 `match` Statement (Planned)

`match` lowers to a sequence of type-tag checks + conditional branches + unbox operations. (Not yet implemented - the parser/frontend is still being built.)

### 2.12 `defer` Blocks (Planned)

Deferred code is cloned into all scope exit paths during Lindsay lowering. Zero runtime overhead (no stack of defer frames). (Not yet implemented.)

### 2.13 `try/catch/finally` (Planned)

Uses DWARF `.eh_frame` for zero-cost exception unwinding. The `die` intrinsic unwinds to the nearest `catch` landing pad.

### 2.14 Pod6 Documentation (Planned)

Raku-style Pod6 is built natively into the parser. Two forms:

**Declarator blocks** - attached to the subsequent definition via `#|`:

```perl
#| Creates a new User with the given name and age.
sub create_user ($name, $age) { ... }
```

**Paragraph blocks** - standalone `=begin` / `=end` sections.

Pod6 nodes are attached directly to the AST as metadata on each `Brocken::Katsuro::Node`. The compiler exposes them via LSP server (hover tooltips, go-to-definition) and `bkn doc` CLI (renders as HTML/man/terminal).

### 2.15 Source Position Convention

Every AST node carries `file`, `line`, and `col` from the token that introduces the construct (its start token, not its closing token). The position is set during parsing and propagates through to error messages.

#### 2.15.1 Line Directives (`# line`)

A `# line` directive overrides the reported source file, line, and column for all
subsequent tokens, allowing generated code or macros to attribute themselves to
their origin source. The directive is lexed and applied by the parser's position
tracking; the overridden position replaces the actual one in both error messages
and DWARF debug output.

```
# line "original.brocken" 42
$x = 1;         # reported as original.brocken:42
# line "original.brocken" 42 5
$x = 1;         # reported as original.brocken:42:5
```

The parser maintains a position stack so that included or inlined code can
restore the caller's position after its scope ends. Runtime functions compiled
from `core.brocken` are always attributed to `<runtime>` as their source file,
enforced by the codegen backends (see §7.2).

| AST Node | Position Source Token |
|---|---|
| `Expr::Const` | NUM / STRING / KEYWORD token |
| `Expr::Var` | VAR token (`$x`) |
| `Expr::Ident` | IDENT token |
| `Expr::Paren` | `(` token |
| `Expr::UnOp` | OP token (`-`, `!`) |
| `Expr::BinOp` | OP token (operator itself) |
| `Expr::Call` / `IntrinsicCall` | `(` token (opening paren) |
| `Expr::MethodCall` / `FieldAccess` | `->` token |
| `Expr::ArrayIndex` | `[` token |
| `Stmt::VarDecl` | VAR token (not `my`) |
| `Stmt::Assign` | `=` / `//=` token |
| `Stmt::Return` | `return` keyword |
| `Stmt::If` | `if` keyword |
| `Stmt::While` | `while` keyword |
| `Stmt::SubDecl` | `sub` keyword |
| `Stmt::ClassDecl` | `class` keyword |
| `Stmt::MethodDecl` | `method` keyword |
| `Stmt::Block` | `{` token |
| `Expr::ClassConst` | `__CLASS__` keyword |

In the implementation, `$file` defaults to an empty string on the AST base class and is set by the parser from its `$filename` field. The parser's `_pos_token($token)` helper returns a flat key-value list (`file => ..., line => ..., col => ...`) that merges with other named constructor arguments. The lowerer's `_loc($ast)` helper reads position from AST nodes for error messages.

### 2.16 v0.1 Bootstrapping Subset

The minimum viable Brocken subset needed to write `core.brocken` (the Immix allocator, channel runtime, and GC). Everything outside this subset is either delegated to the Perl host or deferred until after self-hosting.

#### 2.16.1 Variables & Arrays

```perl
my $dynamic_var;              # Any (Fat Scalar) - default
my int $count = 0;            # Native integer (i64 on all current targets)
my Int $age = 30;             # Same as `int` - capitalized alias
my bool $flag = true;         # Native boolean
my Bool $done = false;        # Same as `bool` - capitalized alias
my ptr $cursor;               # Raw pointer
my i32 $slot;                 # 32-bit signed
my u32 $index;                # 32-bit unsigned
my i8 $byte;                  # 8-bit signed
my u8 $flags;                 # 8-bit unsigned
my i64 @arr = [10, 20, 30];   # Fixed-size array
my [int; 10] @arr;            # Fixed-size array declaration
```

Array elements are accessed by index; bounds are not checked yet:

```perl
@arr[0] = 42;                 # Array write (via Assign with ArrayIndex target)
my i64 $x = @arr[1];          # Array read (via ArrayIndex expression)
```

#### 2.16.2 Subroutines

```perl
sub allocate_block(i64 $size) -> ptr {
    my ptr $cursor = $heap_ptr;
    $heap_ptr = Brocken::ptr_add($cursor, $size);
    return $cursor;
}
```

- Parameters are `(TYPE $name, ...)`
- Return type is `-> TYPE`; omitted means void
- Last expression is NOT implicitly returned - must use `return`

Named parameters:

```perl
sub create(i64 $x, i64 $y, :i64 $color = 0) -> ptr { ... }
create(10, 20, color => 0xFF);
```

#### 2.16.3 Control Flow

```perl
if ($x > 0) { ... } elsif ($x == 0) { ... } else { ... }
while ($cursor < $limit) { ... }
foreach my $item (@arr) {
    next if $item < 0;
    last if $item == 100;
    say($item);
}
return $value;
return;   # void return
```

Not in v0.1: `unless`, `until`, statement modifiers.

#### 2.16.4 Classes

```perl
class Point {
    field i64 $x :param;
    field i64 $y :param;

    ADJUST { $x = 10 if $x < 10; }

    method sum() -> i64 {
        return $x + $y;
    }
}
```

Field attributes: `:param` (constructor param), `:reader` (auto-getter), `:writer` (auto-setter), `:default(N)` (default value).

#### 2.16.5 Intrinsics

See §2.7 for the full table of `Brocken::` intrinsics.

#### 2.16.6 Built-in Functions

`say(...)` and `print(...)` - lowered to `write(1)` syscall.

#### 2.16.7 Feature Flags

```perl
use feature 'brocken_native_types';   # enables i128, u128
```

### 2.17 Excluded Features (Deferred from v0.1)

| Feature | Reason |
|---------|--------|
| `%` hashes | Not needed for the runtime; can be built on top later |
| `struct` keyword | Classes serve as structs in v0.1; struct IR types exist in the type system for field access/GEP, but dedicated `struct` syntax is deferred |
| `ref(T)` references | RC decref/scope machinery not yet connected |
| `ptr(T)` typed pointers | Source-level annotation only; lowering is identical to opaque `ptr` |
| `.rodata` strings | String literals currently use stack alloca; `.rodata` section deferred |
| String ops (`eq`, `ne`, `.`, length, etc.) | String *literals* compile as const data; runtime operations are deferred |
| `type` aliases | Purely syntactic; trivial to add post-v0.1 |
| Regex | Deferred entirely |
| `map`/`grep` | Defer until list primitives exist |
| `eval` | Blocks on dynamic codegen |
| `match` | Pattern matching sugar - defer |
| `defer` | Scope guard - defer |
| `try`/`catch` | Defer - unwinding is complex |
| Pod6 | Documentation - defer |
| Multiple dispatch | Not needed |
| Operator overloading | Not needed |
| `unless` / `until` | Inverted conditionals; use `if`/`while` with negation instead |
| Statement modifiers | e.g., `say "hi" if $x` — deferred to post-v0.1 |
| Inheritance | Classes as flat structs only - no `:isa` |

**Implemented features (previously deferred):**

- **`foreach` / `for` loops** — Single-variable, multi-variable, and reference aliasing (§2.4.1)
- **`next` / `last` / `redo`** — Loop control keywords (§2.4.2)
- **Named parameters** — Perl 5.44-style `:name` params with defaults (§2.5.1)
- **`want` / context** — `want(TypeName)` constant-folds, `want('scalar'|'list'|'void')` calls runtime (P3)
- **Shift operators (`<<`, `>>`)** — `>>` token, `PREC_SHIFT` precedence, `build_shl`/`build_ashr`/`build_lshr` lowering
- **Fat comma (`=>`)** — Auto-quotes bareword LHS as `Expr::Const(String)`; used in hash literals and named parameter calls

---

## 3. Compilation Pipeline

The compiler is divided into three major namespaces: **Katsuro** (Frontend & Platform), **Lindsay** (Middle-end IR), and **Jenny** (Backend & Linker).

```
Source Code (Brocken) + core.brocken (Runtime)
    │
    ▼
┌─────────────┐  Katsuro Lexer: characters → tokens
│  Frontend   │  Katsuro Parser: tokens → AST
└─────────────┘
    │
    ▼
┌─────────────┐  Lindsay Lowering: AST → IR
│ Middle-end  │  (Translates Brocken:: pseudo-namespace to raw memory ops)
│             │  Lindsay Optimizer: IR → optimized IR (DCE, Constant Folding)
└─────────────┘
    │
    ▼
┌─────────────┐  Jenny Codegen: IR → MIR (Machine IR)
│  Backend    │  RegAlloc: Linear Scan (with Spill & Caller-Save handling)
│             │  Jenny Lowerer: MIR → Machine Code Bytes
└─────────────┘
    │
    ▼
┌─────────────┐  Jenny Linker: Machine Code → .exe / .elf / .macho / .wasm
│   Format    │  (Resolves labels, computes RVAs, emits DWARF)
└─────────────┘
    │
    ▼
Native Executable
```

### 3.1 Phase 1: Platform Detection (`Brocken::Katsuro::Platform`)

Figures out what OS and CPU we're on (e.g., `x86_64-pc-linux-gnu`) and calculates ABI constraints, syscall numbers, and register sets.

### 3.2 Phase 2: Lexer (`Brocken::Katsuro::Lexer`)

Top-down while-loop tokenizer using regex matching. Turns source text into an array of tokens: `NUM`, `STRING`, `KEYWORD`, `IDENT`, `VAR`, `OP`, and punctuation. Each token carries its source line and column for error reporting.

Tokens already carry `line`/`col` via the `_token()` helper. Error messages include the source filename, line, and column.

### 3.3 Phase 3: Parser (`Brocken::Katsuro::Parser`)

A Pratt Parser (top-down operator precedence) using `nud`/`led` methods that turns tokens into an Abstract Syntax Tree (AST). It recognizes standard Perl logic as well as the Unsafe Native types (`my ptr $x`, `Brocken::load_i64()`) required for the self-hosted runtime.

Every AST node carries `file`, `line`, and `col` from its start token (see §2.15). The parser also passes a `$filename` parameter (default `(eval)`) that propagates to all AST nodes and error messages.

### 3.4 Phase 4: Lowering (`Brocken::Lindsay::Lowering`)

Walks every AST node and emits linear `Brocken::Lindsay::IR` instructions.

- **Runtime Integration:** Parses `core.brocken` and prepends its AST so the runtime compiles directly into the executable.
- **GC Injection:** Injects `incref` operations on assignment and utilizes the Defer Stack to emit `decref` operations at scope exit.
- **Error Reporting:** All `Carp::croak()` calls include source position (`file line L, col C`) via the `_loc($ast)` helper.

### 3.5 Phase 5: Optimization (`Brocken::Lindsay::Optimizer`)

- Constant folding
- Dead code elimination
- Perceus RC elision (planned)

### 3.6 Phase 6: Code Generation (`Brocken::Jenny::Codegen`)

Translates IR to Machine IR (MIR).

- **Register Allocation:** Fixed-Point Liveness Analysis and Linear Scan allocation, handling spills and Caller-Saved registers.
- **Instruction Dispatch:** Maps MIR to raw `x86_64`, `aarch64`, `riscv64`, or `wasm` instruction bytes.

### 3.7 Phase 7: Format & Linker (`Brocken::Jenny::Linker`)

Packages the raw machine code + data into an executable binary (PE, ELF, Mach-O, Wasm). Computes layout offsets, RVAs, cross-function call fixups, and DWARF debug information.

---

## 4. Memory Management & Runtime

Brocken does not link against an external C runtime. The runtime (`libbrocken`) is written in a subset of Brocken itself (`core.brocken`). The Katsuro frontend silently parses this file and combines it with your code during compilation.

### 4.0 Architecture Overview

Memory management is a three-layer system:

```
┌──────────────────────────────────────────────────┐
│  Layer 3: Perceus (Compile-Time Optimization)    │
│  ┌──────────────────────────────────────────────┐│
│  │  RC Elision: cancel redundant incref/decref  ││
│  │  Reuse Analysis: in-place mutation @ RC==1   ││
│  │  Borrow Inference: avoid ownership transfer  ││
│  └──────────────────────────────────────────────┘│
├──────────────────────────────────────────────────┤
│  Layer 2: Bacon/Rajan Trial Deletion (Runtime)   │
│  ┌──────────────────────────────────────────────┐│
│  │  Suspect Buffer in ICB (offsets 48-56)       ││
│  │  Mark → Scan → Collect cycle detection       ││
│  └──────────────────────────────────────────────┘│
├──────────────────────────────────────────────────┤
│  Layer 1: Immediate RC + Immix (Runtime)         │
│  ┌──────────────────────────────────────────────┐│
│  │  incref/decref on fat scalar refcount field  ││
│  │  Immix: 32KB blocks, 256-byte lines, bump    ││
│  │  alloc_line → alloc_block free list          ││
│  └──────────────────────────────────────────────┘│
└──────────────────────────────────────────────────┘
```

**Key invariant:** Because Isolates are share-nothing OS threads, each heap is entirely thread-local. All RC operations, Immix allocation, and trial deletion require **zero atomic locks** - a massive performance advantage over shared-heap GCs.

### 4.1 The `Any` Type (Fat Scalar)

A dynamically typed variable (`my $x;`) is a 16-byte value allocated on the heap (via the Immix allocator). The layout is fixed and verified at compile time:

```
Offset  Size  Field                     Description
0       2     Reference Count (u16)     Max 65535; overflow pins the object forever
2       1     GC Flags (u8)             Bit 0: Cycle Suspect, Bit 1: Buffered, Bit 2: Leaf
3       1     Type Tag (u8)             0=Int, 1=String, 2=Array, 3=Class, 4=Ptr, 5=Dynamic, 6=i128, 7=List
4       4     Padding / Aux (u32)       Reserved (e.g., cached string byte length)
8       8     Payload (u64)             Raw value (i64/u64/f64/ptr - type determines interpretation)
```

The first 8 bytes (refcount + flags + tag + padding) are called the **header word** and are packed into a single `u64` for efficient load/store. The `box` IR instruction stores the header word as a 64-bit zero (all fields initialized to 0) at `[ptr+0]` and the payload at `[ptr+8]`. The `unbox` IR instruction loads the payload from `[ptr+8]`.

#### 4.1.1 Type Tag Encoding

| Tag | Type       |
|-----|------------|
| 0   | Int        |
| 1   | String     |
| 2   | Array      |
| 3   | Class      |
| 4   | Ptr        |
| 5   | Dynamic    |
| 6   | i128       |
| 7   | List       |
| 8   | Hash       |

A **Hash** is a heap-allocated fat scalar (type tag 8). Like List, the payload at `[+8]` is a pointer to a hash data block allocated via `bump_alloc`:

```
Offset  Size  Content
[+0]:    8    Header (tag = 8, refcount, flags)
[+8]:    8    Pointer to hash data block
```

Hash data block layout (pointed to by `[+8]`):

```
[+0]:   8    i64 header = T_HASH << 24   (tag = 8)
[+8]:   8    i64 count                    (number of key-value pairs)
[+16]:  8    ptr key 0                   (String fat scalar pointer)
[+24]:  8    i64 value 0                 (raw value)
[+32]:  8    ptr key 1                   (String fat scalar pointer)
[+40]:  8    i64 value 1
...
```

Total data block size = `16 + count * 16`. Keys are stored as pointers to `String` fat scalars; values are raw i64. Pairs are stored in insertion order. Hash security (collision resistance) is deferred — see §8.1.

A **List** is a heap-allocated fat scalar (type tag 7). Unlike other types, the payload at `[+8]` is not the value itself but a pointer to a list data block allocated via `bump_alloc`:

```
Offset  Size  Content
[+0]:    8    Header (tag = 7, refcount, flags)
[+8]:    8    Pointer to list data block
```

List data block layout (pointed to by `[+8]`):

```
[+0]:   8    i64 header = T_LIST << 24   (tag = 7)
[+8]:   8    i64 count                    (number of elements)
[+16]:  8    i64 element 0               (raw value)
[+24]:  8    i64 element 1
...
```

Total data block size = `16 + count * 8`. Elements are stored as raw i64 values; list variable declarations (`my ($a, $b) = expr`) convert each element to the declared type via `maybe_convert_type` at compile time.

Tags are assigned by `_type_tag()` in each backend's MIR lowerer and stored as `store_imm` at offset 3 of the fat scalar at `box` time.

#### 4.1.2 GC Flags

| Bit | Name     | Meaning                              |
|-----|----------|--------------------------------------|
| 0   | Suspect  | Object may be part of a cycle        |
| 1   | Buffered | Object is in the suspect buffer      |
| 2   | Leaf     | Object has no outgoing references    |
| 3   | BRC_0    | Bacon & Rajan color (low bit)        |
| 4   | BRC_1    | Bacon & Rajan color (high bit)       |

Bacon & Rajan color encoding (see §4.4.2):

| BRC_1 | BRC_0 | Color  | Meaning |
|-------|-------|--------|---------|
| 0     | 0     | White  | Candidate for collection |
| 0     | 1     | Gray   | Reachable, not yet scanned |
| 1     | 0     | Purple | Potentially cyclic (suspect) |
| 1     | 1     | Black  | Reachable and fully scanned |

The color is stored directly in the object header's GC Flags byte, eliminating the need for a separate hash table during trial deletion. This guarantees O(1), cache-friendly color reads/writes because the header is already in the CPU cache after the `decref` load.

#### 4.1.3 Unified Object Header (All RC-Managed Allocations)

Not every heap object is an `Any` fat scalar. Class instances (`Point->new(...)`) and arrays are also managed by RC/Immix. All such allocations share a common 8-byte header so that `incref`/`decref` can operate blindly on any heap pointer without knowing the allocation's concrete type:

```
Offset  Size  Field                     Description
0       2     Reference Count (u16)     Max 65535; overflow pins the object forever
2       1     GC Flags (u8)             See §4.1.2
3       1     Type Tag (u8)             Type discriminator for debug/trace
4       4     Aux Size (u32)            Payload size in bytes (not used by `Any`; see §4.1 padding)
```

The first 8 bytes of EVERY Immix allocation are this header. The layout of the bytes following the header depends on the allocation kind:

- **`Any` fat scalar**: header + 8-byte payload (16 bytes total). Type tag identifies the payload's interpretation.
- **Class instance**: header + struct fields (8 + N bytes total). `new` allocates `8 + total_field_size` bytes.
- **Array**: header + length prefix + element data (8 + 8 + N×elem_size bytes total).

This means `incref(ptr)` and `decref(ptr)` always read/write `refcount` at `[ptr + 0]` regardless of whether `ptr` points to an `Any`, a class instance, or an array.

### 4.2 Reference Counting (Layer 1)

Reference counting is deterministic, immediate, and non-atomic (thread-local heaps).

#### 4.2.1 RC Operations

Implemented in `core.brocken` as `Brocken::Runtime::incref` and `Brocken::Runtime::decref`:

```
incref(ptr):
  refcount = load_u16(ptr + 0)
  if refcount < 65535:
    refcount += 1
    store_u16(ptr + 0, refcount)

decref(ptr):
  refcount = load_u16(ptr + 0)
  refcount -= 1
  store_u16(ptr + 0, refcount)
  if refcount == 0:
    if has DESTROY:
      call DESTROY(ptr)
    add_to_free_list(ptr)            // Immix: mark line as free
  elsif refcount > 0 && !is_leaf(ptr):
    push_suspect_buffer(ptr)         // might be in a cycle (see §4.3)
```

| Condition | Action |
|-----------|--------|
| RC decrements to 0 | Run `DESTROY` (if any), free memory immediately |
| RC > 0 after decrement, not a leaf | Push to suspect buffer (cycle detection) |
| RC overflows (stays at 65535) | Object is pinned; never freed |

#### 4.2.2 RC Injection (Compiler Pass)

The `Lowerer.pm` (frontend) injects `build_incref` / `build_decref` IR instructions:

- **Variable assignment** (`$x = $y`): emit `build_incref($y_val)` before the store
- **Scope exit** (end of block): emit `build_decref($var)` for each local variable that goes out of scope
- **Function return**: emit `build_decref($old_val)` for the return slot's previous binding
- **Implicit `decref` for return values**: the caller gets ownership of the returned value (no decref needed at the call site)

All four MIR lowerers (X86_64, ARM64, RISCV64, Wasm) handle `Incref`/`Decref` IR instructions by emitting `mov arg0, val` + `call_func @Brocken::Runtime::incref` (or `decref`).

#### 4.2.3 `box` Heap Allocation

The `box` IR instruction does not use stack `alloca`. Instead, it calls `Brocken::Runtime::bump_alloc(heap_base, 16)` to allocate the 16-byte fat scalar on the Immix heap. This ensures RC-managed objects live in heap memory that can be freed and reused.

### 4.3 Immix Allocator (Layer 1)

The Immix allocator replaces general-purpose `malloc`. It uses a block/line architecture for bump-pointer allocation with efficient reclamation.

#### 4.3.1 Constants

| Constant     | Value   |
|--------------|---------|
| BLOCK_SIZE   | 32768   |
| LINE_SIZE    | 256     |
| LINES_PER_BLOCK | 128 |
| BLOCK_SIZE = LINES_PER_BLOCK × LINE_SIZE |

#### 4.3.2 Block Structure

Each block is exactly 32768 bytes for fast block-base computation via `ptr & ~0x7FFF`. The 128-bit line bitmap is embedded inside Line 0, which has only 240 usable bytes:

```
Offset  Size    Field
0       32768   Block (exactly 32KB - aligned to 32KB boundary)
```

The first 128 bits (16 bytes) of the block are the line availability bitmap (1 = free, 0 = used). This bitmap overlaps with the **first 16 bytes of Line 0**:

```
Line 0:  [ 16 bytes bitmap header ][ 240 bytes usable data ]
Line 1:  [ 256 bytes usable data ]
...
Line 127: [ 256 bytes usable data ]
```

Total usable data: 240 + 127×256 = 32752 bytes. The bitmap occupies 16 bytes which is only 0.05% of the 32768-byte block.

#### 4.3.3 Allocation Algorithm

```
alloc(size):
  // Round up to 8-byte alignment; minimum 16 bytes (header + 8-byte payload)
  size = align8(max(size, 16))

  // Try bump allocation in current line
  if immix_cursor + size <= immix_limit:
    result = immix_cursor
    immix_cursor += size
    return result

  // Current line is full; try segregated free list (see §4.3.4)
  result = pop_free16_list()
  if result != 0:
    return result

  // Find next free line in current block
  block = block_containing(immix_cursor)
  line_idx = find_next_free_line(block)
  if line_idx is not None:
    mark_line_used(block, line_idx)
    line_start = line_data_start(block, line_idx)
    immix_cursor = line_start + size
    immix_limit = line_start + line_size(line_idx)
    return line_start

  // No free lines in current block; get a new block
  block = alloc_block_from_icb()
  if block is None:
    // Out of memory; request more from OS (future: mmap)
    return 0
  immix_cursor = block + 16 + size    // skip bitmap header, start of Line 0 data
  immix_limit = block + 256           // Line 0 ends at 256 (240 usable + 16 bitmap)
  return block + 16

line_data_start(block, line_idx):
  if line_idx == 0:
    return block + 16                  // skip bitmap header
  return block + line_idx * LINE_SIZE  // lines 1..127: full 256-byte alignment

line_size(line_idx):
  if line_idx == 0:
    return 240                         // line 0: 16 bytes lost to bitmap
  return LINE_SIZE                     // lines 1..127: full 256 bytes
```

#### 4.3.4 Reclamation

Reclamation uses a **two-tier** strategy: segregated free lists for the hot (decref) path, and full Immix tracing as a cold fallback.

##### Tier 1: Segregated Free Lists (Hot Path)

Maintaining per-line live-object counters on every `decref` is too expensive. Instead, when `decref` frees an object (RC reaches 0):

1. Run `DESTROY` if the object has one (it may free its own children, recursively triggering more decrefs).
2. Push the pointer onto the ICB's **16-byte free list** (`free16_head`). This is a singly-linked list threaded through the freed object's own payload area (bytes 8–15 of the freed fat scalar store the `next` pointer).

```c
push_free16_list(ptr):
  next = ICB.free16_head
  store_i64(ptr + 8, next)      // thread list through payload area
  ICB.free16_head = ptr

pop_free16_list():
  head = ICB.free16_head
  if head == 0:
    return 0                     // empty
  ICB.free16_head = load_i64(head + 8)
  return head
```

Because 100% of Immix allocations in the hot path are 16-byte fat scalars (`Any` variables), this single free list handles the vast majority of reclamation. No line bitmap manipulation is needed on the hot path.

##### Tier 2: Immix Tracing (Cold Path)

When `immix_cursor` reaches `immix_limit` and the free list is empty (no recycled 16-byte slots available), the runtime triggers an Immix mark-region trace:

1. **Mark phase**: walk the object graph starting from the roots (ICB's root set), clearing the line bitmap for every live object's line.
2. **Sweep phase**: iterate all lines in the current block. Any line whose bitmap bit is still set is completely empty - reclaim it.
3. **Free list rebuild**: scan the freed lines, building new 16-byte free list entries from each freed fat scalar location.
4. **Block reclamation**: if all 128 lines of a block are empty, return the entire block to the ICB `free_blocks` list instead of rebuilding its free list.

The trace runs incrementally (a few roots per allocation) to avoid long pauses. A full trace runs only when:
- The block is completely marked (all lines used)
- The free list is empty
- No free blocks are available in `free_blocks`

#### 4.3.5 ICB Integration

The Isolate Control Block (see §4.6) holds Immix state:

| ICB Offset | Field           | Role                                  |
|------------|-----------------|---------------------------------------|
| 24         | immix_cursor    | Current bump pointer within line      |
| 32         | immix_limit     | End of current line / block           |
| 40         | free_blocks     | Linked list head of free 32KB blocks  |
| 48         | free16_head     | Head of 16-byte segregated free list  |

### 4.4 Trial Deletion (Layer 2 - Bacon & Rajan)

Standard reference counting cannot collect cyclic garbage. Brocken uses the Bacon & Rajan Trial Deletion algorithm to detect and reclaim cycles.

#### 4.4.1 Suspect Buffer

When `decref` leaves an object with RC > 0 and the object is not a leaf (has outgoing references), the object is a **suspect** - it might be part of an isolated cycle. The runtime pushes the suspect to the ICB's suspect buffer:

```
ICB offset 48: suspect_buffer_head (pointer to ring buffer)
ICB offset 56: suspect_buffer_tail (pointer to ring buffer)
```

The suspect buffer is a fixed-size ring buffer. When it reaches capacity, draining triggers automatically.

#### 4.4.2 Trial Deletion Algorithm (Per-Suspect)

Color is stored in the **GC Flags** byte (bits 3–4, see §4.1.2), eliminating the need for an external hash table. Each object carries its own Bacon & Rajan color in its cache-friendly header.

For each suspect in the buffer:

1. **Mark (Purple → Gray → White)**: set the suspect's BRC flags to Gray. Recursively traverse outgoing references, decrementing RC counts and marking reachable nodes:
   - If descendants have RC > 0 after decrement, mark them Gray and recurse
   - If descendants have RC == 0, they are not part of a cycle; mark them White
2. **Scan (Gray → Black)**: for each Gray node, trace outgoing references and increment their RC back. Mark the node Black.
3. **Collect**: nodes still marked Gray or White after scanning are confirmed cyclic garbage:
   - Set their RC to 0
   - Run `DESTROY`
   - Push to the segregated free list (see §4.3.4)
4. **Restore**: nodes marked Black are not garbage - reset their BRC flags to Purple (return to suspect state if still referenced) or White (if no longer a suspect).

The algorithm runs incrementally (a few suspects per allocation) to avoid long pauses. The full drain runs only when the suspect buffer is full.

#### 4.4.3 Leaf Optimization

Objects flagged as `Leaf` (GC Flag bit 2) have no outgoing references and cannot be part of a cycle. They are never pushed to the suspect buffer, saving buffer space and scan time. The compiler sets the Leaf flag when:
- The object's type is `Int` (no references)
- The object's type is immutable and contains no reference fields
- After `DESTROY` runs, the object is implicitly a leaf

### 4.5 Perceus Optimization (Layer 3 - Compile-Time)

Perceus is a set of Lindsay IR optimization passes that make RC more efficient. It operates entirely at compile time with zero runtime overhead.

#### 4.5.1 RC Elision

Cancels redundant `incref`/`decref` pairs:

```perl
# Without elision:
my $y = $x;     # incref $x  (new reference)
...             # ...
                # decref $y  ($y goes out of scope)
                # decref $x  ($x goes out of scope)

# With elision:
my $y = $x;     # no-op: $x and $y are never aliased
```

The optimizer analyzes value liveness and reference graph to determine when an incref is immediately followed by a decref on the same object with no intervening aliasing operations.

#### 4.5.2 Reuse Analysis (FBIP)

When a function constructs a new heap object from an existing one, and the input is uniquely owned (RC == 1), Perceus rewrites the allocation as an in-place mutation:

```perl
# Without reuse:
sub increment_all(@arr) {
    my @result = [];            # allocate new array
    for my $i (0..@arr) {
        @result[$i] = @arr[$i] + 1;
    }
    return @result;
}

# With reuse (when @arr is uniquely owned):
sub increment_all(@arr) {
    for my $i (0..@arr) {
        @arr[$i] = @arr[$i] + 1;   # mutate in place
    }
    return @arr;
}
```

The optimizer:
1. Detects that the input array is consumed (its RC drops to 0 after the call completes)
2. Detects that the output array has the same shape and size
3. Rewrites to mutate the input directly, eliminating the allocation

#### 4.5.3 Borrow Inference

Analyzes function signatures to determine which parameters are borrowed (no ownership transfer) vs owned (callee takes ownership). This reduces unnecessary RC operations at call sites:

```perl
sub print_array(@arr) {       # @arr is borrowed
    for my $i (0..@arr) {
        say(@arr[$i]);
    }
}
# No incref/decref at the call site - @arr stays owned by the caller
```

The inference is conservative: if the callee stores the parameter (escaping it), ownership is transferred. Otherwise, the parameter is borrowed.

### 4.6 Allocation (Legacy / Transition)

During the transition from stack-based allocation to full Immix, the following scheme applies:

- **Stack (`alloca`):** Local native-type variables, fiber stacks (64KB), isolate stacks (64KB) remain on the stack.
- **Heap (Immix):** All `box`ed fat scalars, class instances, arrays, and dynamic values are allocated on the Immix heap via `bump_alloc` / `immix_alloc`.
- **ICB fields:** `heap_cursor` (offset 0) is the legacy simple-bump cursor; `immix_cursor`/`immix_limit`/`free_blocks` (offsets 24-40) are the Immix allocator state.

Once the Immix allocator is fully deployed, `heap_cursor` is no longer used and `_init` initializes only the Immix fields.

### 4.6 Isolate Control Block (ICB)

An Isolate is an OS thread. Its control block is a 64-byte struct pinned to a dedicated register:

| Arch | Register |
|------|----------|
| X86_64 | `r14` |
| ARM64 | `x28` |
| RISCV64 | `s11` |

```
Offset  Size    Field
0       8       heap_cursor / state_ptr
8       8       current_fcb (Active Fiber Control Block)
16      8       fiber_head (Head of fiber linked list)
24      8       immix_cursor (Current bump-allocation pointer)
32      8       immix_limit (End of current Immix block)
40      8       free_blocks (Free 32KB block list)
48      8       free16_head  (Head of 16-byte segregated free list)
56      8       suspect_buffer_head / free16_tail
```

The `free16_head` field (offset 48) replaces the original `suspect_buffer_head`. The suspect buffer now shares offset 56 with the free list tail (they are never needed simultaneously: the free list is operated during the Immix cold trace, the suspect buffer during normal RC execution).

Only `heap_cursor` (offset 0) is currently initialized by `_init`. The Immix fields (offsets 24–48) and suspect buffer (offset 56) are initialized lazily during the first allocation that requires them.

Fiber stacks are currently unprotected - deep recursion overflows silently into adjacent memory. A future Lindsay IR pass will inject a **stack probe** at every non-leaf function prologue, comparing `rsp` (or the arch equivalent) against a limit field in the FCB. On overflow, the runtime throws a catchable `Brocken::Exception::StackOverflow` instead of corrupting memory.

### 4.7 Fiber Control Block (FCB)

Fibers are M:N cooperative coroutines. Each has a 64KB or 128KB machine stack and a Fiber Control Block holding saved callee registers.

#### X86_64 FCB (80 bytes, fiber register: `r12`)

| Offset | Field | Notes |
|--------|-------|-------|
| 0 | `rbx` | Callee-save |
| 8 | `rbp` | Callee-save |
| 16 | `self` | FCB pointer. Skip restore during ctx_swap |
| 24 | `r13` | Callee-save |
| 32 | `r14` | Callee-save (ICB reg) |
| 40 | `r15` | Callee-save |
| 48 | `saved_rsp` | Stack pointer |
| 56 | `parent` | Yielder/receiver FCB |
| 64 | `resume_pc` | Resume address |
| 72 | `os_thread` | ICB pointer |

#### ARM64 FCB (128 bytes, fiber register: `x28`)

| Offset | Field | Notes |
|--------|-------|-------|
| 0–88 | `x19`–`x30` | 12 callee-save regs |
| 96 | `saved_sp` | Stack pointer |
| 104 | `parent` | Yielder/receiver FCB |
| 112 | `resume_pc` | Resume address |
| 120 | `os_thread` | ICB pointer |

#### RISCV64 FCB (136 bytes, fiber register: `s11`)

| Offset | Field | Notes |
|--------|-------|-------|
| 0–96 | `s0`–`ra` | 13 callee-save regs |
| 104 | `saved_sp` | Stack pointer |
| 112 | `parent` | Yielder/receiver FCB |
| 120 | `resume_pc` | Resume address |
| 128 | `os_thread` | ICB pointer |

### 4.8 The `ctx_swap` Mechanism

Three operations use context switching:

1. **Fiber transfer** - save current FCB, load target FCB, branch to resume_pc.
2. **Fiber yield** - save current FCB, load `parent` FCB.
3. **Isolate trampoline** - entry point called by `pthread_create` on a new OS thread. Loads FCB from arg struct, sets fiber register, loads args, `call_indirect` to the user function.

### 4.9 The Unsafe Subset (Self-Hosting)

To write the Immix Allocator and RC engine in Brocken, we must bypass the Fat Scalar overhead. The Katsuro frontend exposes Native Types and the `Brocken::` pseudo-namespace:

```perl
# src/runtime/gc.brocken
package Brocken::Runtime::Immix {
    use feature 'brocken_native_types';

    sub allocate_raw( i64 $size ) : NativeReturn(ptr) {
        my ptr $cursor = $Brocken::Runtime::immix_cursor;
        my ptr $next   = Brocken::ptr_add($cursor, $size);

        if (Brocken::ptr_cmp_gt($next, $Brocken::Runtime::immix_limit)) {
            return gc_alloc_slow($size);
        }

        $Brocken::Runtime::immix_cursor = $next;
        return $cursor;
    }
}
```

Calls to the `Brocken::` namespace do not compile to function calls; they are lowered directly to raw machine instructions.

---

## 5. Concurrency

### 5.1 Isolates (OS Threads)

Brocken implements concurrency via OS-level Isolates. Because an Isolate shares absolutely no memory with other Isolates, the heap is completely thread-local. This means garbage collection and reference counting require zero atomic locks.

| IR Instruction | Lowering |
|----------------|----------|
| `isolate_create` | alloca FCB + ICB + arg struct, `pthread_create` / `CreateThread` |
| `isolate_join` | `pthread_join` / `WaitForSingleObject` + `GetExitCodeThread` + `CloseHandle` |

**Wasm:** Both are stubs (return `i64_const 0`). Thread creation is not supported in Wasm MVP.

### 5.2 Fibers (Green Threads)

| IR Instruction | Lowering |
|----------------|----------|
| `fiber_create` | alloca FCB + 64KB stack, init fields, `lea_func` entry |
| `fiber_transfer` | `ctx_swap` MIR |
| `fiber_yield` | load parent from FCB, `ctx_swap` MIR |
| `fiber_id` | mov fiber register to output |
| `fiber_pin` | `sched_setaffinity` / `SetThreadAffinityMask` |

### 5.3 Channels (Cross-Isolate Communication)

Channels provide CSP-style communication between Isolates (and Fibers). They are bounded ring buffers protected by a mutex + condition variable. Values sent are currently limited to `i64`; transferable objects (fat scalars with RC ownership transfer) are future work.

**Future: Transferable Objects.** Because Isolate heaps are thread-local, passing heap pointers across channels would let one Isolate free another's memory. Two approaches are planned (§12.3):
1. **Deep copy**: serialize the object graph into the receiver's heap. Safe but slow.
2. **Zero-copy ownership transfer**: allocate transferable objects in a global, lock-managed heap (e.g., `mmap`'d shared pages). Perceus guarantees `RC == 1` for sent objects, so ownership transfers cleanly without copying. The receiver's `decref` must recognize global-heap pointers and use a different free path.

#### 5.3.1 Channel Data Structure

```c
struct Channel {
    uint32_t capacity;     // Max elements
    uint32_t count;        // Current elements
    uint32_t head;         // Dequeue index
    uint32_t tail;         // Enqueue index
    uint32_t closed;       // 1 if closed
    int64_t  buffer[];     // Ring buffer: capacity * 8 bytes
};
```

The global table lives in the `.data` section of the executable. On Unix, mutex+condvar are initialized to static initializers. On Windows, SRWLOCK and CONDITION_VARIABLE are initialized at startup.

#### 5.3.2 IR Instructions

| Instruction | Signature | Semantics |
|-------------|-----------|-----------|
| `chan_create` | `%ch = chan_create $capacity` | Allocate channel, return handle |
| `chan_send` | `chan_send %ch, %val` | Send (blocks if full) |
| `chan_recv` | `%val = chan_recv %ch` | Receive (blocks if empty) |
| `chan_close` | `chan_close %ch` | Close and broadcast |
| `chan_try_send` | `%ok = chan_try_send %ch, %val` | Non-blocking send |
| `chan_try_recv` | `%val, %ok = chan_try_recv %ch` | Non-blocking recv |

A channel handle is an `i64` value: `(index << 32) | generation`. A handle of 0 is invalid (reserved for allocation failure).

On Wasm, all channel operations are stubs (no-op or return 0).

#### 5.3.3 Linker Imports

**ELF64 (+ MachO):** `pthread_mutex_lock`, `pthread_mutex_unlock`, `pthread_cond_wait`, `pthread_cond_signal`, `pthread_cond_broadcast`

**PE (Windows):** `InitializeSRWLock`, `AcquireSRWLockExclusive`, `ReleaseSRWLockExclusive`, `InitializeConditionVariable`, `SleepConditionVariableSRW`, `WakeConditionVariable`, `WakeAllConditionVariable`

---

## 6. Code Generation & Backends (Jenny)

The backend pipeline consists of three layers:
- `Brocken::Jenny::Codegen` - Orchestrates lowering, register allocation, and encoding.
- `Brocken::Jenny::Lowerer` - Lowers Lindsay IR to Machine IR (MIR) for a specific target.
- `Brocken::Jenny::RegAlloc` - Linear scan register allocator.

### 6.1 Intermediate Representation (Lindsay IR)

Each instruction is an object with an `opcode`, `type`, `dest`, and `operands`.

#### Memory & GC Lifecycle
- `incref` / `decref` - Reference count operations
- `alloca` - Stack memory allocation
- `load` / `store` - Memory read/write
- `store_imm` - Store immediate directly to memory
- `getelementptr` - Compute memory address (base + index * scale + disp)

#### Control Flow
- `label` - Code location marker
- `jmp` - Unconditional jump
- `cond_br` - Conditional branch
- `call` - Call a function (handles arguments via ABI registers)
- `ret` - Return from a function

#### Arithmetic / Logic
- `add`, `sub`, `mul`, `div`, `rem` - Integer math
- `fadd`, `fsub`, `fmul`, `fdiv` - Floating-point math
- `and`, `or`, `xor`, `shl`, `lshr`, `ashr` - Bitwise operations
- `icmp` - Integer comparisons (`eq`, `ne`, `slt`, `ult`, etc.)

#### Fat Scalars
- `box` - Wraps a native type into a 16-byte dynamic Fat Scalar
- `unbox` - Extracts a native type from a Fat Scalar

### 6.2 Register Allocator (`Jenny::RegAlloc`)

Linear Scan algorithm directly on the MIR:

1. **Liveness Analysis:** Fixed-point backward dataflow to determine exact live ranges (aware of CFG branches/loops).
2. **Allocation:** Iterates over live intervals, assigning available physical registers.
3. **Spilling:** If out of registers, spills the interval with the furthest end point to a local stack slot, inserting `load`/`store` operations.
4. **Caller-Save Insertion:** Wraps function calls with saves/restores for active caller-saved registers.

The register pool is fetched dynamically via `Brocken::Katsuro::Platform::ABI`.

### 6.3 Target Lowerers

| Target | Characteristics |
|--------|-----------------|
| **X86_64** | Complex addressing modes (SIB). Handles `umulh` and `div` mapping to RDX/RAX logic. |
| **ARM64** | Pure RISC load/store architecture. |
| **RISCV64** | Standard 32-bit/64-bit integer extensions. |
| **Wasm** | Converts linear IR into stack-machine format, emitting `local_get`/`local_set`. |

### 6.4 Adding a New Architecture

1. Create `Brocken::Katsuro::Platform::ABI::YourArch.pm` - register mapping and calling conventions.
2. Create `Brocken::Jenny::Lowerer::YourArch.pm` - map Lindsay IR to MIR.
3. Create `Brocken::Jenny::Codegen::YourArch.pm` - encode MIR to raw machine bytes.

---

## 7. Debug Information

Brocken emits DWARF v5 debug information in PE and ELF binaries for GDB/LLDB
source-level debugging. Debug data is generated by `Brocken::Jenny::Linker::DWARF`,
assembled during codegen via `build_debug_data` on each backend, and linked into
the final binary by the PE/ELF/Mach-O linker.

### 7.1 Enabled Debug Sections

| Section | Purpose |
|---------|---------|
| `.debug_line` | Machine-code offset → source line/column mapping |
| `.debug_info` | Compile unit, subprograms, base types, struct types, variables |
| `.debug_abbrev` | DIE tag/attribute declarations (ULEB128-encoded) |
| `.debug_frame` | Call frame information (CFA = RSP + 8) |
| `.debug_aranges` | Address range table for fast debug info lookup |
| `.debug_names` | DWARF v5 accelerated access index |
| `.debug_str` | String pool for DIE name attributes |

### 7.2 Source Location Pipeline

1. **IR Level:** Every `Brocken::Lindsay::IR::Instruction` subclass carries
   `$line` and `$col` fields (default 0). The IR `Builder`'s `build_*` methods
   accept optional `$line, $col` parameters.

2. **Lowerer:** `Brocken::Katsuro::Lowerer` passes `$ast->line, $ast->col`
   through to each `build_*` call, linking AST source positions to IR instructions.

3. **MIR Level:** Each `MachineInstruction` (`Brocken::Jenny::MIR`) records
   `$ir_inst_idx` - the index of the originating IR instruction. All four
   lowerers (X86_64, ARM64, RISCV64, Wasm) tag MIR instructions during lowering.

4. **Encoding:** Each encoder accepts a `$source_map` hashref and records
   `ir_inst_idx ⇒ byte_offset` during encoding (first MIR instruction per IR
   instruction wins). The `source_map` is stored in the encoder result blob.

5. **DWARF Assembly:** `build_debug_data` in each backend uses `source_map`
   entries for per-instruction byte-offset precision in `.debug_line`.
   Functions whose name starts with `Brocken::Runtime::` (runtime helpers) are
   attributed to `<runtime>` as their source file; user functions use the
   compiled source file.

### 7.3 Variable Debug Info

Every `alloca` instruction for a user-visible variable gets:
- `debug_name` - source variable name (e.g., `x`, `y`, `z`)
- `debug_type_name` - source type name (e.g., `Int`, `ptr`, `Point`)

These fields are set by `Brocken::Katsuro::Lowerer` during variable declaration
lowering. Parameters are tagged similarly. Each variable/parameter DIE carries:
- `DW_AT_name` - variable name
- `DW_AT_type` - reference to base type or struct type DIE
- `DW_AT_location` - DW_OP_fbreg offset (stack slot)
- `DW_AT_decl_file` - source file index
- `DW_AT_decl_line` - source line (DW_FORM_data2, 16-bit)
- `DW_AT_decl_column` - source column (DW_FORM_data1, 8-bit)
- `DW_AT_artificial` - 0 for user variables, 1 for compiler-generated temps

### 7.4 Struct/Class Type DIEs

When `class_info` is provided (from `$module->class_info`), `.debug_info`
emits `DW_TAG_structure_type` DIEs with `DW_TAG_member` children:

```
DW_TAG_structure_type
  DW_AT_name: "Point"
  DW_TAG_member
    DW_AT_name: "x"
    DW_AT_type: → Int base type
    DW_AT_data_member_location: 0
  DW_TAG_member
    DW_AT_name: "y"
    DW_AT_type: → Int base type
    DW_AT_data_member_location: 8
```

The `class_info` hash is produced by `Brocken::Katsuro::Lowerer` during class
registration and attached to the IR `Module` via `set_class_info`.

### 7.5 Subprogram DIEs

Every function (including `_BROCKEN_ENTRY`) gets a `DW_TAG_subprogram` with:
- `DW_AT_name` - function name
- `DW_AT_linkage_name` - same as name (no C++ mangling)
- `DW_AT_low_pc` / `DW_AT_high_pc` - code range
- `DW_AT_decl_file` - source file index

### 7.6 Compile Unit DIE

The root `DW_TAG_compile_unit` carries:
- `DW_AT_producer` - `"Brocken v0.1"`
- `DW_AT_language` - `DW_LANG_C` (13)
- `DW_AT_name` - source file name
- `DW_AT_comp_dir` - `"."`
- `DW_AT_stmt_list` - offset to `.debug_line`
- `DW_AT_low_pc` / `DW_AT_high_pc` - address range

### 7.7 Addresses

DWARF addresses are absolute virtual addresses (e.g., `0x140001000` for PE).
The `$text_base` parameter adjusts for the platform's image base:
- PE (Windows): `0x140001000`
- ELF (Linux, static): `0x400000`
- ELF (Linux, PIE) / Mach-O: `0`

### 7.8 PE-Specific Details

On Windows PE, GDB uses the COFF symbol table for breakpoint resolution by
function name. Without COFF symbols, GDB can still list functions via
`info functions` (which reads DWARF partial symbol tables) but cannot set
breakpoints with `break <function>`. The PE linker's long section name string
table (for `.debug_line`, `.debug_info`, etc.) shares the COFF string table
location at the end of the file.

### 7.9 GDB Usage

```bash
# Linux (break from DWARF works)
gdb -readnow -ex "break source.brocken:9" -ex run -ex bt ./brocken_out

# Windows (use address or info functions)
gdb -readnow -ex "info functions" ./brocken_out.exe
```

### 7.10 Section Layout

**PE (Windows) with debug:** `.text`, `.data`, `.idata`, `.reloc`,
`.debug_line`, `.debug_info`, `.debug_abbrev`, `.debug_frame`,
`.debug_aranges`, `.debug_names`, `.debug_str` plus PE `.pdata`/`.xdata`

**ELF (Linux) with debug:** `.text`, `.data`, `.debug_line`, `.debug_info`,
`.debug_abbrev`, `.debug_frame`, `.debug_aranges`, `.debug_names`, `.debug_str`

---

## 8. Ecosystem & Tooling (Planned)

### 8.1 The `bkn` CLI (Planned)

A unified command-line tool for the entire Brocken workflow (currently the compiler is invoked as `perl brocken.pl`):

| Command | Purpose |
|---------|---------|
| `bkn build` | Compile source to binary (ELF/PE/Mach-O/Wasm) |
| `bkn test` | Run tests in TAP mode |
| `bkn doc` | Extract Pod6 docs |
| `bkn run` | Compile + execute immediately |
| `bkn fmt` | Auto-format source code |
| `bkn deps` | Dependency management |
| `bkn new` | Scaffold a new project |

The CLI will be implemented in Brocken itself (self-hosting once the frontend matures).

### 8.2 Reproducible Builds & Dependency Management (Planned)

Dependencies will be tracked via a project-local `brocken.lock` file (JSON).
- Global cache at `~/.brocken/cache/`, keyed by content hash.
- Project lock pins exact versions and hashes for all transitive dependencies.
- No system-wide install. Each project is self-contained.
- `bkn deps vendor` copies locked deps into `vendor/` for air-gapped builds.

### 8.3 Sandboxed Build Scripts (Planned)

`build.bkn` scripts execute inside a Wasm-based capability sandbox with restricted filesystem, network, and syscall access.

### 8.4 Code Formatting (`bkn fmt`) (Planned)

Built-in formatter with no configuration options (opinionated, one true style):
- 4-space indentation, no tabs
- K&R brace style
- Spaces around binary operators
- No trailing whitespace
- One blank line between top-level definitions

The formatter operates on the AST, not text - it always produces valid code and never changes semantics.

### 8.5 Native Unit Testing (Planned)

Running `bkn --test file.brocken` will produce TAP output.

| Directive | Signature | Behaviour |
|-----------|-----------|-----------|
| `plan` | `plan(Int)` | Declares expected test count |
| `ok` | `ok(Bool, Str)` | Passes if true |
| `is` | `is($a, $b, Str)` | Passes if `$a eq $b` or `$a == $b` |
| `isa_ok` | `isa_ok($obj, Str)` | Passes if object matches type |
| `fail` | `fail(Str)` | Unconditional failure |
| `subtest` | `subtest(Str, Sub)` | Groups tests under a named block |
| `todo` | `todo(Str)` | Marks a test as expected to fail |
| `skip` | `skip(Str)` | Bypasses a test block entirely |
| `dies` | `dies(Sub)` | Passes if the block throws |
| `bail` | `bail(Str)` | Aborts the entire suite |

---

## 9. Security & Sandboxing

### 9.1 ICB-Pinned Sandboxing

Because the ICB is pinned to a hardware register (`r14`/`x28`/`s11`), sandbox state checks are a single load + test - no memory indirection penalty.

### 9.2 Fuel Injection (Planned)

Fuel is an `i64` at ICB offset 0x30. The compiler inserts fuel decrement instructions at loop back-edges and function entries. When fuel reaches 0, a hard abort is triggered. *Not yet implemented.*

### 9.3 Capability Masking (Planned)

A `capabilities` bitmask at ICB offset 0x48 is checked before syscall intrinsics. Bits: `CAP_FS_READ`, `CAP_FS_WRITE`, `CAP_NET`, etc. *Not yet implemented.*

### 9.4 Host Bindings

The planned `bind` API:
1. Guest calls a Gate Function
2. Arguments are deep-copied from Guest's Immix heap to Host's heap
3. ICB register is swapped to Host ICB
4. Host closure executes
5. Return value is deep-copied back

---

## 10. Extending Brocken

### 10.1 Adding New Keywords

Walkthrough using `defer` as an example:

1. **Lexer:** Add `defer` to `%KEYWORDS` in `Brocken::Katsuro::Lexer`.
2. **AST:** Add a new AST node class:
   ```perl
   class Brocken::Katsuro::AST::Stmt::Defer : isa(Brocken::Katsuro::AST::Node) {
       field $block : param : reader;
   }
   ```
3. **Parser:** Register a handler in `%STMT_HANDLERS` in `Parser.pm`:
   ```perl
   method _parse_defer() {
       $self->advance();
       my $block = $self->_parse_block_stmt();
       return Brocken::Katsuro::AST::Stmt::Defer->new( block => $block );
   }
   ```
4. **Lowering:** Add the defer stack logic to `Lowering.pm`.

### 10.2 Adding an IR Instruction

1. Pick a descriptive name (`incref`, `load_field`).
2. Emit it from Lowering: `$builder->emit( 'incref', 'void', [ $val ] );`
3. Add an `elsif` branch to `emit_op` in each `Jenny::Lowerer::*` module to map it to MIR.

### 10.3 The Self-Hosted Standard Library

The Brocken runtime (`libbrocken`) is written in Brocken, compiled from `src/runtime/core.brocken`. Modifying the GC or runtime means editing this file using the Unsafe/Native subset of the language.

---

## 11. Design Decisions & Alternatives

### 11.1 Shared Memory + Atomics (Rejected)

Using shared mutable memory with atomic operations for cross-isolate communication. Rejected because:
- Violates the share-nothing safety model
- Requires lock-free data structures for correctness
- No clear path to transferable objects with RC
- Wasm threads proposal is not yet stable

### 11.2 Actor Model / Mailboxes (Rejected)

Each Isolate has a mailbox; only the owner can receive. Rejected because:
- Channels are more composable (select over multiple sources, fan-out)
- Channels provide natural backpressure (bounded capacity)
- Multiple receivers are useful for worker pools

### 11.3 Rust-style `mpsc` Channels (Rejected)

Single-consumer channels are simpler but less flexible. Rejected in favor of multiple receivers (worker pools, broadcast patterns).

### 11.4 Wasmtime-fiber for Isolates (Rejected)

Using `wasmtime_fiber::Fiber` for cooperative isolation was considered but rejected because:
- Fibers don't provide parallelism
- Blurs the fiber/isolate abstraction
- Would require significant Wasmtime embedding code

### 11.5 Key Implementation Decisions

- **`$file` on AST base class:** Default empty string; set by parser from `$filename` field; used only in error formatting.
- **Concatenation over interpolation in lowerer errors:** `. $ast->name .` avoids double-quote stringification of the AST object.
- **`_pos_token($token)` returns flat key-value list** so it merges with other named constructor args: `Node->new($self->_pos_token($t), ...)`.
- **`_loc($token)` for parser, `_loc($ast)` for lowerer:** Separate helpers for different input types.
- **VarDecl position from `$var_token`, not `my`:** The variable name token provides the more useful location for error reporting.

---

## 12. TODO / Future Work

### 12.1 Immediate

- Immix Bump Allocator: 32KB blocks, 256-byte lines, line marking + reclamation
- Perceus RC Elision: Static analysis to cancel redundant incref/decref pairs
- Frontend (Katsuro Parser): Lexer + Pratt parser + AST (status: done)
- AST→Lindsay IR Lowerer (status: in progress)
- String support / dynamic (boxed) types

### 12.2 Short-term

- Context Tag (`__context_tag`): Hidden register argument for dynamic context dispatch
- Fuel System: Fuel counter in ICB, decrement on loops/calls, hard abort at 0
- SIMD Vectorization: `vload`/`vstore` IR, AVX/NEON lowering
- `match` / `defer` / `try/catch` lowering in Lindsay IR
- BrockenIO: Layered stream VTable system

### 12.3 Long-term

- Transferable Objects: RC ownership move across channels (instead of deep copy)
- Wasm Isolate/Channel: Real implementation when threads proposal stabilizes
- Self-Hosting: Compile the Brocken compiler with Brocken

### 12.4 Version History

| Milestone | Target | Status |
|-----------|--------|--------|
| Lindsay IR + Jenny MIR | - | ✅ |
| X86_64 codegen + linker | - | ✅ |
| ARM64 codegen + linker | - | ✅ |
| RISCV64 codegen + linker | - | ✅ |
| Wasm codegen + linker | - | ✅ |
| Regalloc + spilling | - | ✅ |
| Fibers + ctx_swap | - | ✅ |
| i128 arithmetic | - | ✅ |
| Isolates (pthread/CreateThread) | - | ✅ |
| Channels (IR, lower stubs, linker imports) | - | ✅ |
| Frontend (Katsuro v0.1) - Lexer + Parser + AST + Compiler | - | ✅ |
| Source location tracking (file/line/col) in AST + errors | - | ✅ |
| Lexer filename in errors | - | ✅ |
| Shift operators (`<<`/`>>`) | - | ✅ |
| Struct types at IR level (`struct` kind on Type, struct GEP) | - | ✅ |
| DWARF v5 debug info (line/col, variable DIEs, struct DIEs) | - | ✅ |
| Per-instruction byte offset tracking in DWARF | - | ✅ |
| GDB backtrace testing with DWARF | - | ✅ |
| Channels (data + native lower) | Post-frontend | ⏸ |
| Immix allocator + ICB expansion | Post-frontend | 📝 |
| Perceus RC elision | After allocator | 📝 |
| AST→Lindsay IR Lowerer | - | ✅ |
| Self-hosting bootstrap | Q4 2026 | 📝 |
| Transferable objects | After allocator + RC | 📝 |
| SIMD auto-vectorization | Future | 📝 |
| Wasm threading | Spec dependent | 🔮 |

### 12.5 Open Issues

1. **Parsing Perl's Grammar AOT:** Perl prototypes alter subsequent parsing rules. Resolution: enforce a strict multi-pass analysis or slight syntactic strictness.

2. **Cross-Isolate Deep Copies:** When sending a complex dynamic object over a channel, do we deep-copy the entire tree or enforce reference capabilities for zero-copy? Resolution deferred until transferable objects are implemented.

3. **Channel Slot Reuse:** The global channel table with generation counters prevents use-after-free but doesn't handle the case where a channel is closed and its slots must be drained before the slot can be recycled. Resolution: add a `drained` flag set when `count == 0 && closed`.

4. **Channel Table Size:** 256 channels × 256 slots × 8 bytes = 512KB for the data alone. Acceptable for v1 but may need dynamic allocation in the future.

---

## 13. Security Considerations

### 13.1 Hash Collision Resistance

Brocken V1 uses a simple linear-probe hash table that stores keys in insertion order. This is **not** secure against hash-collision denial-of-service attacks. An attacker who can control hash keys (e.g., via a web form or untrusted input) could force worst-case O(n) lookups by constructing many keys that collide under the identity hash.

**V2 plan:** Replace the identity hash with **SipHash-2-4**, keyed with a per-process random seed:

- SipHash-2-4 is a cryptographically keyed hash function optimized for short inputs (hash-table keys).
- Per-process seed generated at process startup via OS CSPRNG (see §13.2).
- Key is stored in the Isolate Control Block (ICB) at offset `hb+136`, initialized once by `_init`.
- Hash function is an intrinsic (`siphash(key_str, seed) → i64`), lowered to a small inline sequence or a helper call.
- Fixed overhead: ~1–2 cycles per byte on modern CPUs (negligible for typical hash-table workloads).

Open questions for V2:

1. **Rehashing strategy:** Do we expose rehash to user code or handle transparently when load factor exceeds threshold?
2. **Iteration order:** Linear-probe insertion order vs. sorted order. V1 uses insertion order; V2 may need to preserve this guarantee to match Perl semantics.
3. **Seed rotation:** Should the hash seed rotate periodically for long-running server processes? (Not recommended — would invalidate all in-flight hash tables.)

### 13.2 CSPRNG (Cryptographically Secure Pseudorandom Number Generator)

Brocken needs a `secure_rand()` / `srand()` facility for security-sensitive applications (session tokens, cryptographic nonces, hash seeds). V1 uses the OS syscall directly; V2 will add a built-in ChaCha20-based CSPRNG.

**V1 approach (via `libc` intrinsic):**

| OS | Syscall | Returns |
|----|---------|---------|
| Linux | `getrandom(buf, len, flags)` (syscall 318) | Bytes written (or error) |
| Windows | `BCryptGenRandom(NULL, buf, len, BCRYPT_USE_SYSTEM_PREFERRED_RNG)` | STATUS_SUCCESS |
| macOS/BSD | `getentropy(buf, len)` | 0 on success |

Usage from Brocken code:

```
libc("getrandom", buf, 32, 0);             # Linux
libc("BCryptGenRandom", 0, buf, 32, 0x00000002);  # Windows
```

**V2 plan — Built-in CSPRNG (ChaCha20):**

```
hb+136:  32 bytes  seed (from OS at init time)
hb+168:  64 bytes  ChaCha20 state (4×16 words)
hb+232:  i64       byte counter (total bytes generated from current seed)
```

- On first call to `secure_rand(buf, len)`, seed ChaCha20 with the OS-provided seed and a block counter of 0.
- On subsequent calls, generate keystream blocks, XOR with output buffer, advance counter.
- Re-seed after every 2^32 bytes (or on explicit user request) to prevent state compromise.
- Exposed as `Brocken::Runtime::secure_rand` in `core.brocken`.

Benefits over raw syscall:

- **Performance:** No syscall overhead per random byte. ChaCha20 generates ~3 GB/s on modern hardware.
- **Portability:** Single implementation across all targets.
- **Determinism (optional):** For testing, the seed can be set to a known value via an undocumented flag.

### 13.3 Bind Gate Security

The bind gate (see §7) prevents guest code from forging gate IDs or escaping the heap:

- **Gate ID validation:** The trampoline validates that the gate ID is within the table bounds and that the guest has the required capability bitmask set.
- **Isolate pointer restoration:** Before entering any bound function, `r14` (the Isolate pointer) is restored to the guest's ICB, preventing host memory access.
- **Stack guard:** A guard page is placed below the guest stack to catch runaway recursion.

---

## 14. Glossary

| Term | Definition |
|------|------------|
| **Isolate** | An OS thread with its own independent heap and GC. No shared mutable state between isolates. |
| **Fiber** | A cooperative green thread within an isolate. Fibers share the isolate's heap and are scheduled via explicit `ctx_swap`. |
| **FCB** | Fiber Control Block - per-fiber struct holding saved callee registers, stack pointer, resume PC, and metadata. |
| **ICB** | Isolate Control Block - per-isolate struct pinned to a dedicated register (r14/x28/s11). |
| **CCB** | Channel Control Block - shared ring buffer with mutex/condvar for cross-isolate message passing. |
| **Fat Scalar** | 16-byte dynamic value representation: refcount + gc_flags + type_tag + aux_data + payload. |
| **Immix** | Bump-pointer allocator using 32KB blocks divided into 256-byte lines. Mark-region tracing for cycle collection. |
| **Perceus** | Compile-time RC optimization that cancels redundant incref/decref pairs and enables in-place mutation when refcount == 1. |
| **MIR** | Machine IR - the post-lowering, architecture-specific instruction representation used by the codegen. |
| **ctx_swap** | MIR instruction that saves current register state to the active FCB and restores a target FCB's state. |
| **Lindsay** | The middle-end SSA IR. Architecture-agnostic, in static single-assignment form. |
| **Jenny** | The backend - MIR lowering, register allocation, and binary linking. |
| **Katsuro** | The frontend - platform abstraction, lexer, parser, AST. |
| **DWARF** | Debug information format used for source-level debugging (`.debug_line`, `.debug_info`, etc.). |
| **SEH** | Structured Exception Handling - Windows unwind tables (`.pdata`/`.xdata`). |
