# Brocken Compiler Roadmap

Now that the foundational IR (Lindsay) and Platform abstraction (Katsuro) are in place, we need to bridge the gap between abstract SSA and executable machine code.

## Active Sprint

### Brocken Class Refactoring
- [x] `Brocken->new()` constructor auto-selects codegen, linker, and ext based on platform
- [x] Migrated 13 test files from manual if/elsif/else chains to `Brocken->new()`:
      `3501`–`3508` (isolate/fiber), `3402`, `3405`, `3280`, `3150`, `3270`
- [x] Fixed `Brocken.pm:59`; `$platform->triple` → `$platform->friendly` (method didn't exist)
- [ ] **Remaining ~30 test files** still use manual codegen/linker selection; migrate to `Brocken->new()`

### macOS Intel CI Failures
- [x] **3505_isolate_args.t**; was generating ELF binaries on macOS (exit 126). Fixed by Brocken ADJUST (uses MachO linker on macOS).
- [x] **3502_isolate_fiber_interop.t**; SIGSEGV (`$?=11`) on macOS Intel. Root cause: fiber functions without a terminal `ret` fell through across function boundaries on resume. Fixed by adding second yield + ret to `fiber_a` in `202c0bd`.
- [x] **3503_multi_isolate.t**; Same SIGSEGV (`$?=11`). Same root cause as 3502.
- [x] Root-cause the fiber ctx_swap / isolate trampoline interaction on x86_64 Mach-O. — `r12` was being clobbered in the ctx_swap restore loop; skipped restore since r12 already holds target FCB (step 6 of x86_64 ctx_swap). Fixed in `202c0bd`.
- [ ] **Other macOS failures**; check remaining isolate/fiber tests on macOS Intel after the above fixes.

### Isolate Return Values
- [x] `isolate_join` IR + lowering on all 4 native targets
- [x] `isolate_join` with retval slot on X86_64, ARM64, RISCV64
- [ ] `isolate_join` passes NULL retval; doesn't capture thread result

## Phase 1: Lowering & Instruction Selection (Jenny Expansion)
- [x] Implement a `Lowerer` that converts SSA `Lindsay` IR into platform-specific "Machine IR" (MIR).
- [x] Support complex addressing modes in MIR (`[base + disp]` via `mem` operands).
- [x] Implement instruction selection (Lowerer + Encoder pipeline) for `X86_64`, `ARM64`, `RISCV64`, and `Wasm`.
- [x] Handle "Fat Scalar" (dynamic) operations in the backend (lowering `box`/`unbox`) for all 4 targets.
- [x] Implement memory ops (`alloca`/`load`/`store`/`store_imm`) for all 4 targets.
- [x] Fix operand size selection in encoders (32-bit vs 64-bit load/store) for x86_64, ARM64, RISCV64.
- [x] Support indexed addressing modes in MIR (`[base + index * scale + disp]`).
- [x] Implement `mul` lowering for `X86_64`, `ARM64`, `RISCV64`.
- [x] Implement control flow lowering (conditional branches, jumps) for If/Else and Loops.
- [x] Implement multi-function support (lower `call` IR to cross-function calls, link multiple functions) [all 4 backends + all 3 linkers + Wasm]

## Phase 2: Register Allocation

### Core Allocator
- [x] Linear scan register allocator implemented in `RegAlloc::LinearScan`.
- [x] Uses all available caller + callee registers from platform (not just `rax`).
- [x] Fixed-point dataflow liveness analysis (backward, CFG-aware via block successors/predecessors).
- [x] Spill code insertion integrated into all 3 native codegens (X86_64, ARM64, RISCV64)  handles reload-before-use, spill-after-def, and `mem` operand base vregs.
- [x] `mem` operand bases tracked in liveness analysis (fixed the float crash bug).
- [x] `_vreg_names_from_mem_operands` extracts vreg names from `mem(base="%vreg")`.

### Calling Conventions
- [x] **Proper unified stack frame**  single-frame allocation combining callee-saves + spill slots, aligned to 16 bytes.
- [x] **Spill slot offsets**  relative to `$stack_reg` (RSP/SP), correct.
- [x] **RISCV64 prologue/epilogue**  integrates allocator's `used_callee` list; saves/restores int + FP registers.
- [x] **ARM64 leaf detection**  skips `x30` save/restore for leaf funcs.
- [x] **Leaf function optimization**  X86_64 now skips all prologue/epilogue for leaf functions without a frame (no calls, no callee saves, no spills, no alloca). Shadow space only allocated on Windows for non-leaf functions.
- [x] **Caller-save register handling**  `insert_caller_save_code` called in all 3 native codegen pipelines, skipping return registers (`rax`/`xmm0`, `x0`/`v0`, `a0`/`fa0`).
- [x] **Move coalescing**  `remove_redundant_moves` called in all 3 native codegen pipelines, eliminates `mov` where src/dst map to the same physical register.
- [ ] **Floating-point callee-save on X86_64**  SysV ABI marks all XMM as caller-saved; codegen only uses `PUSH` (GP-only). Would need `MOVUPS`/`MOVDQA` stack save/restore for non-SysV ABI variants.

### ABI Integration
- [x] All 4 Lowerers query `param_registers()`, `return_register()`, `fp_return_register()` from `Platform::ABI`.
- [ ] **Wide-type register pairs**  no `param_pair_registers()` or equivalent exists. i128 returns hard-code the second register (`rdx`/`x1`/`a1`) instead of querying the ABI.

### 128-bit Numerics (i128)
- [x] i128 binops (add/sub/and/or/xor/shl/lshr/ashr/mul)  all 4 targets.
- [x] i128 return values are correctly split into lo/hi across two registers on native targets.
- [x] i128 load/store on all 4 targets, via `_split_i128`.
- [ ] **i128 call arguments**  not split; passes single i128 values through registers designed for 64-bit scalars.
- [ ] **i128 entry block parameters**  not split; same issue as call arguments.
- [ ] **Signed i128 div/rem**  all targets use unsigned algorithm; no sign-extension or absolute-value handling.
- [ ] **i128 `min`/`max`**  not implemented on any target for i128 width.
- [ ] **Large-value i128 tests**  all test values fit in 64 bits; no hi-part carry/borrow exercised.
- [ ] **Endianness**  no handling for big-endian targets.

### OS-level Threads (Isolates)
- [x] IR instructions (`isolate_create`/`isolate_join`) in Lindsay IR + Builder
- [x] `call_indirect` MIR opcode on all 4 targets (X86_64 `FF /2`, ARM64 `BLR`, RISCV64 `JALR`, Wasm stub)
- [x] FCB.os_thread pointer (ICB) at offset 72/120/128, updated `fcb_sz` in all lowerers + codegens
- [x] Main thread ICB allocation in fiber init wrapper
- [x] X86_64 isolate_create lowering + isolate_join lowering (pthread_create/pthread_join)
- [x] X86_64 isolate trampoline MIR function + `call_indirect` dispatch
- [x] ARM64 isolate_create lowering + isolate_join lowering
- [x] ARM64 isolate trampoline MIR function
- [x] RISCV64 isolate_create lowering + isolate_join lowering
- [x] RISCV64 isolate trampoline MIR function
- [x] `pthread_join` added to ELF64 and Mach-O linker imports
- [x] Conditional trampoline emission (only when isolate ops present)
- [x] Compiled isolate runtime test (spawn + join + verify lifecycle)
- [ ] **Isolate return value propagation**  `isolate_join` passes NULL retval; doesn't capture thread result
- [ ] Wasm isolate stubs (lowerer + codegen)
- [ ] Cross-isolate message passing (transferable objects)

## Phase 3: The Frontend (Parser & AST)
- [ ] Define the "Brocken Subset" of Perl for self-hosting (variables, subs, basic control flow).
- [ ] Implement Lexer and Parser.
- [ ] **Gradual Typing & Native Builtins:** Introduce syntax for raw machine types (`my ptr $x`, `my i64 $y`) to bypass Fat Scalar overhead.
- [ ] **Pseudo-Namespace Intrinsics:** Recognize calls like `Brocken::load_i64($ptr)` or `Brocken::ptr_add($p, $offset)` in the parser and lower them directly to single MIR instructions, enabling us to write the runtime in Perl.
- [ ] Implement AST to Lindsay IR Codegen pass.

## Phase 3: The Frontend (Katsuro)
- [ ] Define the "Brocken Subset" of Perl for self-hosting (variables, subs, basic control flow).
- [ ] Implement Lexer and Pratt Parser.
- [ ] **Gradual Typing & Native Builtins:** Introduce syntax for raw machine types (`my ptr $x`, `my i64 $y`) to bypass Fat Scalar overhead.
- [ ] **Pseudo-Namespace Intrinsics:** Recognize calls like `Brocken::load_i64($ptr)` or `Brocken::ptr_add($p, $offset)` in the parser and lower them directly to single MIR instructions, enabling us to write the runtime in Perl.
- [ ] Implement AST to Lindsay IR Codegen pass.

## Phase 4: Self-Hosted Runtime & Memory Management (`core.brocken`)
*Architecture Note: Brocken uses "Isolates" (share-nothing OS threads) and cooperative fibers. Because heaps are entirely thread-local, Garbage Collection and Reference Counting require **zero atomic locks**.*

- [ ] **Fat Scalar Layout:** Define the universal value struct using the native subset (Type Tag, RC, Cycle-Detector Mark, Payload).
- [ ] **Immediate RC:** Implement `incref` and `decref` builtins. Guarantee deterministic `DESTROY` blocks.
- [ ] **Bacon & Rajan Trial Deletion:** Implement the cycle collector to reap uncollectable circular references via the Isolate's Suspect Buffer.
- [ ] **RC Immix Allocator:** Implement 32KB block / 256-byte line bump-pointer allocation in the Perl subset.
- [ ] **Fiber Stack Scanning:** Implement logic to walk the stacks of suspended fibers to find live GC roots.
- [ ] **UTF-8 Everywhere Strings:** Implement native string operations assuming pure UTF-8 payloads.
- [ ] **Self-Hosted PerlIO:** Implement a vtable-based layered I/O system (e.g., `:unix` raw bytes -> `:utf8` validation).

## Phase 5: Optimization & GC Lowering (Lindsay Middle-end)
- [ ] **RC Insertion Pass:** Automatically insert `incref` and `decref` IR instructions around variable assignments. Utilize the Defer Stack to emit `decref` operations at scope exits.
- [ ] **RC Elision & Reuse (Perceus-lite):** Optimize away redundant `incref`/`decref` pairs. If an object is uniquely owned (RC==1), mutate it in place rather than allocating a copy.
- [ ] Constant Folding & Dead Code Elimination (DCE).
- [ ] **Stack Map Generation:** Update `Jenny::Linker` to emit a `.brocken_stackmaps` section so the GC knows exactly which physical registers and stack slots hold pointers during a fiber yield.
