# The Brocken Language Specification

**Author:** Sanko Robinson
**Version:** v0.0.1
**Status:** Active Development

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

The `Brocken::` pseudo-namespace allows `core.brocken` to manipulate memory directly.

| Intrinsic | MIR output |
|-----------|------------|
| `Brocken::ptr_add(p, off)` | `add` (pointer arithmetic) |
| `Brocken::ptr_sub(p, off)` | `sub` (pointer arithmetic) |
| `Brocken::ptr_cmp_gt(a, b)` | `icmp sgt` |
| `Brocken::ptr_cmp_eq(a, b)` | `icmp eq` |
| `Brocken::load_i64(ptr)` | `load i64` |
| `Brocken::store_i64(ptr, val)` | `store i64` |
| `Brocken::syscall(n, ...)` | syscall instruction |
| `Brocken::syscall_by_name(name, ...)` | syscall instruction (resolved via platform ABI) |
| `Brocken::libc(name, ...)` | call libc function by name (resolved at link time) |
```
