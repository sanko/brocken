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
- **Memory Management:** RC Immix system — deterministic reference counting backed by a tracing cycle-detector.
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
| `$` | Scalar/Object — a single value, reference, or object | `my $x = 42` |
| `@` | Array/List — indexed as `@items[0]` | `my @arr` |
| `%` | Hash/Dictionary — accessed as `%map{"key"}` | `my %map` |

Sigils are invariant — they never change based on context (unlike Perl 5).

#### 2.1.2 Built-in Types (Gradual Typing)

If a type is omitted, it defaults to `Any` (a 16-byte Fat Scalar).

| Type | Maps To | Description |
|------|---------|-------------|
| `Any` | `dynamic` | 16-byte fat scalar with refcount, GC flags, type tag, payload |
| `Int` | `int` | Shorthand for the native `int` type (alias) |
| `Bool` | `bool` | Shorthand for the native `bool` type (alias) |
| `String` | `ptr` | Immutable, UTF-8 encoded text (pointer to bytes) |
| `Array` | — | Collection (planned) |
| `Hash` | — | Key-value dictionary (planned) |
| `Class` | — | Object blueprint |

`Int` and `Bool` are not dynamic types — they are aliases for the native `int` and `bool` types declared in §2.1.3. A variable written as `my Int $x` or `my Bool $flag` gets a raw, unboxed machine value with no fat-scalar overhead.

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

Addition, subtraction, multiplication, left shift, and bitwise logical ops (`and`, `or`, `xor`) are identical for signed and unsigned at the machine level — they produce the same bit pattern. Signedness only matters for the operations above.

The lowerer's `maybe_convert_type` (§3.4) uses signedness to choose the correct extension opcode when widening. The backend encoder selects the correct instruction form based on the IR opcode (e.g., x86_64 `idiv` vs `div`, `sar` vs `shr`).

**The `Brocken::` Pseudo-Namespace.** Instead of writing inline assembly, Brocken exposes raw IR instructions via the `Brocken::` pseudo-namespace. The parser recognizes these and translates them directly into single Lindsay IR instructions:

```perl
use feature 'brocken_native_types';
my ptr $heap_cursor;
my i64 $size = 32;
my ptr $next = Brocken::ptr_add($heap_cursor, $size);
```

#### 2.1.4 Struct Types (Planned)

User-defined compound types with named fields, declared via the `struct` keyword:

```perl
struct Point {
    i64 $x;
    i64 $y;
}
```

Struct types retain field names at the IR level for debug info and reflection. Field access uses named lookup (`$pt.x`), lowered to a compile-time byte offset computed from the struct layout. Layout respects alignment requirements:

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
my i64 $x = $pt.x;      # field read — compile-time offset
$pt.y = 30;             # field write
```

Structs declared with `my` on the heap (via `new`) get RC treatment:

```perl
my Point $pt = Point->new(x => 10, y => 20);  # heap-allocated, RC'd
```

##### Relation to Classes

Classes (§2.6) are structs with methods, auto-generated accessors, constructors, and lifecycle hooks (`ADJUST`, `DESTROY`). A `class` without methods is structurally identical to a `struct`. The difference is semantic: classes are always heap-allocated and RC-managed; structs can live on the stack.

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
.rodata    (read-only data — strings, const arrays)
.data      (read-write data — mutable globals)
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
- **No ownership**: The referent is not deallocated when the reference goes out of scope — only when all owning pointers do.

The optimizer can use the non-null guarantee to elide null checks and the RC guarantee to elide early frees.

In the IR, references are opaque pointers (`ptr` type) with `incref` emitted at creation and `decref` emitted at scope exit, wired into the same Perceus RC elision pass that handles class instances.

#### 2.1.7 Typed Pointers (Planned)

A typed pointer carries the type of the pointed-to value at the source level, but lowers to the same opaque `ptr` in the IR:

```perl
my ptr(i64) $p = ...;       # pointer to an i64
my i64 $val = $p[0];        # load i64 through typed pointer — no cast needed
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

- `my` — lexical variable declaration
- `our` — package-scoped variable
- `state` — persistent lexical variable
- `const` — compile-time constant
- `type` — type alias declaration

Array declarations use the syntax `my [TYPE; SIZE] @name`:

```perl
my [i64; 10] @arr;      # fixed-size array of 10 i64s
my i64 @arr = [1,2,3];  # sized from literal count
```

### 2.3 Operators

**Numeric:** `==`, `!=`, `<`, `>`, `<=`, `>=`, `<=>`

**Logical:** `&&`, `||`, `!`, `//` (Defined-OR)

**Bitwise:** `&`, `|`, `^`, `~`

String comparison (`eq`, `ne`, `lt`, `gt`, `le`, `ge`, `cmp`) and
bitwise shift (`<<`, `>>`) are deferred — see §2.17.

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

return $value;
return;        # void return
```

- No statement modifiers (`say "hi" if $x`)
- No `unless`, `until`, `for`, `foreach` in v0.1
- No `next`, `last`, `redo` in v0.1

### 2.5 Subroutines

Strict signatures with arity and optional return type.

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
- Last expression is NOT implicitly returned — must use `return`

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

- `new` — constructor
- `ADJUST` — post-construction invariant enforcement
- `DESTROY` — deterministic destructor (due to Immediate RC)

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
| `Brocken::syscall(n, ...)` | syscall instruction |

### 2.8 Built-in Functions

| Function | Behaviour |
|----------|-----------|
| `say(...)` | Print (newline-terminated) — lowered to `write(1)` syscall |
| `print(...)` | Print (no newline) — lowered to `write(1)` syscall |

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

`match` lowers to a sequence of type-tag checks + conditional branches + unbox operations. (Not yet implemented — the parser/frontend is still being built.)

### 2.12 `defer` Blocks (Planned)

Deferred code is cloned into all scope exit paths during Lindsay lowering. Zero runtime overhead (no stack of defer frames). (Not yet implemented.)

### 2.13 `try/catch/finally` (Planned)

Uses DWARF `.eh_frame` for zero-cost exception unwinding. The `die` intrinsic unwinds to the nearest `catch` landing pad.

### 2.14 Pod6 Documentation (Planned)

Raku-style Pod6 is built natively into the parser. Two forms:

**Declarator blocks** — attached to the subsequent definition via `#|`:

```perl
#| Creates a new User with the given name and age.
sub create_user ($name, $age) { ... }
```

**Paragraph blocks** — standalone `=begin` / `=end` sections.

Pod6 nodes are attached directly to the AST as metadata on each `Brocken::Katsuro::Node`. The compiler exposes them via LSP server (hover tooltips, go-to-definition) and `bkn doc` CLI (renders as HTML/man/terminal).

### 2.15 Source Position Convention

Every AST node carries `file`, `line`, and `col` from the token that introduces the construct (its start token, not its closing token). The position is set during parsing and propagates through to error messages.

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
my $dynamic_var;              # Any (Fat Scalar) — default
my int $count = 0;            # Native integer (i64 on all current targets)
my Int $age = 30;             # Same as `int` — capitalized alias
my bool $flag = true;         # Native boolean
my Bool $done = false;        # Same as `bool` — capitalized alias
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
- Last expression is NOT implicitly returned — must use `return`

#### 2.16.3 Control Flow

```perl
if ($x > 0) { ... } elsif ($x == 0) { ... } else { ... }
while ($cursor < $limit) { ... }
return $value;
return;   # void return
```

Not in v0.1: `unless`, `until`, `for`, `foreach`, statement modifiers, `next`, `last`, `redo`.

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

`say(...)` and `print(...)` — lowered to `write(1)` syscall.

#### 2.16.7 Feature Flags

```perl
use feature 'brocken_native_types';   # enables i128, u128
```

### 2.17 Excluded Features (Deferred from v0.1)

| Feature | Reason |
|---------|--------|
| `%` hashes | Not needed for the runtime; can be built on top later |
| `struct` keyword | Classes serve as structs in v0.1; dedicated struct syntax deferred |
| `ref(T)` references | RC decref/scope machinery not yet connected |
| `ptr(T)` typed pointers | Source-level annotation only; lowering is identical to opaque `ptr` |
| `.rodata` strings | String literals currently use stack alloca; `.rodata` section deferred |
| String ops (`eq`, `ne`, `.`, length, etc.) | String *literals* compile as const data; runtime operations are deferred |
| `type` aliases | Purely syntactic; trivial to add post-v0.1 |
| Regex | Deferred entirely |
| `map`/`grep` | Defer until list primitives exist |
| `eval` | Blocks on dynamic codegen |
| `match` | Pattern matching sugar — defer |
| `defer` | Scope guard — defer |
| `try`/`catch` | Defer — unwinding is complex |
| Pod6 | Documentation — defer |
| Multiple dispatch | Not needed |
| Operator overloading | Not needed |
| `want` / context | Not needed |
| Inheritance | Classes as flat structs only — no `:isa` |

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

### 4.1 Allocation

Memory allocation is currently handled in two ways:

- **Stack (`alloca`):** All local variables, fiber stacks (64KB), isolate stacks (64KB), and boxed fat scalars (16 bytes) are allocated via `alloca` in the current function's frame.
- **ICB.heap_cursor (offset 0):** Each isolate has a heap cursor field in its ICB. It is initialized to NULL and reserved for the future Immix allocator.

### 4.2 The `Any` Type (Fat Scalar)

A dynamically typed variable (`my $x;`) is represented as a 16-byte value:

```
Offset  Size    Purpose
0       2       Reference Count (max 65535, overflows pin the object)
2       1       GC Flags (Bit 0: Cycle Suspect, Bit 1: Buffered, Bit 2: Leaf)
3       1       Type Tag (0=Int, 1=String, 2=Array, 3=Class...)
4       4       Padding / Aux (e.g., String cached char length)
8       8       Payload (Raw 64-bit Int/Float, or Pointer to Heap Data)
```

Currently, `box` allocates this 16-byte struct via `alloca`. The payload and tag are stored as adjacent 8-byte fields. `unbox` reads them back.

### 4.3 Reference Counting

When a variable is assigned, the Lindsay middle-end injects an `incref` instruction. When a variable goes out of scope, a `decref` instruction is fired.

- **Deterministic Destruction:** If `RC == 0`, the object's `DESTROY` block runs immediately, and its memory is reclaimed.
- `incref` and `decref` IR instructions are lowered to calls to `Brocken::Runtime::incref` and `Brocken::Runtime::decref`. (Currently placeholders — the runtime module does not yet exist.)

### 4.4 Cycle Collection (Bacon & Rajan Trial Deletion)

Standard RC leaks memory when objects form circular references. Brocken solves this using Trial Deletion:

- If `RC > 0` after a decrement, the object might be part of an isolated cycle. The runtime pushes the pointer to the Isolate's Suspect Buffer.
- Periodically, the runtime scans the Suspect Buffer to identify and delete true circular references.

### 4.5 Immix Allocator (Planned)

To avoid the overhead of `malloc`, Brocken uses the Immix algorithm for allocating heap data (arrays, strings, objects).

- The OS provides 32KB Blocks.
- Blocks are divided into 256-byte Lines.
- Allocation is a simple pointer bump (`cursor += size`).
- When a block is full, the runtime finds a partially empty block or requests a new one.

*Not yet implemented. See §12.*

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
48      8       suspect_buffer_head
56      8       suspect_buffer_tail
```

Only `heap_cursor` (offset 0) is currently initialized. The full ICB is planned.

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

1. **Fiber transfer** — save current FCB, load target FCB, branch to resume_pc.
2. **Fiber yield** — save current FCB, load `parent` FCB.
3. **Isolate trampoline** — entry point called by `pthread_create` on a new OS thread. Loads FCB from arg struct, sets fiber register, loads args, `call_indirect` to the user function.

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
- `Brocken::Jenny::Codegen` — Orchestrates lowering, register allocation, and encoding.
- `Brocken::Jenny::Lowerer` — Lowers Lindsay IR to Machine IR (MIR) for a specific target.
- `Brocken::Jenny::RegAlloc` — Linear scan register allocator.

### 6.1 Intermediate Representation (Lindsay IR)

Each instruction is an object with an `opcode`, `type`, `dest`, and `operands`.

#### Memory & GC Lifecycle
- `incref` / `decref` — Reference count operations
- `alloca` — Stack memory allocation
- `load` / `store` — Memory read/write
- `store_imm` — Store immediate directly to memory
- `getelementptr` — Compute memory address (base + index * scale + disp)

#### Control Flow
- `label` — Code location marker
- `jmp` — Unconditional jump
- `cond_br` — Conditional branch
- `call` — Call a function (handles arguments via ABI registers)
- `ret` — Return from a function

#### Arithmetic / Logic
- `add`, `sub`, `mul`, `div`, `rem` — Integer math
- `fadd`, `fsub`, `fmul`, `fdiv` — Floating-point math
- `and`, `or`, `xor`, `shl`, `lshr`, `ashr` — Bitwise operations
- `icmp` — Integer comparisons (`eq`, `ne`, `slt`, `ult`, etc.)

#### Fat Scalars
- `box` — Wraps a native type into a 16-byte dynamic Fat Scalar
- `unbox` — Extracts a native type from a Fat Scalar

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

1. Create `Brocken::Katsuro::Platform::ABI::YourArch.pm` — register mapping and calling conventions.
2. Create `Brocken::Jenny::Lowerer::YourArch.pm` — map Lindsay IR to MIR.
3. Create `Brocken::Jenny::Codegen::YourArch.pm` — encode MIR to raw machine bytes.

---

## 7. Debug Information

Brocken can emit rich debug information for GDB, WinDbg, etc. There are two independent debug information systems, selected automatically by the target OS:

| System | Format | Target | Tools |
|--------|--------|--------|-------|
| DWARF | `.debug_*` sections | PE + ELF | GDB, LLDB, readelf |
| SEH | `.pdata` / `.xdata` | PE (win64) | GDB, WinDbg, Xperf |
| `.eh_frame` | DWARF variant | ELF (linux) | GDB, perf, libunwind |

### 7.1 Debug Levels

The `debug` parameter is an integer passed to `Brocken::Compiler->new()` or via the `--debug=N` flag.

| Level | Effect |
|-------|--------|
| 0 | No debug sections (default) |
| 1 | Emit all debug sections (DWARF + SEH + `.eh_frame`) |
| 2 | Level 1 + hex dumps of debug sections |
| 4+ | Include class/struct type DIEs in `.debug_info` |

### 7.2 Architecture

**Source Location Tracking.** During lowering, every source-level IR instruction is annotated with its original line and column. An array of `{ offset, line, col }` hashes is consumed by the DWARF builder to generate `.debug_line` data.

**Function Range Tracking.** Every function (named sub, anonymous sub, method, and the implicit main body) is tracked via `push_func_range` / `close_last_func_range`. Each range entry contains: `name`, `start`/`end` byte offsets in `.text`, `ctx_size`, `params`, `locals`.

### 7.3 DWARF Sections

All DWARF sections are built by `Brocken::Target::Format::DWARF`.

- **`.debug_line`** — Maps machine-code offsets to source lines (DWARF3 line number program).
- **`.debug_info`** — Compilation unit, base types, optional class types (at debug >= 4), and subprogram entries for every function.
- **`.debug_abbrev`** — Compact declaration of DIE tag/attribute layouts.
- **`.debug_frame`** — Call frame information (DWARF3). CFA = RSP + 8, return address saved at CFA - 8.
- **`.debug_aranges`** — Address range table for fast debug info lookup.
- **`.debug_pubnames`** — Public names index.

### 7.4 SEH (Windows PE)

Each function gets one `RUNTIME_FUNCTION` entry (12 bytes) in `.pdata`, all pointing to a single shared `UNWIND_INFO` in `.xdata` (because every Brocken function has an identical prologue on win64).

### 7.5 `.eh_frame` (Linux ELF)

ELF-specific variant of DWARF call frame information. Uses "zR" augmentation for position-independent PC-relative FDE encoding. Survives `strip`.

### 7.6 GDB Usage

```bash
# Linux
perl brocken.pl --debug=1
gdb -ex "break source.brocken:9" -ex "run" -ex "bt" ./brocken_out

# Windows
gdb -ex "break *0x140001000" -ex "run" -ex "bt" --args brocken_out.exe
```

### 7.7 Section Layout

**PE (Windows) with debug:** `.text`, `.data`, `.idata`, `.debug_line`, `.debug_info`, `.debug_abbrev`, `.debug_frame`, `.debug_aranges`, `.debug_pubnames`, `.pdata`, `.xdata`

**ELF (Linux) with debug:** `.text`, `.data`, `.debug_line`, `.debug_info`, `.debug_abbrev`, `.debug_frame`, `.eh_frame`

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

The formatter operates on the AST, not text — it always produces valid code and never changes semantics.

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

Because the ICB is pinned to a hardware register (`r14`/`x28`/`s11`), sandbox state checks are a single load + test — no memory indirection penalty.

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
| Lindsay IR + Jenny MIR | — | ✅ |
| X86_64 codegen + linker | — | ✅ |
| ARM64 codegen + linker | — | ✅ |
| RISCV64 codegen + linker | — | ✅ |
| Wasm codegen + linker | — | ✅ |
| Regalloc + spilling | — | ✅ |
| Fibers + ctx_swap | — | ✅ |
| i128 arithmetic | — | ✅ |
| Isolates (pthread/CreateThread) | — | ✅ |
| Channels (IR, lower stubs, linker imports) | — | ✅ |
| Frontend (Katsuro v0.1) — Lexer + Parser + AST + Compiler | — | ✅ |
| Source location tracking (file/line/col) in AST + errors | — | ✅ |
| Lexer filename in errors | — | ✅ |
| Channels (data + native lower) | Post-frontend | ⏸ |
| Immix allocator + ICB expansion | Post-frontend | 📝 |
| Perceus RC elision | After allocator | 📝 |
| AST→Lindsay IR Lowerer | Next | ✅ |
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

## 13. Glossary

| Term | Definition |
|------|------------|
| **Isolate** | An OS thread with its own independent heap and GC. No shared mutable state between isolates. |
| **Fiber** | A cooperative green thread within an isolate. Fibers share the isolate's heap and are scheduled via explicit `ctx_swap`. |
| **FCB** | Fiber Control Block — per-fiber struct holding saved callee registers, stack pointer, resume PC, and metadata. |
| **ICB** | Isolate Control Block — per-isolate struct pinned to a dedicated register (r14/x28/s11). |
| **CCB** | Channel Control Block — shared ring buffer with mutex/condvar for cross-isolate message passing. |
| **Fat Scalar** | 16-byte dynamic value representation: refcount + gc_flags + type_tag + aux_data + payload. |
| **Immix** | Bump-pointer allocator using 32KB blocks divided into 256-byte lines. Mark-region tracing for cycle collection. |
| **Perceus** | Compile-time RC optimization that cancels redundant incref/decref pairs and enables in-place mutation when refcount == 1. |
| **MIR** | Machine IR — the post-lowering, architecture-specific instruction representation used by the codegen. |
| **ctx_swap** | MIR instruction that saves current register state to the active FCB and restores a target FCB's state. |
| **Lindsay** | The middle-end SSA IR. Architecture-agnostic, in static single-assignment form. |
| **Jenny** | The backend — MIR lowering, register allocation, and binary linking. |
| **Katsuro** | The frontend — platform abstraction, lexer, parser, AST. |
| **DWARF** | Debug information format used for source-level debugging (`.debug_line`, `.debug_info`, etc.). |
| **SEH** | Structured Exception Handling — Windows unwind tables (`.pdata`/`.xdata`). |
