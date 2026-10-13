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

A **class instance** reuses this 8-byte header but stores its field block from offset 8 instead of a single
payload word. It carries type tag `4` (shared with a boxed `ptr`) and, unlike a boxed `ptr`, a nonzero class
id in the 4-byte auxiliary word. The runtime's cycle collector reads that id to reach the compiler-generated
`Class::__scan` / `Class::__restore` methods for the instance; a class with no owned dynamic field against
its whole ancestor chain is marked Leaf, so it is never buffered as a cycle suspect.

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

**Positional parameter defaults.** Typed positional parameters may carry a default (`sub add(i64 $a = 1, i64 $b = 2)`), and omitted *trailing* arguments take their default. The default is then lowered and filled at the call site, so it may reference any earlier parameter — including one that was itself defaulted (`sub pair(i64 $a = 3, i64 $b = $a + 1)`). Filling stops at the first omitted parameter that has no default. Defaults evaluate in the caller's context, so they can use caller-scope variables but not the callee's fields or `$self`. (M0, shipped; see [`class_roadmap.md`](class_roadmap.md) §1.3.)

### 7.2 Named Parameters

**Planned.** Named parameters are prefixed with `:` and passed via `name => value` pairs.
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
- `:param` - Generates constructor argument: `Class->new(field => $val)`. An explicit name may be given: `:param(name)`.
- `:reader` - Generates accessor: `$obj->field()`. An explicit name may be given: `:reader(name)`.
- `:writer` - Generates mutator: `$obj->set_field($val)`, which returns `$self` so calls can be chained. An explicit name may be given: `:writer(name)`.
- `:accessor` - Generates both reader and writer; `:accessor(name)` names the reader (and the writer becomes `set_` + that name).
- `:weak` - Stores the pointer without taking refcount ownership: the constructor, the generated writer, and a field assignment all store without an `incref` (and never release the value they displace), and the generated destructor and the cycle-scan hooks skip the field, so a weak edge cannot hold a reference cycle open. The referent must outlive the instance.

As in `perlclass`, when no explicit name is given, the generated name is the field name minus its sigil with
exactly **one leading underscore removed**: `field $_foo :param;` is addressed by the caller as `new(foo => ...)`,
`:reader` on `$_foo` generates `foo()`, and `:writer` on `$_foo` generates `set_foo()`. A field `$__bar` keeps one
underscore (`_bar`), matching Perl's rule.

A field may also hold several values. `field [T; N] $name` reserves `N` elements of `T` inline in the object, read
in the class as `@name[i]` and outside it as `$obj->name[i]`; `field T @name` is a single pointer slot whose
elements live elsewhere; and `field T %name` is an opaque pointer slot for hash data. A `:reader` on any of the
three returns the element/hash base pointer, and `:param`/`:writer` on the pointer forms take a `ptr`. The inline
count must be a compile-time constant, and an inline array cannot be `:param` because there is no whole-array value
to pass. Indexing a pointer form does not follow a heap header — the slot is the element base itself.

---

## 8. Object-Oriented Programming (Classes)

Brocken uses Corinna-style classes with strict encapsulation. Fields are strictly private unless exposed via attributes.

**Implementation status.** The class system is being brought up in two milestones. v0.0.1 targets parity with Perl's core `class` feature (`perlclass`); v0.0.2 adds selected `Object::Pad` features. Today the front end implements `class` (block form, with an optional version and attributes) and the `class NAME;` statement form, typed `field` with the `:param`/`:reader`/`:writer`/`:accessor` attributes, inline/pointer array fields (`field [T; N] $x`, `field T @x`) and opaque hash fields (`field T %x`), `=`/`//=`/`||=` field defaults (an initializer sees the earlier fields and may use `$self`/`__CLASS__`), `method`, positional parameter defaults (`method greet(String $name = "someone")`), any number of `ADJUST` blocks (run in declaration order), single inheritance via `:isa(CLASS)`, `SUPER::`, and `DESTROY`; writers return `$self` so calls can be chained. Method resolution and dispatch are static (compile-time): `$obj->m` walks the receiver's ancestor chain, so an inherited method is callable and fields remain lexical to the class that declares them. `DESTROY` runs derived-to-root when called. A non-escaping `Class->new` local is reclaimed at scope exit through a generated `Class::__destroy` thunk that runs `DESTROY` exactly once, releases the owned dynamic fields, and frees the instance (an instance that escapes, or whose local is later bound to a non-fresh value, leaks by design). The cycle collector can scan class instances through generated per-class `__scan` / `__restore` methods, selected by the class id in the header. Roles, the optional `:isa` version argument, and `__CLASS__`'s value are **planned, not yet implemented** — the `DatabaseConnection::Static` example below is forward-looking. See [`class_roadmap.md`](class_roadmap.md) for the full shipped-versus-planned breakdown.

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

1. **Release Site:** A compiled site that drops an instance's last reference calls the runtime's `decref_obj`, which returns the new count without freeing; when that count is zero the site branches to the statically-known `Class::__destroy` thunk. (Boxed scalars keep the single runtime `decref`; the split exists so the class's destructor is chosen at compile time rather than through runtime dispatch.)
2. **Cascading Field Teardown:** The user only writes code to clean up external OS resources (file handles, sockets). After `DESTROY` finishes, the generated `Class::__destroy` thunk `decref`s every field containing a managed type (Strings, Arrays, Hashes, other Objects) and then calls `free_obj` to return the instance to the allocator.
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
- Arrays and hashes are scanned by the runtime (`gc_scan_list` / `gc_scan_hash`). Class instances are scanned through per-class `__scan` / `__restore` methods the compiler emits; `gc_scan_obj` / `gc_restore_refs` select them by the class id in the object header (tag `4` with a nonzero auxiliary word, which is how a class instance is told apart from a boxed `ptr`).

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


---

# APPENDIX: Future Material from spec.future.md

# The Brocken Language Specification (Future Edition)

**Document:** `docs/spec.future.md`
**Status:** Design Proposal & Target Architecture
**Author:** Sanko Robinson & Contributors
**Target Version:** v0.2.0+

> **Implementation Note:** This is the forward-looking companion to [`spec.md`](spec.md), which
> describes v0.0.1. It specifies the language and toolchain Brocken is building toward and is written
> ahead of the implementation: some of what follows ships today, some is agreed but unbuilt, and some
> is still a proposal. Read it as the design of record for the target architecture, not a status
> report; [`TODO.md`](../TODO.md) is the shipped-versus-outstanding checklist.

---

# Notation and Conformance

This document is the design of record for Brocken v0.2.0 and later. It specifies both the language
and the toolchain that compiles it.

## Scope

It specifies the surface syntax, the static semantics a conforming compiler **MUST** enforce, and the
observable behavior of a compiled program. It does not specify the internals of the toolchain —
which modules exist, how the register allocator picks a register, how a section is laid out — except
where those internals are observable. The memory layouts, the calling conventions, the diagnostics,
and the on-disk formats **are** part of this specification, because compiled programs, foreign code,
and existing binaries depend on them.

## Normative Language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHOULD**, **SHOULD NOT**,
**RECOMMENDED**, **MAY**, and **OPTIONAL** in this document are to be interpreted as described in
RFC 2119.

- Text marked *informative*, or shown in a note, is explanatory and imposes no requirement.
- All other text is **normative**.
- Code examples are illustrative unless the surrounding text states that a behavior is required.

A conforming implementation **MUST** accept every program this document accepts, and **MUST** reject
the programs it marks as ill-formed. Where this document leaves behavior unspecified, an
implementation **MAY** choose any behavior, but **SHOULD** document the choice.

## Grammar Notation

Grammars in this document use an extended BNF (EBNF) with the following metasyntax:

| Form | Meaning |
|---|---|
| `rule ::= ...` | Definition of a grammar rule |
| `A \| B` | Alternation |
| `( x )` | Grouping |
| `x?` or `[ x ]` | Optional: zero or one |
| `x*` or `{ x }` | Repetition: zero or more |
| `x+` | Repetition: one or more |
| `'text'` | A literal terminal |
| `Ident` | A non-terminal or a lexical class defined in prose |

Whitespace between tokens is not a token and carries no meaning outside string literals and
comments. The grammar is a summary; the token-level rules in [Syntax](#syntax) refine it.

---

# Development

## Installation

The Brocken toolchain (`bkn`) is distributed both as a standalone, zero-dependency static binary and
as an installable Perl distribution for toolchain development. Brocken compiles Ahead-Of-Time (AOT)
to native machine code without an external linker, GCC, LLVM, or C runtime (`libc`).

Brocken is bootstrapped with Perl 5.42+ using the `class` feature; the standalone `bkn` build embeds
the platform definitions and the self-hosted runtime (`src/runtime/core.brocken`), so an ordinary user
never needs Perl.

### Standalone Toolchain Binaries

```bash
# Unix-like (Linux, the BSDs, macOS)
curl -fsSL https://brocken.dev/install.sh | sh

# Windows (PowerShell 7+)
irm https://brocken.dev/install.ps1 | iex
```

### Installation from Source (Bootstrapping Environment)

```bash
git clone https://github.com/sanko/brocken.git
cd brocken

# Validate the host environment and run the compiler test suite
perl Makefile.PL
make
make test

# Install the bootstrap compiler and the bkn driver onto PATH
make install
```

### Verification

```bash
bkn --version
bkn target list
```

Expected output:

```text
bkn v0.2.0 (x86_64-pc-linux-gnu)
Host ABI: System V AMD64
Runtime: Self-Hosted Immix + Fiber Scheduler (core.brocken)
Toolchain Status: Independent (No GCC / No LLVM / No libc)
```

### The Compiler Pipeline

```text
       ┌────────────────────────────────────────────────────────┐
       │               Host Bootstrap / `bkn` Driver            │
       │      Perl 5.42+ bootstrap compiler or static binary    │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Parses user source + core.brocken
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │               Katsuro (Compiler Frontend)              │
       │       Lexer ──▶ Pratt Parser ──▶ AST Construction      │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Lowers to SSA
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │               Lindsay (Middle-End Optimizer)           │
       │    SSA ──▶ RC Insertion ──▶ Inlining ──▶ DCE           │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Lowers to architecture MIR
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │                 Jenny (Backend & Linker)               │
       │     Linear-Scan RegAlloc ──▶ Machine-Code Encoders     │
       │       ELF64 / PE32+ / Mach-O / Wasm Writers            │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Emits
                                  ▼
                 Standalone native executable or Wasm module
```

---

## Quick Start

### 1. Initialize a Project

```bash
bkn new telemetry_daemon
cd telemetry_daemon
```

The scaffolding creates:

```text
telemetry_daemon/
├── Brocken.toml         # Manifest, capabilities, and optimization profiles
├── src/
│   └── main.brocken     # Main compilation unit
└── tests/
    └── smoke.t          # Native TAP test suite
```

### 2. Write Application Code

Edit `src/main.brocken`:

```perl
use feature 'class';

class SensorNode {
    field u64    $id      :param;
    field String $name    :param :reader;
    field f64    $reading :reader = 0.0;

    ADJUST {
        die("Invalid sensor ID: cannot be zero") if $id == 0;
    }

    method sample(f64 $value) :returns(void) {
        $reading = $value;
    }

    method is_hot() :returns(bool) {
        return $reading >= 80.0;
    }
}

my SensorNode $node = SensorNode->new(id => 7, name => "reactor-core");
$node->sample(94.5);

if ($node->is_hot()) {
    say($node->name . " is running hot at " . $node->reading . "C");
}
```

### 3. Build and Run

```bash
# Compile and run immediately, in a temporary image
bkn run

# Compile to a standalone, stripped native binary
bkn build --release

# Confirm the binary has no runtime dependencies
ldd bin/telemetry_daemon 2>&1 || true   # 'not a dynamic executable' on Linux
```

---

## Environment

Brocken binaries interact directly with host kernels through raw system calls and register
conventions; no runtime shim, dynamic loader, or C startup file (`crt1.o`) is used.

### Target Triples

A target is a normalized four-part triple,
$\text{architecture}-\text{vendor}-\text{os}-\text{environment}$:

```text
x86_64-pc-linux-gnu
x86_64-apple-darwin-macho
x86_64-pc-windows-msvc
aarch64-unknown-linux-gnu
aarch64-apple-darwin-macho
aarch64-pc-windows-msvc
riscv64-unknown-linux-gnu
wasm32-unknown-wasi
```

The code generator and the binary format are independent axes: one generator serves several formats.

| Architecture | Code Generator | Binary Format | Calling Convention | Pointer Width |
|---|---|---|---|---|
| **x86_64** | `Codegen::X86_64` | ELF64 / PE32+ / Mach-O 64 | System V AMD64 / Microsoft x64 / Apple x86_64 | 64-bit |
| **AArch64** | `Codegen::ARM64` | ELF64 / PE32+ / Mach-O 64 | AAPCS64 | 64-bit |
| **RISC-V 64** | `Codegen::RISCV64` | ELF64 | LP64D | 64-bit |
| **Wasm32** | `Codegen::Wasm` | Wasm Module | WASI Core | 32-bit index (64-bit types emulated) |

### Register Roles and ABI Conventions

The compiler maps parameters, returns, the isolate control block, and the current fiber to
architecture-specific registers:

| Semantic Role | x86_64 (SysV) | AArch64 (AAPCS64) | RISC-V 64 (LP64D) |
|---|---|---|---|
| **Return 0** | `rax` | `x0` | `a0` |
| **Return 1** | `rdx` | `x1` | `a1` |
| **FP Return** | `xmm0` | `v0` | `fa0` |
| **Integer Arguments** | `rdi rsi rdx rcx r8 r9` | `x0`–`x7` | `a0`-`a7` |
| **Float Arguments** | `xmm0`–`xmm7` | `v0`–`v7` | `fa0`–`fa7` |
| **Frame Pointer** | `rbp` | `x29` | `s0` |
| **Link Register** | (stack) | `x30` | `ra` |
| **Link Register / SP** | `rsp` | `sp` | `sp` |
| **Fiber Register** | `r12` | `x28` | `s11` |

The **fiber register** holds the address of the currently running **Fiber Control Block (FCB)**.
Because it is pinned, every isolate shares one control-block address convention across the runtime,
the code generators, and the stack guards. On AArch64 and RISC-V the fiber register is the same as the
one the OS uses to carry the isolate control block during a fiber switch; the FCB records the owning
isolate in its `os_thread` field.

### Environment Variables

| Variable | Type | Purpose | Default |
|---|---|---|---|
| `BROCKEN_SYSROOT_AARCH64` | Path | Sysroot for emulating foreign AArch64 targets under QEMU | Unset |
| `BROCKEN_SYSROOT_RISCV64` | Path | Sysroot for emulating foreign RISC-V targets under QEMU | Unset |
| `BROCKEN_DUMP_INTERVALS` | Boolean | Emit live-interval ranges and spill decisions to `stderr` | `0` |
| `SOURCE_DATE_EPOCH` | Integer | Fixed epoch timestamp for byte-reproducible output | Host clock |
| `BROCKEN_DEFAULT_FUEL` | Integer | Instruction budget granted to a freshly spawned isolate | `1000000` |
| `BROCKEN_MEM_LIMIT` | Bytes | Hard ceiling for an isolate's heap (`0` = unconstrained) | `0` |
| `BROCKEN_LOG` | String | Log verbosity filter (`error`, `warn`, `info`, `trace`) | `warn` |

---

## Configuration

Project dependencies, compiler profiles, memory guarantees, and capability sandboxing live in
`Brocken.toml`.

```toml
[package]
name = "hyperion"
version = "0.2.0"
authors = ["Sanko Robinson <sanko@cpan.org>"]
entry = "src/main.brocken"
edition = "2026"

[profile.release]
opt_level = 3              # 0 = debug, 1 = size, 2 = speed, 3 = aggressive
strip = true               # Strip local symbols and non-essential sections
debug_level = 0            # 0 = none, 1 = line tables .. 4 = full DWARF v5
reproducible = true        # Sort every hash traversal for bitwise-identical output
lto = true                 # Cross-module SSA inlining and dead-code elimination

[profile.debug]
opt_level = 0
strip = false
debug_level = 4
asan = false               # Memory-layout bounds checker
stack_guard = true         # Emit prologue stack-limit checks

[isolate.defaults]
initial_fuel = 5_000_000   # Fuel decrements at entries, calls, and loop back-edges
initial_heap = "2MB"       # First Immix block allocation
max_heap = "512MB"         # Exceeding this raises ERR_OOM
stack_budget = "2MB"       # Guard runway below the hardware stack pointer

[capabilities]
fs_read = true             # Permit filesystem reads
fs_write = false           # Deny filesystem writes
net = true                 # Permit socket operations
system = false             # Forbid process spawns
ffi = false                # Forbid raw syscall / libc imports
```

---

# Fundamentals

## Syntax

Brocken uses modern Perl syntax while removing historical parsing ambiguities and irregular
grammatical forms.

### Source Text

A compilation unit is a sequence of Unicode scalar values encoded as UTF-8. A byte-order mark is
permitted and ignored. Source files **MUST** be valid UTF-8; a byte sequence that is not is a
well-formedness error reported before parsing. Tabs, carriage returns, and the several Unicode line
separators are not significant except as whitespace.

### Whitespace and Line Structure

Brocken is newline-terminated, not newline-sensitive: a statement ends at its `;`, not at a line
break, so an expression **MAY** span lines. Space, horizontal tab, carriage return, and newline
separate tokens and are otherwise ignored.

### Comments

| Form | Scope |
|---|---|
| `# ...` | A line comment, to the end of the line. |
| `=begin ... =end` | A block of embedded documentation (Pod6), discarded by the compiler. |
| `#\| ...` | A declarator comment attached to the declaration that follows it. |

```perl
# A line comment.
#| Attached to the next declaration; surfaced by the language server and `bkn fmt`.
sub checksum(ptr $buffer, i64 $len) :returns(u32) { ... }
```

### Identifiers and Namespaces

An identifier matches `/[a-zA-Z_][a-zA-Z0-9_]*/` and is case-sensitive. A qualified name uses the
namespace separator `::` (`Net::HTTP::Client`). A leading underscore is a convention, not a rule: a
single leading underscore is stripped when a field name is used to derive a constructor parameter or
accessor name (see [Classes](#classes)).

| Item | Convention |
|---|---|
| Types, classes, roles, packages | `UpperCamelCase` |
| Subroutines, methods, fields, variables | `snake_case` |
| Constants | `UPPER_SNAKE_CASE` |
| Native machine types | `lowercase` (`i32`, `f64`, `ptr`) |
| Managed scalar types | `Capitalized` (`Int`, `String`, `Any`) |

### Punctuation and Separators

Statements terminate with `;`. Blocks are delimited by `{ ... }`. Parentheses group expressions and
delimit call arguments; brackets `[ ... ]` index arrays and construct array references; braces
`{ ... }` index hashes and construct hash references. A comma `,` separates items in lists,
arguments, and declarations.

### Keywords

Keywords are reserved and **MUST NOT** be used as identifiers.

```text
ADJUST  DESTROY  adjoin  and  as  async  await  catch  class  const
decorator  defer  die  else  elsif  false  field  finally  for  foreach
if  isolate  last  method  my  next  not  or  our  package  print  ptr
redo  return  role  say  state  sub  throw  true  try  undef  unless
until  use  while  xor  yield
```

The built-in type names are **not** keywords: they are ordinary identifiers in the type namespace
and **MAY** be shadowed by a user declaration.

```text
i8   i16   i32   i64   i128      u8   u16   u32   u64   u128
f32  f64   bool  int   ptr       Any  Int  Float  Bool  String  Array  Hash
```

`true`, `false`, and `undef` are keyword literals. `async` and `await` are reserved by the
[execution policies](#execution-policies) surface.

### Numeric Literals

| Form | Example | Notes |
|---|---|---|
| Decimal | `1234` | |
| Underscore-separated | `1_000_000` | Ignored; for readability only |
| Hexadecimal | `0xDEAD_beef` | Case-insensitive digits |
| Octal | `0o755` | A lone leading `0` is not octal |
| Binary | `0b1010_0101` | |
| Floating point | `3.14159` | A digit is required on both sides of `.` |
| Scientific | `5e+10`, `1.5e-3` | The exponent sign is optional |
| 128-bit | `170141183460469231731687303715884105727` | Typed by context |

### String Literals and Escapes

A double-quoted string is delimited by `"..."` and interpolates. The following escapes are
recognized within it:

| Escape | Meaning |
|---|---|
| `\n` `\r` `\t` `\f` `\b` | Newline, carriage return, tab, form feed, backspace |
| `\a` `\e` `\0` | Alert, escape, NUL |
| `\\` `\"` | Literal backslash, literal double quote |
| `\$` `\@` `\%` | Suppress interpolation of the following sigil |
| `\x{HH}` | A Unicode scalar by code point (1–6 hex digits) |
| `\N{NAME}` | A named Unicode character |

A single-quoted string (`'...'`) does not interpolate and recognizes only `\\` and `\'`. The exact
interpolation rules are specified under [UTF8](#utf8).

### Grammar (EBNF)

```ebnf
Program         ::= Declaration* Statement* EOF ;

Declaration     ::= ClassDecl | SubDecl | PackageDecl | UseDecl | DecoratorDecl ;

ClassDecl       ::= 'class' Ident ( Version )? ( ClassAttr )* '{' ClassBody '}' ;
ClassBody       ::= ( FieldDecl | MethodDecl | AdjustDecl | DestroyDecl )* ;
FieldDecl       ::= 'field' Type ( Sigil | '[' Type ';' Const ']' Sigil ) Ident
                    ( FieldAttr )* ( FieldInit )? ';' ;
FieldInit       ::= ( '=' | '//=' | '||=' ) Expr ;
MethodDecl      ::= 'method' Ident Signature ( MethodAttr )* Block ;
AdjustDecl      ::= 'ADJUST' Block ;
DestroyDecl     ::= 'DESTROY' Block ;

SubDecl         ::= 'sub' Ident Signature ( SubAttr )* Block ;
Signature       ::= '(' ( ParamList )? ')' ;
ParamList       ::= Param ( ',' Param )* ;
Param           ::= ( ':' )? Type Sigil Ident ( '=' Expr )? ;

Statement       ::= VarDecl | AssignStmt | IfStmt | WhileStmt | ForStmt
                  | ReturnStmt | ThrowStmt | TryCatchStmt | LoopControlStmt
                  | DeferStmt | ExprStmt | Block | ';' ;

VarDecl         ::= 'my' ( Type )? Sigil Ident ( ( '=' | '//=' | '||=' ) Expr )? ';'
                  | 'my' '(' TargetList ')' '=' Expr ';' ;
AssignStmt      ::= Target ( '=' | '+=' | '-=' | '*=' | '/=' | '//=' | '||=' ) Expr ';' ;
Target          ::= Var | FieldAccess | DerefExpr | IndexExpr ;

IfStmt          ::= 'if' '(' Expr ')' Block ( 'elsif' '(' Expr ')' Block )* ( 'else' Block )? ;
WhileStmt       ::= 'while' '(' Expr ')' Block ;
ForStmt         ::= 'for' ( 'my' ( Type )? Sigil Ident )? '(' Expr ')' Block ;
ReturnStmt      ::= 'return' ( ExprList )? ';' ;
ThrowStmt       ::= ( 'throw' | 'die' ) Expr ';' ;
TryCatchStmt    ::= 'try' Block ( 'catch' '(' Sigil Ident ')' Block )? ( 'finally' Block )? ;
LoopControlStmt ::= ( 'last' | 'next' | 'redo' ) ';' ;
DeferStmt       ::= 'defer' Block ;

Expr            ::= BinaryExpr | UnaryExpr | PrimaryExpr ;
PrimaryExpr     ::= Const | Var | CallExpr | MethodCall | ConstructExpr | ParenExpr | Lambda ;
Lambda          ::= 'sub' Signature Block | 'method' Signature Block ;
```

### Operator Precedence and Associativity

Operators are listed from highest precedence (Level 1) to lowest (Level 20):

| Level | Operator | Fixity | Associativity | Description |
|---|---|---|---|---|
| **1** | `->` `->[]` `->{}` `->$*` `->@*` `->%*` | Postfix | Left | Dereference, invocation, indexing |
| **2** | `++` `--` | Postfix | Non-assoc | Post-increment / decrement |
| **3** | `**` | Binary | Right | Exponentiation |
| **4** | `!` `~` `\` `+` `-` | Prefix | Right | Logical/bitwise NOT, ref-take, unary signs |
| **5** | `=~` `!~` | Binary | Left | Pattern binding |
| **6** | `*` `/` `%` `x` | Binary | Left | Multiplicative, repetition |
| **7** | `+` `-` `.` | Binary | Left | Additive, string concatenation |
| **8** | `<<` `>>` | Binary | Left | Shifts |
| **9** | `<` `>` `<=` `>=` `lt` `gt` `le` `ge` | Binary | Left | Relational comparisons |
| **10** | `==` `!=` `<=>` `eq` `ne` `cmp` | Binary | Left | Equality and three-way comparisons |
| **11** | `&` | Binary | Left | Bitwise AND |
| **12** | `\|` `^` | Binary | Left | Bitwise OR / XOR |
| **13** | `&&` | Binary | Left | Short-circuit AND |
| **14** | `\|\|` `//` | Binary | Left | Short-circuit OR, defined-or |
| **15** | `..` `...` | Binary | Non-assoc | Range / flip-flop |
| **16** | `? :` | Ternary | Right | Conditional |
| **17** | `=` `+=` `-=` `*=` `/=` `//=` `\|\|=` | Binary | Right | Assignment and compound assignment |
| **18** | `not` | Prefix | Right | Low-precedence logical NOT |
| **19** | `and` | Binary | Left | Low-precedence logical AND |
| **20** | `or` `xor` | Binary | Left | Low-precedence logical OR / XOR |

---

## Variables

### Invariant Sigils

Sigils are **invariant**: the sigil denotes the storage container and never mutates with access
dimension or evaluation context.

| Sigil | Container | Element Access | Reference | Full Deref |
|---|---|---|---|---|
| `$` | Scalar / native primitive / object | `$x` | `\$x` | `$ref->$*` |
| `@` | Sequential indexed array | `@arr[0]` | `\@arr` | `$ref->@*` |
| `%` | Associative dictionary | `%map{"key"}` | `\%map` | `$ref->%*` |

```perl
# Arrays keep their @ sigil on element access
my @numbers = (10, 20, 30);
my i64 $first = @numbers[0];     # correct
@numbers[1] = 25;                # direct mutation

# Hashes keep their % sigil on element access
my %config = (host => "localhost", port => 8080);
my String $host = %config{"host"};
%config{"port"} = 9090;
```

### Storage Classes

```perl
# Lexical (register or local stack slot), dropped at block exit
my i64 $counter = 0;

# Persistent lexical: allocated once per isolate, survives scope exits
state u64 $call_count = 0;
$call_count++;

# Package-scoped global: lives in the isolate-local .data segment
our String $GLOBAL_NAME = "Primary Worker";

# Compile-time constant: evaluated at compile time, emitted into .rodata
const f64 $PI = 3.141592653589793;
```

### Truthiness

A value is **false** if and only if it is one of:

1. Numeric `0` or `0.0`
2. The string `"0"`
3. The empty string `""`
4. Undefined (`undef`, a null pointer, or Type Tag 0)

Everything else is **true**, including `"00"`, `"false"`, `0.5`, negative numbers, references, and
object pointers. A dynamic `Any` in boolean context is routed through
`Brocken::Runtime::is_truthy(ptr)` rather than being truncated blindly.

### Defined-Or and Conditional Assignment

```perl
# `//` is defined-or: eager (both operands evaluate), no short-circuit
my Any $a;
my Any $b = $a // "default";

# `//=` stores only when the slot is undefined (null pointer / null box)
my String $token;
$token //= generate_token();   # assigned
$token //= generate_token();   # skipped: the slot is now defined

# `||=` stores when the slot is false
my i64 $retries = 0;
$retries ||= 3;                # 3, because zero is false
```

On a native `int`/`float`/`bool`, which can never be `undef`, `//=` degrades to a plain `=`. In a
`my` declaration the conditional forms take the initializer unconditionally, because a fresh variable
has no prior value to test.

---

## Functions

Subroutines are declared with `sub` and require typed signatures. Return types are declared with the
`:returns(...)` attribute.

### Signatures and Register Tuples

A subroutine may return several values as a tuple, mapped directly onto the architecture's return
registers with no heap allocation:

- **x86_64:** `rax`, then `rdx`
- **AArch64:** `x0`, then `x1`
- **RISC-V 64:** `a0`, then `a1`

```perl
sub divide(i64 $numerator, i64 $denominator) :returns(i64, bool) {
    if ($denominator == 0) {
        return (0, false);           # no allocation
    }
    return ($numerator / $denominator, true);
}

my ($quotient, $ok) = divide(42, 6);
```

### Typing Judgements

Static typing is expressed with the usual inference relation $\Gamma \vdash e : \tau$:

$$
\frac{\Gamma(x) = \tau}{\Gamma \vdash x : \tau}\;[\text{Var}]
\qquad
\frac{\Gamma \vdash e_1 : \text{i64} \quad \Gamma \vdash e_2 : \text{i64}}{\Gamma \vdash e_1 + e_2 : \text{i64}}\;[\text{IntAdd}]
$$

$$
\frac{\Gamma \vdash e_1 : \tau \quad \Gamma[x \mapsto \tau] \vdash e_2 : \tau'}{\Gamma \vdash (\text{my } \tau\ x = e_1;\ e_2) : \tau'}\;[\text{Let}]
\qquad
\frac{\Gamma \vdash f : (\tau_1,\dots,\tau_n) \to (\sigma_1,\dots,\sigma_m) \quad \Gamma \vdash a_i : \tau_i}{\Gamma \vdash f(a_1,\dots,a_n) : (\sigma_1,\dots,\sigma_m)}\;[\text{Call}]
$$

### Parameter Defaults

Positional parameters may carry defaults. Omitted **trailing** arguments are filled at the call site,
in the caller's scope; a default may reference any earlier parameter:

```perl
sub connect(String $host, i64 $port = 8080, i64 $timeout = $port > 1024 ? 30 : 60) :returns(ptr) {
    # ...
}

my ptr $a = connect("127.0.0.1");        # port = 8080, timeout = 30
my ptr $b = connect("127.0.0.1", 80);    # port = 80,   timeout = 60
```

### Named Parameters

A parameter prefixed with `:` is passed at the call site by name with `=>`:

```perl
sub spawn_server(String $bind, :i64 $workers = 4, :bool $tls = false) :returns(void) {
    # ...
}

spawn_server("0.0.0.0", workers => 8, tls => true);
```

### Closures and Environment Records

A subroutine that captures no outer lexical lowers to a bare function pointer in `.text`. A
capturing subroutine allocates an Immix-managed **Environment Record** holding the captured slots,
passed to the closure as a hidden environment pointer and governed by the Caller-Borrows contract.

```perl
sub make_accumulator(i64 $start) :returns(ptr) {
    my i64 $total = $start;
    return sub (i64 $delta) :returns(i64) {
        $total += $delta;
        return $total;
    };
}
```

---

## Classes

Brocken implements encapsulation through Corinna-style classes (`use feature 'class'`).

### Fields, Attributes, and the Constructor

```perl
class BankAccount {
    field u64    $account_id :param;
    field String $owner_name :param :reader;
    field i64    $balance    :reader = 0;
    field bool   $is_frozen  = false;

    ADJUST {
        die("Invalid account ID: cannot be zero") if $account_id == 0;
    }

    method deposit(i64 $amount) :returns(i64) {
        die("Account is frozen") if $is_frozen;
        die("Amount must be positive") if $amount <= 0;
        $balance += $amount;
        return $balance;
    }

    DESTROY {
        # Runs immediately when the reference count reaches zero
    }
}
```

`Class->new(...)` is synthesized from the `:param` fields. When no explicit name is given, `:param`,
`:reader`, and `:writer` derive their name by stripping **exactly one** leading underscore:

- `field $_timeout :param;`  $\Rightarrow$ `new(timeout => 30)`
- `field $_timeout :reader;` $\Rightarrow$ `$obj->timeout()`
- `field $_timeout :writer;` $\Rightarrow$ `$obj->set_timeout(60)`
- `field $__private :reader;` $\Rightarrow$ `$obj->_private()` (one underscore remains)

### Field Attributes

| Attribute | Parameter | Semantics |
|---|---|---|
| `:param` | None or `(name)` | Exposes the field as a constructor argument. |
| `:reader` | None or `(name)` | Synthesizes a getter `$obj->name()`. |
| `:writer` | None or `(name)` | Synthesizes a chaining setter `$obj->set_name($v)` returning `$self`. |
| `:accessor` | None or `(name)` | Combines a reader with a chaining writer. |
| `:weak` | None | Stores the pointer without taking refcount ownership (breaks cycles). |

### Inheritance and Static Dispatch

Single inheritance is declared with `:isa(Parent)`. A subclass instance is the parent's field block
followed by the child's:

```perl
class PremiumAccount :isa(BankAccount) {
    field i64 $credit_limit :param = 1000;

    method deposit(i64 $amount) :returns(i64) {
        say("Premium deposit");
        return $self->SUPER::deposit($amount);
    }
}
```

Method dispatch is resolved **statically** at compile time: no vtable, no runtime method lookup, no
indirect branch. Fields are lexically private to the class that declares them and are **not**
inherited; methods are public and are.

### Physical Instance Layout

A class instance is a contiguous Immix allocation. The 8-byte header packs the reference count and
the type tag; fields begin at offset 8, in superclass-then-subclass order, with natural alignment:

```text
Offset  Size  Field
--------------------------------------------------------------------------------
 0      2     Reference Count (u16, saturated at 65535 = pinned)
 2      1     GC Flags (cycle suspect, buffered, leaf, BRC color)
 3      1     Type Tag
 4      4     Auxiliary / padding
 8      8     Superclass field: $account_id (u64)
16      8     Superclass field: $owner_name (managed string pointer)
24      8     Superclass field: $balance (i64)
32      1     Superclass field: $is_frozen (bool)
33      7     Alignment padding
40      8     Subclass field:   $credit_limit (i64)
Total: 48 bytes (8-byte naturally aligned)
```

---

## Modules

A module is a namespace that maps to a file on disk.

```perl
# lib/Math/Geometry.brocken
package Math::Geometry 1.0.0;

use feature 'brocken_native_types';

sub distance(f64 $x1, f64 $y1, f64 $x2, f64 $y2) :export :returns(f64) {
    my f64 $dx = $x2 - $x1;
    my f64 $dy = $y2 - $y1;
    return sqrt($dx * $dx + $dy * $dy);
}
```

Consuming modules:

```perl
# src/main.brocken
use Math::Geometry;

my f64 $dist = Math::Geometry::distance(0.0, 0.0, 3.0, 4.0);
```

During the Lindsay middle-end pass, symbols that are neither exported nor referenced are pruned from
the program (tree-shaking). A `package NAME;` declaration prefixes the declarations that follow, and
`package NAME { ... }` scopes the prefix to the block; an optional version literal (`package NAME VERSION;`)
is recorded as module metadata. Names that already contain `::` are treated as absolute. The special constant
`__PACKAGE__` evaluates to the current package name (the same full name used for qualification); it behaves
analogously to `__CLASS__` but refers to the current package, not the enclosing class. This allows modules
to qualify symbols without repeatedly spelling the full name.

---

## Attributes

Attributes are compile-time directives to the parser, middle end, and code generator.

### Subroutine Attributes

- `:returns(Type, ...)` — Return type, or a tuple mapped to return registers.
- `:inline` — Request inlining into caller blocks.
- `:noinline` — Forbid inlining.
- `:pure` — Guarantee no memory side effects (enables CSE).
- `:export` — Emit the symbol in the dynamic symbol table for C ABI interop.

### Variable Attributes

- `:aligned(N)` — Enforce N-byte alignment on a stack slot or static address.
- `:const` — Assert single assignment; mutation is a compile-time diagnostic.

---

## Decorators

Decorators are compile-time macro wrappers around subroutines, methods, and classes.

```perl
decorator timed(Sub $target) {
    return sub (*@args) {
        my i64 $start = Brocken::monotonic_clock();
        my @res = $target->(@args);
        my i64 $elapsed = Brocken::monotonic_clock() - $start;
        say("" . $target->name . " took ${elapsed}ns");
        return @res;
    };
}

@timed
sub execute_matrix_multiplication(ptr $a, ptr $b) :returns(ptr) {
    # ...
}
```

---

# Advanced

## Concurrency

Brocken's concurrency is modeled on Hoare's Communicating Sequential Processes and Plan 9's Alef. It
has two layers: heavy **isolates** (OS threads with strictly disjoint heaps) and lightweight
**fibers** (cooperative green threads multiplexed inside an isolate). They communicate over typed
**channels**.

```text
┌─────────────────────────────────────────────────────────────┐
│                         ISOLATE 1                           │
│  OS Thread (pthread / CreateThread)                         │
│  Pinned fiber register (r12 / x28 / s11) -> FCB              │
│  Thread-Local Immix Heap (zero-lock reference counting)     │
│                                                             │
│   ┌──────────────┐   ctx_swap    ┌──────────────┐           │
│   │   Fiber A    │ <===========> │   Fiber B    │           │
│   │ Stack (64KB) │               │ Stack (64KB) │           │
│   └──────────────┘               └──────────────┘           │
└──────────────────────────────┬──────────────────────────────┘
                               │
                Bounded channel ring buffer (CCB)
             deep-copy across the isolate boundary
                               │
┌──────────────────────────────┴──────────────────────────────┐
│                         ISOLATE 2                           │
│  Disjoint Immix heap and control block                      │
└─────────────────────────────────────────────────────────────┘
```

### Isolates (Share-Nothing OS Threads)

An isolate is an independent OS thread with its own heap and its own control block.
Because heaps never overlap, reference counting is a local load-modify-store sequence: **no atomic
instructions, no bus locks**. The isolate control block address is held in a pinned register for the
duration of the thread.

```perl
my ptr $iso = isolate(sub () {
    say("Running on an independent OS thread with its own heap");
});

isolate_join($iso);
```

### Fibers (Cooperative Coroutines)

A fiber is an M:N cooperative coroutine with a private 64 KiB stack, switched with the
architecture-specific `ctx_swap` sequence and recorded in a **Fiber Control Block** (FCB). The fiber
register holds the address of the currently running FCB.

```perl
my ptr $worker = fiber(sub ($seed) {
    say("Fiber step 1: received $seed");
    my Any $reply = yield($seed * 10);
    say("Fiber step 2: received $reply");
    return $reply + 5;
});

my i64 $out1 = transfer($worker, 5);   # step 1; returns 50
my i64 $out2 = transfer($worker, 15);  # step 2; returns 20
```

### Fiber Control Block (FCB) Layout

`ctx_swap` spills one 8-byte slot per callee-saved register, in save order; the fiber register's slot
doubles as `self`. Named fields follow the register region. The stack pointer keeps its place in the
register region on AArch64 and RISC-V (which spill `sp`), and takes the first named slot on x86_64.

```text
Offset (AArch64 / RISC-V / x86_64)  Field          Description
-------------------------------------------------------------------------
 0..              (13/14/6 slots)   saved_regs     Callee-saved register spill array
 self*8                              self           FCB self-pointer (fiber-register slot)
 96 / 104 / 48   saved_sp           Hardware stack pointer at the last switch
104 / 112 / 56   parent             FCB address of the parent / yielder fiber
112 / 120 / 64   resume_pc          Code address to jump to on resumption
120 / 128 / 72   os_thread          Owning isolate's control block
128 / 136 / 80   stack_limit        Stack guard boundary for this fiber (sp - runway)
136 / 144 / --   transfer_value     Fiber hand-off value (AArch64 and RISC-V only)
144 / 152 / 88   size               FCB size for the architecture
```

### Channels (CSP)

Channels are typed, synchronized, bounded ring buffers (`chan_create`, `chan_send`, `chan_recv`,
`chan_close`):

```perl
my ptr $chan = chan_create(16);   # capacity 16

isolate(sub () {
    for my $i (1 .. 10) {
        chan_send($chan, $i * 100);
    }
    chan_close($chan);
});

while (my ($value, $open) = chan_recv($chan)) {
    last unless $open;
    say("Received: $value");
}
```

**Data-transfer invariants:**

1. **Primitives** (`i8`..`i128`, `f32`, `f64`, `bool`) are copied by value through the ring buffer.
2. **Aggregates** (Strings, arrays, hashes, objects) are deep-copied into the receiving isolate's
   heap, preserving the thread-local heap invariant. Zero-copy ownership transfer (`move $var` with a
   scoped affine checker and a global message arena) is a later optimization.

### Primitive Reference

The concurrency surface is a small set of intrinsics; everything in this section is defined in terms
of them. They carry no hidden allocation and never block while holding the isolate lock.

| Intrinsic | Signature | Semantics |
|---|---|---|
| `isolate` | `(Code) -> ptr` | Spawns an OS thread with a fresh heap and runs `Code` on it. Returns an opaque thread handle. |
| `isolate_join` | `(ptr) -> Any` | Blocks the caller until the isolate finishes and returns its result; the heap is reclaimed afterwards. |
| `fiber` | `(Code) -> ptr` | Creates a suspended fiber with a 64 KiB stack. Does not run until first `transfer`. |
| `transfer` | `(ptr, Any) -> Any` | Switches to `fiber`, delivering the second argument as the value of that fiber's pending `yield`/`transfer`, and returns the value the fiber hands back. |
| `yield` | `(Any) -> Any` | Suspends the running fiber and hands its value to the resumer; resumes with the value passed to `transfer`. |
| `chan_create` | `(i64) -> ptr` | Allocates a bounded channel with the given capacity (must be `> 0`). |
| `chan_send` | `(ptr, Any) -> bool` | Enqueues a value, blocking while the ring is full; returns false if the channel is closed. |
| `chan_recv` | `(ptr) -> (Any, bool)` | Dequeues a value, blocking while the ring is empty; the flag is false once the channel is drained and closed. |
| `chan_close` | `(ptr) -> bool` | Marks the channel closed; further sends fail and receives drain the remaining values before signaling closed. |

### Scheduling and Memory Model

- **Preemptive between isolates.** Isolates are OS threads scheduled by the kernel; the runtime does
  not intervene.
- **Disjoint heaps.** Each isolate owns an Immix heap. There is no shared mutable state, so
  reference counting needs no atomics and cache lines are never shared across cores.
- **Copy across boundaries.** Every value crossing an isolate boundary is deep-copied; pointers into
  an isolate's heap **MUST NOT** be observed from another isolate. A channel is the only sanctioned
  crossing point.
- **Structured teardown.** An isolate that returns or is joined reclaims its heap. An isolate that
  panics runs its deferred blocks and unwinds, and the handle reports the failure to `isolate_join`.

The `async`/`await` surface is sugar over `fiber`/`transfer`; see
[Execution Policies](#execution-policies) for how a program selects its scheduling discipline.

---

## Exceptions

Exceptions are zero-cost landing dispatchers backed by an SJLJ (`setjmp`/`longjmp`) handler chain
recorded on the isolate control block (`ICB::EXCEPTION_HANDLER_STACK`).

```perl
try {
    die("Database transaction aborted");
}
catch ($err) {
    warn("Recovered from exception: $err");
}
finally {
    say("Releasing transaction locks");
}
```

### The Landing Dispatcher

To guarantee that a `finally` block runs exactly once under every exit path — normal completion,
caught exception, early `return`, `last`, or `next` — the compiler lowers `try` into a state machine:

```text
[try_setup]  ──▶ push the jmp_buf onto ICB::EXCEPTION_HANDLER_STACK
      │
[try_body]   ──▶ normal exit pops the handler ──▶ [finally] ──▶ [merge]
      │
      └── (throw / die)
            │
            ▼
[landing]    ──▶ pop the handler, load the thrown value
            │
            ├──▶ [catch_body] ──▶ [finally] ──▶ [merge]
            └──▶ (no catch)   ──▶ [finally] ──▶ rethrow
```

Because the `longjmp` path restores only callee-saved registers, the register allocator keeps
caller-saved registers out of the pool for any function that calls `setjmp`, so a value live across
the `setjmp` cannot be clobbered by the unwind.

---

## Resources

Deterministic cleanup is expressed with scope destructors and `defer`:

```perl
sub process_file(String $path) :returns(void) {
    my ptr $fh = open_file($path);
    defer { close_file($fh); }   # runs on every block exit

    # ... use $fh ...
}
```

The `defer` body runs when the enclosing block exits, whether by normal completion, `return`,
`last`/`next`, or a thrown exception.

---

## Iterators

An iterator is a zero-allocation cursor object conforming to the iterator protocol: a `next` method
returning a `(value, bool)` register tuple.

```perl
class NumberSequence {
    field i64 $current :param = 0;
    field i64 $limit   :param;

    method next() :returns(i64, bool) {
        return (0, false) if $current >= $limit;
        my i64 $value = $current++;
        return ($value, true);
    }
}

for my $number (NumberSequence->new(limit => 5)) {
    say("Sequence: $number");
}
```

A range in a `for` header lowers to a zero-allocation register induction loop:

```perl
for my i64 $i (0 .. 1000) {
    # $i is a register counter; no array is allocated
}
```

---

## Type System

Brocken separates **unboxed raw machine types** (lowercase) from **managed fat scalars**
(capitalized), both syntactically and physically.

```text
                               Type Universe
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           ▼                                                   ▼
Unboxed Machine Types                                Managed Fat Scalars
(CPU registers / raw stack slots)                    (16-byte Immix fat scalar)
 - i8 .. i128  (signed integers)                      - Any
 - u8 .. u128  (unsigned integers)                    - Int, Float, Bool
 - f32, f64    (IEEE 754 floats)                      - String
 - bool        (1-bit flag)                           - Array, Hash
 - ptr         (64-bit address)                       - Class instances
```

### Unboxed Machine Types

Enabled with `use feature 'brocken_native_types';`. These bypass the fat-scalar header, never
participate in reference counting, and map directly to registers and machine instructions:

```perl
use feature 'brocken_native_types';

my i32  $index    = 0;
my f64  $pi       = 3.141592653589793;
my bool $ready    = true;
my ptr  $raw_addr = Brocken::heap_base();
```

Unboxed types **cannot be `undef`**; uninitialized, they default to `0`, `0.0`, or `false`.

### Managed Fat Scalars (`Any`)

A value without an explicit unboxed type defaults to `Any`, a 16-byte tagged scalar:

```text
Offset  Size  Field
--------------------------------------------------------------------------------
 0      2     Reference Count (u16, saturated at 65535 = pinned)
 2      1     GC Flags (cycle suspect, buffered, leaf, BRC color)
 3      1     Type Tag (0=Undef, 1=Int, 3=Float, 4=Ptr, 5=Dynamic, 7=List, 8=Hash)
 4      4     Auxiliary Data (e.g. cached UTF-8 length) / padding
 8      8     Payload (raw bits of an i64, f64, or pointer)
```

The tag is read from the top byte of the header word. A class instance uses the same header encoding
but places its fields at offset 8 instead of a payload word.

Managed values **default to `undef`** (Type Tag 0, null payload).

### Coercion and Unboxing

- `unbox_i64(ptr)` — reads the tag; a float payload truncates toward zero, an int payload returns directly.
- `unbox_f64(ptr)` — widens an int payload to a double, or returns a float payload directly.
- `box(value)` — allocates a 16-byte slot via the Immix bump allocator, writes the tag, and stores the payload.

---

## UTF8

Strings are immutable, length-prefixed, NUL-terminated byte sequences guaranteed to contain valid
UTF-8.

```perl
my String $greeting = "こんにちは世界";
say(length($greeting));   # character count
say(bytes($greeting));    # raw byte count
```

### Strict Interpolation

Inside double quotes:

1. Scalars interpolate: `"Value is $var"`
2. Disambiguated scalars interpolate: `"Total: ${count}kg"`
3. Container elements interpolate: `"Item: @arr[0]"`, `"Value: %map{key}"`
4. **Method calls do not interpolate**: `"($obj->value)"` prints the stringified object followed by
   the literal `->value`. Method calls must be concatenated: `"(" . $obj->value . ")"`.

### ASCII-Magical String Increment

Applying `++` to a string follows Perl's ASCII-carry rules:

- Applies only to strings matching `/^[a-zA-Z]*[0-9]*\z/` (`"az"++` $\to$ `"ba"`, `"99"++` $\to$ `"100"`).
- Otherwise the string coerces to numeric `0` and increments to `1`.
- Decrement (`--`) is never magical: it coerces to numeric and subtracts `1`.

---

## Execution Policies

Execution boundaries are enforced by the capability bitmask and instruction budget carried in the
isolate control block.

### Isolate Control Block (ICB) Layout

The ICB is a 160-byte structure at the base of an isolate's heap. Generated once from
`Brocken::Layout`, it holds everything the runtime needs:

```text
Offset  Field                      Description
--------------------------------------------------------------------------------
  0     heap_cursor                Bump pointer for legacy heap allocations
  8     current_fcb                Currently running Fiber Control Block
 16     fiber_head                 Head of the active fiber list (GC root)
 24     immix_cursor               Bump pointer within the current Immix line
 32     immix_limit                End of the usable region in the current line
 40     free_blocks                Head of the reusable Block list
 48     free16_head                Hot path: 16-byte segregated free list
 56     suspect_buffer_head        Head of the suspect cycle ring buffer
 64     fuel                       Remaining instruction budget
 72     err_code                   Abort reason (see below)
 80     current_block              Base of the active Immix block
 88     memory_limit               Heap byte ceiling (0 = unlimited)
 96     memory_used                Current heap byte consumption
104     capabilities               Permission bitmask
112     gate_table                 Gate check dispatch table
120     host_icb                   Parent isolate's control block
128     exception_handler_stack    Head of the SJLJ handler chain
136     thrown_value               Payload carried by throw / die
144     free_big_head              Reusable variable-sized array slabs
152     stack_limit                Stack guard floor (sp - runway)
160     SIZE                       Size to reserve for an isolate
```

### Error Codes

| Code | Value | Meaning |
|---|---|---|
| `ERR_OK` | 0 | No error |
| `ERR_OOM` | 1 | Out of memory against `MEMORY_LIMIT` |
| `ERR_NO_FUEL` | 2 | Fuel exhausted |
| `ERR_SECURITY` | 3 | A capability check refused the operation |
| `ERR_DIV_ZERO` | 4 | Integer division by zero |
| `ERR_THROW` | 5 | An uncaught `throw` / `die` reached the top |
| `ERR_STACK` | 6 | Stack guard tripped |

### Capabilities

Privileged operations consult the bitmask at `ICB::CAPABILITIES`:

| Capability | Bit | Guards |
|---|---|---|
| `CAP_FS_READ` | `1 << 0` | Filesystem reads |
| `CAP_FS_WRITE` | `1 << 1` | Filesystem writes |
| `CAP_NET` | `1 << 2` | Socket creation, bind, connect |
| `CAP_SYSTEM` | `1 << 3` | Process spawning |
| `CAP_FFI` | `1 << 4` | Raw `syscall`, `syscall_by_name`, `libc` |

The FFI intrinsics are the only place the capability mask is consulted today. When fuel reaches zero,
execution halts immediately with `ERR_NO_FUEL`.

---

## Performance

### Memory Management Architecture

```text
Layer 3: Perceus (compile-time IR)
  ├── Borrow inference: drop redundant incref/decref at call boundaries
  ├── RC elision: cancel adjacent incref/decref on local bindings
  └── In-place reuse: mutate unique objects (RC == 1) without reallocating

Layer 2: Bacon & Rajan trial deletion (runtime cycle collector)
  ├── Suspect buffer: tracks non-leaf objects whose RC dropped but stayed > 0
  └── 3-phase color sweep: purple (suspect) -> gray -> white (garbage) / black

Layer 1: Reference counting + Immix bump allocation (hot path)
  ├── Hot path: freed 16-byte scalars are pushed to a segregated free16 list
  └── Immix: 32 KiB blocks divided into 256-byte lines
```

### The Caller-Borrows Contract

Passing an argument does not touch a reference count. A callee borrows its parameters and must not
decrement them on exit; it emits an `incref` only when it stores the value into an array, hash, class
field, or global.

### Immix Block Geometry

A block is exactly 32768 bytes and begins on a 32 KiB boundary:

```text
[block + 0 .. 15]:      128-bit line-availability bitmap (bit N = line N in use)
[block + 16 .. 255]:    Line 0   (240 usable bytes; first 16 hold the bitmap)
[block + 256 .. 511]:   Line 1   (256 usable bytes)
...
[block + 32512..32751]: Line 127 (240 usable bytes)
[block + 32752..7]:     live_count (i64) -- live object count in this block
[block + 32760..767]:   next_free (i64) - scan cursor for the next free line
```

Blocks tile a single `BLOCK_SIZE` grid anchored at the first block; a freed object is charged to the
block that *contains its address*, found by masking rather than by trusting the current allocator
block:

$$
\text{block\_base} = \text{arena\_base} + ((\text{obj} - \text{arena\_base})\ \&\ \sim\text{0x7FFF})
$$

When a block's `live_count` reaches zero it is returned to `ICB::FREE_BLOCKS`.

---

## Language Server

The compiler integrates a Language Server Protocol daemon (`bkn lsp`) for diagnostics, completion,
symbol navigation, and type inference.

```bash
bkn lsp --stdio
```

### DWARF v5 Debug Generation

The backend emits DWARF v5 during binary generation:

- **`.debug_line`** — machine-code offset to source line/column mapping.
- **`.debug_info`** — compilation units, subprograms, variables, and class layouts.
- **`.debug_names`** — DWARF v5 accelerated symbol lookup using case-folding DJB hashing.
- **`.debug_frame`** — call-frame information for unwinding.

### Native Backtraces (`.brk_sym`)

The linker can also emit a compact `.brk_sym` section so a stripped release binary can produce
backtraces without external debug files:

```text
word     count
count ×  { start_rva, end_rva, name_offset }
byte[]   NUL-terminated symbol name pool
```

---

## FFI

The `Brocken::` pseudo-namespace is the unsafe native subset. Its intrinsics lower directly to MIR
and never allocate:

| Intrinsic | MIR output |
|---|---|
| `Brocken::ptr_add(p, off)` / `ptr_sub(p, off)` | `add` / `sub` |
| `Brocken::ptr_cmp_gt(a, b)` / `_lt` / `_ge` / `_le` / `_eq` | `icmp sgt` / `slt` / `sge` / `sle` / `eq` |
| `Brocken::load_i64(ptr)` / `store_i64(ptr, val)` | `load i64` / `store i64` |
| `Brocken::load_i32(ptr)` / `load_i8(ptr)` / `load_u16(ptr)` | `load i32` / `i8` / `i16` |
| `Brocken::load_f64(ptr)` / `store_f64(ptr, val)` | `load f64` / `store f64` |
| `Brocken::i64_add(a, b)` / `i64_sub(a, b)` | `add` / `sub` |
| `Brocken::band` / `bor` / `bxor` / `shl` / `shr` | `and` / `or` / `xor` / `shl` / `lshr` |
| `Brocken::syscall(number, ...)` | `syscall` instruction, guarded by `CAP_FFI` |
| `Brocken::syscall_by_name(name, ...)` | `syscall` with the number resolved for the target |
| `Brocken::libc(name, ...)` | `call` to a link-time-resolved symbol |
| `Brocken::heap_base()` | load of `__heap_base` |

```perl
use feature 'brocken_native_types';

my ptr $addr;
my i64 $value = Brocken::load_i64($addr);
Brocken::store_i64($addr, $value + 1);

my i64 $written = Brocken::syscall_by_name("write", 1, "hello\n", 6);
my f64 $root    = Brocken::libc("sqrt", 144.0);
```

`syscall_by_name` and `libc` require a literal string, so the name resolves before linking.

### Bind Gates

Bind gates let guest Brocken code run inside a host process without corrupting memory:

1. Arguments are deep-copied into the host's Immix heap.
2. The pinned control-block register is swapped to the host's.
3. The host function executes.
4. The return value is deep-copied back to the guest heap, and the guest register is restored.

---

# Toolkit

The `bkn` executable is the consolidated toolchain driver: compiler, runtime, test harness,
benchmarker, package manager, formatter, linter, task runner, and language server.

## Commands

```text
bkn build [options] [path]    Compile source into a standalone native executable
bkn run [options] [path]      Compile and execute the program
bkn test [options] [path]     Run the test harness with native TAP output
bkn bench [options] [path]    Run performance microbenchmarks
bkn fmt [options] [files...]  Format sources according to the style spec
bkn lint [options] [files...] Run static analysis and borrow checks
bkn lsp                       Launch the language server
bkn clean                     Clear build caches and temporary artifacts
bkn new <project>             Scaffold a new project directory
bkn target <cmd>              Query and install target triples
bkn vendor                    Vendor dependencies for reproducible builds
bkn task <name>               Execute a declared build task
bkn upgrade                   Update the toolchain
```

### `bkn build`

Compiles source into a standalone native executable. Runs the full pipeline: lex, parse, check,
type, lower to Machine IR, optimize, allocate registers, emit, and link against the runtime archive.

```text
--release                 Optimize and strip (profile.release)
--target <triple>         Cross-compile for a target triple
--opt-level <0..3>        Override the optimization level
--debug-level <0..4>      DWARF emission detail
--reproducible            Byte-identical output for a fixed SOURCE_DATE_EPOCH
--emit <kind>             Stop early: exe | obj | asm | mir
-o, --output <path>       Write the artifact to a specific path
--jobs <n>                Parallel codegen units (default: CPUs)
-v, --verbose             Print each pipeline stage and its timing
```

### `bkn run`

Builds and immediately executes the program, passing any trailing arguments to it.

```text
--release                 Run the optimized build
--emit <kind>             Interpret `mir` directly instead of native code
-v, --verbose             Print each pipeline stage
-- <args>...              Arguments forwarded to the program's ARGV
```

### `bkn test`

Runs the test harness and reports native TAP to standard output.

```text
--filter <pattern>        Only run tests whose path matches
--jobs <n>                Parallel test processes (default: CPUs)
--no-capture              Interleave test output with the harness
--target <triple>         Run tests under the target's emulator (qemu-user)
-v, --verbose             Show each harness invocation
```

### `bkn bench`

Runs performance microbenchmarks and reports timing distributions.

```text
--filter <pattern>        Only run matching benchmarks
--samples <n>             Samples per benchmark (default: 100)
--warmup <n>              Warm-up iterations before sampling (default: 10)
--json                    Emit machine-readable results
```

### `bkn fmt`

Formats sources according to the [formatter](#formatter) style. Writes in place unless `--check`.

```text
--check                   Exit non-zero if any file would change
--diff                    Print a unified diff instead of writing
--stdin                   Read from standard input, write to standard output
--edition <year>          Formatting rules for a language edition
```

### `bkn lint`

Runs static analysis and the borrow/escape checks without producing an executable.

```text
--deny <lint>             Promote a lint to an error (repeatable)
--allow <lint>            Silence a lint (repeatable)
--forbid <lint>           Forbid a lint even if a `deny` attribute allows it
--json                    Emit diagnostics as JSON for editor consumption
```

### `bkn lsp`

Launches the [language server](#language-server) over the requested transport.

```text
--stdio                   Speak LSP over standard input/output (default)
--socket <addr>           Listen on a TCP socket
--pipe <path>             Listen on a named pipe
--log-level <level>       trace | debug | info | warn | error
```

### `bkn clean`

Removes build caches and intermediate artifacts.

```text
--all                     Also remove downloaded toolchains and vendored sources
--target <triple>         Only clean the given target's cache
--dry-run                 Print what would be removed
```

### `bkn new`

Scaffolds a new project directory with a manifest, a source tree, and a test directory.

```text
--lib                     Create a library project (no main entry point)
--bin                     Create an executable project (default)
--vcs <system>            git | none (default: git)
--edition <year>          Language edition for the manifest
```

### `bkn target`

Queries and installs cross-compilation target triples.

```text
bkn target list                    Show installed and available triples
bkn target add <triple>            Register a sysroot for a triple
bkn target install <triple>        Download and unpack a prebuilt runtime
bkn target remove <triple>         Forget a registered triple
```

### `bkn vendor`

Copies every dependency into `vendor/` so builds are reproducible without network access.

```text
--path <dir>              Vendor directory (default: vendor/)
--frozen                  Fail if the lockfile would change
```

### `bkn task`

Executes a task declared in `Brocken.toml` under `[tasks]`.

```text
bkn task <name>           Run the named task
bkn task --list           List every declared task and its description
```

### `bkn upgrade`

Updates the installed toolchain.

```text
--version <x.y.z>         Install a specific version instead of the latest
--check                   Report whether a newer version exists, without installing
```

Every subcommand accepts `--help` for its own usage text; `bkn --version` prints the toolchain
version and the supported target triples.

---

## Runtime

The runtime is written in Brocken's unsafe native subset (`src/runtime/core.brocken`). When a project
compiles, `core.brocken` is parsed and its declarations are prepended to the user's AST. It provides
the Immix allocator, the reference-counting helpers, the trial-deletion collector, the fiber
scheduler, channels, and the intrinsics that the middle end lowers.

```perl
package Brocken::Runtime;

use feature 'brocken_native_types';

sub alloc_raw(ptr $hb, i64 $size) :returns(ptr) {
    my ptr $cursor = Brocken::Runtime::get_immix_cursor($hb);
    my ptr $next   = Brocken::ptr_add($cursor, $size);
    if (Brocken::ptr_cmp_gt($next, Brocken::Runtime::get_immix_limit($hb))) {
        return Brocken::Runtime::bump_alloc($hb, $size);
    }
    Brocken::Runtime::set_immix_cursor($hb, $next);
    return $cursor;
}
```

---

## Testing

Brocken programs emit Test Anything Protocol (TAP) output natively:

```perl
# tests/math.t
use Test::More;

sub add(i64 $a, i64 $b) :returns(i64) {
    return $a + $b;
}

ok(add(2, 3) == 5, "2 + 3 == 5");
is(add(-1, 1), 0,  "-1 + 1 == 0");

done_testing();
```

```bash
bkn test
```

```text
1..2
ok 1 - 2 + 3 == 5
ok 2 - -1 + 1 == 0
# Result: PASS
```

The test harness builds each fixture once and runs it on every available backend. Cross-target
fixtures are executed under QEMU when `BROCKEN_SYSROOT_AARCH64` or `BROCKEN_SYSROOT_RISCV64` is set,
and skipped otherwise.

---

## Benchmarking

Microbenchmarks use high-resolution hardware timestamps:

```perl
# bench/allocation.brocken
use Benchmark;

timethis(1_000_000, sub () {
    my Point $p = Point->new(x => 10, y => 20);
});
```

---

## Bundler

Dependencies are recorded in `Brocken.lock`, content-addressed by digest for reproducible, air-gapped
builds:

```toml
[[package]]
name = "Crypt::SipHash"
version = "1.0.2"
source = "registry+https://pkg.brocken.dev"
digest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
```

```bash
bkn vendor   # copy dependencies into ./vendor
```

---

## Formatter

`bkn fmt` operates on the parsed AST, so it is semantics-preserving. The canonical style:

- 4-space indentation, no tabs
- K&R braces
- A single space around binary operators
- A trailing comma in multi-line lists
- One blank line between declarations

```bash
bkn fmt --check src/
```

---

## Linting

`bkn lint` reports borrow-rule violations, unreachable code, unhandled tuple returns, implicit type
narrowing, and other statically detectable hazards.

```bash
bkn lint src/
```

---

## Tasks

Build automation is declared directly in `Brocken.toml`:

```toml
[tasks.generate_tables]
command = "bkn run scripts/gen_tables.brocken"

[tasks.pre_release]
dependencies = ["lint", "test", "generate_tables"]
```

```bash
bkn task pre_release
```

---

## Upgrade

```bash
bkn upgrade --channel stable
```

---

# Examples

## Hello, World!

```perl
use feature 'class';

class Application {
    field String $message :param;

    method run() :returns(i64) {
        say($message);
        return 0;
    }
}

my Application $app = Application->new(message => "Hello, World!");
exit($app->run());
```

---

## Fibonacci

An iterative version that allocates nothing, and a recursive version for comparison:

```perl
sub fib_iterative(i64 $n) :returns(i64) {
    my i64 $a = 0;
    my i64 $b = 1;
    for my i64 $i (0 .. $n - 1) {
        my i64 $next = $a + $b;
        $a = $b;
        $b = $next;
    }
    return $a;
}

sub fib_recursive(i64 $n) :returns(i64) {
    return 0 if $n <= 0;
    return 1 if $n == 1;
    return fib_recursive($n - 1) + fib_recursive($n - 2);
}

my i64 $n = 30;
say("fib_iterative($n) = " . fib_iterative($n));
say("fib_recursive($n) = " . fib_recursive($n));
```

---

## Leibniz

The Gregory-Leibniz series converges to $\pi$:
$\pi = 4 \sum_{k=0}^{\infty} \frac{(-1)^k}{2k+1}$.

```perl
use feature 'brocken_native_types';

sub estimate_pi(i64 $terms) :returns(f64) {
    my f64 $acc  = 0.0;
    my f64 $sign = 1.0;

    for my i64 $k (0 .. $terms) {
        my f64 $denominator = 2.0 * $k + 1.0;
        $acc  += $sign / $denominator;
        $sign  = -$sign;
    }

    return $acc * 4.0;
}

my i64 $iterations = 10_000_000;
my f64 $pi         = estimate_pi($iterations);

say("Estimated value of PI over $iterations iterations: $pi");
```

---

# Glossary

| Term | Definition |
|---|---|
| **Isolate** | An OS thread with its own Immix heap and its own ICB. Heaps never overlap, so no mutable state is shared. See [Concurrency](#concurrency). |
| **Fiber** | A cooperative green thread inside an isolate, switched by `ctx_swap`; it shares the isolate's heap. See [Concurrency](#concurrency). |
| **ICB** | Isolate Control Block: heap limit, fuel budget, capability bits, and the exception handler chain; addressed from a pinned register. See [Runtime](#runtime). |
| **FCB** | Fiber Control Block: spilled callee-saved registers, saved stack pointer, resume PC, parent, and transfer slot. See [Concurrency](#concurrency). |
| **CCB** | Channel Control Block: a shared, bounded ring buffer guarded by a mutex and condition variable. See [Concurrency](#concurrency). |
| **Fat Scalar** | The 16-byte `Any` representation: a refcount word, GC flags, a type tag, and a payload. See [Type System](#type-system). |
| **Immix** | A bump allocator over 32 KiB blocks divided into 256-byte lines, with segregated free lists. See [Performance](#performance). |
| **Reference counting** | The primary reclamation strategy, performed without atomics because heaps are isolate-local. |
| **Perceus** | Compile-time reference-count optimization (borrow inference, RC elision, allocation reuse). Planned. See [Performance](#performance). |
| **Linear scan** | The register allocator used by the code generator. See [Performance](#performance). |
| **MIR** | Machine IR: the target-independent IR between typing and instruction selection. See [Performance](#performance). |
| **SJLJ** | `setjmp`/`longjmp` landing dispatch used to implement exceptions at zero steady-state cost. See [Exceptions](#exceptions). |
| **Fuel** | A per-isolate step budget in the ICB, decremented at safepoints, used to bound runaway execution. See [Execution Policies](#execution-policies). |
| **Capability bits** | Per-isolate bits in the ICB that gate privileged runtime operations (spawning, FFI, syscalls). See [Runtime](#runtime). |
| **Attribute** | Compile-time metadata attached to a declaration with `:name(value)`. See [Attributes](#attributes). |
| **Decorator** | A program transformation applied to the declaration that follows a `decorator` declaration. See [Decorators](#decorators). |
| **Role** | An abstract, composable behavior fragment that a class `adjoin`s. See [Classes](#classes). |
| **Profile** | A named bundle of build settings (`dev`, `release`) selected by `bkn build`. See [Commands](#commands). |
| **Target triple** | An architecture/vendor/OS tuple such as `riscv64-unknown-linux-gnu`. See [Commands](#commands). |
| **Edition** | A dated language version a project opts into via the manifest. See [Modules](#modules). |

---

# Index

| Topic | Where |
|---|---|
| ABI and calling conventions | [Functions](#functions), [FFI](#ffi), [Performance](#performance) |
| Attributes and decorators | [Attributes](#attributes), [Decorators](#decorators) |
| Bit-widths and native types | [Variables](#variables), [Type System](#type-system) |
| Channels and message passing | [Concurrency](#concurrency) |
| Classes, fields, methods, roles | [Classes](#classes) |
| Command reference | [Toolkit](#toolkit), [Commands](#commands) |
| Exceptions and unwinding | [Exceptions](#exceptions), [Performance](#performance) |
| FFI and foreign calls | [FFI](#ffi) |
| Fibers and scheduling | [Concurrency](#concurrency), [Execution Policies](#execution-policies) |
| Formatter and linter | [Formatter](#formatter), [Linting](#linting) |
| Grammar and notation | [Notation and Conformance](#notation-and-conformance), [Syntax](#syntax) |
| Iterators and generators | [Iterators](#iterators) |
| Manifest and profiles | [Modules](#modules), [Commands](#commands) |
| Memory and garbage collection | [Type System](#type-system), [Performance](#performance) |
| Modules and imports | [Modules](#modules) |
| Operator precedence | [Syntax](#syntax) |
| Resources and `defer` | [Resources](#resources) |
| Reproducible builds | [Commands](#commands), [Bundler](#bundler) |
| Testing and benchmarking | [Testing](#testing), [Benchmarking](#benchmarking) |
| Unicode and strings | [UTF8](#utf8), [Syntax](#syntax) |
| Language server | [Language Server](#language-server) |


---

# APPENDIX: Future Material from spec.future2.md

# The Brocken Language Specification

**Document:** `docs/spec.future.md`
**Status:** Definitive Standard Architecture & Specification
**Author:** Sanko Robinson
**Target Version:** v0.2.0+

> **Implementation Note:** This document specifies the target language, its formal semantics, and the underlying compiler architecture. It serves as the design of record for Brocken v0.0.1 and later, unifying the conceptual language design with exact implementation details (byte layouts, IR lowerings, link-time behaviors, and target ABIs). See [`TODO.md`](../TODO.md) for the shipped-versus-outstanding checklist.

---

# Notation and Conformance

## Scope

This document specifies the surface syntax, the static semantics a conforming compiler **MUST** enforce, the operational semantics, and the observable behavior of a compiled program. It dictates the memory layouts, execution machine models, calling conventions, DWARF diagnostics, and on-disk binary formats. Compliant toolchains, foreign code interop (FFI), and compiled binaries depend entirely on the invariants established here.

## Normative Language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** in this document are to be interpreted as described in RFC 2119.

- Text marked *informative*, or shown in a note, is explanatory and imposes no requirement.
- All other text is **normative**.
- Code examples are illustrative unless the surrounding text states that a behavior is required.

---

# Development

## Philosophy & Compiler Architecture

### What This Compiler Does

Brocken is a systems programming language with the ergonomics and expressiveness of modern Perl. The Brocken compiler parses this Perl-like syntax and compiles it Ahead-Of-Time (AOT) directly into standalone native machine code (Linux ELF, Windows PE, macOS Mach-O, and WebAssembly) for x86_64, ARM64, and RISC-V architectures.

**Brocken relies on no external C runtime (libc), no GCC, and no LLVM.** Everything from the instruction encoders to the linker is written from scratch.

### Core Pillars

- **Zero-Dependency AOT Execution:** Output binaries are 100% standalone. I/O and threading are implemented via direct kernel system calls or linker-resolved OS-level dynamic imports.
- **Self-Hosted Runtime (`core.brocken`):** The garbage collector, memory allocator, fiber scheduler, and channels are not written in C. They are written in Brocken using a special "Unsafe Native Subset" of the language.
- **Share-Nothing Concurrency:** Concurrency relies on independent OS threads (Isolates) with strict thread-local heaps. Because heaps are isolated, **reference counting requires zero atomic locks**.[^rcgc]
- **Deterministic Memory:** Memory is managed by Immediate Reference Counting utilizing an Immix Bump-Allocator[^immix] and segregated free lists. Circular references are handled by Bacon & Rajan trial deletion.[^trialdeletion]
- **Ultra-Modern Perl Ergonomics:** Brocken adopts modern Perl idioms while shedding historical parsing ambiguities: invariant sigils, post-dereference syntax, Corinna-style classes with `ADJUST`/`DESTROY`, compile-time attributes, strict lexical scoping, and zero-cost exceptions.[^perldocs]

## Installation

The Brocken toolchain (`bkn`) is distributed both as a standalone, zero-dependency static binary and as an installable source distribution for toolchain development.

### Standalone Toolchain Binaries

```bash
# Unix-like Platforms (Linux, FreeBSD, OpenBSD, NetBSD, macOS, illumos/Solaris)
curl -fsSL https://brocken.dev/install.sh | sh

# Windows (PowerShell 7+ / Windows Terminal)
irm https://brocken.dev/install.ps1 | iex
```

### Installation from Source (Bootstrapping)

Brocken is bootstrapped using an existing Perl 5.42+ interpreter with the `class` feature enabled.

```bash
git clone https://github.com/sanko/brocken.git
cd brocken

# Validate the host environment and execute the compiler test suite
perl Makefile.PL
make
make test

# Install the bootstrap compiler and the bkn driver onto PATH
make install
```

### Verification

```bash
bkn --version
bkn target info
```

## The Compilation Pipeline

Brocken translates source code to executable machine bytes through a strictly defined pipeline.

```text
       ┌────────────────────────────────────────────────────────┐
       │               Host Bootstrap / `bkn` Driver            │
       │      CLI Orchestration & core.brocken Merging          │
       └──────────────────────────┬─────────────────────────────┘
                                  │
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │               Katsuro (Compiler Frontend)              │
       │       Regex Lexer ──▶ Pratt Parser ──▶ AST Lowering    │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Lowered to Architecture-Agnostic SSA
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │               Lindsay (Middle-End Optimizer)           │
       │   SSA Form ──▶ Perceus RC Elision ──▶ Inlining & DCE   │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Lowered to Architecture MIR
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │                 Jenny (Backend & Linker)               │
       │     Linear-Scan RegAlloc ──▶ Machine-Code Encoders     │
       │       ELF64 / PE32+ / Mach-O / Wasm Writers            │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Emits
                                  ▼
                 Standalone native executable or Wasm module
```

---

## Quick Start

### 1. Initialize a Project

```bash
bkn new telemetry_daemon
cd telemetry_daemon
```

### 2. Write Application Code

Edit `src/main.brocken`:

```perl
use feature 'class';

class SensorNode {
    field u64    $id      :param;
    field String $name    :param :reader;
    field f64    $reading :reader = 0.0;

    ADJUST {
        die("Invalid sensor ID: cannot be zero") if $id == 0;
    }

    method sample(f64 $value) :returns(void) {
        $reading = $value;
    }

    method is_hot() :returns(bool) {
        return $reading >= 80.0;
    }
}

my SensorNode $node = SensorNode->new(id => 7, name => "reactor-core");
$node->sample(94.5);

if ($node->is_hot()) {
    say($node->name . " is running hot at " . $node->reading . "C");
}
```

### 3. Build and Run

```bash
bkn run                   # Compile and run immediately in a temporary Isolate
bkn build --release       # Compile an optimized standalone native binary
ldd bin/telemetry_daemon  # Confirms no dynamic libraries are linked
```

---

## Environment

### Target Triples

A compilation target is a normalized four-part triple: $\text{Architecture} - \text{Vendor} - \text{OS} - \text{Environment}$ (`x86_64-pc-linux-gnu`, `aarch64-apple-darwin-macho`).[^triple]

| Architecture | Code Generator | Binary Format | Calling Convention | Pointers |
|---|---|---|---|---|
| **x86_64**[^x86] | `Codegen::X86_64` | ELF64 / PE32+ / Mach-O | SysV AMD64 / Microsoft x64 / Apple x86_64 | 64-bit |
| **AArch64**[^arm64] | `Codegen::ARM64` | ELF64 / PE32+ / Mach-O | AAPCS64 | 64-bit |
| **RISC-V 64**[^riscv] | `Codegen::RISCV64` | ELF64 | LP64D | 64-bit |
| **Wasm32**[^wasm] | `Codegen::Wasm` | Wasm Module | WASI Core Snapshot 1 | 32-bit (64-bit emulated)|

### Register Roles and ABI Conventions

The compiler maps parameters, returns, the Isolate Control Block, and the current fiber directly to hardware registers to eliminate memory indirection on hot paths.

| Semantic Role | x86_64 (SysV) | x86_64 (Win64) | AArch64 (AAPCS64) | RISC-V 64 (LP64D) |
|---|---|---|---|---|
| **Return 0** | `rax` | `rax` | `x0` | `a0` |
| **Return 1** | `rdx` | `rdx` | `x1` | `a1` |
| **FP Return** | `xmm0` | `xmm0` | `v0` | `fa0` (`f10`) |
| **Int Args 0-5** | `rdi, rsi, rdx, rcx, r8, r9` | `rcx, rdx, r8, r9` | `x0 .. x7` | `a0 .. a7` |
| **FP Args 0-7** | `xmm0 .. xmm7` | `xmm0 .. xmm3` | `v0 .. v7` | `fa0 .. fa7` (`f10..f17`) |
| **Frame Pointer** | `rbp` | `rbp` | `x29` | `s0` (`fp`) |
| **Link Register** | (stack) | (stack) | `x30` (`lr`) | `ra` (`x1`) |
| **Stack Pointer** | `rsp` | `rsp` | `sp` | `sp` |
| **Pinned ICB** | `r14` | `r14` | `x28` | `s11` |
| **Fiber Reg** | `r12` | `r12` | `x28` | `s11` |

*(Note: On AArch64 and RISC-V 64, the fiber register and ICB register share the same hardware slot. The active Fiber Control Block retains a pointer to the Isolate Control Block via its `os_thread` field).*

### Entry Point

There is no special `sub main`. Top-level statements are compiled into an implicit `_BROCKEN_ENTRY`, which receives the heap base from the OS entry stub and returns the process exit status.

```perl
# This program:
my i64 $x = 42;
return $x;

# Is equivalent to:
sub _BROCKEN_ENTRY(ptr $__heap_base) :returns(i64) {
    my i64 $x = 42;
    return $x;
}
```

The entry stub is OS-specific (it sets up the stack, the ICB, and the initial fiber) and is generated by the linker, not written in Brocken.[^linker]

### Environment Variables

| Variable | Description | Default |
|---|---|---|
| `BROCKEN_SYSROOT_AARCH64` | Path to sysroot for emulating foreign AArch64 targets under QEMU. | `undef` |
| `BROCKEN_SYSROOT_RISCV64` | Path to sysroot for emulating foreign RISC-V targets under QEMU. | `undef` |
| `BROCKEN_DUMP_INTERVALS` | Emits live-interval ranges and linear-scan spill decisions to `stderr`. | `0` |
| `SOURCE_DATE_EPOCH` | Sets a fixed UNIX epoch timestamp to guarantee byte-reproducible binary output. | Host clock |
| `BROCKEN_SKIP_PDATA` | Suppress the PE `.pdata` exception table emission. | `0` |

---

## Configuration

Project dependencies, compiler profiles, memory guarantees, and capability sandboxing live in `Brocken.toml`.

```toml
[package]
name = "hyperion"
version = "0.2.0"
authors = ["Sanko Robinson <sanko@cpan.org>"]
entry = "src/main.brocken"
edition = "2026"

[profile.release]
opt_level = 3              # 0 = debug, 1 = size, 2 = speed, 3 = aggressive
strip = true               # Strip local symbols and non-essential sections
debug_level = 0            # 0 = none, 1 = line tables .. 4 = full DWARF v5
reproducible = true        # Sort every hash traversal for bitwise-identical output
lto = true                 # Cross-module SSA inlining and dead-code elimination

[profile.debug]
opt_level = 0
strip = false
debug_level = 4
asan = false               # Memory-layout bounds checker
stack_guard = true         # Emit prologue stack-limit checks

[isolate.defaults]
initial_fuel = 5_000_000   # Fuel decrements at entries, calls, and loop back-edges
initial_heap = "2MB"       # First Immix block allocation
max_heap = "512MB"         # Exceeding this raises ERR_OOM
stack_budget = "2MB"       # Guard runway below the hardware stack pointer

[capabilities]
fs_read = true             # Permit filesystem reads
fs_write = false           # Deny filesystem writes
net = true                 # Permit socket operations
system = false             # Forbid process spawns
ffi = false                # Forbid raw syscall / dynamic library loading
```

---

# Fundamentals

## 1. Syntax

Brocken modernizes Perl semantics while stripping out historical parsing ambiguities, type ambiguity, and irregular grammatical forms.

### Lexical Conventions & Source Position

- **Character Set:** Source files must be valid UTF-8. A Byte Order Mark (BOM) is permitted but ignored.
- **Identifiers:** Match `/[a-zA-Z_][a-zA-Z0-9_]*/` and are case-sensitive. Fully qualified namespaces use `::`.
- **Separators:** Statements terminate with a semicolon `;`. Newlines do not terminate statements.
- **Blocks:** Curly braces `{ ... }` delimit scope.
- **Comments:** `#` runs to end-of-line.
- **Pod6 Documentation:** Raku-style Pod6 is built natively into the parser. Paragraph blocks (`=begin ... =end`) are preserved in the AST. Declarator blocks attached to definitions via `#|` are exposed via the LSP server.
- **Source Directives:** A `# line "file" N C` directive overrides the reported source file, line, and column for all subsequent tokens, allowing generated code or macros to attribute themselves to their origin source.

### The Keyword Dictionary

Keywords are reserved and **MUST NOT** be used as identifiers. Because Brocken maps closely to Perl semantics but strictly enforces AOT types, its keyword list is exhaustive. *(Note: `has` has been completely removed in favor of `field`)*.

#### Declarations & Scoping
* `my` — Lexical variable declaration, scoped to the enclosing block.
* `our` — Package-scoped global variable, placed in `.data`.
* `state` — Persistent lexical variable, initialized exactly once.
* `const` — Immutable compile-time constant, emitted into `.rodata`.
* `type` — Compile-time type alias.
* `sub` — Subroutine declaration.
* `package` — Declares the current namespace compilation unit.
* `use`, `require` — Module and pragma inclusion.

#### Control Flow & Iteration
* `if`, `elsif`, `else` — Standard conditional branching.
* `unless` — Inverted conditional (`if (!cond)`).
* `while`, `until` — Standard and inverted loop constructs.
* `for`, `foreach` — Iteration constructs over ranges, arrays, and iterators.
* `next` — Jump to the next iteration of the enclosing loop.
* `last` — Immediately terminate and exit the enclosing loop.
* `redo` — Re-execute the current loop iteration without evaluating the condition.
* `return` — Exit a subroutine or method, yielding a value or tuple.
* `match` — Pattern matching sequence (lowers to type-tag checks and unbox operations).
* `exit` — Terminate the process (lowers directly to the OS syscall).

#### Object Orientation
* `class` — Begins a Corinna-style class definition.
* `role` — Defines an abstract, composable behavior fragment.
* `adjoin` — Structural role composition (flattens a role into a class).
* `method` — Declares a subroutine bound to an instance (`$self`).
* `field` — Encapsulated instance state slot.
* `ADJUST` — Post-construction initialization phaser.
* `DESTROY` — Deterministic finalization phaser.
* `__CLASS__` — Pseudo-constant evaluating to the current class symbol.
* `__PACKAGE__` — Pseudo-constant evaluating to the current package name.
* `package` — Namespace declaration setting the package for subsequent declarations (`package NAME;` or `package NAME { ... }`; optionally takes a version literal recorded as module metadata). Names already containing `::` are absolute.

#### Concurrency & Asynchrony
* `isolate` — Allocates a share-nothing OS thread with a disjoint Immix heap.
* `fiber` — Allocates a cooperative green thread (Coroutine).
* `yield` — Suspends fiber execution, handing a value to the resumer.
* `transfer` — Resumes a fiber, passing a value to its pending yield.
* `async`, `await` — Syntactic sugar over `fiber` and `transfer` for promise resolution.

#### Exceptions & Resources
* `try` — Establishes a `jmp_buf` landing dispatcher.
* `catch` — Intercepts and binds a thrown exception payload.
* `finally` — Guaranteed execution block on any exit path.
* `throw`, `die` — Emits an exception payload and triggers an unwind.
* `defer` — Enqueues a block to execute at the end of the lexical scope.

#### Logical & Type Operators
* `and`, `or`, `not`, `xor` — Low-precedence logical operators.
* `as` — Explicit static type cast.

#### Pseudo-Functions & Built-ins
* `want` — Queries the calling context (returns `scalar`, `list`, or `void`).
* `length` — Returns the character/element count of a string or array.
* `map`, `grep` — Applies an expression or filter over a list.
* `say`, `print` — Flushes stringified output to stdout.

*(Note: Native types like `i64`, `f32`, and managed types like `Int`, `Any` are reserved identifiers in the Type namespace, but not strict keywords).*

### Grammar Specification (EBNF)

```ebnf
Program         ::= Declaration* Statement* EOF ;

Declaration     ::= ClassDecl | SubDecl | PackageDecl | UseDecl | DecoratorDecl ;

ClassDecl       ::= 'class' Ident ( Version )? ( ClassAttr )* '{' ClassBody '}' ;
ClassBody       ::= ( FieldDecl | MethodDecl | AdjustDecl | DestroyDecl )* ;
FieldDecl       ::= 'field' Type ( Sigil | '[' Type ';' Const ']' Sigil ) Ident
                    ( FieldAttr )* ( FieldInit )? ';' ;
FieldInit       ::= ( '=' | '//=' | '||=' ) Expr ;
MethodDecl      ::= 'method' Ident Signature ( MethodAttr )* Block ;
AdjustDecl      ::= 'ADJUST' Block ;
DestroyDecl     ::= 'DESTROY' Block ;

SubDecl         ::= 'sub' Ident Signature ( SubAttr )* Block ;
Signature       ::= '(' ( ParamList )? ')' ;
ParamList       ::= Param ( ',' Param )* ;
Param           ::= ( ':' )? Type Sigil Ident ( '=' Expr )? ;

Statement       ::= VarDecl | AssignStmt | IfStmt | WhileStmt | ForStmt
                  | ReturnStmt | ThrowStmt | TryCatchStmt | LoopControlStmt
                  | DeferStmt | MatchStmt | ExprStmt | Block | ';' ;

VarDecl         ::= 'my' ( Type )? Sigil Ident ( ( '=' | '//=' | '||=' ) Expr )? ';'
                  | 'my' '(' TargetList ')' '=' Expr ';' ;
AssignStmt      ::= Target ( '=' | '+=' | '-=' | '*=' | '/=' | '//=' | '||=' ) Expr ';' ;
Target          ::= Var | FieldAccess | DerefExpr | IndexExpr ;

IfStmt          ::= 'if' '(' Expr ')' Block ( 'elsif' '(' Expr ')' Block )* ( 'else' Block )? ;
WhileStmt       ::= 'while' '(' Expr ')' Block ;
ForStmt         ::= 'for' ( 'my' ( Type )? Sigil Ident )? '(' Expr ')' Block ;
ReturnStmt      ::= 'return' ( ExprList )? ';' ;
ThrowStmt       ::= ( 'throw' | 'die' ) Expr ';' ;
TryCatchStmt    ::= 'try' Block ( 'catch' '(' Sigil Ident ')' Block )? ( 'finally' Block )? ;
LoopControlStmt ::= ( 'last' | 'next' | 'redo' ) ';' ;
DeferStmt       ::= 'defer' Block ;

Expr            ::= BinaryExpr | UnaryExpr | PrimaryExpr ;
PrimaryExpr     ::= Const | Var | CallExpr | MethodCall | ConstructExpr | ParenExpr | Lambda ;
Lambda          ::= 'sub' Signature Block | 'method' Signature Block ;
```

### Operator Precedence Matrix

Operators are parsed via Pratt top-down precedence. From highest precedence (Level 1) to lowest (Level 20):

| Level | Operator | Fixity | Associativity | Description |
|---|---|---|---|---|
| **1** | `->` `->[]` `->{}` `->$*` `->@*` `->%*` | Postfix | Left | Dereference, invocation, indexing |
| **2** | `++` `--` | Postfix | Non-assoc | Post-increment / decrement |
| **3** | `**` | Binary | Right | Exponentiation |
| **4** | `!` `~` `\` `+` `-` | Prefix | Right | Logical/bitwise NOT, ref-take, unary signs |
| **5** | `=~` `!~` | Binary | Left | Pattern binding |
| **6** | `*` `/` `%` `x` | Binary | Left | Multiplicative, remainder, repetition |
| **7** | `+` `-` `.` | Binary | Left | Additive, string concatenation |
| **8** | `<<` `>>` | Binary | Left | Shifts (Logical/Arithmetic selected by type signedness) |
| **9** | `<` `>` `<=` `>=` `lt` `gt` `le` `ge` | Binary | Left | Relational comparisons |
| **10** | `==` `!=` `<=>` `eq` `ne` `cmp` | Binary | Left | Equality and three-way comparisons |
| **11** | `&` | Binary | Left | Bitwise AND |
| **12** | `\|` `^` | Binary | Left | Bitwise OR / XOR |
| **13** | `&&` | Binary | Left | Short-circuit AND |
| **14** | `\|\|` `//` | Binary | Left | Short-circuit OR, defined-or |
| **15** | `..` `...` | Binary | Non-assoc | Range operator, flip-flop |
| **16** | `? :` | Ternary | Right | Conditional ternary evaluation |
| **17** | `=` `+=` `-=` `*=` `/=` `//=` `\|\|=` | Binary | Right | Assignment and compound assignment |
| **18** | `not` | Prefix | Right | Low-precedence logical NOT |
| **19** | `and` | Binary | Left | Low-precedence logical conjunction |
| **20** | `or` `xor` | Binary | Left | Low-precedence logical disjunction |

---

## 2. Variables & Sigils

### Invariant Sigils

Unlike older versions of Perl where sigils change based on context, Brocken enforces **invariant sigils**. They denote the architectural container and never mutate based on evaluation context, indexing, or dereference target.

| Sigil | Container | Element Access | Reference | Full Deref |
|---|---|---|---|---|
| `$` | Scalar / Native primitive / Object ptr | `$x` | `\$x` | `$ref->$*` |
| `@` | Sequential indexed array | `@arr[0]` | `\@arr` | `$ref->@*` |
| `%` | Associative dictionary | `%map{"key"}` | `\%map` | `$ref->%*` |

```perl
# Arrays keep their @ sigil on element access
my @numbers = (10, 20, 30);
my i64 $first = @numbers[0];     # Correct
@numbers[1] = 25;                # Direct mutation

# Hashes keep their % sigil on element access
my %config = (host => "localhost", port => 8080);
my String $host = %config{"host"};
```

### Postfix Dereferencing (`postderef`)

Brocken strictly uses postfix dereferencing. Traditional circumfix/prefix dereferencing (`$$ref`, `@$ref[0]`) is invalid.

```perl
my $arr_ref  = [ 10, 20, 30 ];
my $hash_ref = { name => "Alice", age => 30 };
my $scalar_ref = \"Hello";

say( $arr_ref->[0] );         # Element: 10
say( $hash_ref->{"name"} );   # Element: "Alice"
say( $scalar_ref->$* );       # Scalar deref: "Hello"

# Full container dereferencing
foreach my $val ( $arr_ref->@* ) { say($val); }
my @keys = $hash_ref->%*;
```

### MUMPS-Style Naked References

When traversing deeply nested associative structures, postfix navigation avoids repetitive root qualification. The compiler reduces these to chained $GEP$ (GetElementPtr) lookups:

```perl
my $user_ref = \%database{"users"}{"104"};

# Naked dereferencing directly into child leaves:
my String $name  = $user_ref->{"profile"}{"name"};
my i64    $login = $user_ref->{"security"}{"last_login"};
```

---

## 3. Type System & Nullability

Brocken maintains a strict syntactic and physical separation between **unboxed raw machine types** (lowercase) and **managed fat scalars** (Capitalized).

```text
                          Type Universe
                                │
          ┌─────────────────────┴─────────────────────┐
          ▼                                           ▼
 Unboxed Machine Types                       Managed Fat Scalars
 (Zero-overhead registers)                (16-byte Immix Fat Scalar)
 - i8 .. i128 (Signed Ints)               - Any
 - u8 .. u128 (Unsigned Ints)             - Int, Float, Bool
 - f32, f64 (IEEE Floats)                 - String
 - bool (i1)                              - Array, Hash
 - ptr (64-bit Address)                   - Class Objects
```

### Unboxed Machine Types (The Unsafe Subset)

Enabled via `use feature 'brocken_native_types';`, these types bypass Fat Scalar overhead and do not participate in reference counting. They live directly in CPU registers or raw stack slots.

* `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `i128`, `u128` (Integers)
* `f32`, `f64` (IEEE 754 Floating Point)
* `bool` (Native boolean, `1` or `0`)
* `ptr` (Opaque 64-bit machine pointer)
* `int` (Alias for `i64` on all current targets)

**Nullability:** Unboxed machine types **cannot be `undef`**. If uninitialized, they default to `0`, `0.0`, or `false`.

### Signedness & Lowering

The `Brocken::Lindsay::IR::Type` carries a `signed` property. Addition and logical operations ignore it (they execute identically at the bit level), but right-shifts and division rely on this static typing to emit arithmetic vs. logical opcodes:
- `>>` on `i64` emits `ashr` (Arithmetic shift, sign-extending).
- `>>` on `u64` emits `lshr` (Logical shift, zero-extending).
- `/` on `i64` emits `sdiv`. `/` on `u64` emits `udiv`.
- `sext` (sign-extend) vs `zext` (zero-extend) when widening.

### Managed Fat Scalars (`Any`)

Variables declared without an explicit type default to `Any`, a 128-bit (16-byte) tagged value on the thread-local Immix heap.[^fatscalar]

```text
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       Reference Count         |    GC Flags   |   Type Tag    |
|            (u16)              |     (u8)      |     (u8)      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Auxiliary / Length                      |
|                             (u32)                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                        Payload Bits                           |
|                       (u64 / f64 / ptr)                       |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

#### Field Definitions:
- **`Reference Count (bits 0..15)`:** 16-bit unsigned integer. Saturating arithmetic: incrementing past `0xFFFF` ($65,535$) pins the object permanently, exempting it from reclamation.
- **`GC Flags (bits 16..23)`:**
  - `Bit 0 [0x01]:` **Suspect** (Object queued for cycle detection).
  - `Bit 1 [0x02]:` **Buffered** (Object currently present in ICB suspect ring).
  - `Bit 2 [0x04]:` **Leaf** (Contains no outbound pointers; exempt from scan).
  - `Bits 3..4 [0x18]:` **Bacon & Rajan Color**:
    - `00b` = White (Candidate for reclamation)
    - `01b` = Gray (Reachable, currently under traversal)
    - `10b` = Purple (Suspected root of cyclic garbage)
    - `11b` = Black (Confirmed live and fully traced)
- **`Type Tag (bits 24..31)`:**
  - `0x00:` Undef / Null
  - `0x01:` Boxed Integer (`i64`)
  - `0x03:` Boxed Float (`f64`)
  - `0x04:` Raw Address (`ptr`)
  - `0x05:` Dynamic Variant Container
  - `0x06:` i128 (Planned)
  - `0x07:` List Container (Points to a 16-byte aligned array slab)
  - `0x08:` Hash Container (Points to an open-addressing table)

**Nullability:** Managed containers **default to `undef`** (Type Tag 0, null payload).

### `undef` and `defined`

- **As a Value Literal:** `$var = undef;` resets a managed variable to the undefined state and drops the refcount of its previous value.
- **As a Mutator Builtin:**
  - `undef($var);` (Same as `$var = undef;`)
  - `undef(@arr);` (Empties the array, decrefs all elements)
  - `undef(%hash);` (Empties the hash, decrefs all keys/values)
- **The `defined` Builtin:** `if (defined $var) { ... }` checks if a managed container has a Type Tag `!= 0`.

### Coercion and Unboxing Mechanics

- `unbox_i64(ptr)`: Inspects Type Tag. If `Float`, truncates the payload float toward zero. If `Int`, returns payload directly.
- `unbox_f64(ptr)`: If tag is `Int`, converts payload integer to double. If `Float`, returns directly.
- `box(val)`: Allocates 16-bytes via `bump_alloc`, writes the tag, stores value in payload slot.

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
3. **Container Elements interpolate:** `say("Item: @arr[0]");` and `say("Value: %map{key}");`
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

### 4.7 Defined-or and Logical-or (`//`, `//=`, `||=`)

`//` is the defined-or operator: it yields its left operand when that is **defined** and its right operand otherwise. Like `&&` and `||`, `//` is **eager**: both operands are evaluated, there is no short-circuit.

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
  tests the box pointer for null only, so a *boxed* `0` is not yet treated as false.

**$\mu$-State Preservation (Defined-Or Evaluation):**

$$\frac{\langle e_1, \sigma, \mu \rangle \Downarrow \langle v_1, \sigma_1, \mu_1 \rangle \quad v_1 \neq \mathbf{null} \wedge \text{Tag}(v_1) \neq 0}{\langle e_1 \mathbin{/\!\!/} e_2, \sigma, \mu \rangle \Downarrow \langle v_1, \sigma_1, \mu_1 \rangle}$$

$$\frac{\langle e_1, \sigma, \mu \rangle \Downarrow \langle v_1, \sigma_1, \mu_1 \rangle \quad (v_1 = \mathbf{null} \vee \text{Tag}(v_1) = 0) \quad \langle e_2, \sigma_1, \mu_1 \rangle \Downarrow \langle v_2, \sigma_2, \mu_2 \rangle}{\langle e_1 \mathbin{/\!\!/} e_2, \sigma, \mu \rangle \Downarrow \langle v_2, \sigma_2, \mu_2 \rangle}$$

---

## 5. Containers & Built-in Functions

Hashes and Arrays are not objects; they are manipulated via built-in keywords.

### 5.1 Arrays
- `push @arr, $val` (Appends, returns new length)
- `pop @arr` (Removes and returns last element)
- `shift @arr` (Removes and returns first element)
- `unshift @arr, $val` (Prepends, returns new length)

### 5.2 Hashes (O(1) Linear Probing)
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

### 5.3 Pattern Matching (`match`)

*(Planned)* `match` lowers to a sequence of type-tag checks, conditional branches, and unbox operations.

---

## 6. Functions

Subroutines are declared with `sub` and enforce strictly typed signatures.

### 6.1 Static Typing Judgements

Static semantics use formal mathematical deduction ($\Gamma \vdash e : \tau$). Let $\Gamma = (\text{Vars} \to \text{Type}) \times (\text{Classes} \to \text{ClassDef}) \times \text{CapMask}$:

$$
\frac{\Gamma(x) = \tau}{\Gamma \vdash x : \tau}\;[\text{Var}]
\qquad
\frac{\Gamma \vdash e_1 : \text{i64} \quad \Gamma \vdash e_2 : \text{i64}}{\Gamma \vdash e_1 + e_2 : \text{i64}}\;[\text{IntAdd}]
$$

$$
\frac{\Gamma \vdash e_1 : \tau \quad \Gamma[x \mapsto \tau] \vdash e_2 : \tau'}{\Gamma \vdash (\text{my } \tau\ x = e_1;\ e_2) : \tau'}\;[\text{Let}]
\qquad
\frac{\Gamma \vdash f : (\tau_1,\dots,\tau_n) \to (\sigma_1,\dots,\sigma_m) \quad \Gamma \vdash a_i : \tau_i}{\Gamma \vdash f(a_1,\dots,a_n) : (\sigma_1,\dots,\sigma_m)}\;[\text{Call}]
$$

### 6.2 Zero-Allocation Register Tuples

When a subroutine returns multiple values, they are mapped to hardware architecture registers. No heap allocation occurs.

$$
\frac{\Gamma \vdash e_i : \tau_i \quad i \in \{1,\dots,k\} \quad k \le |\text{ArchRegs}_{\text{ret}}|}{\Gamma \vdash (e_1, \dots, e_k) \Rightarrow \text{RegTuple}(\vec{r}_k, \vec{e}_k) : \prod_{i=1}^k \tau_i}
$$

```perl
sub divide(i64 $num, i64 $denom) :returns(i64, bool) {
    if ($denom == 0) {
        return (0, false); # mapped directly to RAX, RDX
    }
    return ($num / $denom, true);
}
```

### 6.3 Parameters (Defaults & Named)

Positional parameters may define expression defaults evaluated at the call site in caller scope. Parameters prefixed with `:` are passed by name via `=>`.

```perl
sub configure(String $host, i64 $port = 8080, :bool $tls = false) :returns(ptr) { ... }

my ptr $c1 = configure("127.0.0.1");                # port=8080, tls=false
my ptr $c2 = configure("127.0.0.1", 80, tls=>true); # port=80, tls=true
```

### 6.4 Closures & Environment Records

A subroutine capturing no outer lexicals lowers to a bare function pointer (`.text`). A capturing subroutine allocates an Immix-managed **Environment Record**, passed via a hidden pointer and governed by Caller-Borrows rules.

---

## 7. Classes

Brocken implements true encapsulation via Corinna-style classes (`use feature 'class'`).

### 7.1 Fields, Attributes, and Constructors

```perl
class BankAccount {
    field u64    $account_id :param;
    field String $owner_name :param :reader;
    field i64    $balance    :reader = 0;
    field bool   $is_frozen  = false;

    ADJUST {
        die("Invalid account ID: cannot be zero") if $account_id == 0;
    }

    method deposit(i64 $amount) :returns(i64) {
        die("Account is frozen") if $is_frozen;
        die("Amount must be positive") if $amount <= 0;
        $balance += $amount;
        return $balance;
    }

    DESTROY {
        # Execution guaranteed natively when Reference Count drops to 0
    }
}
```

`Class->new(...)` is synthesized from `:param` fields. The compiler strips **exactly one** leading underscore from field names to generate default public accessors:
- `field $_timeout :param;` $\Rightarrow$ `new(timeout => 30)`
- `field $_timeout :reader;` $\Rightarrow$ `$obj->timeout()`
- `field $_timeout :writer;` $\Rightarrow$ `$obj->set_timeout(60)`
- `field $__private :reader;` $\Rightarrow$ `$obj->_private()` (one underscore kept)

A field may also hold several values. `field [T; N] $name` reserves `N` elements of `T` inline in the object, read in the class as `@name[i]` and outside it as `$obj->name[i]`; `field T @name` is a single pointer slot whose elements live elsewhere; and `field T %name` is an opaque pointer slot for hash data.

### 7.2 Field Attributes Dictionary

| Attribute | Parameter | Semantics |
|---|---|---|
| `:param` | None or `(name)` | Exposes the field as a constructor argument. |
| `:reader` | None or `(name)` | Synthesizes a getter method `$obj->name()`. |
| `:writer` | None or `(name)` | Synthesizes a chaining setter `$obj->set_name($v)` returning `$self`. |
| `:accessor` | None or `(name)` | Combines a reader with a chaining writer. |
| `:weak` | None | Stores the pointer without incrementing RC, breaking cyclic graphs. |

### 7.3 Component Pascal Role Flattening

To support complex composition without interface dispatch tables (vtable indirection), Brocken uses **Structural Role Flattening**.

When a class consumes a role (`adjoin`), the Katsuro frontend inlines the role's field ASTs and method ASTs directly into the class prior to lowering into Lindsay SSA IR. This preserves static direct dispatch with zero indirect branch overhead.

```perl
role Serializable {
    method to_json() :returns(String) { ... }
}

class PremiumAccount :isa(BankAccount) {
    adjoin Serializable; # Flattens to_json directly into PremiumAccount
    field i64 $credit_limit :param = 1000;
}
```

### 7.4 Static Ancestor Resolution

Single inheritance is declared via `:isa(ParentClass)`. Method dispatch is resolved **statically** AOT. There is no vtable.

```perl
class SecureRequest :isa(HTTPRequest) {
    method send_response(i64 $status, String $body) :returns(bool) {
        say("Encrypting...");
        return $self->SUPER::send_response($status, $body);
    }
}
```

### 7.5 Destructor (`DESTROY`) Semantics

1. **Automatic Trigger:** When `decref` drops a class instance's refcount to 0, `ClassName::DESTROY($self)` executes immediately.
2. **Cascading Field Teardown:** After `DESTROY` finishes, the compiler automatically emits hidden teardown code to `decref` all fields containing managed types.
3. **Destructor Panics:** Throwing an unhandled exception inside `DESTROY` during stack unwinding is illegal and triggers a hard runtime abort.

### 7.6 Physical Instance Memory Layout

A class instance is a contiguous memory region allocated via the Immix bump allocator. Subclass fields append directly after superclass fields. Field index offsets are hardcoded by GEP instructions during compilation.

```text
Offset  Size  Field
--------------------------------------------------------------------------------
 0      2     Reference Count (u16, saturated at 65535 = pinned)
 2      1     GC Flags (Cycle suspect, Buffered, Leaf, BRC color)
 3      1     Type Tag (Tag 4 = Class)
 4      4     Auxiliary: class id (u32, 0 for a boxed ptr)
 8      8     Superclass field: $account_id (u64)
16      8     Superclass field: $owner_name (Managed string ptr)
24      8     Superclass field: $balance (i64)
32      1     Superclass field: $is_frozen (bool)
33      7     Alignment padding
40      8     Subclass field:   $credit_limit (i64)
Total: 48 bytes (Strictly 8-byte natural aligned)
```

---

## 8. Modules

A unit of compilation defines a namespace mapped directly to a file on disk.

```perl
package Codec::Base64 1.0.0;

sub encode(ptr $src, i64 $len) :export :returns(String) { ... }
```

### Link-Time Dead Code Elimination (Tree-Shaking)

During the Lindsay SSA compilation pass, unexported subroutines and uninstantiated classes that have no active references are fully pruned from the intermediate representation, generating minimal binaries.

---

## 9. Attributes

Attributes provide compile-time directives to the parser, middle-end, and code generator.

### Subroutine Attributes
- `:returns(Type, ...)`: Defines return types or multi-register tuples.
- `:inline`: Requests mandatory inlining into caller blocks during IR lowering.
- `:noinline`: Forbids inlining (useful for diagnostic boundaries).
- `:pure`: Guarantees absence of memory side effects, eligible for CSE.
- `:export`: Emits the function symbol into the binary dynamic symbol table (`.dynsym` / `.edata`) for C ABI interoperability.

### Variable Attributes
- `:aligned(N)`: Enforces N-byte memory alignment (essential for SIMD registers).
- `:const`: Asserts single assignment; mutation triggers a compile-time diagnostic.

---

## 10. Decorators

Decorators provide syntactic macro wrappers evaluated at compile time.

```perl
decorator timed(Sub $target) {
    return sub (*@args) {
        my i64 $start = Brocken::monotonic_clock();
        my @res = $target->(@args);
        my i64 $elapsed = Brocken::monotonic_clock() - $start;
        say("Execution of " . $target->name . " took ${elapsed}ns");
        return @res;
    };
}

@timed
sub execute_matrix_multiplication(ptr $a, ptr $b) :returns(ptr) { ... }
```

---

# Advanced

## 11. Concurrency

Brocken implements a dual-layer concurrency architecture modeled after Hoare’s CSP and Plan 9’s Alef: heavy **Isolates** (OS threads with strictly isolated heaps) and lightweight **Fibers** (cooperative green threads multiplexed inside an Isolate).

```text
┌─────────────────────────────────────────────────────────────┐
│                         ISOLATE 1                           │
│  OS Thread (pthread / CreateThread)                         │
│  Pinned fiber register (r12 / x28 / s11) -> FCB             │
│  Thread-Local Immix Heap (zero-lock reference counting)     │
│                                                             │
│   ┌──────────────┐   ctx_swap    ┌──────────────┐           │
│   │   Fiber A    │ <===========> │   Fiber B    │           │
│   │ Stack (64KB) │               │ Stack (64KB) │           │
│   └──────────────┘               └──────────────┘           │
└──────────────────────────────┬──────────────────────────────┘
                               │
                Bounded CCB Ring Buffer Channel
             Deep-copy across the isolate boundary
                               │
┌──────────────────────────────┴──────────────────────────────┐
│                         ISOLATE 2                           │
│  Disjoint Immix Heap and Isolate Control Block              │
└─────────────────────────────────────────────────────────────┘
```

### 11.1 Isolates (Share-Nothing OS Threads)

An **Isolate** represents an independent OS thread (`pthread_create` / `CreateThread`).
- **Zero-Lock Refcounting:** Because heaps are physically disjoint, reference counting operations (`incref`/`decref`) execute as simple load-modify-store sequences without bus locks or atomic intrinsics (`LOCK CMPXCHG`).
- **Hardware Pinned ICB:** The address of the Isolate Control Block is pinned permanently to a dedicated CPU register: `r14` (x86_64), `x28` (AArch64), `s11` (RISC-V).

```perl
my ptr $iso = isolate(sub () {
    say("Executing inside an isolated OS thread");
});
isolate_join($iso);
```

### 11.2 Fibers (Cooperative Coroutines)

A **Fiber** is an M:N user-space coroutine with an independent 64 KiB execution stack. Fibers yield execution cooperatively using the architecture-specific `ctx_swap` sequence.

```perl
my ptr $fib = fiber(sub ($val) {
    say("Fiber step 1: $val");
    yield($val * 2);
    say("Fiber step 2");
    return 42;
});

my i64 $res1 = transfer($fib, 10); # Prints step 1, returns 20
my i64 $res2 = transfer($fib, 0);  # Prints step 2, returns 42
```

### 11.3 Context Switch Mechanics (`ctx_swap`)

A Fiber context switch avoids OS kernel traps. It compiles directly to an inline register spill-and-restore sequence targeting the active **Fiber Control Block (FCB)**.

**x86_64 Machine Code Sequence:**
```nasm
mov  r11, rsp                  ; Capture current SP
mov  [r12 + 0],  rbx           ; Spill Callee-saved to current FCB (r12)
mov  [r12 + 8],  rbp
mov  [r12 + 24], r13
mov  [r12 + 32], r14
mov  [r12 + 40], r15
mov  [r12 + 48], r11           ; FCB.saved_sp
lea  r10, [rip + .resume_label]
mov  [r12 + 64], r10           ; Save target PC
mov  r12, rdi                  ; SWAP: Load Target FCB pointer into r12
mov  r10, [r12 + 64]           ; Load Target PC
mov  rbx, [r12 + 0]            ; Restore Callee-saved from Target FCB
mov  rbp, [r12 + 8]
mov  r13, [r12 + 24]
mov  r14, [r12 + 32]
mov  r15, [r12 + 40]
mov  rsp, [r12 + 48]           ; Restore Hardware SP
jmp  r10                       ; Resume target fiber execution
.resume_label:
```

### 11.4 Channels (CSP)

Channels are typed, synchronized, bounded ring buffers (`chan_create`, `chan_send`, `chan_recv`). Every aggregate value crossing an isolate boundary is automatically deep-copied into the receiving Isolate's local Immix heap to preserve thread-local heap invariants. Pointers into another isolate's heap **MUST NOT** be observed.[^csp]

---

## 12. Exceptions

Exceptions utilize zero-cost landing dispatchers managed through `setjmp`/`longjmp` (SJLJ) via the Isolate Control Block (`ICB::EXCEPTION_HANDLER_STACK`).[^landing]

```perl
try {
    die("Database transaction aborted");
}
catch ($err) {
    warn("Recovered from exception: $err");
}
finally {
    say("Releasing transaction locks");
}
```

### The Landing Dispatcher State Machine

To guarantee that `finally` blocks execute exactly once under all possible paths (normal exit, exceptions, early `return`, `last`, or `next`), the compiler lowers the `try` construct into a state machine:

```text
[try_setup]   ──▶ Registers jmp_buf on ICB exception handler stack
       │
[try_body]    ──▶ Normal exit pops handler ──▶ [finally] ──▶ [merge]
       │
       └── (Exception thrown via die/throw)
             │
             ▼
[landing_pad] ──▶ Pops handler, loads thrown value
             │
             ├──▶ [catch_body] ──▶ [finally] ──▶ [merge]
             └──▶ (No catch)   ──▶ [finally] ──▶ [re-throw]
```

Because the `longjmp` path restores only callee-saved registers, the register allocator keeps caller-saved registers out of the pool for any function that calls `setjmp`, so a value live across the `setjmp` cannot be clobbered by the unwind.

---

## 13. Resources

Deterministic resource cleanup is managed through reference-counted `DESTROY` phases and `defer` statements.

```perl
sub process_file(String $path) :returns(void) {
    my ptr $fh = open_file($path);
    defer { close_file($fh); }; # Guaranteed to execute upon block exit

    # File operations...
}
```

The `defer` body runs when the enclosing block exits, whether by normal completion, `return`, `last`/`next`, or a thrown exception.

---

## 14. Iterators

Iterators are zero-allocation cursor objects. The range operator (`..`) inside a `for` header lowers to a zero-allocation register induction loop:

```perl
# Lowered directly to register limits, no Array heap allocation occurs:
for my i64 $i (0 .. 1000) {
    say($i);
}
```

---

## 15. Execution Policies

Execution boundaries are enforced via capability bitmasks located at `ICB::CAPABILITIES` and instruction budgets at `ICB::FUEL`.

### 15.1 Isolate Control Block (ICB) Layout

The ICB is 160 bytes and is dynamically generated from `Brocken::Layout` during compilation:

```text
Offset  Field                      Description
-------------------------------------------------------------------------
0       heap_cursor                Bump pointer for legacy heap allocations
8       current_fcb                Address of currently running Fiber Control Block
16      fiber_head                 Head of active fibers linked list
24      immix_cursor               Bump pointer within current Immix line
32      immix_limit                Boundary limit of current Immix line
40      free_blocks                Head of reusable 32 KiB block linked list
48      free16_head                Hot path: segregated free list for 16-byte objects
56      suspect_buffer_head        Head of suspect cycle ring buffer
64      fuel                       Remaining execution instruction budget
72      err_code                   Abort reason (0=OK, 1=OOM, 2=NO_FUEL, 3=SECURITY)
80      current_block              Base address of currently active 32 KiB Immix block
88      memory_limit               Maximum allowed heap bytes (0 = unlimited)
96      memory_used                Current active heap byte consumption
104     capabilities               Permission bitmask gating privileged intrinsics
112     gate_table                 Table of function pointers for bind gates
120     host_icb                   Pointer to host ICB during gate execution
128     exception_handler_stack    Head of SJLJ jmp_buf exception handler chain
136     thrown_value               Payload transferred via die/throw
144     free_big_head              Head of reusable variable-sized heap array slabs
152     stack_limit                Stack guard floor threshold (sp - 2MB runway)
```

### 15.2 Capabilities

Privileged operations check the bitmask at `ICB::CAPABILITIES`:[^caps]

| Capability | Bit | Gate / Intrinsic Guarded |
|---|---|---|
| `CAP_FS_READ` | `1 << 0` | Filesystem read access |
| `CAP_FS_WRITE`| `1 << 1` | Filesystem write access |
| `CAP_NET` | `1 << 2` | Network socket creation, bind, and connect |
| `CAP_SYSTEM` | `1 << 3` | System execution and process spawning |
| `CAP_FFI` | `1 << 4` | Raw `syscall`, `syscall_by_name`, `libc`, and FFI dynamic binding |

### 15.3 Stack Guards & Fuel Metering

- **Fuel:** Every basic block loop back-edge and function prologue is compiled down to an execution meter check. When fuel reaches 0, execution halts immediately with `ERR_NO_FUEL` (Exit Code 2).[^fuel]
- **Stack Guards:** `ICB::STACK_LIMIT` is seeded to `SP - 2MB`. Prologues check `sp` against the limit. If exceeded, throws `ERR_STACK` (6) to the SJLJ dispatcher or gracefully unwinds recursion.[^stackguard]

---

## 16. Security Considerations

### 16.1 Hash Collision Resistance

The v0.0.1 hash table uses linear probing over an identity hash and preserves insertion order. It is **not** collision-hardened: an attacker who controls keys (a web form, untrusted input) can force worst-case linear lookups. The planned replacement is **SipHash-2-4**, keyed per process from the OS CSPRNG, exposed as an intrinsic.[^siphash]

### 16.2 Randomness (CSPRNG)

For secrets (tokens, nonces, hash seeds), v1 draws from the OS directly through `libc`: `getrandom(2)` on Linux, `BCryptGenRandom` on Windows, and `getentropy(2)` on macOS/BSD. The planned v2 is a built-in ChaCha20 keystream in `core.brocken`.[^csprng]

---

## 17. Performance

### 17.1 Memory Management Architecture

```text
Layer 3: Perceus (Compile-Time IR Optimization)
  ├── Borrow Inference: Eliminate redundant incref/decref at call boundaries
  ├── RC Elision: Cancel adjacent incref/decref pairs on local bindings
  └── In-Place Reuse: Mutate unique objects (RC == 1) without reallocation

Layer 2: Bacon & Rajan Trial Deletion (Runtime Cycle Collector)
  ├── Suspect Buffer: Tracks non-leaf objects whose RC drops but remains > 0
  └── 3-Phase Color Sweep (See Transition Table Below)

Layer 1: Immediate Reference Counting + Immix Allocator (Hot Path)
  ├── Hot Path: Reclaims 16-byte fat scalars directly to segregated free16 list
  └── Immix Bump Allocator: 32 KiB blocks divided into 256-byte lines
```

### 17.2 The Caller-Borrows Contract

Passing an argument does not touch a reference count. A callee borrows its parameters and must not decrement them on exit; it emits an `incref` only when it stores the value into an array, hash, class field, or global.

### 17.3 Bacon & Rajan Cycle Collection

Brocken utilizes the **Bacon & Rajan Synchronous Cycle Collector** over the Immix heap to collect cyclic garbage.[^trialdeletion] The `GC Flags` field in the Fat Scalar contains the color state, dictating the Mark/Scan/Collect transitions:

| Initial State | Event / Phase | Target State | Internal Reference Adjustment |
|---|---|---|---|
| **Black** | `decref` leaving $\text{RC} > 0$ | **Purple** | $\text{RC} \leftarrow \text{RC} - 1$; push to suspect buffer |
| **Purple** | Phase 1: `MarkGray` | **Gray** | Recursively decrement target $\text{RC}$; paint child Gray |
| **Gray** | Phase 2: $\text{RC} > 0$ | **Black** | Recursively restore target $\text{RC}$; cancel collection |
| **Gray** | Phase 2: $\text{RC} == 0$ | **White** | Confirmed isolated cycle; mark for reclamation |
| **White** | Phase 3: `Collect` | **Recycled** | Run `DESTROY`, link to `free16_head` |

### 17.4 Immix Block Geometry

A block is exactly 32768 bytes ($32\text{ KiB}$). Every block begins on a 32 KiB alignment boundary:

```text
[block + 0..15]:         128-bit line availability bitmap (Bit N = Line N in use)
[block + 16..255]:       Line 0  (240 usable bytes; first 16 bytes contain bitmap)
[block + 256..511]:      Line 1  (256 usable bytes)
...
[block + 32512..32751]:  Line 127 (240 usable bytes)
[block + 32752..32759]:  live_count (i64) - Live object count in this block
[block + 32760..32767]:  next_free (i64) - Scan cursor for next free line
```

When an object is freed by `decref`, the owning block is identified by masking the address:

$$\text{block\_base} = \text{arena\_base} + ((\text{obj\_addr} - \text{arena\_base}) \ \& \ \sim 0\text{x7FFF})$$

The owning block's `live_count` is decremented. When `live_count` reaches zero, the block is returned to the ICB's `free_blocks` list.

### 17.5 Variable Borrowing & RC Elision Rule (Perceus)

$$\frac{\Gamma(x) = \text{Any} \quad \text{Liveness}(x, \text{next}(e)) = \emptyset}{\Gamma \vdash x \Rightarrow \text{Move}(x) : \text{Any}}$$

When an `Any` container reaches its terminal lexical use without aliasing, the Lindsay middle-end lowers the access to an affine transfer ($\text{Move}$), eliding the matching $\text{incref}/\text{decref}$ pair at compile time.[^perceus]

### 17.6 Linear Scan Register Allocation

Jenny uses a straightforward live-interval scan with dynamic spill and caller-save handling. Live sets and spill slots must be walked in sorted order for reproducibility.[^linearscan]

### 17.7 Reproducible Builds

Builds are byte-reproducible.[^repro] Perl randomizes hash iteration order once per process (`PERL_HASH_SEED`), and any pass that walks a hash and writes the result into the emitted artifact perturbs the object file from build to build. Every such walk is sorted:
- **RegAlloc** sorts live sets and spill slots while building intervals and reloads.
- **Codegen** sorts its scratch/reload sets and the Wasm source/offset maps.
- **`Linker::ELF64`** sorts the names feeding the SYSV `.hash` chain.

Compiling the identical module under two different `PERL_HASH_SEED` values yields byte-identical objects and linked executables.

---

## 18. Language Server & Debugging

The Brocken compiler integrates a language server protocol (LSP) daemon (`bkn lsp`) providing IDE diagnostics, auto-completion, and real-time type inference.

### 18.1 DWARF v5 Debug Generation

The Jenny backend emits DWARF v5 sections during binary generation:[^dwarf]
- **`.debug_line`**: Machine code byte offset to source file line/column mapping.
- **`.debug_info`**: Compilation units, subprograms, variable names, and class struct layouts.
- **`.debug_names`**: DWARF v5 accelerated symbol lookup table.
- **`.debug_frame`**: Call-frame information for recovering frame pointers and unwinding stacks.

At `debug_level` 5 on PE targets, the `IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE` bit is cleared and a COFF symbol table is emitted, so GDB's `break <funcname>` resolves to a stable address.

### 18.2 Native Backtraces (`.brk_sym`)

In addition to DWARF, the linker emits a compact `.brk_sym` section containing function address ranges and symbol names. This enables backtraces in stripped release binaries without external debug files:[^brksym]

```text
word    count
count × { start_rva, end_rva, name_offset }
byte[]  NUL-terminated symbol name pool
```

---

## 19. FFI

Direct foreign function invocation without `libffi` is handled by the `Brocken::` pseudo-namespace, which lowers directly into MIR instructions without stack frame allocation overhead.

| Intrinsic | MIR output |
|---|---|
| `Brocken::ptr_add(p, off)` / `ptr_sub(p, off)` | `add` / `sub` |
| `Brocken::ptr_cmp_gt(a, b)` / `_lt` / `_ge` / `_le` / `_eq` | `icmp sgt` / `slt` / `sge` / `sle` / `eq` |
| `Brocken::load_i64(ptr)` / `store_i64(ptr, val)` | `load i64` / `store i64` |
| `Brocken::load_i32(ptr)` / `load_i8(ptr)` / `load_u16(ptr)` | `load i32` / `i8` / `i16` |
| `Brocken::load_f64(ptr)` / `store_f64(ptr, val)` | `load f64` / `store f64` |
| `Brocken::i64_add(a, b)` / `i64_sub(a, b)` | `add` / `sub` |
| `Brocken::band` / `bor` / `bxor` / `shl` / `shr` | `and` / `or` / `xor` / `shl` / `lshr` |
| `Brocken::syscall(number, ...)` | `syscall` instruction, guarded by `CAP_FFI` |
| `Brocken::syscall_by_name(name, ...)` | `syscall` with the number resolved for the target |
| `Brocken::libc(name, ...)` | `call` to a link-time-resolved symbol |
| `Brocken::heap_base()` | load of `__heap_base` |

### 19.1 Dynamic Library Loading & Binding

Brocken supports runtime dynamic loading of arbitrary shared libraries (`.so`, `.dll`, `.dylib`), binding to their exported functions and values directly:

```perl
use feature 'brocken_ffi';

# Dynamically load a shared library
my ptr $lib = Brocken::FFI::load_library("libsqlite3.so");

# Bind to an exported function and execute it
my ptr $open_fn = Brocken::FFI::bind_function($lib, "sqlite3_open");
my i64 $result  = Brocken::FFI::call_i64($open_fn, "database.db", \$handle);

# Bind to an exported global value and read it
my ptr $version_ptr = Brocken::FFI::bind_value($lib, "sqlite3_version");
my String $version  = Brocken::load_ptr($version_ptr);
```

### 19.2 Bind Gates

Bind gates allow guest Brocken code to execute inside a host process without memory corruption:
1. Arguments are deep-copied into the host's Immix heap.
2. The pinned ICB hardware register (`r14`/`x28`/`s11`) is swapped to the host's ICB.
3. The host function executes.
4. The return value is deep-copied back to the guest heap, and the guest ICB register is restored.

---

# Toolkit

The `bkn` executable is the consolidated toolchain driver.

## Commands

```text
bkn build [options] [file]    Compile target program into native standalone binary
bkn run [options] [file]      Compile and immediately execute program
bkn test [options] [path]     Run test harness with native TAP emission
bkn bench [options] [path]    Execute performance microbenchmarks
bkn fmt [options] [files...]  Auto-format source files according to style spec
bkn lint [options] [files...] Perform static analysis and borrow checker checks
bkn lsp                       Launch Language Server Protocol daemon
bkn clean                     Clear build caches and temporary artifacts
bkn new <project>             Scaffold new project directory
bkn vendor                    Vendor dependencies locally
bkn target <cmd>              Query and install target architecture triples
bkn task <cmd>                Execute a custom build task
bkn upgrade                   Self-update the bkn toolchain
```

### `bkn build` Options

- `--release`: Compiles with `-O3`, enables LTO, and strips symbol tables.
- `--target <triple>`: Cross-compiles for the target platform triple.
- `--fuel <num>`: Sets the initial instruction budget per Isolate.
- `--mem-limit <bytes>`: Sets the maximum heap memory limit.
- `--cap <mask|list>`: Sets the capability permissions bitmask.
- `--debug-level <0-5>`: Sets the DWARF emission detail level.
- `--reproducible`: Sorts all section names, hashes, and symbol walks based on `SOURCE_DATE_EPOCH`.

---

## Runtime

The runtime (`core.brocken`) is self-hosted and prepended to user ASTs during compilation. It manages:
- Immix bump allocators and line mark-sweeping
- Bacon & Rajan trial deletion cycle collectors
- Fiber context switching (`ctx_swap`)
- Isolate life cycles and CSP channels

---

## Testing

Brocken features built-in Test Anything Protocol (TAP) testing:

```perl
# tests/math.t
use Test::More;

sub add(i64 $a, i64 $b) :returns(i64) { return $a + $b; }

ok(add(2, 3) == 5, "Addition works correctly");
is(add(-1, 1), 0, "Negative addition works");
done_testing();
```

Run test suites:
```bash
bkn test
```

### Test Harness

`Test2::Tools::Brocken` provides `run_exec($file, %args)` for running a compiled binary and checking its exit code. `gdb => 1` runs it under GDB; `keep => 1` leaves the binary on disk; `platform =>` selects path separators.

---

## Fuzzer

`Brocken::Fuzz` generates small random programs, compiles and runs them, and compares against an interpreted answer.[^fuzzing] Every case is identified by a `(seed, case_num, max_ops, max_vars)` tuple, encoded as a reversible hex `case_id`; `run_case_id($id)` replays a failing case exactly.

```bash
bkn fuzz
-t, --time-limit SECS   run for at most SECS seconds (default 300)
-s, --seed N            use a specific random seed
-o, --max-ops N         maximum operations per program (default 20)
-i, --id HEXID          replay one case by its hex case_id
```

---

## Benchmarking

Microbenchmarking framework with high-precision hardware timestamps:

```perl
# bench/allocation.b
use Benchmark;

timethis(1_000_000, sub () {
    my Point $p = Point->new(x => 10, y => 20);
});
```

---

## Bundler

Package dependency management uses `Brocken.lock` files pinning cryptographic SHA-256 content hashes of dependencies for air-gapped reproducible builds.

```bash
bkn vendor
```

---

## Formatter

Opinionated AST-based formatter enforcing canonical Brocken style:
- 4-space indentation.
- K&R brace placement.
- Spaces surrounding binary operators.
- **Trailing commas are strictly removed** from all array, hash, and parameter lists.

Because formatting operates directly on the AST, it perfectly preserves code semantics.

```bash
bkn fmt --check src/
```

---

## Linting

Static analyzer checking borrow rules, unreachable code, unhandled tuple returns, and implicit type narrowing.

```bash
bkn lint src/
```

---

## Tasks

Custom build task automation defined directly in `Brocken.toml`:

```toml
[tasks.generate_tables]
command = "bkn run scripts/gen_tables.brocken"

[tasks.pre_release]
dependencies = ["lint", "test", "generate_tables"]
```

Execute tasks:
```bash
bkn task pre_release
```

---

## Upgrade

Self-updating toolchain:

```bash
bkn upgrade --channel stable
```

---

# Examples

## Hello, World!

```perl
use feature 'class';

# Explicit typed main execution
class Application {
    field String $message :param;

    method run() :returns(i64) {
        say($message);
        return 0;
    }
}

my Application $app = Application->new(message => "Hello, World!");
exit($app->run());
```

---

## Fibonacci

Comparing iterative zero-allocation native loops with recursive execution:

```perl
# Tail-recursive with zero-allocation tuple optimization
sub fib_iterative(i64 $n) :returns(i64) {
    my i64 $a = 0;
    my i64 $b = 1;
    for my $i (0 .. $n - 1) {
        my i64 $temp = $a + $b;
        $a = $b;
        $b = $temp;
    }
    return $a;
}

sub fib_recursive(i64 $n) :returns(i64) {
    if ($n <= 0) { return 0; }
    if ($n == 1) { return 1; }
    return fib_recursive($n - 1) + fib_recursive($n - 2);
}

my i64 $n = 35;
say("Fibonacci($n) Iterative = " . fib_iterative($n));
say("Fibonacci($n) Recursive = " . fib_recursive($n));
```

---

## Leibniz

Calculating $\pi$ using the Leibniz infinite series formula:

$$\frac{\pi}{4} = \sum_{k=0}^{\infty} \frac{(-1)^k}{2k + 1} = 1 - \frac{1}{3} + \frac{1}{5} - \frac{1}{7} + \frac{1}{9} - \cdots$$

```perl
use feature 'brocken_native_types';

sub calculate_pi(i64 $iterations) :returns(f64) {
    my f64 $sum = 0.0;
    my f64 $sign = 1.0;

    for my i64 $k (0 .. $iterations) {
        my f64 $denominator = (2.0 * $k) + 1.0;
        $sum += $sign / $denominator;
        $sign = -$sign;
    }

    return $sum * 4.0;
}

my i64 $terms = 10_000_000;
my f64 $pi_approx = calculate_pi($terms);
say("Leibniz approximation of PI over $terms terms: $pi_approx");
```

---

# Glossary

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

# Index

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


---

# APPENDIX: Future Material from spec.future3.md

# The Brocken Language Specification

**Document:** `docs/spec.md`
**Status:** Unified Standard Architecture & Target Specification
**Author:** Sanko Robinson & Contributors
**Target Version:** v0.1.0+

> **Implementation Note:** This document is the comprehensive, forward-looking design of record for the Brocken programming language and toolchain. It unifies the operational and static semantics of the v0.0.1 baseline (`spec.md`), the class and object-model roadmap (`class_roadmap.md`), the toolchain architecture (`spec.future.md` and `spec.future2.md`), and early runtime internals (`spec_old.md`). Every invariant, memory layout, machine-code sequence, and operational rule from `spec.md` is strictly retained and expanded herein. See `TODO.md` for the current shipped-versus-outstanding implementation checklist.

---

# Notation and Conformance

## Scope

This specification defines the syntax, static typing rules, operational semantics, memory layouts, runtime abstract machine, execution environment, calling conventions, and binary format generation for conforming implementations of the Brocken language.

## Normative Language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**, **SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** in this document are to be interpreted as described in RFC 2119.

- Text explicitly marked *informative*, notes, and rationale commentary are non-normative.
- All code listings, grammar productions, memory layout diagrams, operational deduction rules, and architectural descriptions are **normative** unless otherwise stated.

## Mathematical & Grammatical Conventions

- Static typing is expressed using deductive inference rules of the form $\frac{\text{Premises}}{\text{Conclusion}}\;[\text{RuleName}]$.
- Semantic evaluation judgments are specified via big-step operational semantics: $\langle e, \sigma, \mu \rangle \Downarrow \langle v, \sigma', \mu' \rangle$, where $e$ is an expression, $\sigma$ is the local lexical environment, $\mu$ represents the linear Immix heap/isolate store, and $v$ is the yielded value.
- Surface syntax is described in Extended Backus-Naur Form (EBNF).

---

# Development

## Philosophy & Compiler Architecture

### What This Compiler Does

Brocken is a systems programming language combining the ergonomics, expressiveness, and invariant sigil mechanics of modern Perl with zero-cost Ahead-Of-Time (AOT) machine compilation. The Brocken toolchain compiles source text directly to standalone native machine code (Linux ELF64, Windows PE32+, macOS Mach-O, and WebAssembly) targeting `x86_64`, `aarch64`, and `riscv64`.

**Brocken relies on no external C runtime (libc), no GCC, and no LLVM.** Everything from the Pratt front-end parser, intermediate static single assignment (SSA) optimizers, linear-scan register allocators, target-specific instruction encoders, and format-specific binary linkers is implemented self-contained within the toolchain.

### Core Pillars

1. **Zero-Dependency AOT Execution:** Output binaries are 100% standalone executables. Process bootstrap, I/O, context switching, and memory requests interact directly with host kernels via native system calls or linker-resolved dynamic OS imports.
2. **Self-Hosted Runtime (`core.brocken`):** The garbage collector, memory allocator, cooperative fiber scheduler, and channel IPC runtime are not implemented in C. They are authored in Brocken using the Unsafe Native Subset (`use feature 'brocken_native_types';` and `Brocken::*` intrinsics) and merged at compilation time.
3. **Share-Nothing Concurrency:** Concurrency is structured into heavy preemptive Isolates (OS threads with strictly disjoint heaps) and lightweight cooperative Fibers (M:N coroutines multiplexed inside an Isolate). Because heaps never overlap across Isolates, **reference counting requires zero atomic instructions (`LOCK CMPXCHG`) and zero bus locks** [^rcgc].
4. **Deterministic Memory via Layered RC + Immix:** Hot-path object lifetimes are governed by immediate reference counting under the Caller-Borrows contract. Memory is allocated via an Immix line/block bump allocator [^immix] with segregated free lists. Cyclic graphs are collected without global stop-the-world pauses using Bacon & Rajan trial deletion [^trialdeletion].
5. **Modern Perl Ergonomics without Dynamic Parsing Ambiguities:** Invariant sigils (`$`, `@`, `%`), strict postfix dereferencing (`->$*`, `->@*`, `->%*`), Corinna-style encapsulated classes (`field`, `method`, `ADJUST`, `DESTROY`), compile-time attribute metadata, zero-cost structured exceptions, and deterministic `defer` scope guards [^perldocs].

### The Compiler Pipeline

```text
       ┌────────────────────────────────────────────────────────┐
       │               Host Bootstrap / `bkn` Driver            │
       │     CLI Orchestration, core.brocken Merging, Config    │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Source + Runtime AST
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │               Katsuro (Compiler Frontend)              │
       │       Regex Lexer ──▶ Pratt Parser ──▶ AST Lowering    │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Lowers to Architecture-Agnostic SSA
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │               Lindsay (Middle-End Optimizer)           │
       │    SSA Form ──▶ Perceus RC Elision ──▶ Inlining & DCE  │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Lowers to Architecture MIR
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │                 Jenny (Backend & Linker)               │
       │     Linear-Scan RegAlloc ──▶ Machine-Code Encoders     │
       │       ELF64 / PE32+ / Mach-O / Wasm Writers            │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Emits
                                  ▼
                 Standalone Native Executable or Wasm Module
```

1. **Katsuro (Frontend):** Lexer and Pratt parser generate a strongly-typed Abstract Syntax Tree (AST). Validates lexical scopes and performs type checking.
2. **Lindsay (Middle-end):** Lowers the AST into Static Single Assignment (SSA) IR [^ssa]. Performs constant folding, dead-code elimination (DCE), tree-shaking, and injects `incref`/`decref` instructions according to borrow analysis.
3. **Jenny (Backend):** Lowers SSA IR into Machine IR (MIR). Executes linear-scan register allocation with spilling and caller-save management [^linearscan]. Enters machine encoders, computes relocations and relative virtual addresses (RVAs), generates DWARF v5 debug tables [^dwarf], and links binary file formats [^linker].

---

## Installation

The Brocken toolchain is distributed both as a zero-dependency standalone native executable (`bkn`) and as a bootstrap Perl 5 distribution for toolchain development.

### Standalone Toolchain Binaries

```bash
# Unix-like Platforms (Linux, FreeBSD, OpenBSD, NetBSD, macOS, illumos)
curl -fsSL https://brocken.dev/install.sh | sh

# Windows (PowerShell 7+ / Windows Terminal)
irm https://brocken.dev/install.ps1 | iex
```

### Installation from Source (Bootstrapping Environment)

Brocken is bootstrapped using Perl 5.42+ with `use feature 'class';`:

```bash
git clone https://github.com/sanko/brocken.git
cd brocken

# Validate host environment and run test suite
perl Makefile.PL
make
make test

# Install bootstrap compiler and bkn driver onto PATH
make install
```

### Verification

```bash
bkn --version
bkn target list
```

Expected output:
```text
bkn v0.2.0 (x86_64-pc-linux-gnu)
Host ABI: System V AMD64
Runtime: Self-Hosted Immix + Fiber Scheduler (core.brocken)
Toolchain Status: Independent (No GCC / No LLVM / No libc)
```

---

## Quick Start

### 1. Initialize a Project

```bash
bkn new telemetry_daemon
cd telemetry_daemon
```

The scaffolding creates:
```text
telemetry_daemon/
├── Brocken.toml         # Manifest, capabilities, and optimization profiles
├── src/
│   └── main.brocken     # Main compilation unit
└── tests/
    └── smoke.t          # Native TAP test suite
```

### 2. Write Application Code

Edit `src/main.brocken`:

```perl
use feature 'class';

class SensorNode {
    field u64    $id      :param;
    field String $name    :param :reader;
    field f64    $reading :reader = 0.0;

    ADJUST {
        die("Invalid sensor ID: cannot be zero") if $id == 0;
    }

    method sample(f64 $value) :returns(void) {
        $reading = $value;
    }

    method is_hot() :returns(bool) {
        return $reading >= 80.0;
    }
}

my SensorNode $node = SensorNode->new(id => 7, name => "reactor-core");
$node->sample(94.5);

if ($node->is_hot()) {
    say($node->name . " is running hot at " . $node->reading . "C");
}
```

### 3. Build and Run

```bash
# Compile and execute immediately in a temporary Isolate
bkn run

# Compile to a standalone, stripped native binary
bkn build --release

# Confirm the binary has no runtime dynamic library dependencies
ldd bin/telemetry_daemon 2>&1 || true   # 'not a dynamic executable' on Linux
```

---

## Environment

### Target Triples

A target is specified by a normalized four-part triple: $\text{architecture}-\text{vendor}-\text{os}-\text{environment}$ [^triple].

```text
x86_64-pc-linux-gnu
x86_64-apple-darwin-macho
x86_64-pc-windows-msvc
aarch64-unknown-linux-gnu
aarch64-apple-darwin-macho
aarch64-pc-windows-msvc
riscv64-unknown-linux-gnu
wasm32-unknown-wasi
```

| Architecture | Code Generator | Binary Format | Calling Convention | Pointer Width |
|---|---|---|---|---|
| **x86_64** [^x86] | `Codegen::X86_64` | ELF64 / PE32+ / Mach-O 64 | System V AMD64 / Microsoft x64 / Apple x86_64 | 64-bit |
| **AArch64** [^arm64] | `Codegen::ARM64` | ELF64 / PE32+ / Mach-O 64 | AAPCS64 | 64-bit |
| **RISC-V 64** [^riscv] | `Codegen::RISCV64` | ELF64 | LP64D | 64-bit |
| **Wasm32** [^wasm] | `Codegen::Wasm` | Wasm Module | WASI Core Snapshot 1 | 32-bit (64-bit emulated) |

### Register Roles and ABI Conventions

The compiler maps function parameters, return values, the Isolate Control Block (ICB), and the active Fiber Control Block (FCB) directly to hardware registers:

| Semantic Role | x86_64 (SysV) | x86_64 (Win64) | AArch64 (AAPCS64) | RISC-V 64 (LP64D) |
|---|---|---|---|---|
| **Return 0** | `rax` | `rax` | `x0` | `a0` |
| **Return 1** | `rdx` | `rdx` | `x1` | `a1` |
| **FP Return** | `xmm0` | `xmm0` | `v0` | `fa0` |
| **Int Arguments** | `rdi, rsi, rdx, rcx, r8, r9` | `rcx, rdx, r8, r9` | `x0`–`x7` | `a0`–`a7` |
| **Float Arguments** | `xmm0`–`xmm7` | `xmm0`–`xmm3` | `v0`–`v7` | `fa0`–`fa7` |
| **Frame Pointer** | `rbp` | `rbp` | `x29` | `s0` |
| **Link Register** | (stack) | (stack) | `x30` (`lr`) | `ra` (`x1`) |
| **Stack Pointer** | `rsp` | `rsp` | `sp` | `sp` |
| **Pinned ICB** | `r14` | `r14` | `x28` | `s11` |
| **Fiber Register** | `r12` | `r12` | `x28` | `s11` |

*(Note: On AArch64 and RISC-V 64, the pinned fiber register and ICB register share a physical hardware register. The FCB stores a back-pointer to the owning ICB in its `os_thread` field).*

### Entry Point (`_BROCKEN_ENTRY`)

There is no requirement for an explicit `sub main`. Top-level statements in the entry compilation unit are lowered into an implicit function `_BROCKEN_ENTRY`, which receives the heap base from the OS entry stub and returns the process exit code:

```perl
# Top-level code:
my i64 $code = 0;
return $code;

# Lowers directly to:
sub _BROCKEN_ENTRY(i64 $__heap_base) :returns(i64) {
    my i64 $code = 0;
    return $code;
}
```

The linker emits an OS-specific assembly entry stub (`_start` on ELF/Mach-O, `mainCRTStartup` on PE) that initialises the stack, seeds the ICB and initial FCB, executes `_BROCKEN_ENTRY`, and issues the exit system call with the returned status.

### Environment Variables

| Variable | Type | Purpose | Default |
|---|---|---|---|
| `BROCKEN_SYSROOT_AARCH64` | Path | Sysroot for executing foreign AArch64 binaries under QEMU | Unset |
| `BROCKEN_SYSROOT_RISCV64` | Path | Sysroot for executing foreign RISC-V binaries under QEMU | Unset |
| `BROCKEN_DUMP_INTERVALS` | Boolean | Dumps live intervals and linear-scan spill decisions to `stderr` | `0` |
| `SOURCE_DATE_EPOCH` | Integer | Epoch timestamp for byte-reproducible binary output [^repro] | Host clock |
| `BROCKEN_SKIP_PDATA` | Boolean | Suppresses PE `.pdata`/`.xdata` unwind table generation | `0` |
| `BROCKEN_DEFAULT_FUEL` | Integer | Instruction budget allocated per isolate | `1000000` |
| `BROCKEN_MEM_LIMIT` | Bytes | Hard heap ceiling per isolate (`0` = unconstrained) | `0` |
| `BROCKEN_LOG` | String | Toolchain logging level (`error`, `warn`, `info`, `trace`) | `warn` |

---

## Configuration

Package metadata, compilation profiles, sandbox permissions, and runtime policies are declared in `Brocken.toml`.

```toml
[package]
name = "telemetry_daemon"
version = "0.2.0"
authors = ["Sanko Robinson <sanko@cpan.org>"]
entry = "src/main.brocken"
edition = "2026"

[profile.release]
opt_level = 3              # 0 = debug, 1 = size, 2 = speed, 3 = aggressive
strip = true               # Strip local symbols and non-essential sections
debug_level = 0            # 0 = none, 1 = line tables .. 5 = full DWARF v5 + COFF
reproducible = true        # Sort all hash iterations for bitwise-identical output
lto = true                 # Cross-module SSA inlining and dead-code elimination

[profile.debug]
opt_level = 0
strip = false
debug_level = 4
asan = false               # Memory-layout bounds checker
stack_guard = true         # Emit prologue stack-limit checks

[isolate.defaults]
initial_fuel = 5_000_000   # Fuel decrements at function entry, calls, and loop back-edges
initial_heap = "2MB"       # First Immix block allocation
max_heap = "512MB"         # Exceeding this raises ERR_OOM
stack_budget = "2MB"       # Guard runway below hardware stack pointer

[capabilities]
fs_read = true             # Permit filesystem reads
fs_write = false           # Deny filesystem writes
net = true                 # Permit socket operations
system = false             # Forbid process spawns
ffi = false                # Forbid raw syscall / dynamic library loading
```

---

# Fundamentals

## Syntax

### Lexical Conventions & Source Position

- **Encoding:** Source text **MUST** be valid UTF-8. A Byte Order Mark (BOM) is stripped and ignored.
- **Line Structure:** Statements terminate with a semicolon `;`. Newlines are whitespace and do not terminate statements.
- **Identifiers:** Match `/[a-zA-Z_][a-zA-Z0-9_]*/` and are case-sensitive. Qualified symbols use `::` (`Net::HTTP::Client`).
- **Comments:** `#` runs to the end of the line. Pod6 documentation blocks (`=begin ... =end`) are recognized by the parser and retained in AST metadata. Declarator comments `#|` attach documentation to the declaration directly following them.
- **Source Directives:** A `# line "filename" N [C]` directive overrides the reported file, line, and column for following tokens, enabling preprocessors and macros to report original source coordinates.

### The Keyword Dictionary

Keywords are reserved terminals and **MUST NOT** be used as identifiers.

```text
ADJUST     DESTROY    adjoin     and        as         async      await
catch      class      const      decorator  defer      die        else
elsif      false      field      finally    for        foreach    if
isolate    last       method     my         next       not        or
our        package    print      ptr        redo       return     role
say        state      sub        throw      true       try        undef
unless     until      use        while      xor        yield
```

*(Note: Machine types like `i64`, `f64`, `bool`, and managed types like `Int`, `String`, `Any` are reserved identifiers in the type namespace, but not grammatical keywords).*

### Numeric and String Literals

| Form | Example | Semantics |
|---|---|---|
| Decimal Integer | `1234`, `1_000_000` | Machine int or boxed `Int`; underscores ignored |
| Hexadecimal | `0xDEAD_BEEF` | Case-insensitive hex digits |
| Octal | `0o755` | Base-8 literal (`0755` is not octal) |
| Binary | `0b1010_0101` | Base-2 literal |
| Floating Point | `3.14159`, `1.5e-3` | IEEE 754 double precision (`f64`) |
| Single-quoted String | `'hello\nworld'` | Non-interpolating literal; escapes only `\\` and `\'` |
| Double-quoted String | `"count: $x\n"` | Strictly interpolating UTF-8 string |

### Grammar (EBNF)

```ebnf
Program         ::= Declaration* Statement* EOF ;

Declaration     ::= ClassDecl | RoleDecl | SubDecl | PackageDecl | UseDecl | DecoratorDecl ;

ClassDecl       ::= 'class' Ident ( Version )? ( ClassAttr )* '{' ClassBody '}'
                  | 'class' Ident ( Version )? ( ClassAttr )* ';' ;
RoleDecl        ::= 'role' Ident '{' RoleBody '}' ;
ClassBody       ::= ( FieldDecl | MethodDecl | AdjustDecl | DestroyDecl | AdjoinDecl )* ;
RoleBody        ::= ( FieldDecl | MethodDecl | RequireDecl )* ;

AdjoinDecl      ::= 'adjoin' Ident ';' ;
RequireDecl     ::= 'requires' Ident ';' ;
FieldDecl       ::= 'field' Type ( Sigil | '[' Type ';' Const ']' Sigil ) Ident
                    ( FieldAttr )* ( FieldInit )? ';' ;
FieldInit       ::= ( '=' | '//=' | '||=' ) Expr ;
MethodDecl      ::= 'method' Ident Signature ( MethodAttr )* Block ;
AdjustDecl      ::= 'ADJUST' Block ;
DestroyDecl     ::= 'DESTROY' Block ;

SubDecl         ::= 'sub' Ident Signature ( SubAttr )* Block ;
Signature       ::= '(' ( ParamList )? ')' ;
ParamList       ::= Param ( ',' Param )* ;
Param           ::= ( ':' )? Type Sigil Ident ( '=' Expr )? ;

Statement       ::= VarDecl | AssignStmt | IfStmt | WhileStmt | ForStmt
                  | ReturnStmt | ThrowStmt | TryCatchStmt | LoopControlStmt
                  | DeferStmt | ExprStmt | Block | ';' ;

VarDecl         ::= 'my' ( Type )? Sigil Ident ( ( '=' | '//=' | '||=' ) Expr )? ';'
                  | 'my' '(' TargetList ')' '=' Expr ';'
                  | 'our' ( Type )? Sigil Ident ( '=' Expr )? ';'
                  | 'state' ( Type )? Sigil Ident ( '=' Expr )? ';'
                  | 'const' ( Type )? Sigil Ident '=' Expr ';' ;

AssignStmt      ::= Target ( '=' | '+=' | '-=' | '*=' | '/=' | '//=' | '||=' ) Expr ';' ;
Target          ::= Var | FieldAccess | DerefExpr | IndexExpr ;

IfStmt          ::= 'if' '(' Expr ')' Block ( 'elsif' '(' Expr ')' Block )* ( 'else' Block )?
                  | Statement 'if' Expr ';' ;
WhileStmt       ::= 'while' '(' Expr ')' Block ;
ForStmt         ::= 'for' ( 'my' ( Type )? Sigil Ident )? '(' Expr ')' Block
                  | 'foreach' ( 'my' ( Type )? Sigil Ident )? '(' Expr ')' Block ;
ReturnStmt      ::= 'return' ( ExprList )? ';' ;
ThrowStmt       ::= ( 'throw' | 'die' ) Expr ';' ;
TryCatchStmt    ::= 'try' Block ( 'catch' '(' Sigil Ident ')' Block )? ( 'finally' Block )? ;
LoopControlStmt ::= ( 'last' | 'next' | 'redo' ) ';' ;
DeferStmt       ::= 'defer' Block ';' ;

Expr            ::= BinaryExpr | UnaryExpr | PrimaryExpr ;
PrimaryExpr     ::= Const | Var | CallExpr | MethodCall | ConstructExpr | ParenExpr | Lambda ;
Lambda          ::= 'sub' Signature Block | 'method' Signature Block ;
```

### Operator Precedence Matrix

Parsed via Pratt top-down operator precedence from highest (Level 1) to lowest (Level 20):

| Level | Operator | Fixity | Associativity | Description |
|---|---|---|---|---|
| **1** | `->` `->[]` `->{}` `->$*` `->@*` `->%*` | Postfix | Left | Dereference, invocation, container indexing |
| **2** | `++` `--` | Postfix | Non-assoc | Post-increment / decrement |
| **3** | `**` | Binary | Right | Exponentiation |
| **4** | `!` `~` `\` `+` `-` | Prefix | Right | Unary logical/bitwise NOT, reference take, unary signs |
| **5** | `=~` `!~` | Binary | Left | Pattern binding |
| **6** | `*` `/` `%` `x` | Binary | Left | Multiplicative, remainder, string/list repetition |
| **7** | `+` `-` `.` | Binary | Left | Additive, string concatenation |
| **8** | `<<` `>>` | Binary | Left | Bitwise shifts (arithmetic vs logical chosen by signedness) |
| **9** | `<` `>` `<=` `>=` `lt` `gt` `le` `ge` | Binary | Left | Relational comparisons (numeric vs string) |
| **10** | `==` `!=` `<=>` `eq` `ne` `cmp` | Binary | Left | Equality and three-way comparisons |
| **11** | `&` | Binary | Left | Bitwise AND |
| **12** | `\|` `^` | Binary | Left | Bitwise OR / XOR |
| **13** | `&&` | Binary | Left | Short-circuit logical AND |
| **14** | `\|\|` `//` | Binary | Left | Short-circuit logical OR, defined-or |
| **15** | `..` `...` | Binary | Non-assoc | Sequence range, flip-flop |
| **16** | `? :` | Ternary | Right | Conditional evaluation |
| **17** | `=` `+=` `-=` `*=` `/=` `//=` `\|\|=` | Binary | Right | Assignment and compound assignments |
| **18** | `not` | Prefix | Right | Low-precedence logical NOT |
| **19** | `and` | Binary | Left | Low-precedence logical conjunction |
| **20** | `or` `xor` | Binary | Left | Low-precedence logical disjunction |

---

## Variables

### Invariant Sigils

Sigils are invariant: they designate the container type and do not mutate based on access dimension or evaluation context.

| Sigil | Container | Element Access | Reference | Full Dereference |
|---|---|---|---|---|
| `$` | Scalar / Native Primitive / Object Pointer | `$x` | `\$x` | `$ref->$*` |
| `@` | Sequentially Indexed Array | `@arr[0]` | `\@arr` | `$ref->@*` |
| `%` | Associative Dictionary (Hash) | `%map{"key"}` | `\%map` | `$ref->%*` |

```perl
# Arrays retain @ on element access
my @numbers = (10, 20, 30);
my i64 $first = @numbers[0];     # Valid
@numbers[1] = 25;                # Direct mutation

# Hashes retain % on key access
my %config = (host => "localhost", port => 8080);
my String $host = %config{"host"};
%config{"port"} = 9090;
```

### Postfix Dereferencing (`postderef`)

Circumfix/prefix dereferencing (`$$ref`, `@$ref[0]`) is invalid. Dereferencing is strictly postfix:

```perl
my $arr_ref    = [ 10, 20, 30 ];
my $hash_ref   = { name => "Alice", age => 30 };
my $scalar_ref = \"Hello";

say($arr_ref->[0]);           # Element: 10
say($hash_ref->{"name"});     # Element: "Alice"
say($scalar_ref->$*);         # Scalar deref: "Hello"

foreach my $val ($arr_ref->@*) { say($val); }
my @keys = $hash_ref->%*;
```

### MUMPS-Style Naked References

When traversing nested associative data structures, postfix navigation reduces repeated root qualifiers to chained `GetElementPtr` lookups:

```perl
my $user = \%database{"users"}{"104"};

# Naked dereferencing directly into child leaves:
my String $name  = $user->{"profile"}{"name"};
my i64    $login = $user->{"security"}{"last_login"};
```

### Storage Classes

- `my`: Lexical variable allocated to a hardware register or stack frame slot. Dropped at lexical block exit.
- `our`: Package-scoped variable allocated to the Isolate's local `.data` segment.
- `state`: Persistent lexical variable. Initialized exactly once and survives scope exit.
- `const`: Compile-time immutable constant emitted directly into `.rodata`.

### Truthiness

A value is **false** if and only if it is:
1. Integer `0` or Floating-point `0.0`
2. String `"0"`
3. Empty string `""`
4. Undefined (`undef`, null pointer, or Type Tag 0)

All other values—including `"00"`, `"false"`, `0.5`, negative numbers, array references, and object pointers—are **true**. When a dynamic `Any` scalar is tested in a boolean context, evaluation routes through the runtime helper `is_truthy(ptr)` to guarantee accurate Tag checking without payload truncation.

### Defined-Or and Conditional Assignment (`//`, `//=`, `||=`)

`//` is the defined-or operator. Operands evaluate eagerly:
```perl
my $val = $primary // $fallback // "default";
```

- `//=` assigns only when the destination slot is **undefined** (null pointer or `Any` Tag 0). On native machine primitives (`i64`, `f64`, `bool`), which cannot be undefined, `//=` degrades at compile time to `=`.
- `||=` assigns when the destination slot evaluates to **false**. On native types, it tests for zero/false; on `Any` pointers, it tests for null or non-truthiness.

$$\frac{\langle e_1, \sigma, \mu \rangle \Downarrow \langle v_1, \sigma_1, \mu_1 \rangle \quad v_1 \neq \mathbf{null} \wedge \text{Tag}(v_1) \neq 0}{\langle e_1 \mathbin{/\!\!/} e_2, \sigma, \mu \rangle \Downarrow \langle v_1, \sigma_1, \mu_1 \rangle}$$

$$\frac{\langle e_1, \sigma, \mu \rangle \Downarrow \langle v_1, \sigma_1, \mu_1 \rangle \quad (v_1 = \mathbf{null} \vee \text{Tag}(v_1) = 0) \quad \langle e_2, \sigma_1, \mu_1 \rangle \Downarrow \langle v_2, \sigma_2, \mu_2 \rangle}{\langle e_1 \mathbin{/\!\!/} e_2, \sigma, \mu \rangle \Downarrow \langle v_2, \sigma_2, \mu_2 \rangle}$$

### Containers: Arrays and Hashes

Arrays and Hashes are native first-class containers.
- **Arrays (`@`):** Resizable sequential buffers managed by `push`, `pop`, `shift`, and `unshift`.
- **Hashes (`%`):** Open-addressing tables with linear probing and power-of-two capacity [^hashing]. Managed by `keys`, `values`, `exists`, and `delete`. Keys coerce to strings; values take refcount ownership (`incref`).

---

## Functions

Subroutines are declared via `sub` with strictly typed signatures. Return types are annotated with `:returns(...)`.

### Static Typing Judgements

Typing judgments follow formal deduction $\Gamma \vdash e : \tau$:

$$
\frac{\Gamma(x) = \tau}{\Gamma \vdash x : \tau}\;[\text{Var}]
\qquad
\frac{\Gamma \vdash e_1 : \text{i64} \quad \Gamma \vdash e_2 : \text{i64}}{\Gamma \vdash e_1 + e_2 : \text{i64}}\;[\text{IntAdd}]
$$

$$
\frac{\Gamma \vdash e_1 : \tau \quad \Gamma[x \mapsto \tau] \vdash e_2 : \tau'}{\Gamma \vdash (\text{my } \tau\ x = e_1;\ e_2) : \tau'}\;[\text{Let}]
\qquad
\frac{\Gamma \vdash f : (\tau_1,\dots,\tau_n) \to (\sigma_1,\dots,\sigma_m) \quad \Gamma \vdash a_i : \tau_i}{\Gamma \vdash f(a_1,\dots,a_n) : (\sigma_1,\dots,\sigma_m)}\;[\text{Call}]
$$

### Zero-Allocation Register Tuples

When a subroutine returns multiple values, they are mapped directly onto the architecture's return registers with zero heap allocation:

$$
\frac{\Gamma \vdash e_i : \tau_i \quad i \in \{1,\dots,k\} \quad k \le |\text{ArchRegs}_{\text{ret}}|}{\Gamma \vdash (e_1, \dots, e_k) \Rightarrow \text{RegTuple}(\vec{r}_k, \vec{e}_k) : \prod_{i=1}^k \tau_i}
$$

```perl
sub divide(i64 $numerator, i64 $denominator) :returns(i64, bool) {
    if ($denominator == 0) {
        return (0, false);           # rax = 0, rdx = 0
    }
    return ($numerator / $denominator, true); # rax = quot, rdx = 1
}

my ($quotient, $ok) = divide(42, 6);
```

### Parameter Defaults

Positional parameters may specify default expressions. Omitted trailing arguments are evaluated at the call site in caller scope; a default expression may reference any preceding parameter:

```perl
sub connect(String $host, i64 $port = 8080, i64 $timeout = $port > 1024 ? 30 : 60) :returns(ptr) {
    # ...
}

my ptr $c1 = connect("127.0.0.1");     # port = 8080, timeout = 30
my ptr $c2 = connect("127.0.0.1", 80); # port = 80,   timeout = 60
```

### Named Parameters

Parameters declared with a leading `:` are passed at call sites by name using fat comma `=>`:

```perl
sub spawn_worker(String $task, :i64 $priority = 0, :bool $detached = false) :returns(void) {
    # ...
}

spawn_worker("reindex", priority => 5, detached => true);
```

### Closures & Environment Records

Subroutines that do not capture outer lexical variables lower to bare function pointers in `.text`. Subroutines capturing lexicals allocate an Immix-managed **Environment Record** holding the captured storage cells, passed as a hidden environment pointer governed by the Caller-Borrows contract.

---

## Classes

Brocken implements encapsulation via Corinna-style classes (`use feature 'class'`).

```perl
class BankAccount {
    field u64    $account_id :param;
    field String $owner_name :param :reader;
    field i64    $balance    :reader = 0;
    field bool   $is_frozen  = false;

    ADJUST {
        die("Invalid account ID: cannot be zero") if $account_id == 0;
    }

    method deposit(i64 $amount) :returns(i64) {
        die("Account is frozen") if $is_frozen;
        die("Amount must be positive") if $amount <= 0;
        $balance += $amount;
        return $balance;
    }

    DESTROY {
        # Executes deterministically when reference count reaches 0
    }
}
```

### Constructors & Accessor Naming

Constructors are synthesized as `Class->new(...)`. Accessor and parameter names strip **exactly one** leading underscore from the field name:
- `field $_timeout :param;`  $\Rightarrow$ `new(timeout => 30)`
- `field $_timeout :reader;` $\Rightarrow$ `$obj->timeout()`
- `field $_timeout :writer;` $\Rightarrow$ `$obj->set_timeout(60)`
- `field $__private :reader;` $\Rightarrow$ `$obj->_private()` (one underscore remains)

### Array and Hash Fields

Classes support aggregate field definitions:
- `field [T; N] $inline_arr`: Reserves $N$ elements of type $T$ **inline** inside the instance allocation. Accessed via `@inline_arr[i]`.
- `field T @dyn_arr`: Stores an 8-byte pointer slot to an external array slab.
- `field T %dyn_hash`: Stores an 8-byte pointer slot to an external hash table.

### Field Attributes

| Attribute | Parameter | Semantics |
|---|---|---|
| `:param` | None or `(name)` | Exposes field as constructor argument. |
| `:reader` | None or `(name)` | Synthesizes getter method `$obj->name()`. |
| `:writer` | None or `(name)` | Synthesizes chaining setter returning `$self`. |
| `:accessor` | None or `(name)` | Combines reader and chaining writer. |
| `:weak` | None | Stores pointer without taking refcount ownership (cycle breaking). |

### Component Pascal Role Flattening (`role` & `adjoin`)

To avoid dynamic vtable overhead and preserve AOT monomorphic dispatch, Brocken uses **Structural Role Flattening**:

```perl
role Serializable {
    requires id;

    method to_json() :returns(String) {
        return "{\"id\":" . $self->id . "}";
    }
}

class DeviceNode {
    field u64 $id :param :reader;
    adjoin Serializable; # Inlines Serializable methods at compile time
}
```

When a class `adjoin`s a role, Katsuro flattens the role’s fields and method ASTs directly into the consuming class prior to Lindsay SSA lowering. Method requirements (`requires`) are validated statically.

### Inheritance and Static Dispatch

Single inheritance is declared with `:isa(Parent)`:

```perl
class PremiumAccount :isa(BankAccount) {
    field i64 $credit_limit :param = 1000;

    method deposit(i64 $amount) :returns(i64) {
        say("Applying premium credit check");
        return $self->SUPER::deposit($amount);
    }
}
```

- **Dispatch:** Dispatch is resolved **statically** at compile time based on the receiver's declared type.
- **Privacy:** Fields are strictly private to the declaring class; subclasses inherit methods, not field visibility.
- **`SUPER::`:** Resolves statically to the nearest ancestor method.
- **Layout:** Derived fields append directly after ancestor fields.

### Destructor (`DESTROY`) Semantics

1. When an object's reference count reaches 0, `Class::DESTROY($self)` executes immediately.
2. Destructors chain in derived $\to$ root order.
3. Hidden cascading teardowns emit `decref` operations on all managed fields.
4. An unhandled exception thrown during `DESTROY` triggers an immediate runtime abort.

### Physical Instance Layout

Class instances are contiguous Immix allocations with an 8-byte header followed by naturally aligned fields:

```text
Offset  Size  Field
--------------------------------------------------------------------------------
 0      2     Reference Count (u16, saturated at 65535 = pinned)
 2      1     GC Flags (Cycle suspect, Buffered, Leaf, BRC color)
 3      1     Type Tag (Tag 4 = Class)
 4      4     Auxiliary: class id (u32, 0 for a boxed ptr)
 8      8     Superclass field: $account_id (u64)
16      8     Superclass field: $owner_name (managed string pointer)
24      8     Superclass field: $balance (i64)
32      1     Superclass field: $is_frozen (bool)
33      7     Alignment padding
40      8     Subclass field:   $credit_limit (i64)
Total: 48 bytes (Strictly 8-byte naturally aligned)
```

---

## Modules

Modules map namespaces to compilation units on disk:

```perl
# lib/Math/Geometry.brocken
package Math::Geometry 1.0.0;

use feature 'brocken_native_types';

sub distance(f64 $x1, f64 $y1, f64 $x2, f64 $y2) :export :returns(f64) {
    my f64 $dx = $x2 - $x1;
    my f64 $dy = $y2 - $y1;
    return sqrt($dx * $dx + $dy * $dy);
}
```

Consumed via `use`:
```perl
use Math::Geometry;
my f64 $d = Math::Geometry::distance(0.0, 0.0, 3.0, 4.0);
```

During Lindsay optimization, unused unexported subroutines and unreferenced classes are stripped via Link-Time Dead Code Elimination (tree-shaking).

---

## Attributes

### Subroutine Attributes
- `:returns(Type, ...)`: Specifies return types or multi-register tuples.
- `:inline`: Forces inlining into caller blocks.
- `:noinline`: Forbids inlining.
- `:pure`: Asserts absence of side effects, enabling common subexpression elimination (CSE).
- `:export`: Emits the symbol in the export table (`.dynsym` / `.edata`) for C ABI foreign interop.

### Variable Attributes
- `:aligned(N)`: Enforces $N$-byte memory alignment.
- `:const`: Enforces single-assignment compile-time immutability.

---

## Decorators

Decorators are syntactic compile-time macro transformations wrapping functions or methods:

```perl
decorator timed(Sub $target) {
    return sub (*@args) {
        my i64 $start = Brocken::monotonic_clock();
        my @res = $target->(@args);
        my i64 $elapsed = Brocken::monotonic_clock() - $start;
        say("" . $target->name . " took ${elapsed}ns");
        return @res;
    };
}

@timed
sub process_batch(ptr $data, i64 $len) :returns(void) {
    # ...
}
```

---

# Advanced

## Concurrency

Brocken implements dual-layer concurrency: preemptive **Isolates** (share-nothing OS threads) and cooperative **Fibers** (M:N user-space coroutines) communicating via synchronized **Channels** [^csp].

```text
┌─────────────────────────────────────────────────────────────┐
│                         ISOLATE 1                           │
│  OS Thread (pthread / CreateThread)                         │
│  Pinned fiber register (r12 / x28 / s11) -> FCB             │
│  Thread-Local Immix Heap (zero-lock reference counting)     │
│                                                             │
│   ┌──────────────┐   ctx_swap    ┌──────────────┐           │
│   │   Fiber A    │ <===========> │   Fiber B    │           │
│   │ Stack (64KB) │               │ Stack (64KB) │           │
│   └──────────────┘               └──────────────┘           │
└──────────────────────────────┬──────────────────────────────┘
                               │
                Bounded CCB Ring Buffer Channel
             Deep-copy across the isolate boundary
                               │
┌──────────────────────────────┴──────────────────────────────┐
│                         ISOLATE 2                           │
│  Disjoint Immix Heap and Isolate Control Block              │
└─────────────────────────────────────────────────────────────┘
```

### Isolates (Share-Nothing OS Threads)

An Isolate is an independent OS thread (`pthread_create` / `CreateThread`) owning a dedicated Immix heap and Isolate Control Block (ICB) [^isolate].
- **Zero-Lock Reference Counting:** Because heaps never overlap, `incref` and `decref` execute as plain load-modify-store sequences without bus locks or atomic instructions.
- **Hardware Pinned Register:** The ICB address is pinned to `r14` (x86_64), `x28` (AArch64), or `s11` (RISC-V).

```perl
my ptr $iso = isolate(sub () {
    say("Executing on an independent OS thread with disjoint heap");
});
isolate_join($iso);
```

### Fibers (Cooperative Coroutines)

A Fiber is an M:N user-space coroutine with an independent 64 KiB stack. Fibers switch cooperatively via `ctx_swap` without entering kernel space [^ctxswitch].

```perl
my ptr $fib = fiber(sub ($val) {
    say("Fiber step 1: $val");
    yield($val * 2);
    say("Fiber step 2");
    return 42;
});

my i64 $r1 = transfer($fib, 10); # Yields 20
my i64 $r2 = transfer($fib, 0);  # Returns 42
```

### Fiber Control Block (FCB) Layout

`ctx_swap` spills callee-saved registers into the active FCB, swaps the pinned register, and restores registers from the target FCB.

```text
Offset (AArch64 / RISC-V / x86_64)  Field          Description
-------------------------------------------------------------------------
 0..              (13/14/6 slots)   saved_regs     Callee-saved register spill array
 self*8                              self           FCB self-pointer
 96 / 104 / 48   saved_sp           Hardware stack pointer at last switch
104 / 112 / 56   parent             FCB address of parent/yielder fiber
112 / 120 / 64   resume_pc          Code address jumped to upon resumption
120 / 128 / 72   os_thread          Owning ICB address
128 / 136 / 80   stack_limit        Stack guard floor (sp - runway)
136 / 144 / --   transfer_value     Fiber hand-off payload (ARM64/RISC-V)
144 / 152 / 88   size               FCB structure byte size
```

**x86_64 `ctx_swap` Assembly Sequence:**
```nasm
mov  r11, rsp                  ; Capture current SP
mov  [r12 + 0],  rbx           ; Spill callee-saved registers to current FCB (r12)
mov  [r12 + 8],  rbp
mov  [r12 + 24], r13
mov  [r12 + 32], r14
mov  [r12 + 40], r15
mov  [r12 + 48], r11           ; FCB.saved_sp
lea  r10, [rip + .resume_label]
mov  [r12 + 64], r10           ; Save target resume PC
mov  r12, rdi                  ; SWAP: Load target FCB into fiber register
mov  r10, [r12 + 64]           ; Load target PC
mov  rbx, [r12 + 0]            ; Restore callee-saved registers
mov  rbp, [r12 + 8]
mov  r13, [r12 + 24]
mov  r14, [r12 + 32]
mov  r15, [r12 + 40]
mov  rsp, [r12 + 48]           ; Restore hardware SP
jmp  r10                       ; Resume target fiber
.resume_label:
```

### Channels (CSP)

Channels are typed, synchronized, bounded ring buffers (`chan_create`, `chan_send`, `chan_recv`, `chan_close`):

```c
struct Channel {
    uint32_t capacity;     // Maximum ring buffer elements
    uint32_t count;        // Currently enqueued elements
    uint32_t head;         // Dequeue index
    uint32_t tail;         // Enqueue index
    uint32_t closed;       // Closed flag (1 = closed)
    int64_t  buffer[];     // Ring buffer: capacity * 8 bytes
};
```

- **Primitives:** Transferred by value through the buffer.
- **Aggregates:** Deep-copied across the Isolate boundary into the receiver's Immix heap to preserve heap isolation.
- **Channel Handles:** Encoded as `(index << 32) | generation` to eliminate ABA use-after-free hazards.

---

## Exceptions

Exceptions use zero-cost landing dispatchers backed by an SJLJ (`setjmp`/`longjmp`) handler chain stored on the ICB (`ICB::EXCEPTION_HANDLER_STACK`) [^landing].

```perl
try {
    die("Database transaction aborted");
}
catch ($err) {
    warn("Recovered from exception: $err");
}
finally {
    say("Releasing locks");
}
```

### Landing Dispatcher State Machine

To guarantee that `finally` blocks execute exactly once under every exit path (normal exit, catch, early `return`, `last`, or `next`), the compiler lowers `try` into a state machine:

```text
[try_setup]   ──▶ Registers jmp_buf on ICB exception handler stack
       │
[try_body]    ──▶ Normal exit pops handler ──▶ [finally] ──▶ [merge]
       │
       └── (Exception thrown via die/throw)
             │
             ▼
[landing_pad] ──▶ Pops handler, loads thrown value
             │
             ├──▶ [catch_body] ──▶ [finally] ──▶ [merge]
             └──▶ (No catch)   ──▶ [finally] ──▶ [re-throw]
```

Because `longjmp` restores only callee-saved registers, the register allocator excludes caller-saved registers from the active pool across `setjmp` setup points.

---

## Resources

Deterministic resource cleanup is managed via reference-counted finalizers (`DESTROY`) and lexical `defer` statements:

```perl
sub process_file(String $path) :returns(void) {
    my ptr $fh = open_file($path);
    defer { close_file($fh); };

    # File operations...
}
```

The `defer` block executes whenever the enclosing lexical block terminates—whether by standard exit, early `return`, loop escape, or an unwinding exception.

---

## Iterators

Iterators are zero-allocation cursor objects conforming to the iterator protocol: a `next` method yielding a `(value, bool)` register tuple.

Ranges in `for` loop headers optimize into zero-allocation register induction loops:
```perl
for my i64 $i (0 .. 1000) {
    # $i is held in a hardware register; no array is allocated
}
```

Loop control statements:
- `next`: Jumps to the loop induction step.
- `last`: Terminates loop execution immediately.
- `redo`: Re-enters the loop body without re-evaluating the induction variable.

---

## Type System

Brocken maintains a strict syntactic and physical separation between **unboxed raw machine types** (lowercase) and **managed fat scalars** (Capitalized).

```text
                          Type Universe
                                │
          ┌─────────────────────┴─────────────────────┐
          ▼                                           ▼
 Unboxed Machine Types                       Managed Fat Scalars
 (Zero-overhead registers)                (16-byte Immix Fat Scalar)
 - i8 .. i128 (Signed Ints)               - Any
 - u8 .. u128 (Unsigned Ints)             - Int, Float, Bool
 - f32, f64 (IEEE Floats)                 - String
 - bool (i1)                              - Array, Hash
 - ptr (64-bit Address)                   - Class Objects
```

### Unboxed Machine Types

Enabled via `use feature 'brocken_native_types';`. Unboxed types bypass fat scalar headers, do not participate in reference counting, and map directly to registers and machine instructions:
- `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `i128`, `u128`
- `f32`, `f64`
- `bool`
- `ptr` (Opaque 64-bit machine address)
- `int` (Alias for `i64`)

**Nullability:** Unboxed types **cannot be `undef`**; uninitialized, they default to `0`, `0.0`, or `false`.

### Managed Fat Scalars (`Any`)

Variables without an explicit unboxed type default to `Any`, a 16-byte tagged scalar allocated on the Immix heap [^fatscalar]:

```text
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       Reference Count         |    GC Flags   |   Type Tag    |
|            (u16)              |     (u8)      |     (u8)      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Auxiliary / Length                      |
|                             (u32)                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                        Payload Bits                           |
|                       (u64 / f64 / ptr)                       |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

#### Field Layout:
- **Reference Count (`u16`, bits 0..15):** Saturating refcount. Overflow past `65535` pins the object permanently.
- **GC Flags (`u8`, bits 16..23):**
  - `0x01` [Bit 0]: **Suspect** (Queued in cycle buffer)
  - `0x02` [Bit 1]: **Buffered** (Present in ICB suspect ring)
  - `0x04` [Bit 2]: **Leaf** (Contains no outgoing pointers; exempt from cycle trace)
  - `0x18` [Bits 3..4]: **Bacon & Rajan Color** (`00b` = White, `01b` = Gray, `10b` = Purple, `11b` = Black)
- **Type Tag (`u8`, bits 24..31):**
  - `0x00`: Undef / Null
  - `0x01`: Boxed Integer (`i64`)
  - `0x03`: Boxed Float (`f64`)
  - `0x04`: Raw Address (`ptr`)
  - `0x05`: Dynamic Variant Container
  - `0x06`: Boxed 128-bit Integer (`i128`)
  - `0x07`: List Container (Points to a heap list data block)
  - `0x08`: Hash Container (Points to an open-addressing table)

### List and Hash Data Block Layouts

When a fat scalar represents a List (`Tag 7`) or Hash (`Tag 8`), the payload word points to an Immix-allocated data block:

```text
List Data Block Layout:
[block + 0]:   8 bytes   Header (T_LIST << 24)
[block + 8]:   8 bytes   Element count N
[block + 16]:  8 bytes   Element 0 (i64 / ptr)
[block + 24]:  8 bytes   Element 1
... Total size: 16 + N * 8 bytes

Hash Data Block Layout:
[block + 0]:   8 bytes   Header (T_HASH << 24)
[block + 8]:   8 bytes   Entry count N
[block + 16]:  8 bytes   Key 0 (String fat scalar ptr)
[block + 24]:  8 bytes   Value 0 (i64 / ptr)
[block + 32]:  8 bytes   Key 1 (String fat scalar ptr)
[block + 40]:  8 bytes   Value 1
... Total size: 16 + N * 16 bytes
```

### Coercion and Unboxing Mechanics
- `unbox_i64(ptr)`: Reads tag; truncates float payloads toward zero, unboxes integer payloads directly.
- `unbox_f64(ptr)`: Widens integer payloads to double, loads float payloads directly.
- `box(val)`: Allocates 16 bytes via the Immix bump allocator, writes header/tag, and stores the payload.

---

## UTF8

Strings are immutable, length-prefixed, NUL-terminated byte sequences guaranteed to contain valid UTF-8.

```perl
my String $greeting = "こんにちは世界";
say(length($greeting));   # Character count
say(bytes($greeting));    # Raw byte count
```

### Strict Interpolation Rules

Inside double quotes (`"..."`):
1. Plain scalars interpolate: `"User: $name"`
2. Disambiguated scalars interpolate: `"Count: ${items}kg"`
3. Container elements interpolate: `"First: @arr[0]"`, `"Value: %map{key}"`
4. **Method calls DO NOT interpolate:** `"($obj->name)"` outputs the stringified object followed by literal `->name`. Explicit string concatenation must be used: `"(" . $obj->name . ")"`.

### ASCII-Magical String Increment

Applying `++` to a string implements Perl's ASCII-carry rules:
- Applies strictly to strings matching `/^[a-zA-Z]*[0-9]*\z/` (`"az"++` $\to$ `"ba"`, `"99"++` $\to$ `"100"`).
- Non-matching strings coerce to numeric `0` and increment to `1`.
- Decrement (`--`) is **never magical**: it coerces to numeric and subtracts `1`.

---

## Execution Policies

### Isolate Control Block (ICB) Layout

The ICB is a 160-byte structure pinned to a dedicated hardware register (`r14` on x86_64, `x28` on AArch64, `s11` on RISC-V). Generated from `Brocken::Layout`, it contains all isolate-local runtime state:

```text
Offset  Field                      Description
--------------------------------------------------------------------------------
  0     heap_cursor                Bump pointer for legacy heap allocations
  8     current_fcb                Address of currently running Fiber Control Block
 16     fiber_head                 Head of active fiber list
 24     immix_cursor               Bump pointer within current Immix line
 32     immix_limit                Boundary limit of current Immix line
 40     free_blocks                Head of reusable 32 KiB block linked list
 48     free16_head                Segregated free list for 16-byte fat scalars
 56     suspect_buffer_head        Head of Bacon & Rajan suspect cycle ring buffer
 64     fuel                       Remaining instruction budget
 72     err_code                   Abort reason (see Error Codes table)
 80     current_block              Base address of active 32 KiB Immix block
 88     memory_limit               Heap ceiling in bytes (0 = unconstrained)
 96     memory_used                Current active heap byte consumption
104     capabilities               Permission bitmask gating privileged operations
112     gate_table                 Function dispatch table for host bind gates
120     host_icb                   Parent host ICB pointer during gate execution
128     exception_handler_stack    Head of SJLJ jmp_buf exception handler chain
136     thrown_value               Payload transferred via die/throw
144     free_big_head              Head of reusable variable-sized array slabs
152     stack_limit                Stack guard floor threshold (sp - runway)
160     SIZE                       Total structure allocation size
```

### Error Codes (`ICB::ERR_CODE`)

| Code | Value | Meaning |
|---|---|---|
| `ERR_OK` | 0 | Normal execution |
| `ERR_OOM` | 1 | Out of memory against `MEMORY_LIMIT` |
| `ERR_NO_FUEL` | 2 | Instruction budget exhausted [^fuel] |
| `ERR_SECURITY` | 3 | Sandboxed capability check violation [^caps] |
| `ERR_DIV_ZERO` | 4 | Integer division by zero |
| `ERR_THROW` | 5 | Uncaught exception propagated to top-level |
| `ERR_STACK` | 6 | Stack guard floor tripped [^stackguard] |

### Capabilities (`ICB::CAPABILITIES`)

Privileged intrinsics check the bitmask at `ICB::CAPABILITIES`:

| Capability | Bit | Guards |
|---|---|---|
| `CAP_FS_READ` | `1 << 0` | Filesystem read operations |
| `CAP_FS_WRITE`| `1 << 1` | Filesystem write operations |
| `CAP_NET` | `1 << 2` | Socket creation, binding, and connection |
| `CAP_SYSTEM` | `1 << 3` | Process spawning and execution |
| `CAP_FFI` | `1 << 4` | Raw `syscall`, `syscall_by_name`, and dynamic library FFI |

---

## Performance

### Memory Management Architecture

```text
Layer 3: Perceus (Compile-Time IR Optimization)
  ├── Borrow Inference: Drop redundant incref/decref across call boundaries
  ├── RC Elision: Cancel adjacent incref/decref pairs on local bindings
  └── In-Place Reuse: Mutate unique objects (RC == 1) without reallocation

Layer 2: Bacon & Rajan Trial Deletion (Runtime Cycle Collector)
  ├── Suspect Buffer: Tracks non-leaf objects whose RC dropped but stayed > 0
  └── 3-Phase Color Sweep: Purple -> Gray -> White (Garbage) / Black (Live)

Layer 1: Immediate Reference Counting + Immix Allocator (Hot Path)
  ├── Segregated Free16 List: Reclaims 16-byte fat scalars directly
  └── Immix Bump Allocator: 32 KiB blocks divided into 256-byte lines
```

### The Caller-Borrows Contract

Subroutine arguments are borrowed. Passing an argument does not increment its reference count. The callee borrows the parameter and **MUST NOT** decrement it on exit; an `incref` is emitted only if the value escapes into an array, hash, class field, or global variable.

### Variable Borrowing & RC Elision Rule (Perceus)

$$\frac{\Gamma(x) = \text{Any} \quad \text{Liveness}(x, \text{next}(e)) = \emptyset}{\Gamma \vdash x \Rightarrow \text{Move}(x) : \text{Any}}$$

When an `Any` container reaches its terminal lexical use without aliasing, Lindsay lowers the access to an affine transfer ($\text{Move}$), canceling the matching $\text{incref}/\text{decref}$ pair at compile time [^perceus].

### Bacon & Rajan Synchronous Cycle Collection

Trial deletion runs over the Immix heap to collect cyclic garbage [^trialdeletion]:

| Initial State | Event / Phase | Target State | Internal Reference Adjustment |
|---|---|---|---|
| **Black** | `decref` leaving $\text{RC} > 0$ | **Purple** | Push to ICB suspect buffer |
| **Purple** | Phase 1: `MarkGray` | **Gray** | Recursively decrement child $\text{RC}$; paint child Gray |
| **Gray** | Phase 2: $\text{RC} > 0$ | **Black** | Recursively restore child $\text{RC}$; cancel collection |
| **Gray** | Phase 2: $\text{RC} == 0$ | **White** | Confirmed isolated cycle; mark for reclamation |
| **White** | Phase 3: `Collect` | **Recycled** | Run `DESTROY`, link to `free16_head` |

### Immix Block Geometry

Blocks are exactly 32768 bytes ($32\text{ KiB}$) aligned to 32 KiB boundaries:

```text
[block + 0..15]:         128-bit line availability bitmap (Bit N = Line N in use)
[block + 16..255]:       Line 0   (240 usable data bytes; first 16 bytes contain bitmap)
[block + 256..511]:      Line 1   (256 usable data bytes)
...
[block + 32512..32751]:  Line 127 (240 usable data bytes)
[block + 32752..32759]:  live_count (i64) - Live object count in this block
[block + 32760..32767]:  next_free  (i64) - Scan cursor for next free line
```

When an object is freed, its owning block is derived by address masking:

$$\text{block\_base} = \text{arena\_base} + ((\text{obj\_addr} - \text{arena\_base}) \ \& \ \sim 0\text{x7FFF})$$

The owning block's `live_count` is decremented. When `live_count` reaches zero, the entire block is returned to `ICB::FREE_BLOCKS`.

### Linear Scan Register Allocation

Jenny uses a fixed-point live-interval scan with dynamic spill and caller-save management [^linearscan]. Live sets and spill slots are traversed in sorted order to guarantee reproducible output.

### Reproducible Builds

Builds are byte-reproducible [^repro]. When `SOURCE_DATE_EPOCH` is set, all hash iterations (register allocation, section placement, ELF SYSV `.hash` table, DWARF strings) are sorted deterministically, yielding bitwise-identical binaries across platforms.

---

## Language Server

The compiler embeds a Language Server Protocol (LSP) daemon (`bkn lsp`) providing IDE diagnostics, auto-completion, symbol navigation, and type inference.

### DWARF v5 Debug Generation

The linker emits standard DWARF v5 debugging sections [^dwarf]:
- `.debug_line`: Offset-to-source line/column mappings.
- `.debug_info`: Compilation units, subprograms, variable DIEs (`DW_TAG_variable`), and class struct layouts (`DW_TAG_structure_type`).
- `.debug_names`: Accelerated symbol lookup using case-folding DJB hashing.
- `.debug_frame`: Call frame information for unwinding.

Debug emission levels (`debug_level`):
- `0`: Stripped (no debug tables).
- `1`: `.debug_line`.
- `2`: + `.debug_info`, `.debug_abbrev`.
- `3`: + `.debug_frame`, `.debug_aranges`.
- `4`: + `.debug_names`, `.debug_str`, struct/class DIEs.
- `5`: + COFF symbols and ASLR disabled (`IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE` cleared) for PE targets.

### Native Backtraces (`.brk_sym`)

The linker can emit a compact `.brk_sym` section so stripped release binaries can resolve backtraces without external DWARF files [^brksym]:

```text
word    count
count × { start_rva, end_rva, name_offset }
byte[]  NUL-terminated symbol name pool
```

---

## FFI

Direct foreign function invocation without external wrapper libraries is handled by the `Brocken::` pseudo-namespace, lowering directly into MIR instructions without call overhead:

| Intrinsic | MIR Output | Description |
|---|---|---|
| `Brocken::ptr_add(p, off)` / `ptr_sub(p, off)` | `add` / `sub` | Pointer arithmetic |
| `Brocken::ptr_cmp_gt(a, b)` / `_lt` / `_ge` / `_le` / `_eq` | `icmp sgt` / `slt` / `sge` / `sle` / `eq` | Pointer comparison |
| `Brocken::load_i64(ptr)` / `store_i64(ptr, val)` | `load i64` / `store i64` | 64-bit memory load / store |
| `Brocken::load_i32(ptr)` / `load_i8(ptr)` / `load_u16(ptr)` | `load i32` / `load i8` / `load i16` | Sized integer load |
| `Brocken::load_f64(ptr)` / `store_f64(ptr, val)` | `load f64` / `store f64` | 64-bit float load / store |
| `Brocken::i64_add(a, b)` / `i64_sub(a, b)` | `add` / `sub` | Raw integer arithmetic |
| `Brocken::band` / `bor` / `bxor` / `shl` / `shr` | `and` / `or` / `xor` / `shl` / `lshr` | Bitwise logical operations |
| `Brocken::syscall(num, ...)` | `syscall` | Raw system call (guarded by `CAP_FFI`) |
| `Brocken::syscall_by_name(name, ...)` | `syscall` | Resolved system call (guarded by `CAP_FFI`) |
| `Brocken::libc(name, ...)` | `call` | Linker-resolved dynamic import |
| `Brocken::heap_base()` | `load` | Base address of the Isolate's heap |

### Dynamic Library Loading & Binding

```perl
use feature 'brocken_ffi';

my ptr $lib     = Brocken::FFI::load_library("libsqlite3.so");
my ptr $open_fn = Brocken::FFI::bind_function($lib, "sqlite3_open");
my i64 $res     = Brocken::FFI::call_i64($open_fn, "app.db", \$handle);
```

### Bind Gates

Bind gates enable guest Brocken code to execute inside a host process without heap corruption:
1. Arguments are deep-copied into the host's Immix heap.
2. The pinned ICB hardware register is swapped to the host's ICB.
3. The host function executes.
4. The return value is deep-copied back to the guest heap, and the guest ICB register is restored.

---

# Toolkit

The `bkn` executable is the consolidated toolchain driver.

## Commands

```text
bkn build [options] [path]    Compile source into a standalone native executable
bkn run [options] [path]      Compile and immediately execute the program
bkn test [options] [path]     Run the test harness with native TAP output
bkn bench [options] [path]    Run performance microbenchmarks
bkn fmt [options] [files...]  Format sources according to the canonical style
bkn lint [options] [files...] Run static analysis and borrow checks
bkn lsp                       Launch the language server daemon
bkn clean                     Clear build caches and temporary artifacts
bkn new <project>             Scaffold a new project directory
bkn target <cmd>              Query and install target triples
bkn vendor                    Vendor dependencies for reproducible air-gapped builds
bkn task <name>               Execute a declared build task
bkn upgrade                   Update the toolchain
```

### `bkn build` Flags

- `--release`: Compiles with `-O3`, enables LTO, and strips symbol tables.
- `--target <triple>`: Cross-compiles for the specified target triple.
- `--fuel <num>`: Overrides the default isolate fuel budget.
- `--mem-limit <bytes>`: Sets the maximum isolate heap limit.
- `--cap <mask|list>`: Sets the capability permission bitmask.
- `--debug-level <0..5>`: Sets DWARF detail level.
- `--reproducible`: Enforces deterministic sorting of all emitted sections and symbols.

---

## Runtime

The runtime (`core.brocken`) is self-hosted and prepended to user ASTs during compilation. It manages:
- Immix bump allocators and line mark-sweeping
- Bacon & Rajan trial deletion cycle collectors
- Fiber context switching (`ctx_swap`)
- Isolate life cycles and CSP channels

---

## Testing

Brocken features built-in Test Anything Protocol (TAP) testing:

```perl
# tests/math.t
use Test::More;

sub add(i64 $a, i64 $b) :returns(i64) { return $a + $b; }

ok(add(2, 3) == 5, "2 + 3 == 5");
is(add(-1, 1), 0,  "-1 + 1 == 0");
done_testing();
```

Execute tests:
```bash
bkn test
```

### Test Harness & Fuzzer

- `Test2::Tools::Brocken`: Harness providing `run_exec($file, %args)` for executing compiled binaries, checking exit codes, running under GDB (`gdb => 1`), and driving QEMU emulation.
- `Brocken::Fuzz`: Random program generator comparing compiled outputs against an oracle interpreter. Failing cases encode to a reversible hex `case_id`:
  ```bash
  bkn fuzz --time-limit 300 --seed 42 --id <case_id>
  ```

---

## Benchmarking

Microbenchmarking framework with high-precision hardware timestamps:

```perl
use Benchmark;

timethis(1_000_000, sub () {
    my Point $p = Point->new(x => 10, y => 20);
});
```

---

## Bundler

Package dependencies are tracked in `Brocken.lock`, pinning SHA-256 content hashes:

```toml
[[package]]
name = "Crypt::SipHash"
version = "1.0.2"
source = "registry+https://pkg.brocken.dev"
digest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
```

```bash
bkn vendor   # Copies locked dependencies into ./vendor
```

---

## Formatter

Canonical AST-based formatter (`bkn fmt`):
- 4-space indentation, no tabs
- K&R brace placement
- Single space surrounding binary operators
- Trailing commas in multi-line lists
- One blank line between top-level declarations

Because formatting operates directly on the parsed AST, it guarantees semantics-preserving transformation.

---

## Linting

Static analyzer (`bkn lint`) reporting:
- Borrow-checker violations and premature escapes
- Unreachable dead code blocks
- Unhandled tuple returns
- Implicit lossy numeric conversions
- Unused variables and imports

---

## Tasks

Build automation declared in `Brocken.toml`:

```toml
[tasks.generate_tables]
command = "bkn run scripts/gen_tables.brocken"

[tasks.pre_release]
dependencies = ["lint", "test", "generate_tables"]
```

```bash
bkn task pre_release
```

---

## Upgrade

Self-updating toolchain:

```bash
bkn upgrade --channel stable
```

---

# Examples

## Hello, World!

```perl
use feature 'class';

class Application {
    field String $message :param;

    method run() :returns(i64) {
        say($message);
        return 0;
    }
}

my Application $app = Application->new(message => "Hello, World!");
exit($app->run());
```

---

## Fibonacci

Comparing an iterative zero-allocation loop with recursive execution:

```perl
sub fib_iterative(i64 $n) :returns(i64) {
    my i64 $a = 0;
    my i64 $b = 1;
    for my i64 $i (0 .. $n - 1) {
        my i64 $next = $a + $b;
        $a = $b;
        $b = $next;
    }
    return $a;
}

sub fib_recursive(i64 $n) :returns(i64) {
    return 0 if $n <= 0;
    return 1 if $n == 1;
    return fib_recursive($n - 1) + fib_recursive($n - 2);
}

my i64 $n = 30;
say("fib_iterative($n) = " . fib_iterative($n));
say("fib_recursive($n) = " . fib_recursive($n));
```

---

## Leibniz

Computing $\pi$ using the Leibniz infinite series formula:

$$\frac{\pi}{4} = \sum_{k=0}^{\infty} \frac{(-1)^k}{2k + 1} = 1 - \frac{1}{3} + \frac{1}{5} - \frac{1}{7} + \frac{1}{9} - \cdots$$

```perl
use feature 'brocken_native_types';

sub estimate_pi(i64 $terms) :returns(f64) {
    my f64 $acc  = 0.0;
    my f64 $sign = 1.0;

    for my i64 $k (0 .. $terms) {
        my f64 $denominator = 2.0 * $k + 1.0;
        $acc  += $sign / $denominator;
        $sign  = -$sign;
    }

    return $acc * 4.0;
}

my i64 $iterations = 10_000_000;
my f64 $pi         = estimate_pi($iterations);

say("Estimated value of PI over $iterations iterations: $pi");
```

---

# Glossary

| Term | Definition |
|---|---|
| **Isolate** [^isolate] | An independent OS thread with a disjoint Immix heap and ICB. No shared mutable state. |
| **Fiber** [^ctxswitch] | A cooperative user-space green thread multiplexed inside an Isolate, scheduled via `ctx_swap`. |
| **ICB** [^isolate] | Isolate Control Block: 160-byte control structure pinned to `r14`/`x28`/`s11`. |
| **FCB** [^ctxswitch] | Fiber Control Block: saves callee-saved registers, SP, resume PC, and parent link. |
| **CCB** [^csp] | Channel Control Block: bounded ring buffer guarded by mutex/condvar for cross-isolate IPC. |
| **Fat Scalar** [^fatscalar] | 16-byte `Any` container: refcount, GC flags, type tag, auxiliary data, and 64-bit payload. |
| **Immix** [^immix] | Mark-region allocator managing 32 KiB blocks divided into 256-byte lines. |
| **Reference Counting** [^rcgc] | Immediate reclamation mechanism governed by the Caller-Borrows contract. |
| **Perceus** [^perceus] | Compile-time reference-counting optimization (borrow inference, RC elision, in-place reuse). |
| **Linear Scan** [^linearscan] | Register allocator in `Brocken::Jenny::RegAlloc`. |
| **MIR** [^pipeline] | Machine Intermediate Representation: architecture-specific low-level IR. |
| **Lindsay** [^pipeline] | Architecture-agnostic SSA middle-end IR. |
| **Jenny** [^pipeline] | Backend compiler: MIR lowering, register allocation, machine encoding, binary linking. |
| **Katsuro** [^pipeline] | Compiler frontend: platform detection, lexer, Pratt parser, AST construction. |
| **Trial Deletion** [^trialdeletion] | Bacon & Rajan cycle detection algorithm running over the ICB suspect buffer. |
| **Landing Dispatcher** [^landing] | Per-`try` state machine guaranteeing unified, single-execution `finally` dispatch. |
| **Fuel** [^fuel] | ICB instruction budget decremented at safepoints to bound runaway execution. |
| **Capability** [^caps] | Bitmask in the ICB gating privileged intrinsics (`syscall`, `libc`, FFI). |
| **Stack Guard** [^stackguard] | 2 MiB runway threshold in `ICB::STACK_LIMIT` tripping `ERR_STACK` on overflow. |
| **Target Triple** [^triple] | Normalized `arch-vendor-os-env` identifying target backend and ABI. |
| **`.brk_sym`** [^brksym] | Packed symbol table enabling backtraces in stripped release binaries. |
| **DWARF** [^dwarf] | Industry-standard DWARF v5 debugging format. |
| **SEH** [^seh] | Windows Structured Exception Handling (`.pdata`/`.xdata`). |

---

# Index

### AArch64 (ARM64)
**Expansion.** 64-bit Arm architecture and AAPCS64 calling convention.
**Divergence.** Always maintains frame pointer (`x29`); omits pointer-authentication (`paciasp`) and BTI headers.
**Implementation.** `lib/Brocken/Jenny/Codegen/ARM64.pm`, `lib/Brocken/Jenny/Lowerer/ARM64.pm`.
**Maintenance.** Literal-pool displacement windows and shared argument/return register (`x0`) hand-offs during fiber switches.
**References.** [^arm64]

### Backtraces & Frame Pointers
**Expansion.** Walking saved frame pointer chains (`rbp`, `x29`, `s0`) to reconstruct call stacks.
**Divergence.** Frame pointers are preserved unconditionally across all optimization levels.
**Implementation.** `Codegen/{X86_64,ARM64,RISCV64}.pm`, `linker/DWARF.pm`, `.brk_sym` table.
**Maintenance.** Prologues must strictly link the frame chain in standard order before allocating local stack slots.
**References.** [^backtrace]

### `.brk_sym` (Native Backtrace Info)
**Expansion.** Brocken-specific compact symbol section: `{count, [start_rva, end_rva, name_offset]..., string_pool}`.
**Divergence.** Embedded in release ELF, Mach-O, and PE binaries to resolve symbols without DWARF overhead.
**Implementation.** `Linker.pm` (`build_brk_sym`).
**Maintenance.** Structure alignment and integer endianness must remain strictly identical across all linkers.
**References.** [^brksym]

### Capabilities
**Expansion.** Per-isolate capability permission bitmask.
**Divergence.** Sandboxes operations at the Isolate boundary; checked prior to FFI and raw syscall intrinsics.
**Implementation.** `ICB::CAPABILITIES`, `_emit_cap_check` in `Katsuro/Lowerer.pm`.
**Maintenance.** Every new privileged intrinsic must invoke `_emit_cap_check` with the appropriate bit.
**References.** [^caps]

### Channels (CSP)
**Expansion.** Synchronized, bounded ring buffers for cross-isolate communication.
**Divergence.** Deep-copies aggregate objects across isolate boundaries; encodes handles with ABA generation counters.
**Implementation.** `chan_create`/`chan_send`/`chan_recv` in `core.brocken`, CCB in `lib/Brocken/`.
**Maintenance.** Mutex and condition variables are hosted in shared `.data`; ring index updates must occur under lock.
**References.** [^csp]

### CSPRNG
**Expansion.** Cryptographically secure pseudorandom number generation.
**Divergence.** v1 draws directly from kernel syscalls (`getrandom`, `BCryptGenRandom`, `getentropy`); v2 plans in-tree ChaCha20.
**Implementation.** Runtime helpers in `core.brocken`.
**Maintenance.** Must never fall back to insecure PRNG algorithms upon OS call failure.
**References.** [^csprng]

### DWARF
**Expansion.** DWARF v5 debugging information format.
**Divergence.** Emits case-folding DJB hash `.debug_names` accelerated index.
**Implementation.** `Linker/DWARF.pm`.
**Maintenance.** Section cross-references and ULEB128 abbreviation codes must track emitted DIE structures.
**References.** [^dwarf]

### `.eh_frame` / CFI
**Expansion.** Call Frame Information tables consumed by platform unwinders.
**Divergence.** Implemented as an opt-in section; Brocken's primary exception unwinding is handled by the landing dispatcher.
**Implementation.** `build_eh_frame` in `Linker/DWARF.pm`, `PT_GNU_EH_FRAME` in `Linker/ELF64.pm`.
**Maintenance.** FDE encodings use `pcrel` with `zR` augmentation; relocations must track final text addresses.
**References.** [^ehframe]

### ELF64
**Expansion.** System V Executable and Linkable Format (64-bit).
**Divergence.** Hand-rolls program headers and writes sorted SYSV hash chains for reproducible builds.
**Implementation.** `Linker/ELF64.pm`.
**Maintenance.** Section header counts and program header virtual memory layouts must remain aligned to page sizes.
**References.** [^elf]

### Fat Scalar (`Any`)
**Expansion.** 16-byte tagged dynamic scalar container.
**Divergence.** Fixed 16-byte geometry with saturating refcount at 65535 and Bacon & Rajan cycle flags embedded in the header.
**Implementation.** Type tags and GC flags in `core.brocken`, layout in `Lowerer.pm`.
**Maintenance.** Header word layout (refcount at offset 0, flags at offset 2, tag at offset 3) is hard-coded in all backends.
**References.** [^fatscalar]

### Fibers & Context Switching
**Expansion.** Cooperative M:N green threads switched via user-space register swapping.
**Divergence.** Swapped via architecture-specific assembly sequences spilling into structured FCBs.
**Implementation.** `ctx_swap` MIR, `Jenny/FCB.pm`, `Katsuro/Lowerer.pm`.
**Maintenance.** Register save order in assembly must match physical offsets in `FCB.pm` exactly.
**References.** [^ctxswitch]

### Fuel
**Expansion.** Instruction budget bounding isolate execution.
**Divergence.** Checked at function entries, calls, and loop back-edges; trips `ERR_NO_FUEL` on exhaustion.
**Implementation.** `ICB::FUEL`, `_emit_fuel_check` in `Katsuro/Lowerer.pm`.
**Maintenance.** Every loop back-edge must emit a fuel decrement to prevent infinite execution loops.
**References.** [^fuel]

### Fuzzing
**Expansion.** Random program generation with an oracle interpreter.
**Divergence.** `Brocken::Fuzz` generates typed programs encoded to reversible hex `case_id`s for exact regression replay.
**Implementation.** `lib/Brocken/Fuzz.pm`, `bin/fuzz_runner.pl`.
**Maintenance.** `case_id` bit-packing algorithm must remain frozen to ensure historic test cases remain reproducible.
**References.** [^fuzzing]

### Hash Tables
**Expansion.** Open-addressing hash table with linear probing and power-of-two capacity.
**Divergence.** Keys are stringified; insertion order is preserved; identity hashing in v1, SipHash-2-4 in v2.
**Implementation.** Built-in hash operations in `core.brocken`.
**Maintenance.** Iteration sequences must remain deterministic to satisfy reproducible build requirements.
**References.** [^hashing]

### Immix
**Expansion.** Mark-region bump allocator (Blackburn & McKinley, 2008).
**Divergence.** Allocates in 32 KiB blocks over 256-byte lines with a segregated 16-byte free list; cycles collected via trial deletion.
**Implementation.** `core.brocken`.
**Maintenance.** Freeing objects must derive the block base via address masking to update `live_count` accurately.
**References.** [^immix]

### Isolates
**Expansion.** Share-nothing OS threads with independent heaps.
**Divergence.** Zero-lock reference counting; ICB address pinned to a dedicated hardware register.
**Implementation.** `isolate_create`/`isolate_join` in `Lowerer.pm`, ICB layout in `lib/Brocken/ICB.pm`.
**Maintenance.** Heap pointers must never cross isolate boundaries; all channel data must be deep-copied.
**References.** [^isolate]

### Landing Dispatcher
**Expansion.** Per-`try` state machine ensuring unified `finally` block execution.
**Divergence.** Lowers `try/catch/finally` into a single landing dispatcher backed by an ICB SJLJ handler chain.
**Implementation.** Exception lowering in `Katsuro/Lowerer.pm`, `ICB::EXCEPTION_HANDLER_STACK`.
**Maintenance.** All abnormal control-flow escapes (`last`, `next`, `return`) from a `try` block must route through the dispatcher.
**References.** [^landing]

### Linear Scan
**Expansion.** Linear-scan register allocation (Poletto & Sarkar, 1999).
**Divergence.** Computes fixed-point live intervals directly over MIR; sorts all iteration passes for reproducibility.
**Implementation.** `lib/Brocken/Jenny/RegAlloc.pm`.
**Maintenance.** Fixed-register constraints (e.g., `rax:rdx` for x86_64 division) must be reserved before allocating intervals.
**References.** [^linearscan]

### Linkers & Loaders
**Expansion.** Generation of standalone native executable binaries from machine bytes.
**Divergence.** Fully self-contained; no reliance on system linkers (`ld`, `lld`) or external CRT startup objects.
**Implementation.** `lib/Brocken/Jenny/Linker.pm` and format writers (`ELF64.pm`, `PE.pm`, `MachO.pm`, `Wasm.pm`).
**Maintenance.** Segment alignments, virtual address base calculations, and entry stubs must adhere to target OS invariants.
**References.** [^linker]

### Mach-O
**Expansion.** macOS Mach-O 64-bit binary format.
**Divergence.** Emits both DWARF v5 `.debug_names` and legacy `.debug_pubnames`; anchors entry stubs to GOT layouts.
**Implementation.** `Linker/MachO.pm`.
**Maintenance.** Load command sizing dictates header padding; changes must update the initial text file offset.
**References.** [^macho]

### MIR & Pipeline
**Expansion.** Katsuro (frontend) $\to$ Lindsay (SSA middle-end) $\to$ Jenny (MIR backend and linker).
**Divergence.** Purpose-built intermediate representations carrying source mappings through to binary emission.
**Implementation.** `lib/Brocken/Katsuro/`, `lib/Brocken/Lindsay/`, `lib/Brocken/Jenny/`.
**Maintenance.** IR instruction indices (`ir_inst_idx`) must flow uncorrupted to MIR instructions to maintain line tables.
**References.** [^pipeline]

### PE32+ / COFF
**Expansion.** Windows Portable Executable format (64-bit).
**Divergence.** Clears ASLR bit at `debug_level` 5 to enable stable GDB symbol breakpoint resolution.
**Implementation.** `Linker/PE.pm`.
**Maintenance.** Section virtual sizing must round to section alignment boundaries; timestamps must read `SOURCE_DATE_EPOCH`.
**References.** [^pe]

### Perceus
**Expansion.** Compile-time reference-counting optimization (Reinking et al., 2021).
**Divergence.** Combines whole-program Caller-Borrows contracts with affine `Move` lowering to elide redundant RC churn.
**Implementation.** `Katsuro/Lowerer.pm`, Lindsay middle-end passes.
**Maintenance.** Any construct escaping a borrowed value into a container or field must emit an explicit `incref`.
**References.** [^perceus]

### Perl Language Borrowings
**Expansion.** Adoption of modern Perl semantics: invariant sigils, postderef, Corinna classes, and truthiness.
**Divergence.** Strips dynamic parsing ambiguities; enforces AOT static typing; disallows method interpolation in strings.
**Implementation.** `Katsuro/Lexer.pm`, `Katsuro/Parser.pm`.
**Maintenance.** Language extensions must align with modern `perlclass` and `Object::Pad` specifications.
**References.** [^perldocs]

### Reference Counting (RC)
**Expansion.** Immediate reference counting as the primary memory reclamation engine.
**Divergence.** Operates without atomic locks due to isolate-local heaps; saturates at 65535 to pin long-lived objects.
**Implementation.** `core.brocken`, `Katsuro/Lowerer.pm`.
**Maintenance.** Saturating increment checks must never allow the 16-bit counter to wrap to 0.
**References.** [^rcgc]

### Reproducible Builds
**Expansion.** Generating bitwise-identical binary output from identical source input.
**Divergence.** Sorts all internal hash iterations (register allocator, linker symbol tables, DWARF string pools).
**Implementation.** `Linker/ELF64.pm`, `Linker/PE.pm`, `RegAlloc.pm`.
**Maintenance.** Never iterate an unsorted Perl hash when emitting code, section headers, or debug data.
**References.** [^repro]

### RISC-V 64
**Expansion.** RV64GC architecture and LP64D calling convention.
**Divergence.** Emits pure uncompressed instructions; handles 12-bit immediate limits by dynamic scratch allocation.
**Implementation.** `Codegen/RISCV64.pm`, `Lowerer/RISCV64.pm`.
**Maintenance.** Wide displacement memory loads must allocate scratch registers without clobbering active destinations.
**References.** [^riscv]

### Structured Exception Handling (SEH)
**Expansion.** Windows x64 exception handling (`.pdata`/`.xdata`).
**Divergence.** Emits sorted function runtime entries; unwinding routes through Brocken's landing dispatcher.
**Implementation.** `Linker/PE.pm`.
**Maintenance.** `.pdata` function range arrays must remain strictly sorted by starting RVA.
**References.** [^seh]

### SipHash
**Expansion.** Keyed PRF for hash collision resistance (Aumasson & Bernstein).
**Divergence.** Seeded per isolate from the host CSPRNG to prevent HashDoS attacks on open-addressing tables.
**Implementation.** Planned intrinsic in `core.brocken`.
**Maintenance.** Seeds must never be hard-coded to constants in production configurations.
**References.** [^siphash]

### Static Single Assignment (SSA)
**Expansion.** Compiler intermediate representation where every variable is assigned exactly once.
**Divergence.** Lindsay IR couples SSA representation with explicit linear RC operations.
**Implementation.** `lib/Brocken/Lindsay/`.
**Maintenance.** SSA values are immutable; optimization transformations must create fresh value definitions.
**References.** [^ssa]

### Stack Guard
**Expansion.** Detection of runaway recursion via stack pointer limit checks.
**Divergence.** Emits prologue checks comparing `sp` against `ICB::STACK_LIMIT`, tripping `ERR_STACK` on overrun.
**Implementation.** `StackGuard.pm`, `ICB::STACK_LIMIT`.
**Maintenance.** The stack budget must remain smaller than the OS committed stack reservation.
**References.** [^stackguard]

### Target Triples
**Expansion.** Normalized four-part string defining architecture, vendor, operating system, and environment.
**Divergence.** Normalized strictly to four components across all toolchain commands.
**Implementation.** `Platform.pm`.
**Maintenance.** Adding new target platforms requires defining calling conventions, syscall tables, and binary writers.
**References.** [^triple]

### Trial Deletion
**Expansion.** Cycle collection algorithm for reference-counted heaps (Bacon & Rajan, 2001).
**Divergence.** Synchronous implementation running over the ICB suspect ring buffer using colors stored in GC flags.
**Implementation.** `core.brocken`.
**Maintenance.** The color transition cycle (Purple $\to$ Gray $\to$ White $\to$ Black) must be strictly preserved.
**References.** [^trialdeletion]

### WebAssembly / WASI
**Expansion.** WebAssembly 32-bit stack architecture running under WASI.
**Divergence.** Emulates 64-bit integer operations; isolates and threads are currently mapped to single-threaded stubs.
**Implementation.** `Codegen/Wasm.pm`, `Linker/Wasm.pm`.
**Maintenance.** Memory allocation must respect the initial 1 MiB WASI heap boundary.
**References.** [^wasm]

### x86_64
**Expansion.** 64-bit x86 architecture under System V AMD64 and Microsoft x64 ABIs.
**Divergence.** Hand-encodes SIB addressing and fixed register pairs (`rdx:rax` for division and wide multiplication).
**Implementation.** `Codegen/X86_64.pm`, `Lowerer/X86_64.pm`.
**Maintenance.** Linear-scan register allocation must reserve `rax` and `rdx` across division instructions.
**References.** [^x86]

---

# POD6/RakuDoc (Planned)

Brocken will support a subset of RakuDoc (formerly POD6) for both embedded documentation in `.brocken` source files and standalone documentation in `.rakudoc` and `.pod` files. The goal is strict RakuDoc compatibility for the selected subset.

## File Extensions

- `.rakudoc`: Canonical RakuDoc files (standalone documentation).
- `.pod`: Legacy-compatible extension (accepted for standalone documentation).
- `.brocken`: Embedded RakuDoc may be interleaved with code as in Raku.

## Embedded Documentation in Code

Brocken matches Raku's model for embedding documentation:

- `=pod` blocks, `=begin pod ... =end pod`, and abbreviated/directive forms are recognized.
- `#|` declarator comments attach documentation to the next declaration.
- `#=` comments (where applicable) may attach to preceding declarations, mirroring Raku semantics.

## Supported Block Types (Early)

The following block types will be supported initially:

- Named blocks (`=begin NAME ... =end NAME`), including semantic blocks (`NAME`, `SYNOPSIS`, `DESCRIPTION`, `METHODS`, `AUTHOR`, etc.)
- Headings (`=head1` through `=head6`)
- Paragraphs (implicit and `=para`)
- Code blocks (`=begin code ... =end code`, and abbreviated forms where appropriate)
- Lists (`=item`, `=over`, `=back`)
- Inline formatting (`B<>`, `I<>`, `C<>`, `L<>`, `E<>`, `K<>`, `R<>`, `T<>`, `V<>`, etc. as defined by RakuDoc)
- Tables (`=begin table ... =end table`)

Config/aliases and custom blocks are reserved for future milestones.

## Runtime Introspection

Embedded documentation will be introspectable at runtime:

- The special variable `$=pod` will provide the Pod::Block tree for the current compilation unit (mirroring Raku's `$=pod`).
- Cross-package/introspection access: `$=Some::Package::pod` (or equivalent fully-qualified form) will allow accessing Pod from other packages when available; the exact lookup semantics will follow Raku's behavior where applicable.

## Tooling

- `bkn doc` will be available to render/extract documentation and to validate parsing of Pod. Initially this is the primary way to debug Pod parsing before full runtime introspection is exercised.
- The language server will surface Pod documentation (from `#|`/embedded blocks) in hover/completions.

## Compatibility & Extensibility

- Early support targets strict RakuDoc (POD6) compatibility for the subset above.
- Brocken-specific extensions may be added later; space is reserved, but they will not be introduced in the initial implementation.

## Footnote References

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



---

