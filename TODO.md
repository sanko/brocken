# Brocken Compiler Implementation Roadmap & Task List

This document is the authoritative engineering tracker for bringing the Brocken compiler from its baseline (`v0.0.1`) to complete conformance with `spec.md` (`v0.1.0+`).

---

## 1. Critical Backend Correctness & Linking (Release Blockers)

- [x] **Shift Reload Omission:** Corrected `%reads_dst` in `RegAlloc.pm` to track `lshr`/`ashr`.
- [x] **`umulh` Liveness Gap:** Added `umulh` to `%reads_dst` and `%rmw` in `RegAlloc.pm`.
- [x] **x86-64 Mixed Arg Sum:** Fixed register allocator spill pressure on mixed integer/float calling sequences.
- [x] **F17 - Unbounded Stack Growth:** Heap-promoted dynamic arrays and static arrays $> 4\text{ KiB}$ via `alloc_array`, recycling slabs at loop back-edges.
- [x] **i128 Unsigned Div/Rem:** Corrected ARM64 high-half remainder accumulation and RISC-V 12-bit displacement spills.
- [x] **Fresh-Fiber Stack Guard:** Routed fiber handoff values through FCB slots on ARM64 and RISC-V, preserving `arg0` for `%__heap_base`.
- [x] **RISC-V Large-Frame Callee Saves:** Materialized displacements $> 2047$ bytes through `t0` via `LUI`/`ADDI`/`ADD`.
- [x] **RISC-V Caller-Save Scratch Clobber:** Reserved argument registers `a0-a7` during caller-save/restore emission to force scratch into `t0-t6`.
- [x] **Nondeterministic Codegen:** Deterministic sorting applied across `RegAlloc.pm`, codegen maps, and ELF64 `.hash` chains. Pinned PE timestamps via `SOURCE_DATE_EPOCH`.
- [x] **Linker Rodata Seeding:** `Brocken::compile()` seeds `$linker->set_rodata()` to resolve string constants across all compilation flows.
- [x] **Store Width Preservation:** Enforced narrow store widths in `Builder.pm` and across all four backend lowerers (`X86_64`, `ARM64`, `RISCV64`, `Wasm`).
- [ ] **RISC-V i128 Signed Div/Rem (Open):**
  - [ ] Signed 128-bit `div`/`rem` returns incorrect constants under `qemu-riscv64` and native hardware (`t/30000_jenny/32000_codegen/32650_i128_arithmetic_native.t`).
  - [ ] Implement 64-bit fast-path in `RISCV64.pm` when high words are zero (`hi_lhs == 0 && hi_rhs == 0`).
  - [ ] Replace the 128-iteration fully-unrolled shift-subtract sequence (~5,190 instructions) with a compact looped algorithm or library helper to relieve extreme register pressure.
- [ ] **Wasm Rodata & Data-Segment Support (Open):**
  - [ ] Lowerer currently falls through on `RodataRef`, causing boxed string literals in Wasm to receive garbage pointers.
  - [ ] Port `lea_rodata` / `_materialize` string literal handling from native backends to `Lowerer::Wasm`.
  - [ ] Add Wasm test runner (`wasmtime` or `node`) to CI harness to validate Wasm execution.

---

## 2. Memory Model & Garbage Collection (`core.brocken` & Immix)

Goal: Complete fidelity with the Blackburn & McKinley (PLDI 2008) Immix paper and Bacon & Rajan (ECOOP 2001) trial deletion paper.

- [x] **Immix Block Owner Derivation:** Corrected block base masking using arena-relative offsets (`block_of`) instead of naive `ptr & ~0x7FFF`.
- [x] **Bacon & Rajan Synchronous Trial Deletion:**
  - [x] Wired automatic threshold sweep (`maybe_gc_drain`) triggered when `suspect_count >= 256`.
  - [x] Implemented re-entrancy sentinel (`suspect_count = -1`) to protect Phase 3 `DESTROY` sweeps from mutating the suspect ring.
  - [x] Implemented MarkGray, ScanBlack, and multi-stage collection across Lists, Hashes, and Class instances via compiler-generated `__scan`/`__restore` hooks.
  - [x] Integrated `gc_destroy_class` to run user `DESTROY` blocks on confirmed cyclic garbage before memory reclamation.
- [x] **Object Resurrection Protection:** `Class::__destroy` inspects `$self` refcount following user `DESTROY`; if `RC > 0`, reclamation and field cascades abort, keeping the instance alive.
- [x] **LIFO Field Teardown:** Cascading field teardown in `Class::__destroy` decrefs managed fields in reverse declaration order.
- [x] **Segregated Free Lists (`free16_head` & `free_big_head`):**
  - [x] `free16_head` handles hot-path 16-byte Fat Scalar reclamation.
  - [x] `free_big_head` recycles variable-length Tag 8 (Hash) and Tag 9 (Array) memory slabs via size-matched reuse.
- [x] **Native-Width Header Optimization:** Replaced 64-bit load-mask-shift operations with direct `u16`/`u8` accessors for refcounts, GC flags, and type tags.
- [x] **ICB Accessor Inlining:** Inlined compile-time constant offsets in `bump_alloc`, `decref`, and `free_obj`.
- [x] **Memory Limit Check Hoisting:** Hoisted memory budget checks out of the hot `free16_head` path into fresh line/block allocations.
- [ ] **Immix Line Compaction & Evacuation (Whitepaper Parity):**
  - [ ] Add opportunistic line evacuation: detect fragmented blocks during sweep and evacuate live objects into contiguous lines.
  - [ ] Track two-bit line states (*Free*, *Live*, *Pinned*) to handle multi-line spans across collection cycles.
- [ ] **Out-of-Line Large Object Space (LOS):**
  - [ ] Isolate allocations $\ge 4\text{ KiB}$ from the 32 KiB tiled Immix grid into distinct OS virtual memory allocations (`mmap`/`VirtualAlloc`).
  - [ ] Update `block_of($hb, $addr)` to distinguish contiguous Immix blocks from LOS descriptors.

---

## 3. Caller-Borrows Contract & Lifetime Tracking

- [x] **F3 - Borrowed `Any` UAF:** Callee treats dynamic `Any` parameters as borrowed (`$borrowed_params`), omitting scope-exit decrefs.
- [x] **F5 - Scoped Loop Cleanup:** `_emit_loop_cleanup` decrefs only variables introduced within the current loop iteration scope.
- [x] **F9 - Class Field Ownership:** Dynamic field stores take ownership (`incref`) and decref displaced values across constructors, accessors, and field assignments.
- [x] **F12 - Branch-Body Scope Cleanup:** `if`/`elsif`/`else` bodies execute block-scoped cleanup, eliminating per-iteration leaks.
- [x] **F13 - Return Ownership Normalization:** Pre-pass classifies function return ownership; callers consume owned references (`+1`) without duplicate increfs.
- [x] **Instance Ownership:** Non-escaping fresh instances (`Class->new`) are reclaimed at scope exit via `Class::__destroy`.
- [x] **Field-Return Promotion:** Returning an instance field promotes the field to an owned reference (`incref`), ensuring values outlive temporary receiver parents.
- [x] **Managed Array Element Ownership:** Local `Any` arrays (`Tag 9`) track element ownership via `array_zero` and `array_release`.
- [x] **Weak Reference Semantics (`:weak`):**
  - [x] `:weak` fields and variables store pointers without taking refcount ownership.
  - [x] `builtin::weaken`, `builtin::unweaken`, and `builtin::is_weak` toggle ownership tracking on locals.
- [ ] **Automated Perceus Borrow Inference (PLDI 2021):**
  - [ ] Implement middle-end analysis to infer borrow annotations automatically.
  - [ ] Implement RC elision to cancel redundant adjacent `incref`/`decref` instructions.
  - [ ] Lower terminal lexical uses into affine `Move` transfers.

---

## 4. Language Syntax & Frontend (`Katsuro`)

- [x] **Subroutine Return Syntax:** Replaced `-> Type` with `:returns(Type)` across all grammar productions, runtime files, and tests.
- [x] **Defined-Or & Conditional Assignment:** Implemented `//`, `//=`, and `||=` across variables and class fields.
- [x] **Package Scoping:** Implemented `package NAME;` and `package NAME { ... }` with version parsing and automatic symbol qualification.
- [x] **Compile-Time Pseudo-Constants:** Implemented `__PACKAGE__`, `__CLASS__`, `__FILE__`, and `__LINE__`.
- [x] **Subroutine Forward Prototypes:** Implemented `sub f();` prototype declarations without code bodies.
- [x] **Postfix Conditionals:** Implemented statement modifiers `stmt if cond;` and `stmt unless cond;`.
- [x] **Range Induction Loops:** `for my $i (0 .. 1000)` lowers to register induction loops without array allocation.
- [x] **Compound Assignments:** Implemented `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `.=`.
- [x] **`for` / `foreach` Iteration:** Implemented typed iteration over array elements and flat lists with `my` loop variables.
- [x] **`want` Intrinsic:** Implemented `want('scalar')`, `want('list')`, `want('void')`, and type queries via hidden `%__want` injection.
- [x] **Arity Validation (F14):** Enforced compile-time parameter count checks for function and method calls.
- [x] **Untyped Receiver Method Calls:** Method calls on `Any` boxes unbox the object payload pointer automatically.
- [x] **Empty Function Bodies (F16):** Subroutines with empty bodies `sub f() {}` emit valid epilogues and default returns.
- [x] **Short-Circuiting Logic (`&&`, `||`, `//`):**
  - [x] Replaced eager SSA evaluation in `lower_binop` with CFG-level branching blocks to short-circuit RHS side effects.
  - [x] `||`/`&&` now use Perl *value* semantics (the deciding operand is yielded, not a boolean) with unified result typing.
- [x] **Advisory Native Types:**
  - [x] A native local assigned a value its kind cannot hold is promoted to `Any` for the whole function with a compile-time warning (all native types, `bool` included).
  - [x] Dynamic/unknown sources keep the native slot and emit a runtime store guard warning instead.
- [ ] **Single Evaluation in Compound Assignments:**
  - [ ] Lower compound assignments so complex target indices (e.g. `%map{compute()} += 1`) evaluate keys exactly once.
- [ ] **Full Postfix Dereferencing (`postderef`):**
  - [ ] Add lexer and parser support for `->$*`, `->@*`, `->%*`, and array/hash slice syntax `->@[...]`, `->@{...}`.
- [ ] **Perl Special Variables:**
  - [ ] Add lexer and parser support for `$_`, `@_`, `@ARGV`, `%ENV`, `$$`, `$!`, `$@`, `$a`, `$b`.
  - [ ] Implement implicit shifting: `my $x = shift;` operating automatically on `@_`.
- [ ] **Named Parameters in Subroutines:**
  - [ ] Support colon-prefixed named parameters in signatures: `sub configure(String $host, :i64 $port = 8080)`.
  - [ ] Lower call-site fat-comma pairs (`port => 9000`) into matching parameter slots.
- [ ] **Multi-Value Tuple Returns:**
  - [ ] Extend `:returns(Type, ...)` to return $> 2$ values by allocating hidden return slots on the caller stack frame.
- [ ] **Anonymous Subs & Closures:**
  - [ ] Support anonymous subroutine expressions (`sub (...) { ... }`).
  - [ ] Emit bare function pointers for non-capturing subs and Immix Environment Records for capturing closures.
- [ ] **Persistent Lexicals (`state`):**
  - [ ] Implement `state` variable declarations once writable program-global storage is available.

---

## 5. Built-in Functions & Containers

- [x] **O(1) Open-Addressing Hash Table:** Implemented power-of-two hash tables with linear probing, tombstones, and automatic doubling.
- [x] **Insertion-Ordered Hash Iteration:** Implemented doubly-linked bucket threading (`prev`/`next` indices) for $O(N)$ insertion-ordered `keys` and `values`.
- [x] **Hash Builtins:** Implemented `keys %h`, `values %h`, `exists %h{k}`, and `delete %h{k}`.
- [x] **Array Mutators:** Implemented `push @a, $v`, `pop @a`, `shift @a`, and `unshift @a, $v` for growable Tag 9 arrays.
- [x] **Auto-Increment & Decrement (`++` / `--`):**
  - [x] Implemented pre/post increment/decrement for numbers, string pointers, and dynamic `Any` slots.
  - [x] Implemented Perl ASCII carry rules for strings matching `/^[a-zA-Z]*[0-9]*\z/`.
- [x] **`undef` and `defined` Semantics:**
  - [x] `undef` literal lowers to null box (Tag 0, Payload 0).
  - [x] Mutator `undef($var)`, `undef(@arr)`, and `undef(%hash)` empties containers in place.
  - [x] `defined $var` tests for non-null tags on managed types and folds to true for native types.
- [x] **Process & Diagnostic Builtins:**
  - [x] Implemented `exit($code)` calling libc exit to flush stdio.
  - [x] Implemented `warn(@msgs)` formatting messages to `stderr`.
  - [x] Implemented `die(@msgs)` raising SJLJ exceptions or terminating process with status 255.
- [x] **Core Utility Builtins (`builtin::`):**
  - [x] Implemented `true`, `false`, `is_tainted`, `is_bool`, `created_as_string`, `created_as_number`, `stringify`, `numify`, `refaddr`, `reftype`, `blessed`.
  - [x] Implemented `ceil`, `floor`, `inf`, `nan`, `trim`, `indexed`.
- [ ] **Variadic Float Formatting:**
  - [ ] Lower `sprintf("%f")` float stringification according to architecture variadic ABIs (setting `%al` on x86_64, integer register duplication on RISC-V).

---

## 6. Object-Oriented Features (`perlclass`)

- [x] **Encapsulated Class Declarations:** Block form `class Name { ... }` and statement form `class Name;`.
- [x] **Field Declarations & Attributes:** Implemented `field` with `:param`, `:reader`, `:writer`, `:accessor`, and `:weak`.
- [x] **Automated Accessor Synthesis:** Strips exactly one leading underscore for accessors (`$_x` $\to$ `x()`, `set_x()`).
- [x] **Chained Mutators:** Synthesized `:writer` accessors return `$self`.
- [x] **Initializers & `ADJUST`:** Field defaults (`=`, `//=`, `||=`) and multiple `ADJUST` blocks execute in declaration order.
- [x] **Single Inheritance (`:isa`):** Static ancestor resolution and field layout extension.
- [x] **`SUPER::` Dispatch:** Method calls using `SUPER::method(...)` resolve to ancestor implementations.
- [x] **Destructor Chaining (`DESTROY`):** Executes derived-to-root upon refcount zero.
- [ ] **Component Pascal Role Flattening:**
  - [ ] Parse `role Name { ... }` with method requirements (`requires`).
  - [ ] Implement `adjoin RoleName;` to inline role fields and methods at compile time with zero vtable overhead.

---

## 7. Exception Handling & SJLJ

- [x] **SJLJ Landing Dispatcher:** `try/catch/finally` lowers to `setjmp`/`longjmp` state machines on `ICB::EXCEPTION_HANDLER_STACK`.
- [x] **F4 - Handler Stack Cleanup:** `return`, `last`, and `next` pop active exception handlers before jumping.
- [x] **F18 - Catch-Variable Scope Safety:** Catch variables are bound by bare name with unique allocas, preventing nested catch clobbering.
- [ ] **String Exception Payloads in `catch`:**
  - [ ] Widen `ICB::THROWN_VALUE` handling so `catch ($err)` binds managed string objects from `die`.
- [ ] **Zero-Cost DWARF Unwinding (v0.0.2):**
  - [ ] Transition from `setjmp`/`longjmp` to table-driven DWARF `.eh_frame` unwinding.
  - [ ] Generate Windows SEH `.pdata`/`.xdata` tables on PE32+ targets.

---

## 8. Concurrency, Isolates & Channels

- [x] **Share-Nothing Isolates:** Independent Immix heaps with ICB pinned to hardware registers (`r14`, `x28`, `s11`).
- [x] **Cooperative Fibers:** M:N coroutines with 64 KiB stacks switched via assembly `ctx_swap` using derived FCB layouts.
- [ ] **Bounded CSP Channel Implementation:**
  - [ ] Implement Channel Control Block (CCB) ring buffer in shared `.data` protected by inlined mutex and condition variable sequences.
  - [ ] Implement channel intrinsics: `chan_create($cap)`, `chan_send($c, $v)`, `chan_recv($c)`, `chan_close($c)`.
  - [ ] Implement deep-copy serialization for aggregates sent across channels with cycle-detection traversal.
- [ ] **Isolate Heap Reclamation:**
  - [ ] Ensure `isolate_join($iso)` unmaps and reclaims the terminating Isolate's entire Immix arena and ICB memory.

---

## 9. Compilation Pipeline, Memory & Freestanding Support

- [x] **Parser AST Caching:** Cached parsed `core.brocken` AST structure via `state %core_ast_cache`.
- [x] **Path Lookup Caching:** Cached `DEFAULT_RUNTIME` resolution across compiler instances.
- [ ] **Acyclic IR by Construction:**
  - [ ] Weaken container back-references (`Function` $\to$ `Block`, `Block` $\to$ `Instruction`, `Phi` incoming blocks) to allow automatic Perl garbage collection without manual `$module->release()`.
- [ ] **Lowered Core Module Snapshotting:**
  - [ ] Snapshot lowerer symbol and class state after compiling `core.brocken` to avoid re-lowering runtime IR on every user compile.
- [ ] **Staged Freestanding (No-libc) Builds:**
  - [ ] Add `libc => 0|1` configuration flag to `Brocken->new()`.
  - [ ] Implement freestanding I/O: raw `write(2)` syscall for `say`/`print`, inline string comparison, and inline `itoa`/`ftoa`.
  - [ ] Lower `exit` to raw platform syscall instead of libc dynamic import.
  - [ ] Implement Linux/BSD `clone`-based isolates without `libpthread`.

---

## 10. Tooling & Test Infrastructure

- [x] **5-Digit Test Band Renumbering:** Standardized test directory bands (`00000_basic`, `10000_katsuro`, `20000_lindsay`, `30000_jenny`, `40000_runtime`, `50000_fuzz`).
- [x] **Fuzz Replay Mechanism:** Reversible compact hex `case_id` encoding implemented in `Brocken::Fuzz`.
- [ ] **Fuzzer Corpus Expansion (F0–F9):**
  - [ ] F0: Add `bool`, `i128`, `f64`, boxed `Int`, and `String` generators.
  - [ ] F3: Add array and class property mutation fuzzing.
  - [ ] F4/F5: Implement automated delta-debugging test case minimizer (`_minimize`).
- [ ] **Unified `bkn` CLI Tool:**
  - [ ] Build standalone `bkn` driver binary supporting `build`, `run`, `test`, `clean`, and `new`.
- [ ] **AST-Based Formatter (`bkn fmt`):**
  - [ ] Implement canonical AST pretty-printer (4-space indent, K&R braces, normalized spacing).
- [ ] **Language Server Protocol (`bkn lsp`):**
  - [ ] Implement stdio JSON-RPC daemon providing hover information, completions, and compiler diagnostics.
