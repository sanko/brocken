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
- [x] **F17 - Unbounded Stack Growth:** `alloca_dyn` inside a loop grows `rsp` every iteration until the function epilogue. Fixed by heap-promoting dynamic-sized arrays (and static arrays exceeding 4 KiB) through `alloc_array`, freeing and reusing the slab at each loop back edge so growth is bounded. The dynamic-stack machinery (`alloca_dyn`/`stack_save`/`stack_restore`) and its MIR consumers were removed entirely. Tests: `33080_dynamic_array_alloca.t`, `33090_dynamic_alloca_loop.t`.
- [x] **i128 Unsigned Div/Rem:** `udiv`/`urem` on 128-bit integers produced wrong results on ARM64 (the partial remainder was accumulated in the wrong 64-bit half, inflating it by 2^64) and on RISC-V (12-bit spill displacements for the i128 operand pairs overflowed the machine addressing mode). Test: `32680_i128_unsigned_divrem_native.t`.
- [x] **Fresh-Fiber Stack Guard:** On ARM64 and RISC-V `arg0` is also the return register, so the stack-guard handoff that gives a fresh fiber its ICB was skipped to preserve the fiber transfer value; the fresh entry then read `%__heap_base` from a zeroed register and faulted. Transfer/yield values now travel through an FCB slot, leaving `arg0` free for the ICB. Test: `34060_fiber_stack_guard.t`.
- [x] **RISC-V Large-Frame Callee Saves:** When a function's spill area pushed the callee-save slots or the saved `s0` frame pointer past the 12-bit `SD`/`LD`/`ADDI` displacement range, the prologue and epilogue emitted the raw masked offset, wrapping the access into the bottom of the frame and corrupting live values. Both sites now materialize the displacement through `t0` with `LUI`/`ADDI`/`ADD` when it does not fit, consistent with the existing large-frame `sp` adjustment. This is a prerequisite for the fully-unrolled i128 division sequence's ~12 KiB frame, but does not by itself repair i128 `div`/`rem` (below).
- [x] **RISC-V Caller-Save Scratch Clobber:** The caller-save stores are emitted *after* the lowerer has placed the outgoing arguments in `a0-a7`, and the caller-restore loads are emitted *before* the caller copies the result out of `a0/a1`. Neither value is a virtual register, so the address-scratch picker (`$pick`) treated `a0-a7` as free and grabbed `a0` whenever a spill slot pushed the caller-save area past the 12-bit `SD`/`LD` displacement range -- silently destroying the argument or return value. The scratch now reserves the parameter registers while a `caller-save`/`caller-restore` instruction is being encoded, which forces it into `t0-t6` (spilled first, reloaded last, and never an argument). The float `fload`/`fstore` handlers previously masked the displacement outright; they now route through the same scratch-aware emitter. Test: `32995_riscv_return_scratch.t`.
- [ ] **RISC-V i128 Signed Div/Rem:** `div`/`rem` on 128-bit integers return a value unrelated to the operands on RISC-V (`42 / 2` and `0 / 1` return the same wrong constant), reproducing under `qemu-riscv64` cross-compilation and failing on the native CI runner in `t/30000_jenny/32000_codegen/32650_i128_arithmetic_native.t`. The unsigned path passes natively. The sequence is fully unrolled (no calls), so the caller-save scratch defect above is not implicated; the root cause remains unisolated and is most likely a spill-reload or register-allocation defect exposed only under the register pressure the fully unrolled 128-iteration sequence produces.
- [x] **Nondeterministic Codegen:** Compiling the identical module twice produced byte-different objects from two independent causes. Perl's per-process hash seed perturbed register allocation; the allocator's liveness and spill walks, the codegen scratch/reload sets, the Wasm source/offset maps, and the ELF64 `.hash` chain now iterate in a sorted order. Separately, the PE linker stamped `time()` into the COFF `TimeDateStamp` and the export directory where ELF, Mach-O, and Wasm write no timestamp; the PE stamp now comes from `Linker::effective_timestamp` (an explicit `set_timestamp`, else `SOURCE_DATE_EPOCH`, else the epoch), so output is byte-identical by default. Guards: `32610_deterministic_codegen.t` emits the spill-heavy RISC-V i128 divide under two hash seeds in child processes and compares digests, and `31220_pe_reproducible.t` checks the PE stamp. The "i128 `udiv` correct under some seeds" symptom was the allocator-order defect and is gone; the deterministic RISC-V `div`/`rem` miscompile remains tracked above.

---

## 2. Memory Safety & Reference Counting (v0.0.1)

Implement the **Caller-Borrows** contract: passing arguments does not touch refcounts. Callees only `incref` if storing or escaping a reference.

- [x] **Fix Immix Block Pointer Bug:** `decref()` charged `live_count` to `get_current_block()` rather than the object's owning block, and the legacy allocator carved new blocks on a `heap_base`-anchored grid that overlapped block 0 by `ICB::SIZE` bytes. Added an arena-anchored `block_of()` and routed `decref`, `gc_decref` and `gc_drain` through it; the naive `obj & ~0x7FFF` mask is wrong because `heap_base` is only 16-byte aligned and block 0 sits off any `heap_base`-anchored grid. Covered by `t/40000_runtime/40330_block_owner.t`.
- [ ] **Wire up Bacon/Rajan Cycle Detection:** `gc_drain()` is currently dead code. It must be called when the suspect buffer is full. Additionally, `gc_scan_obj` must be updated to scan `Tag 3` (Class instances), as it currently only scans Lists and Hashes.
- [ ] **F2 - `//=`/`||=` RC Leak:** A conditional assignment on a dynamic (`Any`) slot stores the select result without emitting an `incref` on the replacement or a `decref` of the displaced old value (the same gap as the constructor field-default `||=`, F9).
- [ ] **F3 - Borrowed `Any` UAF:** Callers pass `Any` arguments without `incref`, but callees erroneously `decref` them on exit. Causes Use-After-Free. Remove the callee exit decref for borrowed params.
- [ ] **F5 - Overzealous Loop Cleanup:** `_emit_loop_cleanup` decrefs *all* function-wide `needs_rc` variables on `last`/`next`, instead of only loop-scoped ones.
- [ ] **F9 - Class Field RC Leaks:** Constructors and field assignments store without an `incref` and displace old values without a `decref`.
- [ ] **F12 - Loop/If RC Leak:** `if` and `while` bodies skip block-scoped RC cleanup because they call `lower_block_body` directly instead of `lower_block`.
- [ ] **F13 - Double-Incref on Return:** Dynamic return values are incref'd twice (by the callee and the caller) leading to a permanent +1 leak.
- [ ] **Object Destructors (`DESTROY`):** Implement `DESTROY { ... }` block lowering for classes, with automated cascading `decref`s for fields. Chains derived→root; part of the class object-model work (see §12 and `docs/class_roadmap.md` §1.6).

---

## 3. Syntax, Signatures & Grammar Updates

- [x] **`:returns(Type)` Syntax:** The return annotation is now the attribute `:returns(Type)` on both `sub` and `method` declarations; the old `-> RetType` spelling has been removed from `Parser.pm`, the core runtime (`src/runtime/core.brocken`), tests, and examples. The spec documents this form (§7.4, §8).
- [x] **Defined-or & Conditional Assignment (`//`, `//=`, `||=`):** The parser treats `//` as an eager binary operator — left-associative and at the same precedence as `||` — and `//=`/`||=` as assignment operators, including on a `my` declaration (where they take the initializer unconditionally, since a fresh variable has no prior value). The lowerer tests a `ptr`/`Any` slot against null for `//=`/`//` and against zero for `||=`, then `select`s. `//=` on a native `int`/`float`/`bool`, which can never be undefined, is a plain `=`. `||=` on an `Any` box currently sees only a null box as false (see §4). Tests: `t/10000_katsuro/10980_defined_or_assign.t` plus parser/lowerer cases.
- [ ] **`state` (Persistent Lexical):** `state $x //= EXPR` is the spelling whose condition is actually observable across calls, but the IR and linkers have no writable program-global/static storage yet (`__heap_base` arrives as a function parameter), so `state` still parses nowhere. Blocked on static storage.
- [ ] **`package NAME` Declaration Scoping:** Support a `package NAME;` statement (and optionally `package NAME { ... }`) that prefixes the declarations that follow, so a module can write `sub heap_cursor(...)` inside `package Brocken::Runtime;` instead of spelling `sub Brocken::Runtime::heap_cursor` on every sub. This is a compile-time namespace prefix for `sub`/`method`/`class`/field and constant names within one compilation unit; cross-unit `require`/import stays gated on the module system (spec §17.4). The core runtime (`src/runtime/core.brocken`) is the immediate motivation: it currently names every sub with its full package, e.g. `sub Brocken::Runtime::bump_alloc`.
- [ ] **Tuple Returns:** Extend `:returns(...)` to multi-type register tuples `:returns(i64, bool)`. The parser currently parses up to the comma and rejects tuples with a clear "not yet implemented" error; the `AST`/`Lowerer` still model a single scalar `return_type`.
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
- [x] **Zero-initialised pointer slots:** An uninitialised `ptr` or `Any` variable now starts null — the fresh stack slot is explicitly zeroed — so a null test sees it as undefined instead of whatever the slot held. This is what `//`, `//=`, and `||=` rely on. Native `int`/`float`/`bool` declarations are still not zeroed.
- [ ] **`||=` on a boxed false:** `||=` on an `Any` tests the box pointer, so a box holding `0` is kept rather than replaced; only a null box counts as false. A payload-aware truthiness test needs the runtime box readers and must not fault on a null box (the guard that `if (null_any)` and binary `||` are also missing).
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
- [x] **Test Renumbering:** Tests and their directories now use 5-digit prefixes (the leading digit run right-padded with zeros), e.g. `3000_jenny` -> `30000_jenny` and `3401_fiber_lowering.t` -> `34010_fiber_lowering.t`, so new tests can be inserted without colliding.
- [ ] **Directory-Band Test Renumbering:** Fold tests that overflowed their parent directory's numeric band back into it. `t/30000_jenny/32000_codegen/` owns the 32000-32999 band, but ten later tests spilled into 33xxx: `33000_wasm_integer_minmax.t`, `33010_call_shuffle_rodata.t`, `33020_riscv_mem_source.t`, `33030_arm64_drop_create_thread_thunk.t`, `33040_gate_dispatch_stack_args.t`, `33050_spill_temp_exhaustion.t`, `33060_arm64_call_shuffle_fp_temp.t`, `33070_caller_restore_self_move.t`, `33080_dynamic_array_alloca.t`, and `33090_dynamic_alloca_loop.t`. A test's prefix must stay within the band its immediate directory owns, so each needs a free 32xxx slot (and every reference, including this document's, updated).

---

## 10. Fuzzer Expansion Plan (F0-F9)

- [ ] **F0: Types** - Add `bool`, `i8`-`u64`, `i128`, `f64`, `Int` (fat scalars), and `String`.
- [ ] **F1: Control Flow** - `while` loops, nested `if/else`, chained logic (`&&`/`||`), `break`/`continue`, ternary.
- [ ] **F2: Functions** - Generate random subroutines, inter-procedural calls, and recursion.
- [ ] **F3: Memory** - Arrays, structs/classes, GEP lowering, `say`/`print` stdout capture.
- [ ] **F4/F5: Mutation & Minimization** - Delta-debugging minimizer (`_minimize`) to automatically extract minimal regression tests from a seeded corpus.
- [ ] **F8: Wasm CI** - Execute `.wasm` output via `wasmtime` or `node`. Treat Wasm traps (e.g., out of bounds) as test failures.

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

---

## 12. Class System

v0.0.1 brings classes to `perlclass` (`use feature 'class'`) parity; v0.0.2 adds selected `Object::Pad`
features. The feature-by-feature plan, decisions, and open questions live in
[`docs/class_roadmap.md`](docs/class_roadmap.md). Summary of the work:

- [ ] **v0.0.1 — syntax sugar:** `:returns(Type)` (replacing `-> RET`) [done], parameter defaults [done], `||=`
  defaults [done], `:param(NAME)`/`:reader(NAME)`/`:writer(NAME)` with `_`-stripping [done], `:writer` returns
  `$self` for chaining [done], multiple `ADJUST` blocks [done], earlier-field visibility in field
  initializers [done], `:accessor` [done], array/hash fields, and `:weak` (deferred until class-typed fields
  take ownership — see the roadmap M0 note).
- [ ] **v0.0.1 — object model:** class versions and attributes, `:isa` single inheritance, static
  ancestor resolution and `SUPER::`, constructor chaining over a copied `:param` name map, `DESTROY`
  chaining with cascading field teardown, and field alignment/padding.
- [ ] **v0.0.2:** `role`/`apply`/`:does`/`requires` compile-time flattening, `:abstract`, ADJUST
  `:params`, `:strict(params)`, `:lexical_new`, `my class`, `inherit`, `:override`/`:common`, and
  lexical/anonymous methods.
- [ ] **Deferred:** `BUILD`/`BUILDARGS`, the metaprogramming API, extension attributes,
  `:inheritable` field inheritance, `:lvalue` methods, and `:repr(...)`.

---

## 13. Codegen Performance & Code Size

- [ ] **RISC-V i128 Divide Unroll Replacement:** RISC-V 128-bit `div`/`rem` lower to a fully unrolled
  128-iteration shift/subtract sequence (`reverse 0..127` in `lib/Brocken/Jenny/Lowerer/RISCV64.pm`),
  about 5191 instructions and 23 KiB of code for a single operator -- an order of magnitude more than
  the rest of the function and enough register pressure to have masked the allocator defects in §1.
  Replace the unrolled expansion with a runtime loop (the step sequence emitted once and iterated), or
  a hardware-assisted fast path analogous to x86's `div128_64` and the ARM64 partial fast path, so
  both the code size and the allocator pressure drop. The result must stay bit-identical to today's
  sequence; `t/30000_jenny/32000_codegen/32650_i128_arithmetic_native.t` is the regression guard.
