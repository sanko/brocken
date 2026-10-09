# Brocken Compiler Roadmap & Task List

This document tracks the open work, known bugs, and architectural roadmap for the Brocken compiler. The immediate focus is achieving the **v0.0.1 Release Milestone**.

## The v0.0.1 Milestone Definition ("Hello, World")
A working end-to-end program that can parse text into an O(1) `%hash`, allocate objects (`class`), handle `undef`, catch an error using `try/catch/finally` or `die`, pass data across a Channel between Isolates, and exit cleanly with 0 memory leaks across all targets (x86_64, ARM64, RISC-V, Wasm).

---

## 1. Critical Backend Correctness (Blockers)

These bugs cause silent miscompilations in the code generators and register allocator.

- [x] **Shift Reload Omission:** `RegAlloc.pm`'s `%reads_dst` table uses `shr`/`sar` instead of the actual MIR opcodes `lshr`/`ashr`. Spilled shift destinations are currently overwritten without being reloaded.
- [x] **`umulh` Liveness Gap:** `umulh` is missing from both `%reads_dst` and `%rmw` in `RegAlloc.pm`, causing omitted reloads and latent liveness issues.
- [x] **x86-64 Mixed Arg Sum:** A sum of many mixed integer and floating-point arguments returns the wrong value on x86-64 Linux ELF targets due to register pressure spilling bugs.
- [x] **F17 - Unbounded Stack Growth:** `alloca_dyn` inside a loop grows `rsp` every iteration until the function epilogue. Fixed by heap-promoting dynamic-sized arrays (and static arrays exceeding 4 KiB) through `alloc_array`, freeing and reusing the slab at each loop back edge so growth is bounded. The dynamic-stack machinery (`alloca_dyn`/`stack_save`/`stack_restore`) and its MIR consumers were removed entirely. Tests: `3308_dynamic_array_alloca.t`, `3309_dynamic_alloca_loop.t`.

---

## 2. Memory Safety & Reference Counting (v0.0.1)

Implement the **Caller-Borrows** contract: passing arguments does not touch refcounts. Callees only `incref` if storing or escaping a reference.

- [ ] **Fix Immix Block Pointer Bug:** In `core.brocken`'s `decref()`, `live_count` is erroneously decremented on `get_current_block()`. It must decrement the object's actual owning block by masking its address: `obj & ~0x7FFF`.
- [ ] **Wire up Bacon/Rajan Cycle Detection:** `gc_drain()` is currently dead code. It must be called when the suspect buffer is full. Additionally, `gc_scan_obj` must be updated to scan `Tag 3` (Class instances), as it currently only scans Lists and Hashes.
- [ ] **F2 - `//=` RC Leak:** `//=` on dynamic types stores the select result without emitting `incref` or an old-value `decref`.
- [ ] **F3 - Borrowed `Any` UAF:** Callers pass `Any` arguments without `incref`, but callees erroneously `decref` them on exit. Causes Use-After-Free. Remove the callee exit decref for borrowed params.
- [ ] **F5 - Overzealous Loop Cleanup:** `_emit_loop_cleanup` decrefs *all* function-wide `needs_rc` variables on `last`/`next`, instead of only loop-scoped ones.
- [ ] **F9 - Class Field RC Leaks:** Constructors and field assignments store without an `incref` and displace old values without a `decref`.
- [ ] **F12 - Loop/If RC Leak:** `if` and `while` bodies skip block-scoped RC cleanup because they call `lower_block_body` directly instead of `lower_block`.
- [ ] **F13 - Double-Incref on Return:** Dynamic return values are incref'd twice (by the callee and the caller) leading to a permanent +1 leak.
- [ ] **Object Destructors (`DESTROY`):** Implement `DESTROY { ... }` block lowering for classes, with automated cascading `decref`s for fields.

---

## 3. Syntax, Signatures & Grammar Updates

- [ ] **`:returns(...)` Syntax:** Replace `-> RetType` in `Parser.pm` and `Lowerer.pm` with the subroutine attribute `:returns(...)`. Support multi-type register tuples `:returns(i64, bool)`.
- [ ] **Post-Dereference Syntax (`postderef`):** Implement post-deref parsing and lowering: `$ref->@*`, `$ref->%*`, `$ref->$*`, `$ref->[0]`, `$ref->{key}`.
- [ ] **Strict String Interpolation:** Update `Lexer.pm` and `Parser.pm` double-quote interpolation: support `$scalars`, `@arr[0]`, `%map{key}`, `${var}`. Method calls like `"$pt->x"` must remain raw text (no method call interpolation).
- [ ] **Anonymous Subs & Closures:** Add parser and lowerer support for anonymous `sub (...) :returns(...) { ... }`.
  - Non-capturing: Lower as raw function pointer.
  - Capturing: Promote captured variables to a heap-allocated Environment Record on Immix; pass as hidden environment pointer.
- [ ] **Postfix Conditionals:** Support statement modifiers: `return 0 if $cond;`, `die unless $ok;`, `next if $skip;`.
- [ ] **Compound Assignments:** Support `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `.=`. Ensure target addresses (like `%map{"k"}`) are evaluated only once.
- [ ] **Range Operator Induction Loops:** Lower `for my $i (0 .. N)` to a zero-allocation while/induction loop.

---

## 4. Nullability & `undef` Semantics

- [ ] **Type Separation:** Lowercase native types (`i64`, `f64`, `bool`, `ptr`) default to `0`/`false` in registers and cannot be `undef`. Capitalized managed types (`Int`, `Float`, `Bool`, `String`, `Class`, `Any`) default to `undef` (Fat Scalar tag = 0).
- [ ] **`undef` Keyword & Literal:** Support `undef` as a value (`$x = undef`) and mutator (`undef($var)`, `undef(@arr)`, `undef(%hash)`).
- [ ] **`defined` Builtin:** Implement `defined($val)` to check if a managed container has Tag != 0.

---

## 5. Built-in Functions & Container Operations

- [ ] **Process & Error Builtins:**
  - `exit($code)`: Emits kernel `exit` syscall.
  - `warn(@msgs)`: Formats and writes to `stderr`.
  - `die(@msgs)`: Formats error and emits `throw` (caught by `catch ($err)` or exits 255).
- [ ] **Container Builtins:**
  - Implement keywords: `keys %hash`, `values %hash`, `exists %hash{"k"}`, `delete %hash{"k"}` (returns deleted value).
  - Implement array keywords: `push @arr, $val`, `pop @arr`, `shift @arr`, `unshift @arr, $val`.
- [ ] **Auto-Increment (`++`) and Decrement (`--`):**
  - Implement numeric pre- and post-increment/decrement.
  - Implement Option A ASCII magical string increment (`"az"++` $\rightarrow$ `"ba"`, non-ASCII/symbols convert to numeric 0 and increment to 1). `--` is strictly numeric.

---

## 6. Exception Handling: SJLJ & Landing Dispatcher

- [ ] **Implement Landing Dispatcher:** Lower `try/catch/finally` so that normal exits, `return`, `last`/`next`, and `throw`/`die` all route through a unified dispatch block.
- [ ] **Fix F4 (`try/catch` Memory Leak):** Ensure the ICB exception handler stack is cleanly popped in the Landing Dispatcher on every single exit path.
- [ ] **Fix F18 (Catch-var Aliasing):** Prevent nested catch blocks from aliasing to the exact same static frame slot.

---

## 7. Hash Tables & Perl Semantics

- [ ] **O(1) Hash Table:** Replace the linear array-of-pairs list in `core.brocken` with an Open Addressing / Linear Probing power-of-two hash table.
- [ ] **Hash Ownership:** Ensure hash insertions properly `incref` values, and hash destruction recursively `decref`s all stored keys and values.
- [ ] **Perl Truthiness Rules:** Fix conditionals (Bug F7) to evaluate truthiness correctly. `0`, `"0"`, `""`, and `undef` (NULL) are false. Everything else (including `0.5` and `"00"`) is true. Use an `is_truthy(ptr)` runtime helper for dynamic variables instead of raw truncation via `unbox_i64`.
- [ ] **F1 - `say`/`print` Segfaults:** `say(42)` passes raw integers to `puts()`, expecting a pointer. Inject proper stringification (`i64_to_str`, etc.).
- [ ] **F6 - Order-dependent Mixed Signs:** Mixed-sign comparisons at equal widths (< 64-bit) derive their `sext`/`zext` rule entirely from the LHS. `u8 < i8` and `i8 > u8` yield contradictory results.
- [ ] **F8 - Unary Float Truncation:** Unary `-` and `!` on dynamic values force `unbox_i64`, silently breaking boxed floats.

---

## 8. Concurrency & Channels (v0.0.1)

- [ ] **Channel Data Structure:** Implement the global bounded ring-buffer table in the `.data` section.
- [ ] **Inline Synchronization:** Inline `pthread_mutex` / `pthread_cond` (or SRWLock) sequences on X86_64, ARM64, and RISCV64 for channel operations.
- [ ] **Deep-Copy / Primitive Transfers:** For v0.0.1, channels pass primitives (`i64`, `f64`, `bool`). Aggregates passed through channels are deep-copied into the receiver's Immix heap.
- [ ] **Channel Tests:** Two-isolate send/recv (native and compiled execution).

---

## 9. Compiler Diagnostics & Minor Missing Features

- [ ] **Dynamic Boxing:** `my Int $x = 10` currently lowers like `i64`. Implement actual heap allocation (`bump_alloc(16)`) for top-level boxes.
- [ ] **F11 - Silent Casts:** `maybe_convert_type` silently allows `int` <-> `ptr` casts as a no-op fallback instead of throwing a hard error.
- [ ] **F14 - Arity Checking:** The compiler currently silently ignores excess arguments and leaves missing arguments uninitialized. Add basic argument count validation.
- [ ] **F15 - `__CLASS__` Lowering:** Currently lowers to a pointer constant that gets numified by the encoder.
- [ ] **F16 - Empty Function Bodies:** An empty `sub f() {}` produces a declaration with no definition, resulting in a silent linker error.
- [ ] **Debug Info Context:** Track source line/col through to compilation diagnostics and runtime error messages.
- [ ] **Test Renumbering:** Move all unit tests to a 5-digit numbering scheme (e.g., `3000` -> `30000`) to prevent file crowding.

---

## 10. Fuzzer Expansion Plan (F0-F9)

- [ ] **F0: Types** — Add `bool`, `i8`-`u64`, `i128`, `f64`, `Int` (fat scalars), and `String`.
- [ ] **F1: Control Flow** — `while` loops, nested `if/else`, chained logic (`&&`/`||`), `break`/`continue`, ternary.
- [ ] **F2: Functions** — Generate random subroutines, inter-procedural calls, and recursion.
- [ ] **F3: Memory** — Arrays, structs/classes, GEP lowering, `say`/`print` stdout capture.
- [ ] **F4/F5: Mutation & Minimization** — Delta-debugging minimizer (`_minimize`) to automatically extract minimal regression tests from a seeded corpus.
- [ ] **F8: Wasm CI** — Execute `.wasm` output via `wasmtime` or `node`. Treat Wasm traps (e.g., out of bounds) as test failures.

---

## 11. Backlog (v0.0.2)

These items are deferred to the subsequent release:

- [ ] **Zero-Cost Exceptions:** DWARF `.eh_frame` bytecode interpreter (written in `core.brocken`), Windows SEH (`.pdata`/`.xdata`), and Wasm `try_table`/`throw`.
- [ ] **Zero-Copy Channels:** Implement the **Scoped Affine Move Checker** (`move $var`) and the **Global Message Arena** for zero-copy ownership transfer between Isolates.
- [ ] **Option B Magical String Increment:** Unicode alphabetic block carry-increment (Cyrillic, Greek).
- [ ] **Float Width Casting:** Implement `fptrunc` and `fpext` to allow mixing `f32` and `f64`.
- [ ] **Float-to-Int Overflows:** Define overflow and NaN semantics for float-to-int conversions (`fptoui`).
- [ ] **Perceus RC Elision:** Compile-time optimizations (Borrow Inference, RC Elision, Reuse Analysis).
- [ ] **Fiber Stack Scanning:** Walk stacks of suspended fibers to find live GC roots for the tracing cycle detector.
- [ ] **Stack Map Section:** Emit `.brocken_stackmaps` for precise GC root enumeration.
- [ ] **Big-Endian Targets:** `i128` math has no handling for big-endian byte layouts.
- [ ] **illumos Isolate Segfaults:** `Platform::Solaris` crashes on isolate tests. Requires an OmniOS VM to debug.
- [ ] **Apple AAPCS Varargs:** Test and verify the 64-byte vararg register save area on Apple Silicon.
