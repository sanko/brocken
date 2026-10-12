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
- **Share-Nothing Concurrency:** Concurrency relies on independent OS threads (Isolates) with strict thread-local heaps. Because heaps are isolated, **reference counting requires zero atomic locks**.
- **Deterministic Memory:** Memory is managed by Immediate Reference Counting utilizing an Immix Bump-Allocator and segregated free lists. Circular references are handled by Bacon & Rajan trial deletion.
- **Ultra-Modern Perl Ergonomics:** Brocken adopts modern Perl idioms while shedding historical parsing ambiguities: invariant sigils, post-dereference syntax, Corinna-style classes with `ADJUST`/`DESTROY`, compile-time attributes, strict lexical scoping, and zero-cost exceptions.

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
- `state` - Persistent lexical variable (initialized once).
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

If a variable type is omitted, it defaults to `Any`. Managed types are dynamically allocated on the thread-local Immix heap and tracked via reference counting.

* `Any` - The universal dynamic 16-byte Fat Scalar.
* `Int` - Boxed integer.
* `Float` - Boxed float.
* `Bool` - Boxed boolean.
* `String` - Managed pointer to UTF-8 length-prefixed, NUL-terminated bytes.
* `Class` - Managed heap object instance pointer.

**The Fat Scalar Layout (`Any`):**
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

All other values—including `0.5`, `-1`, `"00"`, `"false"`, and any object pointer—evaluate to **true**.
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
Hashes in `core.brocken` use an **O(1) Open Addressing with Linear Probing** architecture.
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
- `:returns(Type, ...)` — Defines return type or tuple.
- `:export` — Emits the symbol into the binary’s export table for FFI/C interop.
- `:inline` / `:noinline` — Direct optimization hint.
- `:pure` — Guarantees no side effects (eligible for CSE and Dead Code Elimination).

**Variable Attributes:**
- `:const` — Immutable after initialization; re-assignment is a compile error.
- `:aligned(N)` — Enforces N-byte memory alignment (useful for SIMD arrays).

**Class Field Attributes:**
- `:param` — Generates constructor argument: `Class->new(field => $val)`.
- `:reader` — Generates accessor: `$obj->field()`.
- `:writer` — Generates mutator: `$obj->set_field($val)`.
- `:accessor` — Generates both reader and writer.
- `:weak` — Weak reference; prevents reference cycles by bypassing `incref`/`decref`.

---

## 8. Object-Oriented Programming (Classes)

Brocken uses Corinna-style classes with strict encapsulation. Fields are strictly private unless exposed via attributes.

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
} catch ($err) {
    warn("Recovered: $err");
} finally {
    say("Cleanup complete");
}
```

**v0.0.1 Implementation:** Brocken implements exceptions via `setjmp`/`longjmp` (SJLJ) managed on the Isolate Control Block (ICB).
- **The Landing Dispatcher:** To guarantee `finally` blocks execute exactly once under all conditions, the compiler lowers the `try` block into a state machine.
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

Objects are allocated using the Immix algorithm:
- Memory is managed in 32KB blocks, sub-divided into 256-byte lines.
- **Hot Path:** Freed 16-byte fat scalars are immediately pushed to a segregated singly-linked list (`free16_head`) threaded directly through the freed payload slots. `bump_alloc` consumes this list first.
- **Cold Path:** Line-aware bump allocation using a 128-bit availability bitmap stored in the header of the 32KB block.
- **Block Ownership:** Blocks tile a single `BLOCK_SIZE` grid anchored at the first block (`heap_base + ICB::SIZE`). A freed object is charged to the block that contains its address, so `live_count` is always decremented on the owning block regardless of which block is currently allocating.

### 10.3 Trial Deletion (Bacon & Rajan Cycle Detection) (Layer 2)

To collect circular references without a tracing pause, Brocken uses Bacon & Rajan trial deletion.
- When `decref` leaves an object with `RC > 0` (and it is not marked as a Leaf), it is pushed to a suspect ring buffer on the ICB.
- When the buffer fills, `gc_drain()` executes a local sub-graph trace: marking nodes Purple -> Gray -> White, scanning, and collecting isolated cycles.

---

## 11. Concurrency: Isolates, Fibers, and Channels

### 11.1 Isolates (OS Threads)
An Isolate is a heavy, share-nothing OS thread with an independent Immix heap and Isolate Control Block (ICB) pinned to a hardware register (`r14` on x86_64, `x28` on ARM64, `s11` on RISCV64).

### 11.2 Fibers (Green Threads)
Fibers are M:N cooperative coroutines multiplexed inside an Isolate. They share the Isolate's heap and are scheduled via explicit `ctx_swap` instructions managed by a Fiber Control Block (FCB).

### 11.3 CSP Channels
Channels (`chan_create`, `chan_send`, `chan_recv`) provide thread-safe communication between Isolates. They are bounded ring buffers protected by a global `.data` mutex and condition variable.

**v0.0.1 Ownership Semantics (Erlang Model):**
Because heaps are strictly thread-local, passing pointers between Isolates is fatal. In v0.0.1, channels accept primitives (`i64`, `f64`, `bool`). If an aggregate (Hash, Array, Class) is sent across a channel, the runtime automatically executes a **Deep-Copy Serialization** into the receiving Isolate's heap.

*(Note: Zero-copy ownership transfer using a `move $var` affine scope checker and a Global Message Arena is planned for v0.0.2).*

---

## 12. Compilation Pipeline & Intrinsics

1. **Katsuro (Frontend):** Lexer and Pratt Parser generate the AST.
2. **Lindsay (Middle-end):** Lowers AST to architecture-agnostic Static Single Assignment (SSA) IR. Injects `incref`/`decref`, lowers `Brocken::` pseudo-namespaces to raw memory opcodes.
3. **Jenny (Backend):**
   - Lowers IR to Machine IR (MIR).
   - **RegAlloc:** Linear Scan register allocation handling Spills and Caller-Saved registers dynamically.
   - **Linker:** Outputs raw machine code bytes to executable formats (`ELF64`, `PE32+`, `Mach-O`, `Wasm`), resolving cross-function RVAs and generating native OS entry stubs.
   - **DWARF v5:** Emits `.debug_line`, `.debug_info`, and `.debug_frame` for native GDB/LLDB debugging.

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

The FFI intrinsics are the only place the capability mask is consulted today (§15.4). `syscall_by_name` and `libc` require a literal string for the name so it can be resolved before linking.

### 12.2 Targets & Binary Formats

A target is a normalized four-part triple, `arch-vendor-os-env` (`x86_64-pc-linux-gnu`, `aarch64-apple-darwin-macho`). `Brocken::Katsuro::Platform::parse` maps a triple to a platform class, and that class answers the register sets, the calling convention, the syscall numbers, and which code generator and linker to build. Host detection probes `clang`, then `gcc`, then falls back to Perl's `Config`.

The code generator and the binary format are independent axes: one generator serves several formats.

| Architecture | Code generator | Notes |
|---|---|---|
| `x86_64` | `Codegen::X86_64` | Complex addressing (SIB), `RDX:RAX` for `div`/`umulh` |
| `aarch64` | `Codegen::ARM64` | Load/store architecture |
| `riscv64` | `Codegen::RISCV64` | 12-bit immediates force scratch materialisation under pressure |
| `wasm32` | `Codegen::Wasm` | Stack machine; no threads |

| OS family | Format | Linker |
|---|---|---|
| Linux, the BSDs, Haiku, Solaris/illumos | ELF64 | `Linker::ELF64` |
| macOS / Darwin | Mach-O | `Linker::MachO` |
| Windows | PE32+ | `Linker::PE` |
| WASI | Wasm module | `Linker::Wasm` |

An architecture with no code generator is refused with `Unsupported platform for Brocken: <friendly>`; the platform asks its own class for the backend rather than carrying a dispatch table.

### 12.3 Cross-Compiling

A cross compile is a platform passed to the constructor; every later call is unchanged.

```perl
my $brocken = Brocken->new(
    platform => Brocken::Katsuro::Platform::parse('aarch64-unknown-linux-gnu')
);
```

The linker writes a real executable for the other architecture. It does not run there; executing it needs an emulator or the real target. The test suite uses `BROCKEN_SYSROOT_AARCH64` / `BROCKEN_SYSROOT_RISCV64` to run foreign output under `qemu` and skips those tests when the sysroot is unset (§17.3).

### 12.4 Entry Point

There is no special `sub main`. Top-level statements are compiled into an implicit `_BROCKEN_ENTRY`, which receives the heap base from the OS entry stub and returns the process exit status.

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

The entry stub is OS-specific (it sets up the stack, the ICB, and the initial fiber) and is generated by the linker, not written in Brocken.

---

## 13. Building & Reproducible Builds

### 13.1 How a Build Is Driven

The compiler is a Perl library (a `bkn` CLI is planned — §17.4). A build is four calls:

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
| `fuel` | instruction budget per isolate (§15.2) | 1,000,000 |
| `mem_limit` | heap bytes per isolate, `0` = unlimited (§15.3) | 0 |
| `capabilities` | capability bitmask (§15.4) | `~0` |
| `stack_reserve` | initial thread stack reserve, PE only | 4 MiB |
| `stack_commit` | initial thread stack commit, PE only | 2 MiB |
| `runtime` | path to `core.brocken` | `src/runtime/core.brocken` |

`Brocken->set_default_policy(%opts)` moves the defaults for every compiler built afterwards, and is equivalent to setting `$Brocken::default_fuel`, `$Brocken::default_mem_limit`, and `$Brocken::default_capabilities`. Debug information is enabled on the linker (`set_debug_level`, §14.2), not the constructor.

### 13.2 Deterministic Output

Builds are byte-reproducible. Perl randomizes hash iteration order once per process (`PERL_HASH_SEED`), and any pass that walks a hash and writes the result into the emitted artifact perturbs the object file from build to build. Every such walk is sorted:

- **RegAlloc** sorts live sets and spill slots while building intervals and reloads.
- **Codegen** sorts its scratch/reload sets and the Wasm source/offset maps.
- **`Linker::ELF64`** sorts the names feeding the SYSV `.hash` chain.

Compiling the identical module under two different `PERL_HASH_SEED` values now yields byte-identical objects and linked executables. Determinism here is a correctness property, not just convenience: an unsorted walk in the allocator was what made RISC-V i128 `udiv` correct under some seeds and wrong under others.

### 13.3 Timestamps

The linker carries a `timestamp` (`set_timestamp`), defaulting to `effective_timestamp() = $timestamp // time()`. On PE32+ that value is written into the COFF header and the optional header; setting it explicitly, or exporting the conventional `SOURCE_DATE_EPOCH`, pins the bytes. ELF64 emits deterministic OSABI/ABI notes, so it has no equivalent knob.

### 13.4 Seeded Inputs

The test generator's reproducibility rests on a seed, not on program text. A `(seed, case_num, max_ops, max_vars)` tuple is packed into a compact, reversible hex `case_id` (`Brocken::Fuzz::encode_case_id`), and `Brocken::Fuzz::run_case_id($id)` re-seeds and replays exactly that input in any process, on any machine, days later (§17.1).

---

## 14. Debugging & Diagnostics

Brocken exposes itself to debuggers two ways: standard DWARF v5 for source-level work, and a compact `.brk_sym` table for return-address symbolisation without DWARF. It also carries internal trace hooks for debugging the compiler itself.

### 14.1 Debug Information (DWARF v5)

Debug data is built by `Brocken::Jenny::Linker::DWARF`, assembled during codegen by each backend's `build_debug_data`, and linked into the final image.

| Section | Purpose |
|---|---|
| `.debug_line` | Machine-code offset to source line/column mapping |
| `.debug_info` | Compile unit, subprograms, base types, struct types, variables |
| `.debug_abbrev` | DIE tag/attribute declarations (ULEB128) |
| `.debug_frame` | Call-frame information and frame-pointer recovery |
| `.debug_aranges` | Address-range table for fast lookup |
| `.debug_names` | DWARF v5 accelerated access index (case-folding DJB hash) |
| `.debug_str` | String pool referenced by `.debug_names` |
| `.eh_frame` / `.eh_frame_hdr` | Unwind data, built when an `eh_frame_base` is supplied |

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

Every user-visible `alloca` carries a `debug_name` and `debug_type_name`, set by the lowerer and attached to its variable DIE (`DW_AT_name`, `DW_AT_type`, `DW_AT_location` as `DW_OP_fbreg`, `DW_AT_decl_file/line/column`, and `DW_AT_artificial` — 0 for user variables, 1 for compiler temporaries). When `class_info` is present, `.debug_info` also emits `DW_TAG_structure_type` DIEs with `DW_TAG_member` children (offset, name, type) at level ≥ 4, and every function gets a `DW_TAG_subprogram` with its name and code range.

### 14.5 Native Backtraces (`.brk_sym`)

Every function saves its frame pointer (`rbp`, `x29`, or `s0`) and points it at the caller's saved frame pointer, so a backtrace is a pointer walk. `.debug_frame` describes the same recovery for debuggers.

Independently of DWARF, the linker can emit a `.brk_sym` ("Native Backtrace Info") section from `set_func_ranges([{ name => ..., start => ..., end => ... }, ...])`:

```
word    count
count × { start_rva, end_rva, name_offset }
byte[]  NUL-terminated name pool
```

This gives a minimal symbol table that resolves return addresses without any `.debug_*` sections. ELF64, Mach-O, and PE all emit it, and it is the mechanism behind the zero-cost native backtrace test.

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
| `SOURCE_DATE_EPOCH` | Pin the PE link timestamp (§13.3) |

### 14.8 Compile-Time Diagnostics

Every AST node carries `file`, `line`, and `col` from the token that introduces it, and the position propagates into parse/lower errors. A `# line "file" N [C]` directive overrides the reported position for subsequent tokens, so generated code can attribute itself to its origin. Runtime error messages follow the same convention: `die`/`warn` append `" at file line N.\n"` when the message lacks a trailing newline (§9.3).

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

Fuel is an `i64` at `ICB::FUEL`. The lowerer emits a decrement-and-test at function entry, at every loop back-edge, and before call sites; at zero it writes `ERR_NO_FUEL` and routes to an exit block. The default is 1,000,000 and it is set with `fuel =>` or `$Brocken::default_fuel`. A smaller budget makes a runaway loop fail fast rather than hang a test run.

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

The mask defaults to `~0`. Only `CAP_FFI` is consulted on the current path; the remaining bits are reserved for the filesystem, network, and process-spawn gates.

### 15.5 Stack Guard

`ICB::STACK_LIMIT` is seeded at entry to `sp - STACK_BUDGET`, where `STACK_BUDGET` is a 2 MiB runway, and the PE stack reserve must stay above it. Each fiber seeds the same guard against its own 64 KiB stack. Overflow sets `ERR_STACK`. Because ARM64 and RISC-V share a register between the first argument and the return value, a fresh fiber receives its ICB through an FCB transfer slot rather than the return register.

### 15.6 Error Codes

`ICB::ERR_CODE` records the reason a program aborted: `ERR_OK` (0), `ERR_OOM` (1), `ERR_NO_FUEL` (2), `ERR_SECURITY` (3), `ERR_DIV_ZERO` (4), `ERR_THROW` (5), `ERR_STACK` (6).

---

## 16. Security Considerations

### 16.1 Hash Collision Resistance

The v0.0.1 hash table uses linear probing over an identity hash and preserves insertion order. It is **not** collision-hardened: an attacker who controls keys (a web form, untrusted input) can force worst-case linear lookups. The planned replacement is **SipHash-2-4**, keyed per process from the OS CSPRNG, exposed as an intrinsic. (Planned for v0.0.2.)

### 16.2 Randomness (CSPRNG)

For secrets (tokens, nonces, hash seeds), v1 draws from the OS directly through `libc`:

| OS | Call |
|---|---|
| Linux | `getrandom(buf, len, flags)` |
| Windows | `BCryptGenRandom(NULL, buf, len, BCRYPT_USE_SYSTEM_PREFERRED_RNG)` |
| macOS / BSD | `getentropy(buf, len)` |

The planned v2 is a built-in ChaCha20 keystream in `core.brocken`, seeded from the OS once and reseeded periodically, exposed as `Brocken::Runtime::secure_rand` with an optional fixed-seed mode for tests.

### 16.3 Host Bindings (Planned)

The ICB already reserves `gate_table` and `host_icb`. The planned `bind` API enters a guest-visible gate, deep-copies arguments into the host heap, swaps the ICB register to the host's, runs the host closure, and deep-copies the result back — validating the gate ID and the capability mask, and using the stack guard to contain runaway recursion.

---

## 17. Tooling & Ecosystem

### 17.1 Fuzzer

`Brocken::Fuzz` generates small random programs, compiles and runs them, and compares against an interpreted answer. Every case is identified by a `(seed, case_num, max_ops, max_vars)` tuple, encoded as a reversible hex `case_id`; `run_case_id($id)` replays a failing case exactly. `bin/fuzz_runner.pl` wraps it:

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
| **Isolate** | An OS thread with its own Immix heap and ICB. No shared mutable state. |
| **Fiber** | A cooperative green thread within an isolate, scheduled by `ctx_swap`; shares the isolate's heap. |
| **ICB** | Isolate Control Block, pinned to `r14`/`x28`/`s11`. Holds limit, fuel, capability, and GC state. |
| **FCB** | Fiber Control Block: spilled callee registers, saved stack pointer, resume PC, parent, and transfer slot. |
| **CCB** | Channel Control Block: a shared bounded ring buffer with a mutex and condition variable. |
| **Fat Scalar** | The 16-byte `Any` representation: refcount, GC flags, type tag, aux data, payload. |
| **Immix** | Bump allocator over 32 KiB blocks divided into 256-byte lines, with segregated free lists. |
| **Perceus** | Compile-time RC optimization (borrow inference, RC elision, reuse). Planned. |
| **MIR** | Machine IR, the post-lowering architecture-specific instruction form. |
| **Lindsay** | The architecture-agnostic SSA middle-end IR. |
| **Jenny** | The backend: IR-to-MIR lowering, register allocation, encoding, linking. |
| **Katsuro** | The front end: platform abstraction, lexer, parser, AST, lowering to Lindsay. |
| **Trial deletion** | Bacon & Rajan cycle collection run from the ICB suspect buffer. |
| **`.brk_sym`** | The Native Backtrace Info section: a packed function table for symbolising return addresses. |
| **DWARF** | The standard debug-information format emitted for GDB/LLDB. |
| **SEH** | Windows structured exception handling (`.pdata`/`.xdata`). Planned. |
