# The Brocken Language Specification

**Author:** Sanko Robinson
**Version:** v0.0.1
**Status:** Active Development

> **Implementation Note:** This document specifies the target language and is written ahead of the implementation. Brocken is under active development, so sections below range from fully shipped and covered by the test suite to planned or partially implemented. Read it as the design of record, not a status report; see [`TODO.md`](../TODO.md) for what is shipped versus outstanding.

---

## 1. Philosophy & Compiler Architecture

### 1.1 What This Compiler Does

Brocken is a systems programming language with the ergonomics and expressiveness of modern Perl. The Brocken compiler parses this Perl-like syntax and compiles it Ahead-Of-Time (AOT) directly into standalone native machine code (Linux ELF, Windows PE, macOS Mach-O, and WebAssembly) for x86_64, ARM64, and RISC-V architectures.

**Brocken relies on no external C runtime (libc), no GCC, and no LLVM.** Everything from the instruction encoders to the linker is written from scratch in Perl 5.

### 1.2 Core Pillars

- **Zero-Dependency AOT Execution:** Output binaries are 100% standalone. I/O and threading are implemented via direct kernel system calls or linker-resolved OS-level dynamic imports.
- **Self-Hosted Runtime (`core.brocken`):** The garbage collector, memory allocator, fiber scheduler, and channels are not written in C. They are written in Brocken using a special "Unsafe Native Subset" of the language.
- **Share-Nothing Concurrency:** Concurrency relies on independent OS threads (Isolates) with strict thread-local heaps. Because heaps are isolated, **reference counting requires zero atomic locks**.[^rcgc]
- **Deterministic Memory:** Memory is managed by Immediate Reference Counting utilizing an Immix Bump-Allocator[^immix] and segregated free lists. Circular references are handled by Bacon & Rajan trial deletion.[^trialdeletion]
- **Ultra-Modern Perl Ergonomics:** Brocken adopts modern Perl idioms while shedding historical parsing ambiguities: invariant sigils, post-dereference syntax, Corinna-style classes with `ADJUST`/`DESTROY`, compile-time attributes, strict lexical scoping, and zero-cost exceptions.[^perldocs]

---

## 2. Lexical Structure, Variables & Sigils

### 2.1 Invariant Sigils

Unlike older versions of Perl where sigils change based on context (e.g., `$arr[0]` vs `@arr`), Brocken enforces **invariant sigils**. The sigil dictates the container type and never changes.

| Sigil | Container | Access / Dereference | Reference |
|---|---|---|---|
| `$` | Scalar / Object / Reference | `$x` | `\$x` |
| `@` | Array | `@arr[0]` | `\@arr` |
| `%` | Hash | `%map{"key"}` | `\%map` |

### 2.2 Scoping and Declarations

Variables are lexically scoped.
- `my` - Lexical variable declaration.
- `our` - Package-scoped global variable.
- `state` - Persistent lexical variable (initialized once). **Planned, not yet implemented** — the keyword is reserved but there is no writable program-global storage yet (TODO §3).
- `const` - Compile-time constant (emitted into the `.rodata` section).

---

## 3. The Type System & Nullability

Brocken maintains a strict syntactic and physical separation between **managed/nullable Perl containers** (Capitalized) and **unboxed raw machine types** (lowercase).

### 3.1 Unboxed Machine Types (The Unsafe Subset)

Enabled via `use feature 'brocken_native_types';`, these types bypass Fat Scalar overhead and do not participate in reference counting. They live directly in CPU registers or raw stack slots.

* `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `i128`, `u128` (Integers)
* `f32`, `f64` (IEEE 754 Floating Point)
* `bool` (Native boolean, `1` or `0`)
* `ptr` (Opaque 64-bit machine pointer)
* `int` (Alias for `i64` on all current targets)

**Nullability:** Unboxed machine types **cannot be `undef`**. If uninitialized, they default to `0`, `0.0`, or `false`.

### 3.2 Managed Perl Containers (Fat Scalars)

If a variable type is omitted, it defaults to `Any`. Managed types are dynamically allocated on the thread-local Immix heap[^immix] and tracked via reference counting.[^rcgc]

* `Any` - The universal dynamic 16-byte Fat Scalar.
* `Int` - Boxed integer.
* `Float` - Boxed float.
* `Bool` - Boxed boolean.
* `String` - Managed pointer to UTF-8 length-prefixed, NUL-terminated bytes.
* `Class` - Managed heap object instance pointer.

**The Fat Scalar Layout (`Any`):**[^fatscalar]
```
Offset  Size  Field
0       2     Reference Count (u16, max 65535 pins the object)
2       1     GC Flags (u8: Cycle Suspect, Buffered, Leaf, BRC Color)
3       1     Type Tag (u8: 0=Undef, 1=Int, 3=Float, 4=Ptr, 5=Dynamic, 7=List, 8=Hash)
4       4     Auxiliary Data / Padding (u32)
8       8     Payload (u64 / f64 / ptr)
```

**Nullability:** Managed containers **default to `undef`** (Type Tag 0, Payload 0).

### 3.3 `undef` and `defined`

- **As a Value Literal:** `$var = undef;` resets a managed variable to the undefined state and drops the refcount of its previous value.
- **As a Mutator Builtin:**
  - `undef($var);` (Same as `$var = undef;`)
  - `undef(@arr);` (Empties the array, decrefs all elements)
  - `undef(%hash);` (Empties the hash, decrefs all keys/values)
- **The `defined` Builtin:** `if (defined $var) { ... }` checks if a managed container has a Type Tag `!= 0`.

---

## 4. Operators, Strings & Truthiness

### 4.1 Truthiness Rules (Perl Semantics)

In Brocken, exactly four conditions evaluate to **false**:
1. `0` (Integer `0` or Float `0.0`)
2. `"0"` (String)
3. `""` (Empty string)
4. `undef` (Null pointer / Uninitialized managed variable)

All other values including `0.5`, `-1`, `"00"`, `"false"`, and any object pointer evaluate to **true**.
When a dynamic `Any` variable is evaluated in a conditional (`if ($x)`), the compiler invokes a runtime helper `is_truthy(ptr)` that enforces these exact rules without blindly truncating payloads.

### 4.2 Stringification

The `say()`, `print()`, and concatenation (`.`) operators automatically stringify values.
- `Int` and `i64` invoke the `i64_to_str` runtime helper.
- `Float` and `f64` invoke `sprintf("%f")` (or equivalent runtime float-to-string helper).
- `Bool` stringifies to `"1"` or `""`.
- Classes and Arrays stringify to `"ClassName=ptr:0x..."` unless the class implements a custom stringify method.

### 4.3 String Interpolation (Strict)

To prevent grammatical ambiguity and eliminate arbitrary-lookahead lexer hacks, Brocken strictly enforces interpolation rules inside double quotes (`"..."`):

1. **Scalars interpolate:** `say("Hello, $name!");`
2. **Disambiguated Scalars:** `say("Total: ${count}kg");`
3. **Container Elements interpolate:** `say("Item: $arr[0]");` and `say("Value: $map{key}");`
4. **Method calls DO NOT interpolate:**
   ```perl
   # The following DOES NOT call ->x()!
   say("Point: ($pt->x)"); # Prints literally: "Point: (Point=ptr:0x1234->x)"
   ```
   *Method calls must be concatenated explicitly using the `.` operator:*
   ```perl
   say("Point: (" . $pt->x . ")");
   ```

### 4.4 Auto-Increment (`++`) and Decrement (`--`)

Brocken supports numeric pre- and post-increment/decrement (`$i++`, `--$i`).

**Magical String Increment (Perl 5 Compatibility):**
If `++` is applied to a String, Brocken uses Perl's ASCII-carry increment rules:
- Applies strictly to strings matching `/^[a-zA-Z]*[0-9]*\z/` (e.g., `"az"++` $\rightarrow$ `"ba"`, `"99"++` $\rightarrow$ `"100"`).
- If the string contains non-ASCII characters or symbols, it falls back to numeric coercion (the string becomes numeric `0`, and `0++` becomes `1`).
- String decrement (`--`) is **never magical**. It always coerces to numeric and subtracts 1.

### 4.5 Ranges (`..`)

The range operator generates sequences. When used directly in a `for` loop header:
```perl
for my $i (0 .. 1000) { ... }
```
The compiler optimizes this into a **zero-allocation induction loop** (`$i = 0; while ($i <= 1000) { ... $i++; }`) rather than allocating a 1000-element array in memory.

### 4.6 Compound Assignment

Brocken evaluates target addresses exactly once during compound assignments (`+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `.=`).
```perl
%map{"total"} += 5; # The hash key "total" is looked up only once.
```

#### Defined-or and logical-or (`//`, `//=`, `||=`)

`//` is the defined-or operator: it yields its left operand when that is **defined** and its right operand otherwise.

```perl
my $first = $earnings // $reserve // 0;   # the first of the three that is defined
```

`//=` (defined-or assign) and `||=` (logical-or assign) are the corresponding assignments. Both keep the value
already in the slot when that value counts as "present" and store the right operand otherwise, but they differ in what
"present" means:

* `//=` fires when the slot is **undefined** — for a `ptr` or an untyped `Any` that is a null pointer / null box. A
  native `int`/`float`/`bool` can never be undefined, so `//=` on one has no test to make and degrades to a plain `=`
  store.
* `||=` fires when the slot is **false**: a native `0` / `0.0`, or a null `ptr` / `Any`. On an `Any` box, `||=` currently
  tests the box pointer for null only, so a *boxed* `0` is not yet treated as false (see TODO §4).

```perl
my Any $name;      # starts undefined
$name //= 'John';  # 'John'
$name //= 'Jane';  # still 'John' -- the slot is now defined

my i64 $count = 0;
$count ||= 3;      # 3 -- zero is false, so the RHS is stored
```

In a `my` declaration the conditional form is accepted but behaves exactly like `=`, because a fresh variable has no
prior value to test. `state $x //= EXPR` — the form whose condition can actually be observed on a variable that
persists across calls — is **not implemented yet**, because writable program-global storage is still missing (TODO §3).

Like `&&` and `||`, `//` is **eager**: both operands are evaluated, there is no short-circuit.

---

## 5. Postfix Dereferencing & References

Brocken discards traditional circumfix/prefix dereferencing (`$$ref`, `@$ref[0]`) in favor of strict, left-to-right **postfix dereferencing** (`postderef`).

```perl
# References
my $arr_ref = [ 10, 20, 30 ];
my $hash_ref = { name => "Alice", age => 30 };
my $scalar_ref = \"Hello";

# Element dereferencing
say( $arr_ref->[0] );         # Array element: 10
say( $hash_ref->{"name"} );   # Hash element: "Alice"
say( $scalar_ref->$* );       # Scalar deref: "Hello"

# Full container dereferencing
foreach my $val ( $arr_ref->@* ) { say($val); }
my @keys = $hash_ref->%*;

# Slices
my @subset = $arr_ref->@[ 0, 2 ];
my @vals   = $hash_ref->@{ "name", "age" };
```

---

## 6. Containers & Built-in Functions

Hashes and Arrays are not objects; they are manipulated via built-in keywords.

### 6.1 Arrays
- `push @arr, $val` (Appends, returns new length)
- `pop @arr` (Removes and returns last element)
- `shift @arr` (Removes and returns first element)
- `unshift @arr, $val` (Prepends, returns new length)

### 6.2 Hashes (O(1) Linear Probing)
Hashes in `core.brocken` use an **O(1) Open Addressing with Linear Probing** architecture.[^hashing]
- Capacity is always a power of two.
- Non-string keys (integers, objects) are automatically stringified upon insertion.
- **Ownership:** Hashes take ownership (`incref`) of stored values.
- **Destruction:** Hash destruction recursively `decref`s all stored keys and values.

**Hash Builtins:**
- `keys %hash` (Returns a list of string keys)
- `values %hash` (Returns a list of values)
- `exists %hash{"key"}` (Returns `bool`)
- `delete %hash{"key"}` (Removes the entry and returns the deleted value)

---

## 7. Subroutines, Attributes & Closures

### 7.1 Signatures & Returns

Return types are declared using the `:returns(...)` attribute. Subroutines can return multi-value tuples which map directly to multiple hardware registers (`rax:rdx` on x86_64, `x0:x1` on ARM64) enabling **zero-allocation tuple returns**.

```perl
sub divide(i64 $num, i64 $denom) :returns(i64, bool) {
    return (0, false) if $denom == 0;
    return ($num / $denom, true);
}
my ($result, $ok) = divide(10, 2);
```

### 7.2 Named Parameters

Named parameters are prefixed with `:` and passed via `name => value` pairs.
```perl
sub configure(String $host, :i64 $port = 5432, :bool $ssl = true) { ... }
configure("localhost", port => 8080);
```

### 7.3 Anonymous Subs & Closures

Anonymous subroutines are first-class values.
- **Function Pointers:** If an anonymous sub does not capture any variables from its outer scope, it is emitted as a raw code address in the `.text` segment (zero allocation overhead).
- **True Closures:** If a sub captures lexical variables from its outer scope, the compiler allocates an **Environment Record** on the Immix heap. The sub becomes a Fat Closure (`{ code_ptr, env_ptr }`). The environment is refcounted and kept alive as long as the closure reference exists.

### 7.4 Attribute Dictionary

Attributes provide compile-time metadata for the optimizer and linker:

**Subroutine & Method Attributes:**
- `:returns(Type, ...)` - Defines return type or tuple.
- `:export` - Emits the symbol into the binary’s export table for FFI/C interop.
- `:inline` / `:noinline` - Direct optimization hint.
- `:pure` - Guarantees no side effects (eligible for CSE and Dead Code Elimination).

**Variable Attributes:**
- `:const` - Immutable after initialization; re-assignment is a compile error.
- `:aligned(N)` - Enforces N-byte memory alignment (useful for SIMD arrays).

**Class Field Attributes:**
- `:param` - Generates constructor argument: `Class->new(field => $val)`.
- `:reader` - Generates accessor: `$obj->field()`.
- `:writer` - Generates mutator: `$obj->set_field($val)`, which returns `$self` so calls can be chained.
- `:accessor` - Generates both reader and writer.
- `:weak` - Weak reference; prevents reference cycles by bypassing `incref`/`decref`.

---

## 8. Object-Oriented Programming (Classes)

Brocken uses Corinna-style classes with strict encapsulation. Fields are strictly private unless exposed via attributes.

**Implementation status.** The class system is being brought up in two milestones. v0.0.1 targets parity with Perl's core `class` feature (`perlclass`); v0.0.2 adds selected `Object::Pad` features. Today the front end implements `class` (block form), typed `field` with the `:param`/`:reader`/`:writer`/`:accessor` attributes, `=`/`//=`/`||=` defaults, `method`, and any number of `ADJUST` blocks (run in declaration order); writers return `$self` so calls can be chained. Method resolution is static (compile-time) and there is no inheritance. `:isa`, `SUPER::`, versioned classes, roles, and `DESTROY` are **planned, not yet implemented** — the `DatabaseConnection::Static` example below is forward-looking. See [`class_roadmap.md`](class_roadmap.md) for the full shipped-versus-planned breakdown.

```perl
class DatabaseConnection {
    field ptr $handle   :param :reader;
    field bool $is_open = true;

    ADJUST {
        if (Brocken::ptr_cmp_eq($handle, 0)) {
            die "Invalid database handle";
        }
    }

    method query(String $sql) :returns(ptr) {
        die "Connection is closed" unless $is_open;
        return Brocken::syscall_by_name("query", $handle, $sql);
    }

    DESTROY {
        if ($is_open) {
            Brocken::syscall_by_name("close", $handle);
            $is_open = false;
        }
    }
}

# Planned (v0.0.1): :isa, versioned classes, and SUPER:: are not yet implemented.
class DatabaseConnection::Static :isa(DatabaseConnection) {
    field bool $toggle = true;

    method commit( String $sql ) :returns(ptr) {
        return $self->SUPER::commit( $sql ) if $toggle;
    }
}
```

### 8.1 Destructor (`DESTROY`) Semantics

1. **Automatic Trigger:** When `decref` drops a class instance's refcount to 0, `ClassName::DESTROY($self)` executes immediately.
2. **Cascading Field Teardown:** The user only writes code to clean up external OS resources (file handles, sockets). After `DESTROY` finishes, the compiler automatically emits hidden teardown code to `decref` all fields containing managed types (Strings, Arrays, Hashes, other Objects).
3. **Destructor Panics:** Throwing an unhandled exception inside `DESTROY` during stack unwinding is illegal and triggers a hard runtime abort.

---

## 9. Control Flow & Error Handling

### 9.1 Postfix Modifiers

Postfix conditionals are supported for concise guard clauses:
```perl
return 0 if $n <= 0;
die "File not found" unless defined $fh;
next if $item == 0;
last if $done;
```

### 9.2 Exceptions & The Landing Dispatcher (`try / catch / finally`)

```perl
try {
    die "Something broke" if $failed;
}
catch ($err) {
    warn("Recovered: $err");
}
finally {
    say("Cleanup complete");
}
```

**v0.0.1 Implementation:** Brocken implements exceptions via `setjmp`/`longjmp` (SJLJ) managed on the Isolate Control Block (ICB).
- **The Landing Dispatcher:**[^landing] To guarantee `finally` blocks execute exactly once under all conditions, the compiler lowers the `try` block into a state machine.
- Whether the block exits normally, catches an exception, encounters an early `return`, or hits a `last`/`next`, execution jumps to a unified dispatcher that pops the exception handler from the ICB and executes the `finally` code before resuming the targeted branch or returning the value.

*(Note: Zero-cost DWARF `.eh_frame` and Windows SEH unwinding are planned for v0.0.2).*

### 9.3 Process & Error Builtins
- `exit($code = 0)`: Lowered directly to the kernel `exit` syscall. Terminates the process.
- `warn(@msgs)`: Concatenates arguments, appends `" at file line N.\n"` if missing a trailing newline, and writes directly to `stderr` (FD 2). Does not abort.
- `die(@msgs)`: Emits an automatic `throw` with a formatted error string. Caught by `catch ($err)`. If uncaught, writes to `stderr` and exits with code 255.

---

## 10. The Memory Model: RC & Immix

Brocken operates on a **thread-local heap model**. There are no atomic locks required for reference counting or allocation because OS threads (Isolates) do not share memory.

### 10.1 The Caller-Borrows Contract

To eliminate massive Reference Counting churn, Brocken strictly enforces a **Caller-Borrows** convention:
- When passing a variable to a function, the caller passes the reference without incrementing the refcount.
- The callee *borrows* the parameter and is strictly forbidden from decrementing it upon exit.
- The callee only emits `incref` if it explicitly stores the value into an array, hash, class field, or global variable.

### 10.2 Immix Bump Allocator (Layer 1)

Objects are allocated using the Immix algorithm:[^immix]
- Memory is managed in 32KB blocks, sub-divided into 256-byte lines.
- **Hot Path:** Freed 16-byte fat scalars are immediately pushed to a segregated singly-linked list (`free16_head`) threaded directly through the freed payload slots. `bump_alloc` consumes this list first.
- **Cold Path:** Line-aware bump allocation using a 128-bit availability bitmap stored in the header of the 32KB block.
- **Block Ownership:** Blocks tile a single `BLOCK_SIZE` grid anchored at the first block (`heap_base + ICB::SIZE`). A freed object is charged to the block that contains its address, so `live_count` is always decremented on the owning block regardless of which block is currently allocating.

### 10.3 Trial Deletion (Bacon & Rajan Cycle Detection) (Layer 2)

To collect circular references without a tracing pause, Brocken uses Bacon & Rajan trial deletion.[^trialdeletion]
- When `decref` leaves an object with `RC > 0` (and it is not marked as a Leaf), it is pushed to a suspect ring buffer on the ICB.
- When the buffer fills, `gc_drain()` executes a local sub-graph trace: marking nodes Purple -> Gray -> White, scanning, and collecting isolated cycles.

---

## 11. Concurrency: Isolates, Fibers, and Channels

### 11.1 Isolates (OS Threads)
An Isolate is a heavy, share-nothing OS thread with an independent Immix heap and Isolate Control Block (ICB) pinned to a hardware register (`r14` on x86_64, `x28` on ARM64, `s11` on RISCV64).[^isolate]

### 11.2 Fibers (Green Threads)
Fibers are M:N cooperative coroutines multiplexed inside an Isolate. They share the Isolate's heap and are scheduled via explicit `ctx_swap` instructions managed by a Fiber Control Block (FCB).[^ctxswitch]

### 11.3 CSP Channels
Channels (`chan_create`, `chan_send`, `chan_recv`) provide thread-safe communication between Isolates. They are bounded ring buffers protected by a global `.data` mutex and condition variable.[^csp]

**v0.0.1 Ownership Semantics (Erlang Model):**
Because heaps are strictly thread-local, passing pointers between Isolates is fatal. In v0.0.1, channels accept primitives (`i64`, `f64`, `bool`). If an aggregate (Hash, Array, Class) is sent across a channel, the runtime automatically executes a **Deep-Copy Serialization** into the receiving Isolate's heap.

*(Note: Zero-copy ownership transfer using a `move $var` affine scope checker and a Global Message Arena is planned for v0.0.2).*

---

## 12. Compilation Pipeline & Intrinsics

1. **Katsuro (Frontend):** Lexer and Pratt Parser generate the AST.
2. **Lindsay (Middle-end):** Lowers AST to architecture-agnostic Static Single Assignment (SSA) IR.[^ssa] Injects `incref`/`decref`, lowers `Brocken::` pseudo-namespaces to raw memory opcodes.
3. **Jenny (Backend):**
   - Lowers IR to Machine IR (MIR).
   - **RegAlloc:** Linear Scan register allocation handling Spills and Caller-Saved registers dynamically.[^linearscan]
   - **Linker:** Outputs raw machine code bytes to executable formats (`ELF64`, `PE32+`, `Mach-O`, `Wasm`), resolving cross-function RVAs and generating native OS entry stubs.[^linker]
   - **DWARF v5:** Emits `.debug_line`, `.debug_info`, and `.debug_frame` for native GDB/LLDB debugging.[^dwarf]

### 12.1 Intrinsics (`Brocken::*`)

The `Brocken::` pseudo-namespace is the Unsafe Native Subset. It is how `core.brocken` manipulates raw memory and issues system calls without a C runtime. Every intrinsic lowers directly to MIR and none of them allocates.

| Intrinsic | MIR output |
|-----------|------------|
| `Brocken::ptr_add(p, off)` | `add` |
| `Brocken::ptr_sub(p, off)` | `sub` |
| `Brocken::ptr_cmp_gt(a, b)` | `icmp sgt` |
| `Brocken::ptr_cmp_lt(a, b)` | `icmp slt` |
| `Brocken::ptr_cmp_ge(a, b)` | `icmp sge` |
| `Brocken::ptr_cmp_le(a, b)` | `icmp sle` |
| `Brocken::ptr_cmp_eq(a, b)` | `icmp eq` |
| `Brocken::load_i64(ptr)` | `load i64` |
| `Brocken::store_i64(ptr, val)` | `store i64` |
| `Brocken::load_i32(ptr)` / `store_i32(ptr, val)` | `load i32` / `store i32` |
| `Brocken::load_i8(ptr)` / `store_i8(ptr, val)` | `load i8` / `store i8` |
| `Brocken::load_u16(ptr)` / `store_u16(ptr, val)` | `load i16` / `store i16` |
| `Brocken::load_f64(ptr)` / `store_f64(ptr, val)` | `load f64` / `store f64` |
| `Brocken::i64_add(a, b)` / `i64_sub(a, b)` | `add` / `sub` |
| `Brocken::band(a, b)` / `bor(a, b)` / `bxor(a, b)` | `and` / `or` / `xor` |
| `Brocken::shl(a, b)` / `shr(a, b)` | `shl` / `lshr` |
| `Brocken::syscall(n, ...)` | `syscall` instruction, guarded by `CAP_FFI` |
| `Brocken::syscall_by_name(name, ...)` | `syscall` with the number resolved from the target platform, guarded by `CAP_FFI` |
| `Brocken::libc(name, ...)` | `call` to a link-time-resolved symbol, guarded by `CAP_FFI` |
| `Brocken::heap_base()` | load of `__heap_base` |

The FFI intrinsics are the only place the capability mask is consulted today (15.4). `syscall_by_name` and `libc` require a literal string for the name so it can be resolved before linking.

### 12.2 Targets & Binary Formats

A target is a normalized four-part triple, `arch-vendor-os-env` (`x86_64-pc-linux-gnu`, `aarch64-apple-darwin-macho`). `Brocken::Katsuro::Platform::parse` maps a triple to a platform class, and that class answers the register sets, the calling convention, the syscall numbers, and which code generator and linker to build. Host detection probes `clang`, then `gcc`, then falls back to Perl's `Config`.[^triple]

The code generator and the binary format are independent axes: one generator serves several formats.

| Architecture | Code generator | Notes |
|---|---|---|
| `x86_64`[^x86] | `Codegen::X86_64` | Complex addressing (SIB), `RDX:RAX` for `div`/`umulh` |
| `aarch64`[^arm64] | `Codegen::ARM64` | Load/store architecture |
| `riscv64`[^riscv] | `Codegen::RISCV64` | 12-bit immediates force scratch materialisation under pressure |
| `wasm32`[^wasm] | `Codegen::Wasm` | Stack machine; no threads |

| OS family | Format | Linker |
|---|---|---|
| Linux, the BSDs, Haiku, Solaris/illumos | ELF64[^elf] | `Linker::ELF64` |
| macOS / Darwin | Mach-O[^macho] | `Linker::MachO` |
| Windows | PE32+[^pe] | `Linker::PE` |
| WASI | Wasm module[^wasm] | `Linker::Wasm` |

An architecture with no code generator is refused with `Unsupported platform for Brocken: <friendly>`; the platform asks its own class for the backend rather than carrying a dispatch table.

### 12.3 Cross-Compiling

A cross compile is a platform passed to the constructor; every later call is unchanged.

```perl
my $brocken = Brocken->new(
    platform => Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu')
);
```

The linker writes a real executable for the other architecture. It does not run there; executing it needs an emulator or the real target. The test suite uses `BROCKEN_SYSROOT_AARCH64` / `BROCKEN_SYSROOT_RISCV64` to run foreign output under `qemu` and skips those tests when the sysroot is unset (17.3).

### 12.4 Entry Point

There is no special `sub main`. Top-level statements are compiled into an implicit `_BROCKEN_ENTRY`, which receives the heap base from the OS entry stub and returns the process exit status.

```perl
# This program:
my i64 $x = 42;
return $x;

# Is equivalent to:
sub _BROCKEN_ENTRY(i64 $__heap_base) :returns(i64) {
    my i64 $x = 42;
    return $x;
}
```

The entry stub is OS-specific (it sets up the stack, the ICB, and the initial fiber) and is generated by the linker, not written in Brocken.

---

## 13. Building & Reproducible Builds

### 13.1 How a Build Is Driven

The compiler is a Perl library (a `bkn` CLI is planned in 17.4). A build is four calls:

```perl
use Brocken;

my $brocken = Brocken->new;
my $module  = $brocken->compile($source);                      # front end + lowering
my $funcs   = $brocken->codegen->emit_functions($module->functions);
$brocken->linker->write_executable($file, $funcs, $brocken->platform);
```

`compile` reads `src/runtime/core.brocken` and merges its statements ahead of the caller's, so the allocator, collector, fibers, and exception support travel with every program. The constructor's options are:

| Option | Meaning | Default |
|---|---|---|
| `platform` | target platform | host platform |
| `fuel` | instruction budget per isolate (15.2) | 1,000,000 |
| `mem_limit` | heap bytes per isolate, `0` = unlimited (15.3) | 0 |
| `capabilities` | capability bitmask (15.4) | `~0` |
| `stack_reserve` | initial thread stack reserve, PE only | 4 MiB |
| `stack_commit` | initial thread stack commit, PE only | 2 MiB |
| `runtime` | path to `core.brocken` | `src/runtime/core.brocken` |

`Brocken->set_default_policy(%opts)` moves the defaults for every compiler built afterwards, and is equivalent to setting `$Brocken::default_fuel`, `$Brocken::default_mem_limit`, and `$Brocken::default_capabilities`. Debug information is enabled on the linker (`set_debug_level`, 14.2), not the constructor.

### 13.2 Deterministic Output

Builds are byte-reproducible. Perl randomizes hash iteration order once per process (`PERL_HASH_SEED`), and any pass that walks a hash and writes the result into the emitted artifact perturbs the object file from build to build. Every such walk is sorted:

- **RegAlloc** sorts live sets and spill slots while building intervals and reloads.
- **Codegen** sorts its scratch/reload sets and the Wasm source/offset maps.
- **`Linker::ELF64`** sorts the names feeding the SYSV `.hash` chain.

Compiling the identical module under two different `PERL_HASH_SEED` values now yields byte-identical objects and linked executables. Determinism here is a correctness property, not just convenience: an unsorted walk in the allocator was what made RISC-V i128 `udiv` correct under some seeds and wrong under others.[^repro]

### 13.3 Timestamps

The linker carries a `timestamp` (`set_timestamp`), defaulting to `effective_timestamp() = $timestamp // time()`. On PE32+ that value is written into the COFF header and the optional header; setting it explicitly, or exporting the conventional `SOURCE_DATE_EPOCH`, pins the bytes. ELF64 emits deterministic OSABI/ABI notes, so it has no equivalent knob.

### 13.4 Seeded Inputs

The test generator's reproducibility rests on a seed, not on program text. A `(seed, case_num, max_ops, max_vars)` tuple is packed into a compact, reversible hex `case_id` (`Brocken::Fuzz::encode_case_id`), and `Brocken::Fuzz::run_case_id($id)` re-seeds and replays exactly that input in any process, on any machine, days later (17.1).

---

## 14. Debugging & Diagnostics

Brocken exposes itself to debuggers two ways: standard DWARF v5 for source-level work, and a compact `.brk_sym` table for return-address symbolisation without DWARF. It also carries internal trace hooks for debugging the compiler itself.

### 14.1 Debug Information (DWARF v5)

Debug data is built by `Brocken::Jenny::Linker::DWARF`, assembled during codegen by each backend's `build_debug_data`, and linked into the final image.[^dwarf]

| Section | Purpose |
|---|---|
| `.debug_line` | Machine-code offset to source line/column mapping |
| `.debug_info` | Compile unit, subprograms, base types, struct types, variables |
| `.debug_abbrev` | DIE tag/attribute declarations (ULEB128) |
| `.debug_frame` | Call-frame information and frame-pointer recovery |
| `.debug_aranges` | Address-range table for fast lookup |
| `.debug_names` | DWARF v5 accelerated access index (case-folding DJB hash) |
| `.debug_str` | String pool referenced by `.debug_names` |
| `.eh_frame` / `.eh_frame_hdr`[^ehframe] | Unwind data, built when an `eh_frame_base` is supplied |

Mach-O additionally carries `.debug_pubnames`, the pre-v5 public-names index its tooling expects.

### 14.2 Debug Levels

All debug output is gated by `debug_level` on the linker object:

| Level | Emits |
|---|---|
| 0 | Nothing (default) |
| 1 | `.debug_line` |
| 2 | + `.debug_info`, `.debug_abbrev` |
| 3 | + `.debug_frame`, `.debug_aranges` |
| 4 | + `.debug_names`, `.debug_str`, struct DIEs (full DWARF) |
| 5 | + COFF symbols and ASLR disabled (GDB breakpoints on PE) |

At level 5 on PE the `IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE` bit is cleared and a COFF symbol table is emitted, so GDB's `break <funcname>` resolves to a stable address. At levels below 5 GDB can still enumerate functions via `.debug_names`, but cannot set breakpoints by name.

### 14.3 Source-Location Pipeline

1. **IR:** every `Brocken::Lindsay::IR::Instruction` carries `$line`/`$col`, and the builder's `build_*` methods accept them.
2. **Lowerer:** `Brocken::Katsuro::Lowerer` threads `$ast->line`/`$ast->col` into each `build_*` call.
3. **MIR:** each `MachineInstruction` records `ir_inst_idx`, the index of the originating IR instruction.
4. **Encoding:** each encoder records `ir_inst_idx => byte_offset` into a `source_map` (first instruction per IR instruction wins).
5. **DWARF:** `build_debug_data` turns `source_map` entries into per-instruction `.debug_line` rows. Functions named `Brocken::Runtime::*` are attributed to `<runtime>`; user functions to the compiled file.

### 14.4 Variable, Struct and Subprogram DIEs

Every user-visible `alloca` carries a `debug_name` and `debug_type_name`, set by the lowerer and attached to its variable DIE (`DW_AT_name`, `DW_AT_type`, `DW_AT_location` as `DW_OP_fbreg`, `DW_AT_decl_file/line/column`, and `DW_AT_artificial`; 0 for user variables, 1 for compiler temporaries). When `class_info` is present, `.debug_info` also emits `DW_TAG_structure_type` DIEs with `DW_TAG_member` children (offset, name, type) at level ≥ 4, and every function gets a `DW_TAG_subprogram` with its name and code range.

### 14.5 Native Backtraces (`.brk_sym`)

Every function saves its frame pointer (`rbp`, `x29`, or `s0`) and points it at the caller's saved frame pointer, so a backtrace is a pointer walk.[^backtrace] `.debug_frame` describes the same recovery for debuggers.

Independently of DWARF, the linker can emit a `.brk_sym` ("Native Backtrace Info") section from `set_func_ranges([{ name => ..., start => ..., end => ... }, ...])`:

```
word    count
count × { start_rva, end_rva, name_offset }
byte[]  NUL-terminated name pool
```

This gives a minimal symbol table that resolves return addresses without any `.debug_*` sections. ELF64, Mach-O, and PE all emit it, and it is the mechanism behind the zero-cost native backtrace test.[^brksym]

### 14.6 Using GDB / LLDB

```bash
# Linux: source-level breakpoints work from DWARF
gdb -readnow -ex "break source.brocken:9" -ex run -ex bt ./brocken_out

# Windows PE (level 5): break by function name, resolved from COFF
gdb -readnow -ex "break _BROCKEN_ENTRY" -ex run -ex backtrace ./brocken_out.exe
```

`Test2::Tools::Brocken::run_exec($file, gdb => 1)` runs a compiled binary under GDB from the test suite.

### 14.7 Compiler Trace Hooks

Several environment variables expose compiler internals without changing the language:

| Variable | Effect |
|---|---|
| `BROCKEN_DUMP_INTERVALS` | Dump block liveness and linear-scan intervals to stderr |
| `BROCKEN_SKIP_PDATA` | Suppress the PE `.pdata` exception table |
| `BROCKEN_SYSROOT_AARCH64` / `BROCKEN_SYSROOT_RISCV64` | Cross sysroots for executing foreign output under `qemu` |
| `SOURCE_DATE_EPOCH` | Pin the PE link timestamp (13.3) |

### 14.8 Compile-Time Diagnostics

Every AST node carries `file`, `line`, and `col` from the token that introduces it, and the position propagates into parse/lower errors. A `# line "file" N [C]` directive overrides the reported position for subsequent tokens, so generated code can attribute itself to its origin. Runtime error messages follow the same convention: `die`/`warn` append `" at file line N.\n"` when the message lacks a trailing newline (9.3).

---

## 15. Sandboxing & Runtime Limits

The Isolate Control Block (ICB) is pinned to a hardware register (`r14` on x86_64, `x28` on ARM64, `s11` on RISC-V), so every limit check is a single load and test with no memory indirection. The limits are fixed per build and set by the compiler, not by the compiled program.

### 15.1 ICB Layout

The fields, in order, are generated from a single definition (`lib/Brocken/ICB.pm`) via `Brocken::Layout`, so the offsets below are a consequence of that list and not maintained by hand.

| Offset | Field | Offset | Field |
|---|---|---|---|
| 0 | `heap_cursor` | 80 | `current_block` |
| 8 | `current_fcb` | 88 | `memory_limit` |
| 16 | `fiber_head` | 96 | `memory_used` |
| 24 | `immix_cursor` | 104 | `capabilities` |
| 32 | `immix_limit` | 112 | `gate_table` |
| 40 | `free_blocks` | 120 | `host_icb` |
| 48 | `free16_head` | 128 | `exception_handler_stack` |
| 56 | `suspect_buffer_head` | 136 | `thrown_value` |
| 64 | `fuel` | 144 | `free_big_head` |
| 72 | `err_code` | 152 | `stack_limit` |

`ICB::SIZE` is 160 bytes. The initial heap (`HEAP_SIZE`) is 1 MiB.

### 15.2 Fuel

Fuel is an `i64` at `ICB::FUEL`. The lowerer emits a decrement-and-test at function entry, at every loop back-edge, and before call sites; at zero it writes `ERR_NO_FUEL` and routes to an exit block. The default is 1,000,000 and it is set with `fuel =>` or `$Brocken::default_fuel`. A smaller budget makes a runaway loop fail fast rather than hang a test run.[^fuel]

### 15.3 Memory Limit

`ICB::MEMORY_LIMIT` (`ICB::MEMORY_USED` tracks consumption) bounds heap bytes per isolate; `0` means unlimited. A Wasm target, whose memory must be reserved up front, forces the limit to `HEAP_SIZE` (1 MiB) when none is given. Exhaustion sets `ERR_OOM`.

### 15.4 Capabilities

`ICB::CAPABILITIES` is a bitmask checked before the FFI intrinsics (`syscall`, `syscall_by_name`, `libc`). A denied call sets `ERR_SECURITY` and aborts. The defined bits are:

| Constant | Bit | Meaning |
|---|---|---|
| `CAP_FS_READ` | 1 | File-system read |
| `CAP_FS_WRITE` | 2 | File-system write |
| `CAP_NET` | 4 | Network access |
| `CAP_SYSTEM` | 8 | `system()` / process spawn |
| `CAP_FFI` | 16 | `syscall`, `libc`, raw FFI |

The mask defaults to `~0`. Only `CAP_FFI` is consulted on the current path; the remaining bits are reserved for the filesystem, network, and process-spawn gates.[^caps]

### 15.5 Stack Guard

`ICB::STACK_LIMIT` is seeded at entry to `sp - STACK_BUDGET`, where `STACK_BUDGET` is a 2 MiB runway, and the PE stack reserve must stay above it. Each fiber seeds the same guard against its own 64 KiB stack. Overflow sets `ERR_STACK`.[^stackguard] Because ARM64 and RISC-V share a register between the first argument and the return value, a fresh fiber receives its ICB through an FCB transfer slot rather than the return register.

### 15.6 Error Codes

`ICB::ERR_CODE` records the reason a program aborted: `ERR_OK` (0), `ERR_OOM` (1), `ERR_NO_FUEL` (2), `ERR_SECURITY` (3), `ERR_DIV_ZERO` (4), `ERR_THROW` (5), `ERR_STACK` (6).

---

## 16. Security Considerations

### 16.1 Hash Collision Resistance

The v0.0.1 hash table uses linear probing over an identity hash and preserves insertion order. It is **not** collision-hardened: an attacker who controls keys (a web form, untrusted input) can force worst-case linear lookups. The planned replacement is **SipHash-2-4**, keyed per process from the OS CSPRNG, exposed as an intrinsic.[^siphash] (Planned for v0.0.2.)

### 16.2 Randomness (CSPRNG)

For secrets (tokens, nonces, hash seeds), v1 draws from the OS directly through `libc`:

| OS | Call |
|---|---|
| Linux | `getrandom(buf, len, flags)` |
| Windows | `BCryptGenRandom(NULL, buf, len, BCRYPT_USE_SYSTEM_PREFERRED_RNG)` |
| macOS / BSD | `getentropy(buf, len)` |

The planned v2 is a built-in ChaCha20 keystream in `core.brocken`, seeded from the OS once and reseeded periodically, exposed as `Brocken::Runtime::secure_rand` with an optional fixed-seed mode for tests.[^csprng]

### 16.3 Host Bindings (Planned)

The ICB already reserves `gate_table` and `host_icb`. The planned `bind` API enters a guest-visible gate, deep-copies arguments into the host heap, swaps the ICB register to the host's, runs the host closure, and deep-copies the result back, validating the gate ID and the capability mask, and using the stack guard to contain runaway recursion.

---

## 17. Tooling & Ecosystem

### 17.1 Fuzzer

`Brocken::Fuzz` generates small random programs, compiles and runs them, and compares against an interpreted answer.[^fuzzing] Every case is identified by a `(seed, case_num, max_ops, max_vars)` tuple, encoded as a reversible hex `case_id`; `run_case_id($id)` replays a failing case exactly. `bin/fuzz_runner.pl` wraps it:

```
-t, --time-limit SECS   run for at most SECS seconds (default 300)
-s, --seed N            use a specific random seed
-o, --max-ops N         maximum operations per program (default 20)
-v, --max-vars N        maximum variables per program (default 5)
-c, --count N           run exactly N iterations instead of time-limited
-i, --id HEXID          replay one case by its hex case_id
```

### 17.2 Test Harness

`Test2::Tools::Brocken` provides `run_exec($file, %args)` for running a compiled binary and checking its exit code. `gdb => 1` runs it under GDB; `keep => 1` leaves the binary on disk; `platform =>` selects path separators. The suite is organized by band: `t/00000_basic`, `t/10000_katsuro`, `t/20000_lindsay`, `t/30000_jenny`, `t/40000_runtime`, `t/50000_fuzz`, `t/90000_diagnostics`.

### 17.3 Cross-compilation & Execution

Execution tests run the native target, and run a foreign one under `qemu` when the matching `BROCKEN_SYSROOT_AARCH64` / `BROCKEN_SYSROOT_RISCV64` is configured; otherwise they skip. Disassembling with `wasm2wat` / `objdump`, or dumping linear-scan intervals with `BROCKEN_DUMP_INTERVALS`, is the usual way to debug a miscompile.

### 17.4 The `bkn` CLI (Planned)

A unified front end is planned; today the compiler is driven as a library. Planned commands:

| Command | Purpose |
|---|---|
| `bkn build` | Compile source to a binary |
| `bkn run` | Compile and execute immediately |
| `bkn test` | Run tests in TAP mode |
| `bkn doc` | Extract Pod documentation |
| `bkn fmt` | Format source |
| `bkn deps` | Dependency management |
| `bkn new` | Scaffold a project |

Dependency handling is planned around a project-local `brocken.lock` plus a content-hashed `~/.brocken/cache/`, with `bkn deps vendor` for air-gapped builds.

### 17.5 Formatter (Planned)

`bkn fmt` is planned as an AST-based, zero-configuration formatter: 4-space indentation, K&R braces, spaces around binary operators, no trailing whitespace, one blank line between top-level definitions. Operating on the AST means it never changes semantics.

---

## 18. Glossary

| Term | Definition |
|---|---|
| **Isolate**[^isolate] | An OS thread with its own Immix heap and ICB. No shared mutable state. |
| **Fiber**[^ctxswitch] | A cooperative green thread within an isolate, scheduled by `ctx_swap`; shares the isolate's heap. |
| **ICB**[^isolate] | Isolate Control Block, pinned to `r14`/`x28`/`s11`. Holds limit, fuel, capability, and GC state. |
| **FCB**[^ctxswitch] | Fiber Control Block: spilled callee registers, saved stack pointer, resume PC, parent, and transfer slot. |
| **CCB**[^csp] | Channel Control Block: a shared bounded ring buffer with a mutex and condition variable. |
| **Reference counting**[^rcgc] | The primary reclamation strategy; increments and decrements under the Caller-Borrows contract. |
| **Fat Scalar**[^fatscalar] | The 16-byte `Any` representation: refcount, GC flags, type tag, aux data, payload. |
| **Immix**[^immix] | Bump allocator over 32 KiB blocks divided into 256-byte lines, with segregated free lists. |
| **Perceus**[^perceus] | Compile-time RC optimization (borrow inference, RC elision, reuse). Planned. |
| **Linear scan**[^linearscan] | The register allocator in `Brocken::Jenny::RegAlloc`. |
| **MIR**[^pipeline] | Machine IR, the post-lowering architecture-specific instruction form. |
| **Lindsay**[^pipeline] | The architecture-agnostic SSA middle-end IR. |
| **Jenny**[^pipeline] | The backend: IR-to-MIR lowering, register allocation, encoding, linking. |
| **Katsuro**[^pipeline] | The front end: platform abstraction, lexer, parser, AST, lowering to Lindsay. |
| **Trial deletion**[^trialdeletion] | Bacon & Rajan cycle collection run from the ICB suspect buffer. |
| **Landing dispatcher**[^landing] | The per-`try` state machine that guarantees `finally` runs exactly once. |
| **Fuel**[^fuel] | An instruction budget in the ICB, decremented at entry, calls, and loop back-edges. |
| **Capability**[^caps] | A bitmask in the ICB gating FFI; checked before `syscall`/`libc`. |
| **Stack guard**[^stackguard] | The `sp - 2 MiB` runway in `ICB::STACK_LIMIT` that trips `ERR_STACK`. |
| **Target triple**[^triple] | The normalized `arch-vendor-os-env` string selecting backend and format. |
| **`.brk_sym`**[^brksym] | The Native Backtrace Info section: a packed function table for symbolising return addresses. |
| **DWARF**[^dwarf] | The standard debug-information format emitted for GDB/LLDB. |
| **SEH**[^seh] | Windows structured exception handling (`.pdata`/`.xdata`). Planned. |

---

## 19. Index

The footnotes referenced from the text and from the glossary are expanded here. Each entry states
what the term or technique is (**Expansion**), where Brocken deliberately parts company with the
cited work (**Divergence**), where it lives in this tree (**Implementation**), and what to watch
when changing it (**Maintenance**). Each entry ends with the footnote that collects its links to
papers and online documentation.

### AArch64 (ARM64)
**Expansion.** The 64-bit Arm instruction set and its ABI, AAPCS64.
**Divergence.** We follow AAPCS64 (x0–x7 arguments, x8 indirect result, x29 frame pointer) but
always save the frame pointer even where the ABI allows omission, and we do not emit the
pointer-authentication (`paciasp`/`autiasp`) or BTI prologues that modern Apple/Android targets use.
**Implementation.** `lib/Brocken/Jenny/Codegen/ARM64.pm`, `lib/Brocken/Jenny/Lowerer/ARM64.pm`.
**Maintenance.** Branch reach (`adrp`/`add` pairs), the 4096-entry literal-pool windows, and the
variadic register save area are the fragile spots; macOS ARM64 uses a different varargs path than
Linux.
**References.** [^arm64]

### Backtraces & frame pointers
**Expansion.** Walking saved frame pointers (or CFI) from a return address to a function name.
**Divergence.** Brocken always saves a frame pointer rather than relying on DWARF CFI alone, so a
backtrace is a plain pointer walk even in binaries built without debug info.
**Implementation.** Frame set-up in `Codegen/{X86_64,ARM64,RISCV64}.pm`; `.debug_frame` in
`linker/DWARF.pm`; `.brk_sym` emission via `set_func_ranges`.
**Maintenance.** Every prologue that pushes a frame must update the chain in the same order the
unwinder expects; a missed or reordered push silently truncates backtraces.
**References.** [^backtrace]

### `.brk_sym` (Native Backtrace Info)
**Expansion.** A Brocken-specific packed symbol table: `{count, [start_rva, end_rva, name_off]…,`
`string pool}`.
**Divergence.** This section is not part of any standard; ELF, Mach-O, and PE all carry it anyway,
so return addresses can be symbolized without shipping the much larger `.debug_*` sections.
**Implementation.** Field layout in `Brocken/Jenny/Linker.pm` (`compare_func_ranges`,
`build_brk_sym`); consumers in the backtrace tests.
**Maintenance.** Keep the entry layout and endianness identical across the three emitters; a
change to one must change `build_brk_sym` and every writer together.
**References.** [^brksym]

### Capabilities
**Expansion.** A per-isolate permission bitmask (capability-based security).
**Divergence.** Only `CAP_FFI` gates anything today. The filesystem, network, and process-spawn
bits are defined and reserved, not yet enforced. This is coarser than a full object-capability
system, where capabilities are unforgeable references rather than a global mask.
**Implementation.** Bits in `lib/Brocken.pm`; field in `lib/Brocken/ICB.pm`; the check is
`_emit_cap_check` in `lib/Brocken/Katsuro/Lowerer.pm`, wired to `syscall`, `syscall_by_name`, and
`libc`.
**Maintenance.** A new privileged intrinsic must call `_emit_cap_check` with the right bit, or it
becomes an unguarded escape hatch. Update the bit table and this index together.
**References.** [^caps]

### Channels (CSP)
**Expansion.** Bounded, mutex-protected ring buffers between isolates, after Hoare's CSP.
**Divergence.** Brocken channels default to *deep-copying* aggregates rather than transferring
ownership; affine `move` semantics are planned. Buffering is a fixed ring, not the unbounded
mailbox an actor language would use.
**Implementation.** `chan_create`/`chan_send`/`chan_recv`/`chan_try_send`/`chan_close` IR; CCB in
`lib/Brocken/`; runtime in `core.brocken`.
**Maintenance.** The mutex and condition variable live in `.data`, shared by all isolates; any
change to the ring indices must stay under the mutex to avoid torn reads.
**References.** [^csp]

### CSPRNG
**Expansion.** A cryptographically secure random source for secrets and hash seeds.
**Divergence.** v1 draws from the OS through `libc` on every call; the ChaCha20 userspace generate
to avoid per-call syscalls is planned, and no userspace buffering exists yet.
**Implementation.** Runtime calls in `core.brocken`; documented in 16.2.
**Maintenance.** Never fall back to a userspace PRNG when the OS call fails; that is the classic
failure mode. Add a fixed-seed test mode when the ChaCha20 generator lands.
**References.** [^csprng]

### DWARF
**Expansion.** The DWARF v5 debugging-information format.
**Divergence.** We emit the v5 `.debug_names` index and a case-folding DJB hash rather than the
older `.debug_pubnames`; Mac-O carries both. `.eh_frame` is built only when an `eh_frame_base` is
supplied.
**Implementation.** `lib/Brocken/Jenny/Linker/DWARF.pm`, driven by each backend's
`build_debug_data`; `debug_level` gate in `lib/Brocken/Jenny/Linker.pm`.
**Maintenance.** Section sizes and cross-references (`.debug_abbrev` codes, `.debug_str` offsets)
must stay consistent; a new abbrev code needs a matching DIE emitter.
**References.** [^dwarf]

### `.eh_frame` / CFI
**Expansion.** Compact unwind tables (`Call Frame Information`) consumed by libgcc/libunwind.
**Divergence.** Emission is implemented but opt-in (`eh_frame_base`); full zero-cost exception
unwinding is still planned for v0.0.2, so `.eh_frame` is not yet the primary unwind path.
**Implementation.** `build_eh_frame`/`build_eh_frame_hdr` in `linker/DWARF.pm`; `.eh_frame` and
`.eh_frame_hdr` sections and the `PT_GNU_EH_FRAME` program header in `linker/ELF64.pm`.
**Maintenance.** FDE encoding is `pcrel` with the `zR` augmentation; relocation of the FDE address
must track the final text layout.
**References.** [^ehframe]

### ELF64
**Expansion.** The System V ELF object/executable format, including the SYSV `.hash` table.
**Divergence.** We write the classic SYSV hash chain (sorted for reproducibility) rather than
GNU hash, and we hand-roll the program headers rather than driving a system linker.
**Implementation.** `lib/Brocken/Jenny/Linker/ELF64.pm`.
**Maintenance.** Program-header and section-header counts must agree; `sort` the `.hash` chain
names or reproducible builds break (see 13.2).
**References.** [^elf]

### Fat Scalar (`Any`)
**Expansion.** A 16-byte tagged value: 2-byte refcount, 1-byte GC flags, 1-byte type tag, 4 bytes
aux, 8-byte payload.
**Divergence.** Similar in spirit to Perl's `SV` and Lua's `TValue`, but fixed at 16 bytes with no
variant union beyond the payload, and with a refcount that saturates at 65535 (pinned) instead of
widening.
**Implementation.** Layout in 3.2; type tags and flags in `core.brocken`.
**Maintenance.** The offset-3 tag byte and the refcount at offset 0 are read by generated code and
the runtime; changing the layout means changing both, plus the allocator's 16-byte free list.
**References.** [^fatscalar]

### Fibers & context switching
**Expansion.** Cooperative M:N green threads switched by an explicit `ctx_swap` that spills one
FCB and restores another.
**Divergence.** We switch through a generated register-save sequence rather than `ucontext` or
Boost.Context's assembly; the FCB layout is derived once (`FCB.pm`) instead of being copied as
bare offsets.
**Implementation.** `ctx_swap` MIR; `lib/Brocken/Jenny/FCB.pm`; fiber lowering in
`Katsuro/Lowerer.pm`; 64 KiB fiber stacks.
**Maintenance.** The transfer value rides in the return register on x86-64 but through an FCB slot
on ARM64/RISC-V (shared argument/return registers); the platform-specific spill order must match
`FCB.pm`.
**References.** [^ctxswitch]

### Fuel
**Expansion.** An instruction budget that bounds execution, after Wasmtime's fuel metering.
**Divergence.** We decrement a counter in the ICB at function entry, loop back-edges, and calls,
and abort with `ERR_NO_FUEL`, a whole-program budget rather than per-instruction metering with
exact cost tables, and with no way for the program to top it up.
**Implementation.** `ICB::FUEL`; `_emit_fuel_check` in `lib/Brocken/Katsuro/Lowerer.pm`; default
`$Brocken::default_fuel`.
**Maintenance.** Any new control-flow edge that can loop must decrement fuel, or a budgeted program
can hang. Keep the check off the hot path where possible.
**References.** [^fuel]

### Fuzzing
**Expansion.** Random program generation with an oracle, in the spirit of QuickCheck and libFuzzer.
**Divergence.** `Brocken::Fuzz` generates typed Brocken programs and compares a compiled run
against an interpreter, keyed by a reversible `case_id`; it is not coverage-guided.
**Implementation.** `lib/Brocken/Fuzz.pm`, `bin/fuzz_runner.pl`, `t/50000_fuzz/`.
**Maintenance.** A `case_id` must decode to the same `(seed, case_num, max_ops, max_vars)` forever,
or old regression cases stop replaying; treat the encoding as frozen.
**References.** [^fuzzing]

### Hash tables
**Expansion.** Open addressing with linear probing and power-of-two capacity.
**Divergence.** Insertion order is preserved and keys are stringified; the hash is an identity hash
with no per-process secret, so it is vulnerable to HashDoS until SipHash lands (16.1).
**Implementation.** `core.brocken` hash builtins (`keys`, `values`, `exists`, `delete`).
**Maintenance.** Probe sequences must stay deterministic (no hash-order-dependent output) for the
reproducible-build guarantee.
**References.** [^hashing]

### Immix
**Expansion.** A mark-region collector (Blackburn & McKinley, PLDI 2008): 32 KiB blocks, 256-byte
lines, line-aware bump allocation.
**Divergence.** Brocken implements the *allocator* only (bump allocation with per-block bitmaps
and a 16-byte segregated free list) and collects cycles with trial deletion rather than the
paper's mark-region tracing/evacuation. There is no opportunistic defragmentation or line
evacuation, and the heap is single-threaded per isolate.
**Implementation.** 10.2; allocator and block layout in `core.brocken`.
**Maintenance.** Block ownership (`live_count` charged to the owning block) and the 256-byte line
grid must stay in step; a mis-charged free corrupts neighbouring blocks.
**References.** [^immix]

### Isolates
**Expansion.** Share-nothing OS threads, one thread-local heap and ICB each.
**Divergence.** Like Erlang processes in philosophy but implemented as one OS thread per isolate
(`pthread_create`/`CreateThread`) rather than a scheduler-multiplexed process; because heaps do not
share, RC needs no atomics.
**Implementation.** `isolate_create`/`isolate_join` IR; ICB pinned in a register; TLS on
x86-64/ARM64.
**Maintenance.** Never pass a heap pointer to another isolate; channels must deep-copy. The isolate
trampoline and the main-fiber wrapper must build byte-identical ICB layouts.
**References.** [^isolate]

### Landing dispatcher
**Expansion.** The per-`try` state machine that guarantees a single `finally`.
**Divergence.** A Brocken-specific lowering: `try` becomes a dispatcher that pops the ICB exception
handler and routes normal exit, catch, early `return`, `last`, and `next` to one place. There is no
Itanium/MSVC-style table-driven unwinder yet.
**Implementation.** Exception lowering in `lib/Brocken/Katsuro/Lowerer.pm`; handler stack in the
ICB (`EXCEPTION_HANDLER_STACK`).
**Maintenance.** Every new control-flow exit from a `try` body must route through the dispatcher;
a direct jump out leaks the handler-stack entry.
**References.** [^landing]

### Linear scan
**Expansion.** Linear-scan register allocation (Poletto & Sarkar, 1999).
**Divergence.** We use a straightforward live-interval scan with dynamic spill and caller-save
handling, not the SSA-based variant (Wimmer & Franz); the allocator operates on a simplified
liveness model and reserves fixed registers.
**Implementation.** `lib/Brocken/Jenny/RegAlloc.pm`; `BROCKEN_DUMP_INTERVALS` dumps intervals.
**Maintenance.** Live sets and spill slots must be walked in sorted order for reproducibility; see
the RISC-V wide-displacement load-scratch reuse for a subtle case where a destination register
doubles as address scratch.
**References.** [^linearscan]

### Linkers & loaders
**Expansion.** Turning relocatable code and data into a loadable image: symbol resolution,
relocations, GOT/PLT, and the entry stub.
**Divergence.** Brocken has no object-file layer and no system linker: the backend emits bytes and
the linker places them directly, resolving labels and computing RVAs in-process.
**Implementation.** `lib/Brocken/Jenny/Linker.pm` plus the per-format writers; import stubs and
`.got` handling in `ELF64.pm`.
**Maintenance.** Relocation offsets and the GOT layout must be finalized before the entry stub is
emitted; Mach-O anchors the entry stub to the final GOT layout for this reason.
**References.** [^linker]

### Mach-O
**Expansion.** Apple's object/executable format.
**Divergence.** We emit `.debug_pubnames` for Mach-O in addition to the DWARF v5 `.debug_names`;
the entry stub is anchored to the final GOT layout.
**Implementation.** `lib/Brocken/Jenny/Linker/MachO.pm`.
**Maintenance.** Load-command sizes feed the header size; a change to any command shifts every
offset and must be reflected in the entry stub's GOT anchoring.
**References.** [^macho]

### MIR & the pipeline
**Expansion.** The three-namespace compiler: Katsuro (front end), Lindsay (SSA middle end), Jenny
(backend, MIR, regalloc, encoding, linking).
**Divergence.** Brocken's IRs are purpose-built rather than LLVM IR or MLIR; the names are local.
**Implementation.** `lib/Brocken/Katsuro/`, `lib/Brocken/Lindsay/`, `lib/Brocken/Jenny/`.
**Maintenance.** The pipeline contract is positional: an IR instruction index flows to MIR
(`ir_inst_idx`) and then to the encoder's `source_map`; breaking that chain silently degrades debug
line info.
**References.** [^pipeline]

### PE32+ / COFF
**Expansion.** The Windows Portable Executable (PE32+) format and its COFF symbol table.
**Divergence.** At `debug_level` ≥ 5 we *disable ASLR* (clear
`IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE`) and emit COFF symbols so GDB can set breakpoints by name,
which is unusual for a modern toolchain.
**Implementation.** `lib/Brocken/Jenny/Linker/PE.pm`; `.pdata` unless `BROCKEN_SKIP_PDATA`;
timestamps from `SOURCE_DATE_EPOCH`.
**Maintenance.** RVA/page rounding and the section table offsets; the `.pdata` exception table must
be suppressed for targets that cannot use it.
**References.** [^pe]

### Perceus
**Expansion.** Compile-time reference-counting optimization: borrow inference, RC elision, and
reuse (Reinking et al., PLDI 2021).
**Divergence.** Planned, not implemented. Today the **Caller-Borrows** contract is a manual,
whole-program discipline (the caller does not increment; the callee may not decrement) rather than
inferred Perceus annotations with reuse analysis.
**Implementation.** Contract in 10.1; `incref`/`decref` injection in `Brocken::Katsuro::Lowerer`.
**Maintenance.** The borrow contract is the correctness boundary: a callee that decrefs a borrowed
parameter underflows the refcount. Any new escape path (field, global, container) must incref.
**References.** [^perceus]

### Perl language borrowings
**Expansion.** The language deliberately reuses Perl's semantics (sigils, truthiness,
stringification, references, post-deref, `class`/`ADJUST`/`DESTROY`, attributes).
**Divergence.** Brocken *removes* Perl's parsing ambiguities and several pseudohashes/magic
behaviours; e.g. `i128`/`u128` are named types and method calls never interpolate.
**Implementation.** The front end (`Katsuro`) targets Perl 5.42 `feature 'class'` spellings.
**Maintenance.** When Perl's own docs change, decide per feature whether Brocken follows; record
the choice here so the divergence is intentional rather than accidental.
**References.** [^perldocs]

### Reference counting (RC)
**Expansion.** Immediate reference counting as the primary reclamation strategy, with a
Caller-Borrows contract to avoid RC churn.
**Divergence.** We keep RC immediate and thread-local (no atomics) rather than a deferred or
concurrent scheme; cycles are cleaned separately by trial deletion, mirroring the RC/tracing
duality.
**Implementation.** `incref`/`decref` injection in `Katsuro/Lowerer.pm`; refcount in the fat
scalar.
**Maintenance.** The refcount saturates at 65535 (object pinned); code must not assume it wraps.
Every ownership transfer needs a matching release.
**References.** [^rcgc]

### Reproducible builds
**Expansion.** Byte-identical output from identical input.
**Divergence.** Reproducibility required sorting the hash-order-dependent walks inside our own
passes (RegAlloc, codegen, ELF64 SYSV `.hash`), the canonical SOURCE_DATE_EPOCH guidance only
covers timestamps. See 13.2–13.3.
**Implementation.** Sorted walks; `Linker::ELF64`; `set_timestamp`/`effective_timestamp` and
`SOURCE_DATE_EPOCH` in `linker/PE.pm`.
**Maintenance.** Any new pass that iterates a hash and writes into the artifact must sort first, or
`PERL_HASH_SEED` makes builds non-deterministic and reopens the RISC-V i128-style "seed-dependent"
bugs.
**References.** [^repro]

### RISC-V
**Expansion.** The RV64GC instruction set and its ELF psABI.
**Divergence.** We emit no compressed instructions and no pseudo-instruction macros; with only a
12-bit signed immediate, wide displacements force a scratch register, which is where our most
subtle codegen bugs have occurred (RISC-V does not reserve a scratch the way ARM64's x16/x17 are
dedicated).
**Implementation.** `lib/Brocken/Jenny/Codegen/RISCV64.pm`,
`lib/Brocken/Jenny/Lowerer/RISCV64.pm`.
**Maintenance.** When a load needs an address scratch, it may reuse its own destination (gated to
non-store, non-float); stores must not, because the destination is not otherwise free.
**References.** [^riscv]

### SEH
**Expansion.** Windows structured exception handling: `.pdata`/`.xdata` unwind tables.
**Divergence.** We emit `.pdata` for ARM64 (suppressible with `BROCKEN_SKIP_PDATA`) but zero-cost
SEH unwinding is still planned; today exceptions use the landing dispatcher, not the OS unwinder.
**Implementation.** `lib/Brocken/Jenny/Linker/PE.pm`.
**Maintenance.** `.pdata` entries must be sorted by code address and stay in sync with function
ranges.
**References.** [^seh]

### SipHash
**Expansion.** A keyed short-input PRF for collision-resistant hashing (Aumasson & Bernstein).
**Divergence.** Planned for v0.0.2; the v0.0.1 identity hash is not collision-hardened and is
attacker-influenceable.
**Implementation.** To be a per-process-seeded intrinsic; today only documented in 16.1.
**Maintenance.** Seed from the OS CSPRNG per process, never a fixed constant; keep an escape hatch
for deterministic tests without making it the default.
**References.** [^siphash]

### SSA
**Expansion.** Static Single Assignment, the middle-end representation (Cytron et al., 1991).
**Divergence.** Lindsay is SSA-with-explicit-`incref`; we do not build a full φ-node dominance
frontier in one pass, and many passes work on a linearized form.
**Implementation.** `lib/Brocken/Lindsay/`.
**Maintenance.** Values are immutable once created; a pass that mutates a value in place breaks
downstream users that still hold the old handle.
**References.** [^ssa]

### Stack guard
**Expansion.** A hard limit below the entry stack that turns runaway recursion into a trap.
**Divergence.** We compute `stack_limit = sp - 2 MiB` at entry and check it, rather than relying on
OS guard pages; each 64 KiB fiber seeds its own limit. Windows PE stack reserve must exceed the
budget.
**Implementation.** `lib/Brocken/Jenny/StackGuard.pm`; `ICB::STACK_LIMIT`; `ERR_STACK`.
**Maintenance.** Keep the budget below any real stack reserve, and keep the fiber growth path in
step with the guard seed; the ARM64/RISC-V fiber handoff hides the ICB in an FCB slot.
**References.** [^stackguard]

### Target triples
**Expansion.** `arch-vendor-os-env` strings selecting backend, ABI, syscalls, and format.
**Divergence.** We normalize to exactly four parts and always keep a vendor (defaulting it), where
LLVM and Zig accept several arities; we also map a few vendorless triples (e.g. MidnightBSD).
**Implementation.** `lib/Brocken/Katsuro/Platform.pm` (`parse`, `gen_triple`, `normalize_triple`).
**Maintenance.** A new OS/arch must supply a syscall table, register set, and linker; add a
round-trip normalize test rather than relying on substring matching.
**References.** [^triple]

### Trial deletion
**Expansion.** Bacon & Rajan cycle collection from a suspect buffer (ECOOP 2001).
**Divergence.** We run the **synchronous** form: `decref` pushes a `RC > 0`, non-Leaf object onto
an ICB suspect ring, and a full `gc_drain()` traces when the buffer fills; not the concurrent
algorithm, and without a separate purple/gray/white header word.
**Implementation.** 10.3; suspected-buffer head in the ICB; colors in the fat-scalar GC flags.
**Maintenance.** The `Leaf` flag must be set correctly for acyclic types or the suspect buffer
grows unbounded; the color transition order (Purple → Gray → White) is load-bearing.
**References.** [^trialdeletion]

### WebAssembly / WASI
**Expansion.** The Wasm stack-machine target and its WASI syscall surface.
**Divergence.** Threads and isolates are stubs (Wasm MVP has none), and the memory is reserved up
front, so `mem_limit` is forced to the 1 MiB `HEAP_SIZE`.
**Implementation.** `lib/Brocken/Jenny/Codegen/Wasm.pm`, `linker/Wasm.pm`.
**Maintenance.** Wasm has no registers; the codegen's source/offset maps must be sorted for
reproducibility like the native backends.
**References.** [^wasm]

### x86-64
**Expansion.** The AMD64/Intel 64 instruction set and the System V AMD64 (and Windows x64) ABIs.
**Divergence.** We hand-encode; complex addressing via SIB, and `div`/`umulh` use the fixed
`RDX:RAX` pair, which constrains allocation around those instructions.
**Implementation.** `lib/Brocken/Jenny/Codegen/X86_64.pm`, `Lowerer/X86_64.pm`.
**Maintenance.** Fixed-register instructions must reserve their implicit operands in RegAlloc; the
RIP-relative and SIB encodings are the usual source of wrong-bytes bugs.
**References.** [^x86]

#### Footnote links

[^arm64]: Arm Architecture Reference Manual for A-profile (ARMv8-A) <https://developer.arm.com/documentation/ddi0487/latest> · AAPCS64 <https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst> · Apple arm64 ABI <https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms>.
[^backtrace]: `backtrace_symbols(3)` <https://man7.org/linux/man-pages/man3/backtrace_symbols.3.html> · libunwind <https://www.nongnu.org/libunwind/> · GCC code-gen options (`-fno-omit-frame-pointer`) <https://gcc.gnu.org/onlinedocs/gcc/Code-Gen-Options.html> · GDB <https://sourceware.org/gdb/current/onlinedocs/gdb.html/>.
[^brksym]: Brocken-specific; related symbolization: `backtrace_symbols(3)` <https://man7.org/linux/man-pages/man3/backtrace_symbols.3.html> · libunwind <https://www.nongnu.org/libunwind/> · DWARF `.debug_names` <https://dwarfstd.org/doc/DWARF5.pdf>.
[^caps]: H. M. Levy, "Capability-Based Computer Systems" <https://homes.cs.washington.edu/~levy/capabook/> · Capability-based security <https://en.wikipedia.org/wiki/Capability-based_security> · WASI <https://github.com/WebAssembly/WASI> · Linux seccomp <https://man7.org/linux/man-pages/man2/seccomp.2.html> · OpenBSD `pledge(2)` <https://man.openbsd.org/pledge.2>.
[^csp]: C. A. R. Hoare, "Communicating Sequential Processes", CACM 1978 <https://doi.org/10.1145/359576.359585> · CSP <https://en.wikipedia.org/wiki/Communicating_sequential_processes> · Go specification (channels) <https://go.dev/ref/spec> · Rust `mpsc` <https://doc.rust-lang.org/std/sync/mpsc/>.
[^csprng]: `getrandom(2)` <https://man7.org/linux/man-pages/man2/getrandom.2.html> · `BCryptGenRandom` <https://learn.microsoft.com/en-us/windows/win32/api/bcrypt/nf-bcrypt-bcryptgenrandom> · `getentropy(2)` <https://man.openbsd.org/getentropy.2> · ChaCha20-Poly1305, RFC 8439 <https://www.rfc-editor.org/rfc/rfc8439> · NIST SP 800-90A <https://csrc.nist.gov/pubs/sp/800/90/a/r1/final>.
[^ctxswitch]: Boost.Context <https://www.boost.org/doc/libs/release/libs/context/doc/html/index.html> · its `fcontext` layer <https://www.boost.org/doc/libs/release/libs/context/doc/html/context/ff.html> · Windows fibers <https://learn.microsoft.com/en-us/windows/win32/procthread/fibers> · POSIX `getcontext` <https://man7.org/linux/man-pages/man3/getcontext.3.html> · `setjmp`/`longjmp` <https://man7.org/linux/man-pages/man3/setjmp.3.html> · Fibers <https://en.wikipedia.org/wiki/Fiber_(computer_science)>.
[^dwarf]: DWARF v5 <https://dwarfstd.org/doc/DWARF5.pdf> · dwarfstd.org <https://dwarfstd.org/> · LLVM source-level debugging <https://llvm.org/docs/SourceLevelDebugging.html> · GDB <https://sourceware.org/gdb/current/onlinedocs/gdb.html/> · DWARF overview <https://en.wikipedia.org/wiki/DWARF>.
[^ehframe]: LSB exception frames <https://refspecs.linuxfoundation.org/LSB_5.0.0/LSB-Core-generic/LSB-Core-generic/ehframechpt.html> · Itanium C++ ABI exception handling <https://itanium-cxx-abi.github.io/cxx-abi/abi-eh.html> · I. L. Taylor on exception handling <https://www.airs.com/blog/archives/460>.
[^elf]: System V gABI <https://refspecs.linuxfoundation.org/elf/gabi4+/contents.html> · ELF overview <https://en.wikipedia.org/wiki/Executable_and_Linkable_Format> · GNU hash <https://flapenguin.me/elf-dt-gnu-hash>.
[^fatscalar]: R. Ierusalimschy, L. H. de Figueiredo, W. Celes, "The Implementation of Lua 5.0" <https://www.lua.org/doc/jucs05.pdf> · R. Nystrom, "Crafting Interpreters" <https://craftinginterpreters.com/> · Perl internals (the `SV`) <https://perldoc.perl.org/perlguts>.
[^fuel]: Wasmtime fuel (`Config`) <https://docs.wasmtime.dev/api/wasmtime/struct.Config.html> · Wasmtime `Store` fuel <https://docs.wasmtime.dev/api/wasmtime/struct.Store.html> · wasmi metering <https://github.com/wasmi-labs/wasmi> · Ethereum gas (Yellow Paper) <https://ethereum.github.io/yellowpaper/paper.pdf>.
[^fuzzing]: K. Claessen, J. Hughes, "QuickCheck", ICFP 2000 <https://doi.org/10.1145/1806596.1806604> · libFuzzer <https://llvm.org/docs/LibFuzzer.html> · AFL <https://github.com/google/AFL> · Hypothesis <https://hypothesis.readthedocs.io/> · Test2 <https://metacpan.org/pod/Test2> · Test2::V0 <https://metacpan.org/pod/Test2::V0>.
[^hashing]: Open addressing <https://en.wikipedia.org/wiki/Open_addressing> · Swiss Tables <https://abseil.io/about/design/swisstables> · HashDoS advisory <http://www.ocert.org/advisories/ocert-2011-003.html> · Perl data structures <https://perldoc.perl.org/perldata>.
[^immix]: S. M. Blackburn, K. S. McKinley, "Immix: A Mark-Region Garbage Collector with Space Efficiency, Fast Collection, and Mutator Performance", PLDI 2008 <https://doi.org/10.1145/1375581.1375586> · MMTk <https://www.mmtk.io/> · <https://github.com/mmtk/mmtk-core> · The GC Handbook <https://gchandbook.org/>.
[^isolate]: `pthread_create(3)` <https://man7.org/linux/man-pages/man3/pthread_create.3.html> · Windows `CreateThread` <https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createthread> · ELF TLS (Drepper) <https://www.akkadia.org/drepper/tls.pdf> · Erlang processes <https://www.erlang.org/doc/reference_manual/processes.html>.
[^landing]: Brocken-specific; related: Itanium C++ ABI EH <https://itanium-cxx-abi.github.io/cxx-abi/abi-eh.html> · Microsoft C++ exceptions and stack unwinding <https://learn.microsoft.com/en-us/cpp/cpp/exceptions-and-stack-unwinding-in-cpp> · `setjmp`/`longjmp` <https://man7.org/linux/man-pages/man3/setjmp.3.html>.
[^linearscan]: M. Poletto, V. Sarkar, "Linear Scan Register Allocation", TOPLAS 21(5), 1999 <https://www.cs.ucla.edu/~palsberg/course/cs132/linearscan.pdf> · C. Wimmer, M. Franz, "Linear Scan Register Allocation on SSA Form", CGO 2010 <https://doi.org/10.1145/1772954.1772979> · LLVM code generator <https://llvm.org/docs/CodeGenerator.html>.
[^linker]: J. R. Levine, "Linkers and Loaders" <https://linker.iecc.com/> · I. L. Taylor, "Linkers" series <https://www.airs.com/blog/archives/38> · E. Bendersky, "Position Independent Code" <https://eli.thegreenplace.net/2011/11/03/position-independent-code-pic-in-shared-libraries/> · "Really Teensy ELF Executables" <https://www.muppetlabs.com/~breadbox/software/tiny/teensy.html> · "How programs get run" <https://lwn.net/Articles/631631/>.
[^macho]: "OS X ABI Mach-O File Format Reference" <https://github.com/aidansteele/osx-abi-macho-file-format-reference> · Mach-O overview <https://en.wikipedia.org/wiki/Mach-O> · XNU `loader.h` <https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h>.
[^pe]: PE Format <https://learn.microsoft.com/en-us/windows/win32/debug/pe-format> · `.pdata` <https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#the-pdata-section> · x64 software conventions <https://learn.microsoft.com/en-us/cpp/build/x64-software-conventions> · PE overview <https://en.wikipedia.org/wiki/Portable_Executable>.
[^perceus]: A. Reinking, N. Xie, L. de Moura, D. Leijen, "Perceus: Garbage Free Reference Counting with Reuse", PLDI 2021 <https://doi.org/10.1145/3453483.3454032> · S. Ullrich, L. de Moura, "Counting Immutable Beans" <https://arxiv.org/abs/1908.05647> · Koka <https://koka-lang.github.io/koka/doc/index.html> · Lean 4 <https://lean-lang.org/>.
[^perldocs]: `perlclass` <https://perldoc.perl.org/perlclass> · `feature` <https://perldoc.perl.org/feature> · `perlref` <https://perldoc.perl.org/perlref> · `perlop` <https://perldoc.perl.org/perlop> · `perlsub` <https://perldoc.perl.org/perlsub> · `perlobj` <https://perldoc.perl.org/perlobj> · `perlvar` <https://perldoc.perl.org/perlvar> · `perlfunc` <https://perldoc.perl.org/perlfunc> · `perlsyn` <https://perldoc.perl.org/perlsyn> · `perlguts` <https://perldoc.perl.org/perlguts>.
[^pipeline]: LLVM code generator <https://llvm.org/docs/CodeGenerator.html> · MLIR <https://mlir.llvm.org/> · Cranelift <https://github.com/bytecodealliance/wasmtime/tree/main/cranelift>.
[^rcgc]: G. E. Collins, "A Method for Overlapping and Erasure of Lists", CACM 3(12), 1960 <https://doi.org/10.1145/367390.367400> · D. F. Bacon, P. Cheng, V. T. Rajan, "A Unified Theory of Garbage Collection", OOPSLA 2004 <https://doi.org/10.1145/1028976.1028982> · The GC Handbook <https://gchandbook.org/> · Reference counting <https://en.wikipedia.org/wiki/Reference_counting>.
[^repro]: SOURCE_DATE_EPOCH specification <https://reproducible-builds.org/specs/source-date-epoch/> · Reproducible Builds <https://reproducible-builds.org/docs/> · Debian <https://wiki.debian.org/ReproducibleBuilds> · Perl `PERL_HASH_SEED` <https://perldoc.perl.org/perlrun>.
[^riscv]: The RISC-V Instruction Set Manual <https://github.com/riscv/riscv-isa-manual> · specifications <https://riscv.org/technical/specifications/> · RISC-V ELF psABI <https://github.com/riscv-non-isa/riscv-elf-psabi-doc> · RISC-V Assembly Programmer's Manual <https://github.com/riscv-non-isa/riscv-asm-manual> · Linux/RISC-V <https://www.kernel.org/doc/html/latest/arch/riscv/index.html> · toolchain <https://github.com/riscv-collab/riscv-gnu-toolchain>.
[^seh]: Microsoft x64 exception handling <https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64> · Structured Exception Handling <https://learn.microsoft.com/en-us/windows/win32/debug/structured-exception-handling> · C++ exceptions and stack unwinding <https://learn.microsoft.com/en-us/cpp/cpp/exceptions-and-stack-unwinding-in-cpp> · SEH overview <https://en.wikipedia.org/wiki/Structured_Exception_Handling>.
[^siphash]: J.-P. Aumasson, D. J. Bernstein, "SipHash: A Fast Short-Input PRF" <https://doi.org/10.1007/978-3-642-34931-7_28> · reference implementation <https://github.com/veorq/SipHash> · SipHash overview <https://en.wikipedia.org/wiki/SipHash> · author page <https://131002.net/siphash/>.
[^ssa]: R. Cytron, J. Ferrante, B. Rosen, M. Wegman, F. K. Zadeck, "Efficiently Computing Static Single Assignment Form and the Control Dependence Graph", TOPLAS 1991 <https://doi.org/10.1145/115372.115320> · LLVM Language Reference <https://llvm.org/docs/LangRef.html>.
[^stackguard]: Windows stack usage / stack probes <https://learn.microsoft.com/en-us/cpp/build/stack-usage> · GCC stack-clash protection <https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html> · Qualys, "Stack Clash" <https://www.qualys.com/2017/06/19/stack-clash/stack-clash.txt>.
[^triple]: LLVM `Triple` <https://llvm.org/doxygen/Triple_8h_source.html> · Clang cross-compilation <https://clang.llvm.org/docs/CrossCompilation.html> · OSDev target triplet <https://wiki.osdev.org/Target_Triplet> · "The trouble with target triples" <https://mcyoung.xyz/2025/04/14/target-triples/> · Zig targets <https://ziglang.org/documentation/master/>.
[^trialdeletion]: D. F. Bacon, V. T. Rajan, "Concurrent Cycle Collection in Reference Counted Systems", ECOOP 2001 <https://doi.org/10.1007/3-540-45337-7_12> · "A Unified Theory of Garbage Collection" <https://doi.org/10.1145/1028976.1028982> · Tracing/RC <https://en.wikipedia.org/wiki/Tracing_garbage_collection>.
[^wasm]: WebAssembly Core Specification <https://webassembly.github.io/spec/core/> · WebAssembly overview <https://en.wikipedia.org/wiki/WebAssembly> · WASI <https://github.com/WebAssembly/WASI>.
[^x86]: Intel 64 and IA-32 Architectures SDM <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html> · AMD64 APM <https://www.amd.com/en/support/tech-docs> · System V AMD64 ABI <https://gitlab.com/x86-psABIs/x86-64-ABI> · Linux x86-64 syscall table <https://github.com/torvalds/linux/blob/master/arch/x86/entry/syscalls/syscall_64.tbl> · ASLR <https://en.wikipedia.org/wiki/Address_space_layout_randomization>.
