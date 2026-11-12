# The Brocken Language Specification

**Author:** Sanko Robinson
**Version:** v0.0.1
**Status:** Active Development

> **Implementation Note:** This document specifies the target language and compiler architecture. Brocken is under active development. Sections below describe the authoritative design and current implementation invariants. For outstanding milestones and known gaps, refer to [`TODO.md`](../TODO.md).

---

## 1. Philosophy & Compiler Architecture

### 1.1 What This Compiler Does

Brocken is a systems programming language with the ergonomics and expressiveness of modern Perl. The Brocken compiler parses this Perl-like syntax and compiles it Ahead-Of-Time (AOT) directly into standalone native machine code (Linux ELF, Windows PE, macOS Mach-O, and WebAssembly) for x86_64, ARM64, and RISC-V architectures.

**Brocken relies on no external C runtime (libc), no GCC, and no LLVM.** Everything from the instruction encoders to the linker is written from scratch in Perl 5.

### 1.2 Core Pillars

- **Zero-Dependency AOT Execution:** Output binaries are 100% standalone. I/O and threading are implemented via direct kernel system calls or linker-resolved OS-level dynamic imports.
- **Self-Hosted Runtime (`core.brocken`):** The garbage collector, memory allocator, fiber scheduler, and channels are not written in C. They are written in Brocken using the Unsafe Native Subset (`use feature 'brocken_native_types';` and `Brocken::*` intrinsics).
- **Share-Nothing Concurrency:** Concurrency relies on independent OS threads (Isolates) with strict thread-local heaps. Because heaps are isolated, **reference counting requires zero atomic locks**.[^rcgc]
- **Deterministic Memory:** Memory is managed by Immediate Reference Counting utilizing an Immix Bump-Allocator[^immix] and segregated free lists (`free16_head` and `free_big_head`). Circular references are handled by Bacon & Rajan trial deletion.[^trialdeletion]
- **Ultra-Modern Perl Ergonomics:** Brocken adopts modern Perl idioms while shedding historical parsing ambiguities: invariant sigils, Corinna-style classes with `ADJUST`/`DESTROY`, compile-time attributes, strict lexical scoping, and structured exception handling.[^perldocs]

### 1.3 Known Incomplete

This is the design of record, written ahead of certain upcoming milestones:

- **Perceus (10.1):** Borrow inference, RC elision, and reuse analysis are not fully automated; the Caller-Borrows contract is currently enforced via lowering conventions.
- **Concurrency (11):** Isolates, the fiber scheduler, and thread-local heaps are shipped. The bounded channel ring buffer, inlined mutex/condvar synchronization, and zero-copy affine moves are not.
- **Exceptions (9.2):** `try`/`catch`/`finally` lower via `setjmp`/`longjmp` landing pads on the ICB; zero-cost DWARF `.eh_frame` unwinding is planned for v0.0.2.
- **Language Surface:** Invariant postderef tokens (`->$*`, `->@*`, `->%*`) (5), anonymous closures (7.3), Perl punctuation variables (2.3), and versioned packages are specified or partially implemented.
- **Backends:** x86_64 is the reference backend; ARM64 and RISC-V are fully supported. WebAssembly currently lacks full data-segment support for static literal addresses.

[`TODO.md`](../TODO.md) is the authoritative tracker for work in progress.

---

## 2. Lexical Structure, Variables & Sigils

### 2.1 Invariant Sigils

Unlike older versions of Perl where sigils change based on context (e.g., `$arr[0]` vs `@arr`), Brocken enforces **invariant sigils**. The sigil dictates the container type and never changes.

| Sigil | Container | Access / Dereference | Reference |
|---|---|---|---|
| `$` | Scalar / Object / Reference | `$x` | `\$x` |
| `@` | Array | `@arr[0]` | `\@arr` |
| `%` | Hash | `%map{"key"}` | `\%map` |

### 2.2 Scoping, Declarations & Special Constants

Variables are lexically scoped:
- `my` - Lexical variable declaration.
- `our` - Package-scoped global variable.
- `state` - Persistent lexical variable (reserved, planned).
- `const` - Compile-time constant (emitted into `.rodata`).

**Compile-Time Pseudo-Constants:**
- `__PACKAGE__` - String name of the enclosing package (defaults to `"main"`).
- `__CLASS__` - String name of the enclosing class within a method or class body.
- `__FILE__` - String literal of the current compilation unit filename.
- `__LINE__` - Integer constant of the current source line.

### 2.3 Perl Special Variables

**Planned, not yet implemented** (TODO §3). Brocken reserves Perl's punctuation variables. Using an unsupported punctuation variable is a compile error, never a silent `undef`.

| Variable | Meaning |
|---|---|
| `$_` | The default argument / loop variable. |
| `@_` | The arguments of the running `sub`/`method`, in call order. |
| `$a`, `$b` | The comparison variables for `sort`. |
| `@ARGV` | Command-line invocation arguments. |
| `%ENV` | Process environment hash. |
| `$$` / `$PID` | Isolate or process ID. |
| `$!` / `$ERRNO` | Host platform system call error code (`errno`). |
| `$@` / `$EVAL_ERROR` | Error payload from the last failing `try` block. |

---

## 3. The Type System & Nullability

Brocken maintains a strict syntactic and physical separation between **managed/nullable Perl containers** (Capitalized) and **unboxed raw machine types** (lowercase).

### 3.1 Unboxed Machine Types (The Unsafe Subset)

Enabled via `use feature 'brocken_native_types';`, these bypass Fat Scalar overhead and do not participate in reference counting:

* `i1` (Native 1-bit integer; a wider value stored in it is masked to bit 0)
* `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `i128`, `u128` (Integers)
* `f32`, `f64` (IEEE 754 Floating Point)
* `bool` (Logical boolean; promoted to `Any` when handed a value a one-bit slot cannot hold -- see below)
* `ptr` (Opaque 64-bit machine pointer)
* `int` (Alias for `i64` on all current targets)
* `void` (Zero-width unit return type)

**`bool` vs `i1`:** `i1` is the raw one-bit integer, and storing a wider value in it masks to bit 0 (`my i1 $b = 24;` yields `0`, because `24 & 1` is `0`). `bool` is *logical*: a `bool` local that is assigned a value a one-bit slot cannot hold is instead **promoted to `Any`** for the whole function, so the value survives (`my bool $b = false; $b = $b || -26;` leaves `$b` holding `-26`, matching Perl). The compiler warns when it promotes. A `bool` that is only ever assigned genuine booleans -- comparisons, `!`/`not`, `true`/`false`, or the literals `0`/`1` -- stays an `i1`.

**Native types are advisory hints.** A native type name describes how a value is *stored* -- it buys speed by skipping the Fat Scalar -- not a promise about what the variable holds. A native local handed a value its kind cannot represent is **promoted to `Any`** for the whole function so the value survives, and the compiler warns; nothing is silently truncated. Kinds that are mutually representable never promote:

* an `int` or `float` destination accepts any integer, any float, or a `ptr`;
* a `ptr` destination accepts an `int`, another `ptr`, a `String`, or a class instance (a `ptr` holds a machine address, so `my ptr $p = 0;` is fine);
* a `bool` destination accepts only a genuine boolean (`bool`, `Bool`, or `i1`), so any wider integer, float, or reference promotes it.

Integers and floats interconvert at any width, so `my i8 $x = $some_i64;` and `my f64 $x = 5;` keep their slot. When the assigned value's kind cannot be pinned down at compile time -- a call result, a field or element read -- the native slot is kept and a runtime guard warns if the stored tag does not fit. Managed types (`Any`, `Int`, `String`, classes) are never promoted.

**Nullability:** Unboxed machine types **cannot be `undef`**. If uninitialized, they default to `0`, `0.0`, or `false`.

### 3.2 Managed Perl Containers (Fat Scalars)

Variables without an explicit type default to `Any`. Managed types are dynamically allocated on the thread-local Immix heap[^immix] and tracked via reference counting.[^rcgc]

* `Any` - Universal dynamic 16-byte Fat Scalar.
* `Int` - Boxed integer (`i64`).
* `Float` - Boxed float (`f64`).
* `Bool` - Boxed boolean.
* `String` - Managed pointer to UTF-8 length-prefixed, NUL-terminated bytes.
* `Class` - Managed heap object instance pointer.

**The Fat Scalar Layout (`Any`):**[^fatscalar]
```
Offset  Size  Field
0       2     Reference Count (u16, max 65535 pins the object)
2       1     GC Flags (u8: Bit 0=Suspect, Bit 1=Buffered, Bit 2=Leaf, Bits 3..4=Color)
3       1     Type Tag (u8: see Tag table below)
4       4     Auxiliary Data: Cached String Byte-Length or Class ID (u32)
8       8     Payload (u64 / f64 / ptr)
```

**Type Tags:**
- `0` = Undef / Null
- `1` = Int (narrow integers, `i1`..`i32`)
- `2` = Int (`i64`)
- `3` = Float (`f64`)
- `4` = Ptr (Boxed `String` or Class Instance)
- `5` = Dynamic Variant Container
- `6` = Int128 (`i128` / `u128`)
- `7` = List (Immutable / fixed list buffer)
- `8` = Hash (Open-addressing table)
- `9` = Array (Heap-promoted growable array)

**String vs. Class Disambiguation (Tag 4):**
For Tag 4, Offset 4 stores:
- **String:** The cached `u32` byte length of the string.
- **Class Instance:** A non-zero `u32` Class ID. Class instances place fields starting at Offset 8.

**Nullability:** Managed containers **default to `undef`** (Type Tag 0, Payload 0).

### 3.3 `undef` and `defined`

- **As a Value Literal:** `$var = undef;` resets a managed variable to the undefined state (Tag 0, Payload 0) and decrefs its previous value.
- **As a Mutator Builtin:**
  - `undef($var);` (Same as `$var = undef;`)
  - `undef(@arr);` (Empties array elements in-place)
  - `undef(%hash);` (Empties hash keys and values in-place)
- **The `defined` Builtin:** `if (defined $var)` checks if a managed container has Type Tag `!= 0`. For raw native types (`i64`, `f64`, `bool`), `defined` evaluates to compile-time constant `true`.

---

## 4. Operators, Strings & Truthiness

### 4.1 Truthiness Rules (Perl Semantics)

In Brocken, exactly four conditions evaluate to **false**:
1. `0` (Integer `0` or Float `0.0`)
2. `"0"` (String)
3. `""` (Empty string)
4. `undef` (Null pointer / Uninitialized managed variable)

All other values—including `0.5`, `-1`, `"00"`, `"false"`, and any object pointer—evaluate to **true**.
In conditionals (`if ($x)`), dynamic `Any` variables invoke the runtime helper `is_truthy(ptr)`.

### 4.2 Stringification

The `say()`, `print()`, and concatenation (`.`) operators automatically stringify values:
- `Int` and `i64` invoke `i64_to_str` / `u64_to_str`.
- `Float` and `f64` invoke runtime `sprintf("%f")`.
- `Bool` stringifies to `"1"` or `""`.
- Classes and Arrays stringify to `"ClassName=ptr:0x..."`.

### 4.3 String Interpolation (Strict)

Inside double quotes (`"..."`):
1. **Scalars interpolate:** `say("Hello, $name!");`
2. **Disambiguated Scalars:** `say("Total: ${count}kg");`
3. **Container Elements interpolate:** `say("Item: @arr[0]");` and `say("Value: %map{key}");`
4. **Method calls DO NOT interpolate:**
   ```perl
   say("Point: (" . $pt->x . ")"); # Correct concatenation
   ```

### 4.4 Auto-Increment (`++`) and Decrement (`--`)

- Applied to numbers, steps values in place.
- Applied to a `String` (ptr), invokes `str_inc_bytes` (magical ASCII alphanumeric carry) or `str_dec_bytes` (numeric decrement).
- Applied to an `Any` slot, invokes `inc_slot` / `dec_slot` to manage reference counting and box allocation.

### 4.5 Ranges (`..`)

The range operator in a `for` loop header lowers to a **zero-allocation induction loop**:
```perl
for my $i (0 .. 1000) { ... }
```

### 4.6 Binary and Compound Assignment Operators

Compound assignments (`+=`, `-=`, `*=`, etc.) lower to `$target = $target OP $expr`.

#### Defined-or, Logical-or, and Logical-and (`//`, `||`, `&&`)

- `//` yields its left operand when **defined** (non-null for pointers and `Any` boxes) and its right operand otherwise.
- `||` yields its left operand when **true** and its right operand otherwise.
- `&&` yields its left operand when **false** and its right operand otherwise.
- `//=` assigns only if the destination is **undefined** (null). Degrades to `=` on native types.
- `||=` assigns if the destination evaluates to **false** via `is_truthy(ptr)`.

**Evaluation Semantics:**
`//`, `||`, and `&&` all **short-circuit**: the right operand is not evaluated when the left already decides the result, so `false && $x` and `$x || $y` never read the side they do not need (a division by zero in the skipped operand is harmless).

`||` and `&&` follow Perl's *value* semantics, not a boolean one: the expression yields whichever operand decides it. So `0 || -26` is `-26`, `3 && 4` is `4`, and `$b = false; $b || -26;` leaves `$b` holding `-26`. Truthiness is Perl's (§4.1) -- an integer is true when non-zero, a float when non-zero (not when it truncates), and a box through `is_truthy(ptr)`. The result type unifies the two operands: `i64` when both are integers, `f64` when either is a float, `ptr` when both are pointers, and a box otherwise. This is what lets a native `bool` (or any advisory native slot) that receives a `||`/`&&` result be promoted to `Any` rather than truncated (see §3.1).

---

## 5. References & Postfix Syntax

```perl
# References
my $scalar_ref = \"Hello";
my @arr = (10, 20, 30);
my $arr_ref = \@arr;

# Hash Literals use parentheses and fat commas:
my %config = (host => "localhost", port => 8080);
my $hash_ref = \(host => "localhost", port => 8080);

# Element Access
say( @arr[0] );
say( %config{"host"} );
```

---

## 6. Containers & Built-in Functions

### 6.1 Arrays

Arrays are declared with explicit types:
```perl
my [i64; 10] @fixed;   # Stack-allocated array of 10 elements
my [i64] @growable;     # Heap-promoted growable array (Tag 9)
```

**Array Builtins:**
- `push @arr, $val` (Appends, returns new length)
- `pop @arr` (Removes and returns last element)
- `shift @arr` (Removes and returns first element)
- `unshift @arr, $val` (Prepends, returns new length)

**Tag 9 Array Layout (Heap):**
```
Offset  Size  Field
0       8     Header (RC: u16, Flags: u8, Tag: 9)
8       8     Element Count N (i64)
16      8     Payload bytes (N * elem_size)
24      ...   Element array data
```

### 6.2 Hashes (O(1) Linear Probing)

Hashes in `core.brocken` use open addressing with linear probing and power-of-two capacities.[^hashing]
- Keys are borrowed NUL-terminated strings. Values take refcount ownership (`incref`).
- Displaced values are automatically `decref`d. Table release recursively decrefs all values.

**Tag 8 Hash Layout:**
```
Offset  Size  Field
0       8     Header (RC: u16, Flags: u8, Tag: 8)
8       8     Live Entry Count (i64)
16      8     Bucket Area Size in Bytes (capacity * 32)
24      8     Tombstone Count (i64)
32      8     Insertion-Order Head Bucket Index (i64, -1 if empty)
40      8     Insertion-Order Tail Bucket Index (i64, -1 if empty)
48      ...   Buckets Array (capacity * 32 bytes)
```

**Bucket Geometry (32 bytes):**
```
Offset  Size  Field
0       8     Key Pointer (ptr; 0 = empty, 1 = tombstone)
8       8     Value Pointer (ptr / i64)
16      8     Prev Bucket Index in Insertion Order (i64)
24      8     Next Bucket Index in Insertion Order (i64)
```

**Hash Builtins:**
- `keys %hash` - Returns a Tag 7 List of string keys in insertion order.
- `values %hash` - Returns a Tag 7 List of values in insertion order.
- `exists %hash{"key"}` - Returns boolean `i1`.
- `delete %hash{"key"}` - Removes entry and transfers value ownership to caller.

### 6.3 Context Introspection (`want`)

Subroutines query calling context via `want`:
```perl
if (want('list'))   { return (1, 2, 3); }
if (want('scalar')) { return 42; }
if (want('void'))   { return; }
```
Functions receive a hidden `%__want` argument (0 = void, 1 = scalar, 2 = list).

### 6.4 The `builtin::` Namespace

| Builtin | Semantics |
|---|---|
| `builtin::true()` / `builtin::false()` | Emits constant `i1` (`1` / `0`). |
| `builtin::is_tainted(EXPR)` | Evaluates for side effects; returns `false`. |
| `builtin::weaken($v)` / `unweaken($v)` | Modifies variable ownership tracking. |
| `builtin::is_weak($v)` | Compile-time check if `$v` is `:weak`. |
| `builtin::is_bool($v)` | Checks for native `i1`/`bool` or boxed Tag 1. |
| `builtin::created_as_string($v)` | Checks for string provenance (Tag 4, Class ID 0). |
| `builtin::created_as_number($v)` | Checks for numeric provenance (Tag 1, 2, 3, or 6). |
| `builtin::stringify($v)` | Renders `$v` as a `String` pointer. |
| `builtin::numify($v)` | Converts `$v` to `f64`. |
| `builtin::refaddr($v)` | Yields address of container/pointer as `u64`. |
| `builtin::reftype($v)` | Returns `"SCALAR"`, `"ARRAY"`, `"HASH"`, or `"OBJECT"`. |
| `builtin::blessed($v)` | Returns class name string, or `undef`. |
| `builtin::ceil($v)` / `floor($v)` | Rounds `$v` to `i64` via SSA instructions. |
| `builtin::inf(SIGN)` / `nan()` | Returns IEEE 754 infinity or NaN as `f64`. |
| `builtin::trim($v)` | Strips leading/trailing ASCII whitespace. |
| `builtin::indexed(@arr)` | Unrolls array into flat `(index, value)` lists. |

---

## 7. Subroutines, Attributes & Signatures

### 7.1 Signatures & Calling Conventions

Subroutines can return multi-value tuples mapping directly to hardware registers (`rax:rdx` on x86_64, `x0:x1` on ARM64, `a0:a1` on RISC-V).

**Hidden Parameters:**
- Free functions receive `%__heap_base` (`ptr`) and `%__want` (`i64`).
- Methods receive `%__heap_base` (`ptr`), `%__want` (`i64`), and `%self` (`ptr`).

**Forward Prototypes:**
```perl
sub calculate(i64 $x) :returns(i64);
```

**Parameter Defaults:**
```perl
sub connect(String $host, i64 $port = 8080) { ... }
```

### 7.2 Variable & Field Attributes

- `:weak` - Disables refcount ownership on variables/fields, breaking reference cycles.
- `:param` - Generates constructor arguments for fields: `Class->new(field => $val)`.
- `:reader` - Generates getter accessor methods: `$obj->field()`.
- `:writer` - Generates mutators returning `$self`: `$obj->set_field($val)`.
- `:accessor` - Combines `:reader` and `:writer`.

Accessor names strip **exactly one leading underscore** (`field $_id :reader;` generates `$obj->id()`).

---

## 8. Object-Oriented Programming (Classes)

```perl
class DatabaseConnection {
    field ptr  $handle   :param :reader;
    field bool $is_open  = true;

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

### 8.1 Destructor (`DESTROY`) & Field Teardown Semantics

1. **Release Site:** When an instance's refcount reaches zero via `decref_obj`, execution routes to `Class::__destroy`.
2. **Object Resurrection:** Inside `DESTROY`, storing `$self` increments its refcount. If `RC > 0` after `DESTROY`, teardown is aborted and the object survives.
3. **LIFO Field Teardown:** If `RC == 0`, fields are decref'd in **LIFO** (reverse declaration) order before the memory slab is recycled via `free_obj`.

---

## 9. Control Flow & Error Handling

### 9.1 Control Flow Statements

- `if`, `elsif`, `else`, `unless`
- `while`, `for`, `foreach`
- `last`, `next`
- Postfix modifiers: `return $x if $cond;`

### 9.2 Exceptions (`try / catch / finally`)

Exceptions use landing pads backed by an SJLJ (`setjmp`/`longjmp`) handler chain on the ICB (`ICB::EXCEPTION_HANDLER_STACK`):

```perl
try {
    die "Fatal error";
}
catch ($err) {
    warn("Recovered: $err");
}
finally {
    say("Cleanup complete");
}
```

### 9.3 Process & Diagnostic Builtins

- `exit($code = 0)`: Flushes stdio and terminates via kernel exit.
- `warn(@msgs)`: Writes formatted text to `stderr` (FD 2).
- `die(@msgs)`: Formats error and raises an exception (exits with 255 if uncaught).

---

## 10. Memory Model: Reference Counting & Immix

### 10.1 The Caller-Borrows Contract

- Callers pass references without incrementing refcounts.
- Callees borrow arguments and must not decrement them on exit.
- Returning a field promotes it to an **owned** reference (`incref` on return).

### 10.2 Immix Bump Allocator, Compaction & Large Object Space

Heap memory is divided into 32 KiB blocks containing 256-byte lines.[^immix]

- **Block Layout (32 KiB):**
  - `[block + 0..31]`: 256-bit line state bitmap (2 bits per line: `0`=Free, `1`=Live, `2`=Pinned).
  - Line 0: bytes `32..255` usable (224 bytes).
  - Lines 1..126: 256 bytes usable each.
  - Line 127: bytes `32512..32751` usable (240 bytes).
  - `[block + 32752..32759]`: `live_count` (`i64`).
  - `[block + 32760..32767]`: `next_free` (`i64`).
- **Two-Bit Line States:** Each line tracks whether it is *Free*, *Live*, or *Pinned*. Multi-line spans and evacuated objects mark all lines they occupy as *Pinned* (state `2`) to prevent line-level reuse during sweep cycles.
- **Opportunistic Line Compaction:** Fragmented blocks with sparse live counts can evacuate surviving live objects to contiguous free lines via `evacuate_obj`, freeing entire blocks for recycling into `free_blocks`.
- **Large Object Space (LOS):** Allocations $\ge 4\text{ KiB}$ bypass the 32 KiB tiled Immix grid and are allocated out-of-line in Large Object Space (LOS) bumping downward from the ceiling of the arena via `ICB::los_head` (or via OS virtual memory mappings). The runtime helper `block_of($hb, $addr)` inspects `ICB::los_head` and the arena boundary to distinguish Immix blocks from LOS memory, bypassing block metadata and live-count operations for large objects.
- **Segregated Free Lists:**
  - `ICB::free16_head` (offset 48): Recycles 16-byte Fat Scalars.
  - `ICB::free_big_head` (offset 144): Recycles variable-sized Tag 8 and Tag 9 slabs.

### 10.3 Cycle Collection (Bacon & Rajan Trial Deletion)

Cyclic references are collected via Bacon & Rajan trial deletion.[^trialdeletion]
- `decref` and `decref_obj` enqueue non-leaf objects with $RC > 0$ onto the suspect buffer.
- `maybe_gc_drain` automatically triggers `gc_drain` when `suspect_count >= 256`.
- `suspect_count` is set to `-1` during drains to prevent recursive re-entry.
- Four-phase drain: MarkGray, ScanBlack, Destroy, and Collect.

---

## 11. Concurrency: Isolates, Fibers, and Channels

### 11.1 Isolates (OS Threads)

An Isolate is a share-nothing OS thread with an independent Immix heap and Isolate Control Block (ICB) pinned to a hardware register (`r14` on x86_64, `x28` on ARM64, `s11` on RISCV64).[^isolate]

### 11.2 Fibers (Green Threads)

Fibers are cooperative coroutines multiplexed inside an Isolate. Each fiber maintains a 64 KiB stack and a Fiber Control Block (FCB) swapped via assembly `ctx_swap`.[^ctxswitch]

### 11.3 CSP Channels

Channels provide synchronized communication between Isolates, deep-copying aggregate structures across boundaries to preserve thread-local heap invariants.

---

## 12. Compilation Pipeline & Intrinsics

1. **Katsuro (Frontend):** Lexer and Pratt Parser build the AST.
2. **Lindsay (Middle-end):** SSA IR lowering, reference count insertion, and constant folding.[^ssa]
3. **Jenny (Backend):** Linear scan register allocation[^linearscan], machine code encoding, and format linking (ELF64, PE32+, Mach-O, Wasm).[^linker]

### 12.1 Intrinsics (`Brocken::*`)

| Intrinsic | MIR Output |
|---|---|
| `Brocken::ptr_add(p, off)` / `ptr_sub(p, off)` | `add` / `sub` (typed as `ptr`) |
| `Brocken::ptr_cmp_gt(a, b)` / `_lt` / `_ge` / `_le` / `_eq` | `icmp ugt` / `ult` / `uge` / `ule` / `eq` |
| `Brocken::load_i64(ptr)` / `store_i64(ptr, val)` | `load i64` / `store i64` |
| `Brocken::load_i32(ptr)` / `store_i32(ptr, val)` | `load i32` / `store i32` |
| `Brocken::load_i8(ptr)` / `store_i8(ptr, val)` | `load i8` / `store i8` |
| `Brocken::load_u16(ptr)` / `store_u16(ptr, val)` | `load u16` / `store u16` |
| `Brocken::load_f64(ptr)` / `store_f64(ptr, val)` | `load f64` / `store f64` |
| `Brocken::i64_add(a, b)` / `i64_sub(a, b)` | `add` / `sub` |
| `Brocken::band` / `bor` / `bxor` / `shl` / `shr` | `and` / `or` / `xor` / `shl` / `lshr` |
| `Brocken::syscall(n, ...)` | Raw platform `syscall` instruction |
| `Brocken::syscall_by_name(name, ...)` | Platform-resolved syscall by string name |
| `Brocken::libc(name, ...)` | Dynamic C ABI import invocation |
| `Brocken::heap_base()` | Load of the isolate's `%__heap_base` pointer |
| `Brocken::icb_size()` | Compiled byte size of the ICB structure (184) |
| `Brocken::block_size()` | Size of an Immix memory block (32768) |

---

## 13. Building & Reproducibility

Builds are byte-reproducible. All hash walks in register allocation, code generation, and symbol tables are deterministically sorted. Setting `SOURCE_DATE_EPOCH` pins timestamps across Windows PE and native linkers.[^repro]

---

## 14. Debugging & Diagnostics

- **DWARF v5:** Emits `.debug_line`, `.debug_info`, `.debug_abbrev`, `.debug_frame`, and accelerated `.debug_names` tables.[^dwarf]
- **Native Backtraces (`.brk_sym`):** Emits a packed binary symbol table into ELF, PE, and Mach-O files to allow symbol resolution in stripped release binaries without external DWARF files.[^brksym]

---

## 15. Sandboxing & Runtime Limits

### 15.1 ICB Layout

The Isolate Control Block is pinned to a hardware register (`r14` on x86_64, `x28` on ARM64, `s11` on RISCV64). Generated from `Brocken::Layout`, its fields are:

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `heap_cursor` | `ptr` | Legacy bump allocator pointer |
| 8 | `current_fcb` | `ptr` | Active Fiber Control Block pointer |
| 16 | `fiber_head` | `ptr` | Head of active fiber list |
| 24 | `immix_cursor` | `ptr` | Immix line bump cursor |
| 32 | `immix_limit` | `ptr` | Immix line allocation limit |
| 40 | `free_blocks` | `ptr` | Head of reusable block list |
| 48 | `free16_head` | `ptr` | Segregated 16-byte free list |
| 56 | `suspect_buffer_head` | `ptr` | Bacon & Rajan cycle suspect ring |
| 64 | `fuel` | `i64` | Remaining instruction step budget |
| 72 | `err_code` | `i64` | Runtime abort code |
| 80 | `current_block` | `ptr` | Active 32 KiB Immix block |
| 88 | `memory_limit` | `i64` | Heap memory ceiling in bytes |
| 96 | `memory_used` | `i64` | Active heap bytes allocated |
| 104 | `capabilities` | `i64` | Permission capability bitmask |
| 112 | `gate_table` | `ptr` | Host bind gate dispatch table |
| 120 | `host_icb` | `ptr` | Host ICB reference during gate dispatch |
| 128 | `exception_handler_stack` | `ptr` | Head of SJLJ `jmp_buf` handler chain |
| 136 | `thrown_value` | `i64` | Payload passed to `throw`/`die` |
| 144 | `free_big_head` | `ptr` | Segregated free list for large Tag 8 and Tag 9 slabs |
| 152 | `stack_limit` | `ptr` | Floor stack limit threshold |
| 160 | `suspect_count` | `i64` | Number of live entries in suspect buffer (-1 = drain active) |
| 168 | `arena_size` | `i64` | Total bytes allocated for the isolate arena |
| 176 | `los_head` | `ptr` | Top-of-arena downward bump cursor for Large Object Space (LOS) |

**Total ICB Size:** **184 bytes**.

### 15.2 Sandboxing Flags

- **Fuel:** `ICB::FUEL` decrements at function entry and loop back-edges; reaching zero halts with `ERR_NO_FUEL` (2).[^fuel]
- **Capabilities:** `ICB::CAPABILITIES` gates privileged intrinsics (`CAP_FS_READ=1`, `CAP_FS_WRITE=2`, `CAP_NET=4`, `CAP_SYSTEM=8`, `CAP_FFI=16`).[^caps]
- **Stack Guards:** Monitored against `ICB::STACK_LIMIT`; overrun halts with `ERR_STACK` (6).[^stackguard]

---

## 16. Security Considerations

- **Hash Collision Resistance:** v0.0.1 utilizes open addressing with identity hashes; keyed SipHash-2-4 is planned for v0.0.2 to prevent HashDoS attacks.[^siphash]
- **CSPRNG:** System entropy is collected directly via kernel system calls (`getrandom`, `BCryptGenRandom`, `getentropy`).[^csprng]

---

## 17. Tooling & Ecosystem

- **Fuzzer (`Brocken::Fuzz`):** Replayable random differential program testing keyed by compact hex `case_id` strings.[^fuzzing]
- **Test Harness (`Test2::Tools::Brocken`):** Native execution, TAP testing, and QEMU cross-architecture emulation runner.

---

## 18. Glossary

| Term | Definition |
|---|---|
| **Isolate**[^isolate] | A share-nothing OS thread with independent heap and pinned ICB. |
| **Fiber**[^ctxswitch] | Cooperative green thread inside an isolate scheduled by `ctx_swap`. |
| **ICB**[^isolate] | Isolate Control Block (184-byte struct pinned to hardware register). |
| **FCB**[^ctxswitch] | Fiber Control Block: spilled registers, saved SP, and resume PC. |
| **Fat Scalar**[^fatscalar] | 16-byte `Any` tagged dynamic value. |
| **Immix**[^immix] | 32 KiB block, 256-byte line mark-region bump allocator. |
| **Trial Deletion**[^trialdeletion] | Bacon & Rajan cycle reclamation algorithm. |

---

## 19. Index & Technical Footnotes

[^arm64]: Arm Architecture Reference Manual (ARMv8-A) <https://developer.arm.com/documentation/ddi0487/latest> · AAPCS64 <https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst>.
[^backtrace]: `backtrace_symbols(3)` <https://man7.org/linux/man-pages/man3/backtrace_symbols.3.html> · libunwind <https://www.nongnu.org/libunwind/>.
[^brksym]: Brocken-specific packed symbol table: `{count, [start_rva, end_rva, name_offset]..., string_pool}`.
[^caps]: H. M. Levy, "Capability-Based Computer Systems" <https://homes.cs.washington.edu/~levy/capabook/>.
[^csp]: C. A. R. Hoare, "Communicating Sequential Processes", CACM 1978 <https://doi.org/10.1145/359576.359585>.
[^csprng]: RFC 8439 <https://www.rfc-editor.org/rfc/rfc8439> · NIST SP 800-90A <https://csrc.nist.gov/pubs/sp/800/90/a/r1/final>.
[^ctxswitch]: Boost.Context <https://www.boost.org/doc/libs/release/libs/context/>.
[^dwarf]: DWARF v5 Standard <https://dwarfstd.org/doc/DWARF5.pdf>.
[^ehframe]: LSB exception frames <https://refspecs.linuxfoundation.org/LSB_5.0.0/LSB-Core-generic/LSB-Core-generic/ehframechpt.html>.
[^elf]: System V gABI <https://refspecs.linuxfoundation.org/elf/gabi4+/contents.html>.
[^fatscalar]: R. Ierusalimschy et al., "The Implementation of Lua 5.0" <https://www.lua.org/doc/jucs05.pdf> · Perl SV Internals <https://perldoc.perl.org/perlguts>.
[^fuel]: Wasmtime fuel metering <https://docs.wasmtime.dev/api/wasmtime/struct.Config.html>.
[^fuzzing]: K. Claessen, J. Hughes, "QuickCheck", ICFP 2000 <https://doi.org/10.1145/1806596.1806604>.
[^hashing]: Open addressing with linear probing <https://en.wikipedia.org/wiki/Open_addressing>.
[^immix]: S. M. Blackburn, K. S. McKinley, "Immix: A Mark-Region Garbage Collector with Space Efficiency, Fast Collection, and Mutator Performance", PLDI 2008 <https://doi.org/10.1145/1375581.1375586>.
[^isolate]: Erlang process architecture <https://www.erlang.org/doc/reference_manual/processes.html>.
[^linearscan]: M. Poletto, V. Sarkar, "Linear Scan Register Allocation", TOPLAS 21(5), 1999 <https://www.cs.ucla.edu/~palsberg/course/cs132/linearscan.pdf>.
[^linker]: J. R. Levine, "Linkers and Loaders" <https://linker.iecc.com/>.
[^macho]: OS X ABI Mach-O File Format Reference <https://github.com/aidansteele/osx-abi-macho-file-format-reference>.
[^pe]: Microsoft Portable Executable and COFF Specification <https://learn.microsoft.com/en-us/windows/win32/debug/pe-format>.
[^perldocs]: `perlclass` <https://perldoc.perl.org/perlclass> · `perlop` <https://perldoc.perl.org/perlop>.
[^rcgc]: G. E. Collins, "A Method for Overlapping and Erasure of Lists", CACM 3(12), 1960 <https://doi.org/10.1145/367390.367400>.
[^repro]: SOURCE_DATE_EPOCH specification <https://reproducible-builds.org/specs/source-date-epoch/>.
[^riscv]: The RISC-V Instruction Set Manual, Volume I <https://github.com/riscv/riscv-isa-manual>.
[^siphash]: J.-P. Aumasson, D. J. Bernstein, "SipHash: A Fast Short-Input PRF" <https://doi.org/10.1007/978-3-642-34931-7_28>.
[^ssa]: R. Cytron et al., "Efficiently Computing Static Single Assignment Form and the Control Dependence Graph", TOPLAS 1991 <https://doi.org/10.1145/115372.115320>.
[^stackguard]: GCC stack-clash protection <https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html>.
[^triple]: LLVM Target Triplet documentation <https://llvm.org/doxygen/Triple_8h_source.html>.
[^trialdeletion]: D. F. Bacon, V. T. Rajan, "Concurrent Cycle Collection in Reference Counted Systems", ECOOP 2001 <https://doi.org/10.1007/3-540-45337-7_12>.
[^wasm]: WebAssembly Core Specification <https://webassembly.github.io/spec/core/>.
[^x86]: Intel 64 and IA-32 Architectures Software Developer’s Manual <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>.
