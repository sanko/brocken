# Brocken Compiler Roadmap

Now that the foundational IR (Lindsay) and Platform abstraction (Katsuro) are in place, we need to bridge the gap between abstract SSA and executable machine code.

## Open work by namespace

The sections below are ordered by when the work was found and why. This is the same
open work seen from the other side: which namespace owns it. Each line points at the
section carrying the detail, so nothing here is stated twice.

### `Brocken::Katsuro` — front end

Lexer, parser, AST, `Katsuro::Lowerer`, and the `Platform`/`ABI` classes. A fix here
changes what every target is handed.

- Dynamic (boxed) types at top level — [Upcoming](#upcoming)
- Hash support — [Upcoming](#upcoming)
- RC injection into the frontend lowerer (`build_incref` on assignment, `build_decref` on scope exit) — [R1](#r1-immediate-reference-counting-ir--runtime)
- Float-to-bool assignment is not normalized to 0/1 — [Open](#open)
- Mixed-width signed/unsigned comparison compares at 32 bits — [Open](#open)

### `Brocken::Lindsay` — the IR

Types, values, instructions, blocks, functions, and the builder. Work here needs an
instruction or an IR pass, not a change to any one target.

- Perceus: borrow inference, RC elision, reuse analysis, FBIP — [R4](#r4-perceus-rc-elision--reuse-lindsay-optimizer-pass)
- `fptrunc`/`fpext`, so mixing `f32` and `f64` is not a hard error — [Open](#open)
- `fptoui`, plus a chosen NaN and overflow rule for float→int — [Open](#open)
- Source locations carried through to diagnostics — [Upcoming](#upcoming)
- Channel instructions stay stubs until the data structure exists — [Channels](#channels-blocked-until-immix-allocator)

### `Brocken::Jenny` — back end

MIR, the per-target lowerers, register allocation, codegen, and the linkers. Work here
is per architecture or per object format.

- Fat scalar `box`/`unbox` layout at `[ptr+0]` and `[ptr+8]` — [R0](#r0-fix-fat-scalar-layout-prerequisite-for-all-rc-work)
- Unsigned 128-bit div/rem — [128-bit Numerics](#128-bit-numerics-i128)
- Big-endian targets, which no lowering handles — [128-bit Numerics](#128-bit-numerics-i128)
- Mixed integer/floating arguments wrong on x86-64 Linux ELF — [Known Bugs](#known-bugs)
- Floating-point callee-save on X86_64 — [Calling Conventions](#calling-conventions)
- f32 conversions unverified on ARM64 and Wasm — [Open](#open)
- Channel lowering past the stubs — [Channels](#channels-blocked-until-immix-allocator)
- ARM64 macOS varargs register save area, needs a run on Apple Silicon — [Known Issues (Remaining)](#known-issues-remaining)
- illumos isolate segfaults — [Untouched by this series](#untouched-by-this-series)
- A stack map section for GC root enumeration — [R5](#r5-future-runtime-work)

### Runtime and fuzzer

Neither is a stage of the compiler, so neither is a namespace.

- `incref`/`decref`, the Immix allocator, trial deletion — [Phase 4](#phase-4-self-hosted-memory-management-corebrocken)
- Fiber stack scanning, UTF-8 strings, self-hosted PerlIO — [R5](#r5-future-runtime-work)
- Fuzzer expansion, phases F0–F9 — [Fuzzer Expansion Plan](#fuzzer-expansion-plan)
- How these bugs are found and what the tests have to execute — [Test-process lessons](#test-process-lessons)

## Active Sprint: Memory Management Runtime (R0–R1)

### R0: Fix Fat Scalar Box Layout
- [ ] Change `box` in all 4 MIR lowerers: store header word (packed refcount+flags+tag+pad) at `[ptr+0]`, payload at `[ptr+8]` instead of payload at `[ptr+0]` and tag at `[ptr+8]`
- [ ] Change `unbox` to load payload from `[ptr+8]` instead of `[ptr+0]`
- [ ] Update `_type_tag` and related metadata
- [ ] Tests in `t/4000_runtime/`

### R1: Immediate Reference Counting
- [ ] Implement `Brocken::Runtime::incref`/`decref` in `core.brocken` (load u16 at `[ptr+0]`, inc/dec, store; decref to 0 → free)
- [ ] Wire RC injection in frontend Lowerer (`Katsuro/Lowerer.pm`) - `build_incref` on assignment, `build_decref` on scope exit
- [ ] Change `box` from `alloca` to heap allocation via `bump_alloc`
- [ ] Tests in `t/4000_runtime/`

## Earlier Completed Sprints

### Brocken Class Refactoring
- [x] `Brocken->new()` constructor auto-selects codegen, linker, and ext based on platform
- [x] Migrated 13 test files from manual if/elsif/else chains to `Brocken->new()`:
      `3501`–`3508` (isolate/fiber), `3402`, `3405`, `3280`, `3150`, `3270`
- [x] Fixed `Brocken.pm:59`; `$platform->triple` → `$platform->friendly` (method didn't exist)
- [x] Migrated all native tests (no runtime codegen/linker): `3020_regalloc.t`, `3030_regalloc_frame.t`
- [x] **Linker-format tests** (`3110_elf.t`, `3120_pe.t`, `3130_macho.t`, `3140_ffi.t`) intentionally test specific linker formats; cannot use `$brocken->linker` since that returns the host linker. All pass.
- [x] **Cross-platform lowering tests** (`3250_gep.t`, `3260_i128_lowering.t`, `3401_fiber_lowering.t`) explicitly test each arch's lowerer (X86_64, ARM64, RISCV64, Wasm); not about codegen/linker selection. All pass.

### macOS Intel CI Failures
- [x] **3505_isolate_args.t**; was generating ELF binaries on macOS (exit 126). Fixed by Brocken ADJUST (uses MachO linker on macOS).
- [x] **3502_isolate_fiber_interop.t**; SIGSEGV (`$?=11`) on macOS Intel. Root cause: fiber functions without a terminal `ret` fell through across function boundaries on resume. Fixed by adding second yield + ret to `fiber_a` in `202c0bd`.
- [x] **3503_multi_isolate.t**; Same SIGSEGV (`$?=11`). Same root cause as 3502.
- [x] Root-cause the fiber ctx_swap / isolate trampoline interaction on x86_64 Mach-O. - `r12` was being clobbered in the ctx_swap restore loop; skipped restore since r12 already holds target FCB (step 6 of x86_64 ctx_swap). Fixed in `202c0bd`.
- [x] **Other macOS failures**; Mach-O import stub recalculation used base GOT RVA instead of per-function GOT slot RVA, causing all import stubs (pthread_create, pthread_join, dlopen, dlsym) to point to dlopen's GOT slot. Fixed by storing per-stub GOT offset and recomputing absolute RVA from current GOT base.

### Isolate Return Values
- [x] `isolate_join` IR + lowering on all 4 native targets
- [x] `isolate_join` with retval slot on X86_64, ARM64, RISCV64
- [x] `isolate_join` passes NULL retval; doesn't capture thread result (Mach-O import stub fix)

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

### Known Bugs
- [ ] **A sum of many mixed integer and floating-point arguments comes back wrong on the x86-64 Linux ELF target**  a function taking both files at once, `sub g(i64 $i8, ..., f64 $f1) -> f64 { return $i8 + ... + $f1; }`, returns a sum that is not the sum. 7+7 is correct, 8+8 returns 75 instead of 72, 10+10 returns 111 instead of 110. The same source is correct on `x86_64-pc-windows-gnu` at every count tried, so the frame and the argument files are not the whole of it. The wrong answer tracks register pressure and nothing else: taking one register out of the pool at the baseline, with no change to any reload code, reproduces the 8+8 wrong answer exactly, and produces a third wrong answer at 10+10, so this is not a fault in the spill-reload path added with `spill_addr_temp`. Only observable when a foreign target is actually executed, which needs `BROCKEN_SYSROOT*` to be set; `t/3000_jenny/3200_codegen/3300_stack_arguments.t` covers it and fails on this target at 10+10 today. Not investigated further; the allocator change is not the cause and the two need to be tracked apart.

### Fixed
- [x] **A store through a spilled address reloaded its value over the address (all backends)**  every parameter is given an `alloca` cell, and the cell's address is a virtual register that is live for the whole body when several parameters are read in one expression. Past about 14 live ones the allocator spills most of those addresses, and there was a single scratch register for all reloads, so a store that needed both a reloaded address and a reloaded value loaded the value over the address and then wrote through it; the address was usually a small integer, so the program took an access violation. Boundary on x86-64: a sum of 14 live parameters is correct, 15 crashes. The allocator now reserves a second scratch, `spill_addr_temp`, alongside `spill_temp`. The reserve is made on a second pass, and only when the first pass actually produced a collision, because taking a register out of the pool unconditionally shrinks it for every function and changes assignments that were already correct. When there is no register outside the pool left to use, the reserve falls back to the callee set and is reported in `used_callee`, which costs an extra prologue save. Covered by `t/3000_jenny/3200_codegen/3301_spilled_address_store.t`.
- [x] **RISC-V floating-point arguments and return were placed in `ft0`, not `fa0`**  `RISCV64::fp_param_registers` began at `f0` and `fp_return_register` was `f0`, but under LP64D the floating-point arguments arrive in `fa0`-`fa7` (spelled `f10`-`f17`) and a result returns in `fa0`. `f0`-`f7` are the scratch registers `ft0`-`ft7`, which the callee is free to clobber, so an argument could be overwritten and an interop call reached a register external code did not use. Nothing failed internally because both halves of the call agreed on the wrong register; the lowerer already indexes the two register files independently, so only the declared register names were wrong. They now start at `fa0`, and `t/3000_jenny/3200_codegen/3302_riscv_float_argument_registers.t` reads the lowering to check the caller places and the callee reads `f10`/`f11` and returns in `f10`.
- [x] **Win64 parameter registers are not positional**  `X86_64_Win64::param_registers` returned 4 GP registers and `fp_param_registers` 4 XMM registers as two independently sized files, so a mixed argument list used the second xmm before the first argument position was reached and the 5th argument of either class overflowed to the stack. The real Microsoft x64 convention numbers positions 1-4 across both classes  the first argument is `rcx` or `xmm0`, the second `rdx` or `xmm1`, and so on, and the fifth and later arguments go on the stack whatever their class. The placement rule now lives on `Platform::ABI::argument_locations`, which takes the class of each argument and returns the register pair or stack slot it goes to; the base implementation keeps the independent per-class counters SysV, AArch64, and RISC-V use, and `X86_64_Win64` sets `positional_arguments` so the x86-64 lowerer numbers positions across both files. Both the entry-parameter walk and the call-argument walk in `Jenny::Lowerer::X86_64` consume that result, so the two halves of a call cannot disagree. `t/3000_jenny/3200_codegen/3303_win64_argument_positions.t` checks the Win64 and SysV placements against each other and reads the lowering to verify the callee captures and the caller passes an f64 that follows the hidden parameters in `xmm3`.

### Calling Conventions
- [x] **Proper unified stack frame**  single-frame allocation combining callee-saves + spill slots, aligned to 16 bytes.
- [x] **Spill slot offsets**  relative to `$stack_reg` (RSP/SP), correct.
- [x] **RISCV64 prologue/epilogue**  integrates allocator's `used_callee` list; saves/restores int + FP registers.
- [x] **ARM64 leaf detection**  skips `x30` save/restore for leaf funcs.
- [x] **Leaf function optimization**  X86_64 now skips all prologue/epilogue for leaf functions without a frame (no calls, no callee saves, no spills, no alloca). Shadow space only allocated on Windows for non-leaf functions.
- [x] **Caller-save register handling**  `insert_caller_save_code` called in all 3 native codegen pipelines, skipping return registers (`rax`/`xmm0`, `x0`/`v0`, `a0`/`fa0`).
- [x] **Move coalescing**  `remove_redundant_moves` called in all 3 native codegen pipelines, eliminates `mov` where src/dst map to the same physical register.
- [x] **X86_64 outgoing stack arguments**  the area was not counted anywhere: the caller wrote them through a captured `%rsp.N` virtual register, so `_compute_spill_frame` never saw them and the spill/alloca/callee-save area began at the bottom of the frame, directly underneath. A call that overflowed the register file wrote its arguments over the caller's own saved registers, and it took 9 arguments before that was visible. The lowerer now emits them against the physical `rsp` tagged `raw => 'stack'`, `_compute_call_arg_frame` reserves them at the bottom of the frame, and `_compute_spill_frame` ignores raw operands so the two sets of displacements are disjoint by construction. Reserved in the prologue rather than pushed at the call, which is what keeps the allocator's spill slots valid across the call and rsp 16-byte aligned.
- [x] **Physical `rsp` is not a vreg**  `_vreg_names_from_mem_operands` treated a memory operand based on the stack register as naming a virtual register, which could hand the name an interval and a spill slot. It now skips the platform's stack register, and `mem_modrm` resolves a raw operand's stack base physically instead of looking it up in the allocation table.
- [x] **X86_64 incoming stack arguments tagged `raw => 'entry'`**  they were read through the `%__frame_base` capture with no tag, so they were indistinguishable from allocator-placed slots. Tagging them is what lets `_compute_spill_frame` and `_compute_call_arg_frame` tell the convention's displacements from the allocator's.
- [ ] **Floating-point callee-save on X86_64**  SysV ABI marks all XMM as caller-saved; codegen only uses `PUSH` (GP-only). Would need `MOVUPS`/`MOVDQA` stack save/restore for non-SysV ABI variants.

### ABI Integration
- [x] All 4 Lowerers query `param_registers()`, `return_register()`, `fp_return_register()` from `Platform::ABI`.
- [x] **Wide-type register pairs**  `Platform::ABI` now answers both halves of a 128-bit register pair: `param_pair_registers($spent)` returns the consecutive parameter registers a wide argument takes once `$spent` integer registers are in use, and `return_pair_registers()` returns the pair a wide result comes back in. The base class derives the parameter pair from `param_registers` and defaults the return pair to the single `return_register`; `X86_64` (and so `X86_64_Win64`), `AArch64`, and `RISCV64` name `rax:rdx`, `x0:x1`, and `a0:a1`. The entry-parameter and call-argument walks in the ARM64 and RISC-V lowerers and the i128 return paths in all three native lowerers query the ABI instead of naming the second register themselves. `t/3000_jenny/3200_codegen/3304_wide_return_register_pairs.t` checks the pairs and reads the lowering on every backend from any host.

### 128-bit Numerics (i128)
- [x] i128 binops (add/sub/and/or/xor/shl/lshr/ashr/mul)  all 4 targets.
- [x] i128 return values are correctly split into lo/hi across two registers on native targets.
- [x] i128 load/store on all 4 targets, via `_split_i128`.
- [x] **i128 call arguments**  split into lo/hi across two consecutive param registers in all 4 lowerers.
- [x] **i128 entry block parameters**  split into _lo/_hi virt_regs at the entry block, consuming two param regs.
- [x] **i128 call return capture (ARM64, RISCV64, Wasm)**  caller now reconstructs _lo/_hi from both return registers (x0/x1, a0/a1, Wasm stack) - was only done on X86_64.
- [x] **Signed i128 div/rem**  all targets use abs(inputs) + apply sign to output.
- [x] **i128 `min`/`max`**  implemented on all 4 targets (X86_64, ARM64, RISCV64, Wasm).
- [x] **Large-value i128 icmp tests**  added native (246 tests) and Wasm (328 tests) execution tests with Math::BigInt constants > 2^64.
- [ ] **Unsigned 128-bit div/rem**  only the signed form is implemented; all targets use abs(inputs)
      + sign on the output, so a `u128` division or remainder runs the signed path and gives the
      wrong answer for operands with bit 127 set. The fuzzer omits `u128` generation until this
      exists.
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
- [x] **Isolate return value propagation**  `isolate_join` passes NULL retval; doesn't capture thread result - fixed by Mach-O import stub fix (stubs pointed to dlopen, not pthread_join)
- [x] Wasm isolate stubs (lowerer) - `isolate_create`/`isolate_join` return `i64_const 0` placeholder

## Active Sprint: Katsuro Frontend (Bootstrapping Subset v0.1)

### Completed: Language Features
- [x] **Subset spec:** `docs/spec.md §2.16` - formal Brocken v0.1 bootstrapping language spec
- [x] **Lexer:** Finite-state tokenizer with keywords, sigils, numbers, strings, operators
- [x] **AST nodes:** Program, VarDecl, Assign, Block, If, While, Return, BinOp, UnOp, Const,
      Var, Ident, Paren, Call, IntrinsicCall, SubDecl, ClassDecl, FieldDecl, ArrayDecl, ArrayIndex
- [x] **Parser:** Recursive descent (statements) + Pratt parser (expressions) -
      handles all v0.1 constructs including arrays, classes, methods, field access, `use feature`
- [x] **Compiler orchestrator:** `Brocken` - lex → parse → AST
- [x] **Tests:** 25 parser subtests; 26 lowerer subtests; 19 integration subtests (all passing)

### Completed: Lowering & Pipeline
- [x] **AST→Lindsay IR Lowerer:** Two-pass conversion of `AST::Program` into `Lindsay::IR::Module`
      with blocks, instructions, and SSA values using the existing Builder API.
      Handles: sub decl, class methods, var decl/assign, if/elsif/else, while, return,
      binops, unops, comparisons, function calls, Brocken::* intrinsics, say/print, arrays,
      field access, auto-generated readers/writers/constructors, ADJUST blocks.
- [x] **End-to-end pipeline:** Wire Compiler output into Jenny codegen + linker → runnable binary.
      Test compiles v0.1 programs, codegens, links, executes, and verifies exit codes.
      19 subtests covering: constants, vars, arithmetic, if/else, while, comparisons,
      function calls, factorial, logical not, class constructors, readers, writers,
      custom methods, ADJUST, direct field read/write, implicit main, arrays, i128.

### Completed: Array Support
- [x] **ArrayDecl AST node** - parses `my i64 @arr = [10, 20, 30];`
- [x] **ArrayIndex AST node** - parses `$arr[0]` for both read and write
- [x] **Lowering** - alloca with element count, GEP for element access, load/store

### Completed: Class Methods & Auto-Generated Accessors
- [x] **Method declarations** - `method foo() -> TYPE { ... }` inside class, lowered as `ClassName::foo`
- [x] **`:reader` attribute** - auto-generates getter method
- [x] **`:writer` attribute** - auto-generates setter method (`set_<name>`)
- [x] **`:param` attribute** - auto-generates constructor (`ClassName->new(...)`)
- [x] **ADJUST block** - runs after constructor assigns :param fields
- [x] **`__CLASS__` expression** - compile-time class name constant
- [x] **MethodCall expression** - `$obj->method(args)` lowered to `ClassName::method($obj, args)`

### Completed: Implicit Entry Point
- [x] **`sub main` is just a function** - no special heap param, no automatic invocation
- [x] **Top-level code becomes `_BROCKEN_ENTRY`** - internal function with heap_base param
- [x] **All codegen/linker paths** - replaced `main` references with `_BROCKEN_ENTRY`
- [x] **Parser filters `use feature`** - returns `undef` statements filtered in `parse_program`

### Known Issues (Remaining)

- [ ] **ARM64 macOS: int-to-string via `sprintf` varargs** - ARM64 AAPCS requires 64-byte register save area for variadic calls. Fixed in Codegen/ARM64.pm (`sub sp, #64` / `add sp, #64` around `call_func`/`call_indirect`). Needs testing on Apple Silicon.

### Known Issues (Resolved)
- [x] **RISC-V `3125_rodata.t` failure - undef param name:** Entry param handler in all three lowerers (`X86_64.pm`, `ARM64.pm`, `RISCV64.pm`) used `$param->name` directly as the `virt_reg` value. When `Value->new(type => ptr())` is created without a name (as in test `3125_rodata.t`), `$param->name` is undef, creating a MIR operand with undef value. Fixed: all three lowerers now declare `$param_name` with a synthetic fallback (`%pN`) when name is undef, and use it consistently for all virt_reg creations (i128 split, entry temps, main virt_reg).
- [x] **RISC-V RodataRef routing:** Call handler, box-store, and incref/decref in Lowerer/RISCV64.pm now route `RodataRef` through `_materialize` instead of `_lower_opnd`, preventing undef virt_regs.
- [x] **RISC-V codegen defensive guards:** Codegen/RISCV64.pm added undef-value checks - `$reg_id` returns `0` if `$r` is undef; `$resolve` dies with `"resolve: operand value is undef"` if `$op->value` is undef. This caught the param_name bug above.
- [x] **macOS ARM unnamed-arg stack passing:** Lowerer/ARM64.pm passes `num_named`+`num_unnamed` as extra `call_func` operands on macOS ARM; Codegen/ARM64.pm emits `sub sp, #(N*8)`, `str` for each unnamed arg, BL, `add sp, #(N*8)` - only on macOS ARM. Non-macOS keeps original `sub sp, #64` / `add sp, #64`.
- [x] **Duplicate block names in MIR codegen:** Fixed - Lowerer now generates unique block names via `$block_id` counter.
- [x] **`terminator` returned last instruction regardless of type:** Fixed - now checks `isa` for Ret/Br/CondBr.
- [x] **SSA name collisions on var ref:** Fixed - `lower_var_ref` no longer passes explicit names to `build_load`.
- [x] **`as_condition` i1 detection:** Fixed - now checks `bits == 1` instead of `kind eq 'i1'`.
- [x] **Class runtime ordering:** ClassDecls now generate before SubDecl bodies in Pass 2, so auto-generated methods exist when entry function body calls them.

### Upcoming
- [ ] **Dynamic (boxed) types at top level:** `my Int $x = 10` currently lowers like `i64`; needs actual box allocation
- [x] **String support:** String literals, `say("hello")`, `.` concatenation (RodataRef fold + runtime CRT)
- [ ] **Debug info:** Source location tracking through the pipeline (line numbers in errors)
- [ ] **Better error messages:** Report source line + column for parse/lower/codegen errors
- [ ] **Hash support:** `%` hashes, basic key-value storage
- [ ] **Write `core.brocken`:** Start implementing runtime primitives (allocator, channels) using v0.1 subset

## Deferred (post-frontend)

### Channels (blocked until Immix allocator)
- [x] **IR instructions:** `chan_create`, `chan_send`, `chan_recv`, `chan_close`, `chan_try_send`, `chan_try_recv` (IR.pm + Builder.pm)
- [x] **Lowering stubs (all 4 targets):** Wasm + X86_64 + ARM64 + RISCV64 return 0 / no-op
- [x] **Tests:** Lowering tests (MIR opcode verification on all 4 targets) + IR render tests
- [x] **Doc:** Interface spec defined in `docs/spec.md §5.3` + Mermaid diagrams
- [x] **Linker imports:** Added mutex/condvar symbols (pthread_mutex_lock/unlock, pthread_cond_wait/signal/broadcast) to ELF64, MachO, and PE linkers
- [ ] **Channel data structure:** Global fixed-size table in .data section
- [ ] **Lowering (X86_64/ARM64/RISCV64):** Inline pthread_mutex/pthread_cond sequences
- [ ] **Runtime tests:** Two-isolate send/recv (native, compiled execution)

## Phase 4: Self-Hosted Memory Management (`core.brocken`)
*Architecture Note: Brocken uses "Isolates" (share-nothing OS threads) and cooperative fibers. Because heaps are entirely thread-local, Garbage Collection and Reference Counting require **zero atomic locks**.*

### Overview: Three-Layer Memory Architecture

```
┌──────────────────────────────────────────────┐
│  Layer 3: Perceus (RC Elision + Reuse)       │  Lindsay Optimizer
│  - Cancel redundant incref/decref pairs      │  (compile-time IR pass)
│  - In-place mutation when refcount == 1      │
│  - Borrow inference                          │
├──────────────────────────────────────────────┤
│  Layer 2: Bacon/Rajan Trial Deletion         │  runtime + ICB
│  - Suspect buffer in ICB (ptrs 48-56)        │
│  - Mark/Scan/Collect cycle detection         │
│  - Recovers cyclic garbage                   │
├──────────────────────────────────────────────┤
│  Layer 1: Immediate RC + Immix Allocator     │  core.brocken + ICB
│  - incref/decref on fat scalar refcount      │
│  - Immix: 32KB blocks / 256-byte lines       │
│  - Bump allocation within current line       │
└──────────────────────────────────────────────┘
```

### Fat Scalar Layout (Revised - MUST match spec)

The 16-byte dynamic value (`Any` type) layout, enforced by `box` lowering:

```
Offset  Size  Field
0       2     Reference Count (u16, max 65535; overflow pins object)
2       1     GC Flags (Bit 0: Cycle Suspect, Bit 1: Buffered, Bit 2: Leaf)
3       1     Type Tag (0=Int, 1=String, 2=Array, 3=Class, 4=Ptr, 5=Dynamic, 6=i128)
4       4     Padding / Aux (e.g., String cached char length)
8       8     Payload (Raw u64/i64/f64/ptr)
```

Total: 16 bytes. The current `box` lowering stores payload at offset 0 and tag at offset 8 - this must be changed to match the spec layout above before RC can work.

### Phase Plan

#### R0: Fix Fat Scalar Layout (prerequisite for all RC work)
- [ ] Change `box` lowering in all 4 MIR lowerers:
  - `alloca 16` stays the same
  - Instead of `store payload at [ptr+0]` and `store tag at [ptr+8]`:
    - `store_imm 0 at [ptr+0]` (zero-initialize refcount + flags + tag + padding as u64)
    - `store payload at [ptr+8]`
    - `store_imm tag at [ptr+3]` (tag byte at offset 3)
  - Wait: storing individual bytes is complex in MIR. Simpler approach:
    - Pack the header: `((padding << 32) | (tag << 24) | (flags << 16) | refcount)` as one u64
    - `store_imm header at [ptr+0]` (zero header = all zeros initially)
    - `store payload at [ptr+8]`
- [ ] Change `unbox` lowering to load from `[ptr+8]` instead of `[ptr+0]`
- [ ] All 4 backends: X86_64, ARM64, RISCV64, Wasm

#### R1: Immediate Reference Counting (IR → Runtime)
- [x] `incref`/`decref` IR instructions defined in Lindsay IR
- [x] `build_incref`/`build_decref` in Builder API
- [x] All 4 MIR lowerers already handle `Incref`/`Decref` → emit `call_func @Brocken::Runtime::incref`/`decref`
- [ ] **NEW:** Implement `Brocken::Runtime::incref(ptr)` and `Brocken::Runtime::decref(ptr)` in `core.brocken`:
  - `incref`: load u16 from `[ptr+0]`, if < 65535, increment by 1, store back
  - `decref`: load u16 from `[ptr+0]`, decrement by 1, store back; if result == 0, add to free list (or call DESTROY + free)
- [ ] **NEW:** Wire RC injection in frontend Lowerer (`Katsuro/Lowerer.pm`):
  - On variable assignment (`lower_assign`): emit `build_incref` on the new value
  - On scope exit (block end): emit `build_decref` for each local variable
  - On function return: emit `build_decref` for the return value's old binding
- [ ] **NEW:** Change `box` lowering to use heap allocation (via `Brocken::Runtime::bump_alloc`) instead of `alloca` so RC-managed objects live on the heap

#### R2: Immix Allocator
- [ ] Implement Immix allocator in `core.brocken`:
  - `BLOCK_SIZE = 32768` (32KB), `LINE_SIZE = 256` bytes, `LINES_PER_BLOCK = 128`
  - Line header in each block: 128-bit bitmap tracking which lines are available
  - `alloc_block(size)` → allocate or reuse a 32KB block from the ICB free list
  - `alloc_line(block)` → find next free line, mark as used, return line address
  - `alloc(size)` → bump-allocate within current line; if insufficient space, allocate a new line (or block if all lines full)
  - Block recycling: when all lines in a block are freed (via RC), return block to ICB free list
- [ ] Update ICB layout to track Immix state:
  - `immix_cursor` at ICB offset 24 (current bump pointer within current line)
  - `immix_limit` at ICB offset 32 (end of current block)
  - `free_blocks` at ICB offset 40 (linked list of free blocks)
  - `suspect_buffer_head/tail` at ICB offsets 48/56 (for trial deletion)
- [ ] Update entry stub and `_init` to initialize ICB fields
- [ ] Replace `Brocken::Runtime::bump_alloc` with Immix `alloc`
- [ ] Wire `box` → Immix allocator (instead of `alloca`)

#### R3: Bacon/Rajan Trial Deletion (Cycle Detection)
- [ ] Suspect buffer operations:
  - On `decref` where RC > 0 after decrement: push pointer to suspect buffer
  - `suspect_buffer_push(ptr)`: store ptr at ICB suspect_buffer_head, advance
  - `suspect_buffer_drain()`: called periodically, processes all suspects
- [ ] Mark phase: for each suspect, increment an internal "gc_mark" counter
- [ ] Scan phase: trace references from each suspect, decrement marks
- [ ] Collect phase: objects with mark == 0 are confirmed cyclic garbage - free them
- [ ] All implemented in `core.brocken`

#### R4: Perceus RC Elision & Reuse (Lindsay Optimizer Pass)
- [ ] **Borrow inference**: analyze function parameters to determine ownership (borrowed vs owned)
- [ ] **RC elision**: cancel redundant incref/decref pairs when a value is immediately used and dropped
- [ ] **Reuse analysis**: when constructing a new object, if the input is uniquely owned (RC==1), mutate in place instead of allocating
- [ ] **FBIP (Functional But In-Place)** fragment: linear type analysis guaranteeing no allocation at all for pure data transformations
- [ ] All implemented as Lindsay IR → IR optimization passes (no runtime changes)

#### R5: Future Runtime Work
- [ ] **Fiber Stack Scanning:** Walk stacks of suspended fibers to find live GC roots for accurate cycle detection
- [ ] **UTF-8 Everywhere Strings:** Native string operations assuming pure UTF-8 payloads
- [ ] **Self-Hosted PerlIO:** Vtable-based layered I/O system (e.g., `:unix` raw bytes → `:utf8` validation)
- [ ] **Stack Map Generation:** `.brocken_stackmaps` section for GC root enumeration

## Active Sprint: Type System Expansion

### Phase A: Type Infrastructure (Lowerer + IR)
- [x] Add `%TYPE_MAP` entries for `int`, `bool`, `u8`..`u128`
- [x] Fix `%TYPE_NATIVE_MAP` for `Int`/`Bool` (→ i64/i1, not dynamic)
- [x] Add signedness-aware widening to `maybe_convert_type` (zext/sext)
- [x] Add `zext`/`sext` IR instructions to `IR.pm` + `Builder.pm`
- [x] Backend: lower `zext`/`sext` on all 4 targets
- [x] Add signed/unsigned div/rem IR instructions (`udiv`/`urem`)
- [x] Backend: proper `movzx`/`movsx`/`UXTB`/`SXTB` encoding for zext/sext

### Phase B: Int/Bool native alias support
- [x] Lower `Int` and `Bool` as native types (i64/i1)
- [x] Update `maybe_convert_type` for Int→int aliasing
- [x] Constant lowering for `Int`/`Bool`
- [x] Parser: add `int`, `bool`, `u8`..`u128` keywords

### Phase C: String Constants & .rodata
- [x] Add `.rodata` section to linkers (ELF64, PE, MachO, Wasm)
- [x] Lower string literals to `.rodata` (length-prefixed, null-terminated)
- [x] Emit `lea`/ADRP+ADD to reference `.rodata` addresses
- [x] Wire `say`/`print` to `.rodata` strings (replace alloca+store)
- [x] `.` operator for compile-time string concat (RodataRef folding) + runtime concat (CRT calls via linker)
- [x] `.` operator with int/float operands - `_stringify` converts via `sprintf` with platform-appropriate format specifiers (`%lld`/`%I64d`)
- [x] `build_alloca` count wrapping - bare integer `$count` wrapped in `Constant` object (Builder.pm:226, fixes `"value" via package "64"` on ARM64/RISCV64/Wasm)

### Phase D: Struct Types (IR level)
- [x] Add structural type to IR: `Type::struct([field_types...], [field_names...])`
- [x] Extend GEP for struct field access (byte offset from struct layout) via `struct_field_idx` on GetElementPtr
- [x] Lower field access to struct-aware GEP: `build_struct_gep` in Builder; all field-access methods in Lowerer use it
- [x] Update all 4 codegen lowerers (X86_64, ARM64, RISCV64, Wasm) to handle struct-typed GEP

### Phase E: Signedness in Binop Lowering
- [x] Default signedness for `int` type (signed i64; same for `Int`)
- [x] Propagate signedness through `lower_binop`:
  - `/` → `div` (signed) or `udiv` (unsigned)
  - `%` → `rem` (signed) or `urem` (unsigned)
  - `<`/`>`/`<=`/`>=` → signed predicates (`slt`/`sgt`/`sle`/`sge`) or unsigned (`ult`/`ugt`/`ule`/`uge`)
- [x] Add `<<`/`>>` shift operators to parser + lexer; `>>` → `ashr` (signed) or `lshr` (unsigned)

## Debug Info / DWARF Gaps

### What's Implemented
- [x] DWARF v5 sections: `.debug_line`, `.debug_info`, `.debug_abbrev`, `.debug_frame`, `.debug_aranges`, `.debug_names`, `.debug_str`, `.eh_frame`, `.eh_frame_hdr`
- [x] Per-instruction byte offset tracking (`ir_inst_idx` → `source_map`)
- [x] Per-function `DW_AT_decl_file` attribute
- [x] Variable/parameter DIEs with name, type (`DW_AT_type` ref4), location (`DW_AT_location` exprloc `DW_OP_fbreg`), decl_line, decl_column, artificial
- [x] Struct type DIEs (`DW_TAG_structure_type` + `DW_TAG_member`) from `class_info`
- [x] Line/col on IR instructions (passed through `build_*` methods)
- [x] GDB backtrace end-to-end test (PE, `-readnow`)
- [x] All 4 backends (X86_64, ARM64, RISCV64, Wasm) with consistent DWARF output
- [x] Programmatic binary-structure validation test (`3218_dwarf_validate.t`)
- [x] Debug levels (0–5) controlling which DWARF sections are emitted
- [x] `DW_AT_producer` (`"Brocken v0.1"`) and `DW_AT_comp_dir` on compile_unit DIE
- [x] `DW_AT_linkage_name` on subprogram DIEs (same as function name)
- [x] `DW_AT_decl_line` (data2) and `DW_AT_decl_column` (data1) on variable/param DIEs
- [x] `DW_AT_artificial` (data1) on variable/param DIEs
- [x] `.eh_frame_hdr` generation with `DW_EH_PE_absptr` encoding (empty when `eh_frame_base` is 0)
- [x] `PT_GNU_EH_FRAME` program header pointing to `.eh_frame_hdr`

### Gap 9: No split DWARF / type units / DWARF compression
**Description:** All debug data is emitted inline in the executable. No `.debug_types` (type units), `.debug_cu_index`, or DWARF compression (`.zdebug_*`). This increases binary size for projects with many types or large source files.
**Impact:** Future optimization. Not relevant for current v0.1 subset.
**Priority:** Future
**Dependencies:** Would require linker changes (section name mapping for compressed sections) and structural changes to DWARF.pm to emit type units separately.

### Gap 10: Wasm source_map translation is fragile [x] Fixed
**Description:** The Wasm encoder records raw per-block offsets during encoding, but the flat `$bytes` buffer includes block headers (`0x02 0x40`), markers, and `0x0B` terminators that shift offsets. The translation in `build_debug_data` accounts for these, but the computation was complex and may not survive changes to Wasm block structure (e.g., adding new branch types).
**Status:** Fixed. The block_start computation is now inline with the assembly phase (tracks `$pos` during byte emission) instead of a separate post-phase calculation. A locals_size offset bug was also fixed (source_map offsets in `emit_functions` now include the locals prefix length so they align with the blob's `bytes` field). A comprehensive test (`3219_wasm_debug.t`) validates source_map offsets are within function byte range and monotonically increasing.
**Impact:** Low. Test provides regression coverage against block structure changes.
**Priority:** Low
**Dependencies:** Tied to Wasm encoder's block structure. Changing Wasm's structured control flow would require updating the inline offset tracking.

### Gap 11: Runtime functions share user source file for `DW_AT_decl_file` [x] Fixed
**Description:** All functions (user code + runtime helpers like `Brocken::Runtime::_init`) currently get `source_file => $source_file` in `build_debug_data`, so `DW_AT_decl_file` points to the user's source file for everything. Runtime functions should ideally reference a different source file (e.g., `core.brocken` or `<runtime>`).
**Status:** Fixed. Each backend's `build_debug_data` now checks `$fname =~ /^Brocken::Runtime::/` and sets `source_file => '<runtime>'` for those functions, including per-instruction source locations. The `source_files` array automatically picks up the distinct file name.
**Impact:** Low. GDB will now attribute runtime functions to `<runtime>` instead of the user's source file.
**Priority:** Low
**Dependencies:** None.

### Gap 12: All source_locs use implicit file index 0 [x] Fixed
**Description:** The line number program entries (source_locs) don't carry a file index. All source locations implicitly refer to the first file in the file table (index 0 → DWARF file index 1). If we ever have multiple source files contributing to one compilation unit, line entries can't distinguish them.
**Status:** Fixed. Added `file` field to source_locs entries in all 4 codegen backends. `build_debug_line` emits `DW_LNS_set_file` (opcode 0x04) when the file changes between consecutive entries, using a filename-to-index mapping built from the `source_files` list. A validation subtest in `3218_dwarf_validate.t` verifies multi-file line programs emit (0x04) with the correct file index. Entries without a `file` field default to `$source_file`.
**Impact:** Low. Enables multiple source files per compilation unit with correct line attribution.
**Priority:** Low
**Dependencies:** None. `source_files` / `file_idx` infrastructure was already in place.

### Gap 13: No GDB JIT interface for runtime-compiled (JIT) code
**Description:** Brocken supports loading new source at runtime (JIT compilation), but there is no mechanism to inform the debugger about the new code. GDB will not know about JIT'd functions, cannot set breakpoints in them, and backtraces through them will be opaque (no source lines, no variables).

The GDB JIT interface requires:
1. A `__jit_debug_register_code()` function - a no-op that acts as a GDB breakpoint target. GDB sets a breakpoint here and catches SIGTRAP when new code is registered.
2. A global `__jit_debug_descriptor` symbol of type `struct jit_descriptor`:
   ```c
   struct jit_code_entry {
       struct jit_code_entry *next_entry;
       struct jit_code_entry *prev_entry;
       const char *symfile_addr;   // pointer to in-memory ELF/DWARF image
       uint64_t    symfile_size;   // size of the image
   };
   struct jit_descriptor {
       uint32_t version;           // must be 1
       uint32_t action_flag;       // 0 = register, 1 = unregister
       struct jit_code_entry *relevant_entry;
       struct jit_code_entry *first_entry;
   };
   ```
3. The in-memory ELF image (`symfile_addr`) must be a valid ELF that GDB's BFD loader can parse. At minimum it needs:
   - ELF header (e_hdr) with correct e_machine, e_shoff pointing to section headers
   - At least one `.debug_info` section with valid DWARF CU pointing to the JIT code's PC range
   - `.debug_abbrev`, `.debug_line` sections referenced by the CU
   - Section header string table (`.shstrtab`) so GDB can find sections by name
   - `sh_size` must be actual data length (not padded allocation size) - see Gap 3 fix
   - `e_shoff` aligned to `e_shentsize` (64 bytes for ELF64) - see Gap 3 fix
4. Thread safety: the descriptor linked list must be updated under a lock (or atomically) since multiple threads may JIT simultaneously
5. CIE/FDE in `.eh_frame` or `.debug_frame` must use absolute addresses (`DW_EH_PE_absptr`) since relocations are not available at runtime - our current `.eh_frame_hdr` already uses absptr encoding

**Implementation plan:**
- Add a runtime helper function `__jit_debug_register_code()` (no-op, called by GDB breakpoint)
- Add a runtime global `__jit_descriptor` (initialized at program start)
- Add a `Brocken::Runtime::jit_register(elf_data)` function that:
  a. Allocates a `struct jit_code_entry`
  b. Appends it to the descriptor linked list
  c. Sets `action_flag = 0` (register)
  d. Sets `relevant_entry` to the new entry
  e. Calls `__jit_debug_register_code()`
- Modify `Brocken::Jenny::Linker::ELF64` (or add a new method) to produce a minimal in-memory ELF image containing only the DWARF sections for a given JIT unit, using `build_debug_data` output. This ELF image does NOT need a text section - GDB uses PC ranges from `.debug_aranges` / `DW_AT_low_pc`/`high_pc` to map addresses.
- The ELF image can be as small as the DWARF data plus minimal ELF/section headers (~4 KB typical for a small function)
- Test: create a minimal JIT ELF, feed it to GDB's `add-symbol-file` or the JIT interface, verify GDB can set breakpoints and backtrace through JIT'd code
- **Not required initially**: `.eh_frame` in the JIT ELF (runtime unwinding through JIT frames). `.debug_frame` is sufficient for GDB's `bt` command.

**Priority:** Medium (enables interactive debugging of JIT code)
**Dependencies:** All DWARF sections already JIT-ready (parameterized `text_base`, absolute encoding, proper section sizes). Needs a new ELF64 convenience method to wrap DWARF sections in a minimal in-memory ELF, plus the runtime glue (descriptor + registration function).

## Found Bugs: Float & Backend Correctness

Found while backporting float work from `dev` (branch `october2026`, 2026-09-30). Every item
here was reproduced against a natively compiled and executed binary, not read off the MIR.

### Fixed in this series

- [x] **Float literal stored at the wrong width** - a decimal literal is lexed as `f64`, so
      `my f32 $t = 1.5;` emitted a double-width store into a four-byte slot. The backends take
      a store/load/move width from an operand's type, so re-tagging the constant to the target
      type is the whole conversion (and where rounding to f32 happens). `aeb4e3f`
- [x] **`lower_binop` widened the wrong side** - when a literal and a value of different float
      widths met, it promoted the *value*, reinterpreting a four-byte pattern as eight. Now the
      literal is re-tagged instead. `aeb4e3f`
- [x] **Negative float literals were not folded** - `-1.5` became an `fneg` of a positive
      constant, and the result is not a `Constant`, so `my f32 $a = -1.0;` had nothing to
      re-tag and died. Folded for floats only; folding `-5` for an i64 is left alone since an
      unsigned neg is defined as wrapping. `aeb4e3f`
- [x] **Every ordered float comparison was false** - the frontend picked `slt`/`ult`/`sle`/...
      off `is_signed`, but neither backend's float table has those names (x86-64 `%fcond` at
      `Codegen/X86_64.pm:2434` is `lt/le/gt/ge`, ARM64 at `Lowerer/ARM64.pm:2974` is
      `cset_lt/...`). Affected `<`, `>`, `<=`, `>=` at *any* float width including f64.
      `==`/`!=` survived only because they are spelled the same for both. `1a8a713`
- [x] **x86-64 int<->float conversion always used the double form** - `cvtsi2sd`/`cvttsd2si`
      hardcoded the `F2` prefix, so an f32 was converted by reading or writing eight bytes of a
      four-byte value. The single-precision forms are the same opcodes under `F3`; the prefix is
      now taken from the float operand's type, matching how `fload`/`fstore`/`fmov` already
      choose. `cf4fef9`
- [x] **RISC-V int<->float conversion always used the double form** - the same bug as the x86-64
      one above, found by the RISC-V CI lane failing `1076_float_conversion.t` while x86-64
      passed. `Codegen/RISCV64.pm` hardcoded `FCVT_D_L`/`FCVT_L_D` (int64<->float64) for every
      `scvtf`/`fcvtzs`; the lowerer emits a bare opcode, so an f32 was converted as if its
      register held a double and returned 0. An f32 subtest failed and every f64 one passed,
      which is the signature of a width-selection bug. Now selects on both the float format
      (`S`/`D`) and the integer width (`W`/`L`), mirroring ARM64. New constants in
      `Codegen/RISCV64/Encodings.pm`; coverage in `t/3000_jenny/3200_codegen/3296_riscv_fcvt_width.t`
      (codegen-level, host-independent) plus the existing executing `1076_float_conversion.t`.
- [x] **The ELF64 linker warned when a probe compiler was absent** - every `write_executable` on
      the RISC-V lane printed `Can't exec "clang": No such file or directory at
      lib/Brocken/Jenny/Linker/ELF64.pm line 193`. `_cc_print_file_name` now resolves a bare
      compiler name with `IPC::Cmd::can_run` and returns early when it is not installed; an
      explicit path is still used as given so the stub-compiler test is unaffected.
- [x] **`fmov`/`mv` were not accepted by the entry-shuffle fixup** - `fix_entry_shuffle` in
      `lib/Brocken/Jenny/RegAlloc.pm` scanned only `mov`, so a run of float captures (an `fmov`)
      or RISC-V integer captures (an `mv`) was left unscheduled and a capture that wrote a
      register could land before one that read it, so an argument arrived as a copy of its
      neighbour. It now recognises `mov`, `mv` and `fmov`, partitions the captures by register
      class, and breaks a cycle with the spill temp of the matching class.
      Coverage: `t/3000_jenny/3200_codegen/3297_entry_shuffle.t` (integer, executing).
- [x] **The call arguments were not a parallel move either** - the lowerer emitted one copy per
      register argument just before a call in reverse order, on the theory that setting the first
      argument last keeps a later copy from clobbering it. That is only true while no copy's
      source is another copy's destination; with two floats allocated to xmm1 and xmm2 it wrote
      xmm1 first and destroyed the source of the copy into xmm0, so the earlier argument read
      back as its neighbour (a variable float argument is the case `dev`'s tests never reach,
      because they pass literals). New `fix_call_shuffle` schedules the run as a real parallel
      move, reusing the entry-shuffle algorithm and the same reserved spill temps; a run with no
      collision, or one with a stack store, immediate, spilled source or spill temp, is left as
      written. Coverage: `t/3000_jenny/3200_codegen/3298_float_param_registers.t` (float, variable
      arguments, executing).
- [x] **A float literal could not be passed directly as an argument** - the call path lowered
      every argument with `_lower_opnd`, which returns a float `Constant` as a raw immediate, and
      `fmov` cannot encode one, so `g(1.5)` died with `Unexpected operand kind: imm`. The return
      path already routed float constants through `_materialize` (bit pattern into a general
      register, then `fmov_gp2f`); the argument path now does the same on x86-64, ARM64 and
      RISC-V64. Materialising exposed a second fault: `RegAlloc`'s reserved-physical-register scan
      read the register class off the operand type, but a call-argument copy is a `fmov` with an
      untyped physical destination, so the argument's XMM stayed allocatable and a later literal's
      temporary landed on it (`1+2+3+4` arrived as 9). The class is now taken from the opcode when
      the type is absent. Coverage:
      `t/3000_jenny/3200_codegen/3299_float_literal_arguments.t` (codegen-level plus executing).
      `dev`'s literal-argument float parameter tests can now be adopted as-is.
- [x] **x86-64 `cmp` and ALU immediates were truncated to 32 bits** - every
      `cmp`/`add`/`sub`/`and`/`or`/`xor`/`mul` immediate was emitted as
      `pack('CCCV', ...)`, a 32-bit field, and the 64-bit forms sign-extend it, so
      any i64 constant outside signed 32 bits was read as a different number:
      `my i64 $x = 4294967296; return $x == 4294967296 ? 1 : 0;` answered false and
      `$x + 4294967296` lost the add. There is no 64-bit immediate form for these
      opcodes at all, so the constant has to go through a register. The lowerer now
      materialises one (`_materialize_wide_imm`) before the ALU or compare
      instruction and leaves in-range immediates untouched; the `mov` encoder
      already emitted `movabs`. The scalar `neg` path, which lowers `-C` to
      `sub dst, C`, had the same fault and is fixed the same way. Coverage:
      `t/1000_katsuro/1077_imm64.t` (executing: comparison boundary, add/sub/mul, a
      64-bit `and` mask, and a negative out-of-range literal).
- [x] **An f32 literal argument read back as NaN on RISC-V** - found by the RISC-V CI lane
      failing `3299_float_literal_arguments.t` (every `f32` subtest, no `f64`). The literal is
      retagged to the parameter's type, but `_place_float_constant` moved its bit pattern into the
      argument register through an *untyped* physical operand, so `Codegen/RISCV64.pm` took the
      move's width from `$dst->type`, defaulted to 64 bits, and emitted `fmv.d.x`. RISC-V reads a
      single-precision operand whose upper 32 bits are not all ones as a canonical NaN, so the
      callee saw NaN and the sum comparison failed. x86-64 already typed its destination
      (`_materialize_into`); RISC-V and ARM64 now do too. ARM64 has no NaN-boxing, so its
      double-register form was not observably wrong, but the width now comes from the literal
      there as well. Coverage: host-independent codegen-level checks in
      `3299_float_literal_arguments.t` that encode an f32 argument for RISC-V and ARM64 and require
      `fmv.w.x`/`fmov.s`, not `fmv.d.x`/`fmov.d`.

### Open

- [ ] **Mixed-width signed/unsigned comparison compares at 32 bits** - the equal-width fix at
      `Katsuro/Lowerer.pm:1380` covers only `lbits == rbits`. When the widths differ, the narrower
      signed operand is promoted to the wider unsigned type (`i8` -> `u16`), but the value is still
      carried sign-extended in a 32-bit register, so the unsigned predicate sees `0xFFFFFFC3`
      instead of `0x0000FFC3`. `my i8 $a = -61; my u16 $b = 65509; return $a >= $b ? 1 : 0;` exits
      1; after the frontend's promotion it should be 0. Found by the fuzzer (case 295, seed
      20260713).
- [ ] **f32 conversions are unverified on ARM64 and Wasm** - x86-64 and RISC-V64 are now fixed
      and covered (see above). ARM64 encodes the width in the instruction (`fcvtzs`, `scvtf`) and
      its codegen already selects on both widths, so it is *probably* fine; Wasm has its own
      conversion ops. Neither can be executed here, so both remain unverified until `run_cross`
      exists.
- [ ] **No float-width cast exists, by design** - `maybe_convert_type` croaks with "No
      float-to-float conversion ... the IR has no fptrunc or fpext" for a *non-constant*
      mismatch. This matches `dev`'s choice to fail loudly rather than silently reinterpret bits,
      but it does mean mixing `f32` and `f64` in one expression is a hard error unless one side
      is a literal. Adding `fptrunc`/`fpext` instructions is the real fix; until then the croak
      is the intended behaviour and should not be "fixed" by widening.
- [ ] **Float-to-unsigned-int conversion is absent** - the IR has `SIToFP`/`FPToSI` only. There
      is no `fptoui`, so `my u32 $j = $negative_float;` has no defined lowering.
- [ ] **Out-of-range and NaN float->int conversion is undefined** - `cvttss2si`/`cvttsd2si`
      return the "integer indefinite" value (all ones) for NaN and for overflow. No saturation or
      trap semantics have been chosen or tested.
- [x] **`i128` surface syntax is feature-gated, not absent** - `my i128 $x = 3;` fails to parse
      with "Expected variable name after 'my'", but only because `i128`/`u128` sit behind `use
      feature 'brocken_native_types'`; with the gate the declaration parses, the lowerer splits
      it across two registers, and the value executes. The gate is deliberate and documented in
      `Katsuro::Parser`. The stale claim that a 128-bit value cannot be declared in source, and so
      has no end-to-end test, is dropped: `t/1000_katsuro/1078_i128_surface_syntax.t` checks the
      rejection without the gate and runs a declare/widen/narrow round trip on the host.
- [x] **Multi-block Wasm call fixups are rebased onto the assembled body** - a call index was
      recorded against its own block and never rebased, so a call from any block but the first
      pointed into the middle of the dispatch loop and the module did not validate. Fixed in
      `09e6d0a`: each fixup now has `$block_start[$fx->{block}]` added to it before the linker
      patches it. The rebase is needed even for a call in the entry block now that the dispatch
      prologue precedes that block. Covered by `t/3000_jenny/3200_codegen/3271_multiblock_call_wasm.t`,
      which calls a helper from `if.then` and runs the module under `wasmtime`; that test fails
      if the rebase is removed, as does `3270_multi_func.t`.
- [x] **The Wasm module now runs as a WASI command** - the linker named the entry export
      `_BROCKEN_ENTRY`, which takes a heap base as an i64 parameter, while a WASI reactor looks for
      a `_start` that takes nothing, so the module could not be run as a command at all. The
      multi-function path now appends a `_start` stub that pushes the link-time heap base in the
      entry's own parameter type, calls it, and drops the result. Dropping rather than exiting
      with the entry's value is deliberate: an exit status would mean importing
      `wasi_snapshot_preview1.proc_exit`, which would also break every caller that instantiates
      the module directly, so both 42 and 1 exit 0. `_BROCKEN_ENTRY` is still exported and still
      takes a heap base, for `--invoke`. Two smaller things came with it: the base is a
      signed LEB128 constant, where the unsigned form only happened to agree at 1024, and the
      memory section now covers the base plus the 24-byte runtime header it holds, so a base past
      64KB gets a second page instead of a header out of bounds.
- [x] **Float-to-bool assignment is not normalized to 0/1** - `my bool $b = false; my f64 $x = 24.0;
      $b = $x; return $b;` exited 24, not 0. The float->int conversion behind the assignment produced
      the integer value without masking it to the one-bit destination, so a `bool` could hold any int;
      an fptosi typed at a narrow destination still lowers to a full-width convert (a 32-bit
      `cvttsd2si`, an `fcvtzs` to `w`), which left the bits above the destination intact. Fixed in
      `Katsuro::Lowerer::maybe_convert_type`: the float->int branch now masks to the destination width
      the way the int->int branch already did, folded for a constant and an explicit `and` for
      everything else. A bool holds bit 0 of the truncated value, which is this compiler's existing
      convention for a one-bit destination and what the integer path does (`i64 24` gives 0) -- it is
      not truthiness, so `t/1000_katsuro/1076_float_conversion.t` asserts the integer cases beside the
      float ones to keep the two sources from drifting apart again. That file fails on six of its
      cases if the mask is removed. Checked on the host and under qemu on aarch64 and riscv64.

### Test-process lessons

- [ ] **MIR-level assertions give false confidence on float bugs** - `3280_sitofp_fptosi.t` and
      the other float tests assert on IR shape, and passed while the emitted code computed
      `0.0f`. Every float fix in this series is covered by a new test in `t/1000_katsuro/`
      (`1074_float_width.t`, `1075_float_ordering.t`, `1076_float_conversion.t`) that compiles,
      links, and **executes**, and each was confirmed to fail with its fix reverted.
- [ ] **Byte-pattern greps over emitted code are unreliable** - searching for `F3 0F 11` misses
      any encoding with a REX byte between the prefix and `0F`. This produced a false "no
      movss-store found" reading during the f32 investigation. Prefer instrumenting the lowerer
      and printing operand types, or disassembling with a real tool.

### Untouched by this series

- [ ] **illumos isolate segfaults are still unexplained** - the six skipped
      `t/3000_jenny/3500_isolate/` tests and the two `1050_integration.t` skips are masking a real
      crash, not fixing it. `Platform::Solaris` has no `libpthread_name` override and DT_NEEDED
      is still just `libc.so.1`, so the pthread probe has not found anything. Needs an
      illumos/OmniOS VM and gdb; not attempted here.

## Fuzzer Expansion Plan

The current fuzzer (`lib/Brocken/Fuzz.pm`) only exercises i64 arithmetic + if/else. Expansion is needed to cover the compiler's full language surface and catch regressions across all pipeline stages (lexer, parser, lowerer, codegen, linker, runtime).

### Known Findings (400-iteration run, seed 20260713)

The fuzzer's integer evaluator was rewritten to mirror the frontend's promotion rules, and its
type pool now generates only signed `i128`. A 400-iteration run reports 5 miscompiles and 1
Windows spawn failure:

- case 100 - float-to-bool assignment is not normalized (see Open bugs).
- case 295 - mixed-width signed/unsigned comparison compares at 32 bits (see Open bugs).
- cases 117, 195 - `i128` mixed with `f64`; not yet reduced to a minimal repro.
- case 301 - ternary with a `u64` and a `bool` arm; not yet reduced.
- case 335 - `system()` failed to spawn the child ("Inappropriate I/O control operation"). The
  fuzzer retries a few times, which removes the transient cases, but not this one.

### Phase F0: Type Diversity (Fuzzer Expansion: Types)
*Goal: Exercise code paths for all scalar types the compiler supports.*

- [ ] **Bool/i1** - Add `_rand_bool_val()` + `_gen_bool_decl()`, generate `my bool $b = true/false;` with `&&`/`||`/`!` ops
- [ ] **Fixed-width ints (u8-u64)** - Add `_rand_int_val(type)` that generates in-range values; declare vars of random fixed-width type (`u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `i64`, `u64`) and test cross-type assignment + implicit widening
- [ ] **i128** - Generate `my i128 $v = <big>;` using `Math::BigInt` for expected values; exercise `+` `-` `*` `/` `%` `&` `|` `^` `<<` `>>` with large operands
- [ ] **Float (f64)** - Track `_eval_f64` separately (Perl double vs x86_64 `cvtsi2sd`); generate mixed float/int expressions
- [ ] **Fat scalar (`Int`, `Bool`)** - Generate `my Int $x = 42;` (currently lowers as i64). Once box is heap-allocated, test boxing/unboxing round-trips
- [ ] **String** - Generate string literal assignment + `.` concatenation; compare length via `chars()` intrinsic or `say` output
- [ ] **Pointer types** - Test address-of (`&$var`) and pointer arithmetic, though this may be lower priority until manual memory ops are stable

### Phase F1: Control Flow & Structures
*Goal: Exercise IR/MIR control flow lowering, register allocation around branches, and CFG edge handling.*

- [ ] **While loops** - `_gen_while()`: generate `while ($v <op> $w) { <stmt>; <stmt>; }` with tracked expected value
- [ ] **Nested if/else** - `_gen_nested_if()`: if/else blocks containing further if/else trees (not just single assignments)
- [ ] **Chained comparisons** - `_gen_multi_cmp()`: `$v < $w && $x > $y` in conditions
- [ ] **Break/continue** - Once parsed, generate loops with `last`/`next` to exercise non-local control flow
- [ ] **Logical operators** - `$v && $w`, `$v || $w`, `!$v` in expression context (short-circuit lowering)
- [ ] **Ternary** - `$cond ? $then : $else` expression form

### Phase F2: Multi-Function Programs
*Goal: Exercise inter-procedural register allocation, calling convention, and stack frame management.*

- [ ] **Random subroutines** - Generate N random `sub foo() -> TYPE { ... return $val; }` with `_gen_sub($name, $n_params, $n_ops)`
- [ ] **Function calls** - `_gen_call()`: call a previously defined sub with random args, assign result to a var
- [ ] **Recursion** - Generate a simple recursive function (e.g., `sub fact(i64 $n) -> i64 { if ($n <= 1) { return 1; } return $n * fact($n - 1); }`) with deterministic expected value
- [ ] **Mutual recursion** - Even/odd pair or similar with multiple functions calling each other
- [ ] **The `main` function** - Test both implicit `_BROCKEN_ENTRY` and explicit `sub main` forms
- [ ] **Forward references** - Generate functions that call functions declared later in the source

### Phase F3: Memory & Aggregates (Frontend Lowerer)
*Goal: Exercise `alloca`/`load`/`store` codegen, GEP lowering, array bounds, and struct field access.*

- [ ] **Arrays** - Generate `my i64 @arr = [a, b, c];` with random element values; read/write `$arr[i]` with compile-time-constant index; track expected value
- [ ] **Array loops** - Populate array elements via loop over index, sum elements, verify total
- [ ] **Structs/classes** - Generate a class with random :param fields, construct with `MyClass->new(f1 => v1, ...)`, call a method that computes a return value
- [ ] **Auto-generated readers/writers** - Test `:reader` and `:writer` attribute access patterns
- [ ] **ADJUST blocks** - Generate classes with ADJUST that modifies a field; test the modified value
- [ ] **String ops** - `.` concat with string literals + int-to-string (`$i . "suffix"`)
- [ ] **`say`/`print` output** - Capture stdout and compare against expected output string (needs `capture_stdout` helper in test infrastructure)

### Phase F4: Mutation & Corpus Management
*Goal: Move from pure random generation to mutation-based fuzzing for deeper coverage.*

- [ ] **Seed corpus** - Collect interesting programs (edge cases, div-by-zero avoidance, large constants) as a reusable seed set; shuffle and mutate rather than regenerate from scratch each run
- [ ] **Mutations** - Implement operators: replace opcode, replace operand, swap operands, delete statement, duplicate statement, change constant value (including boundary values: 0, 1, -1, MAX_INT, MIN_INT), add dead code
- [ ] **Cross-over** - Take two programs from corpus, splice one statement from program A into program B at a random position
- [ ] **Corpus directory** - `t/5000_fuzz/corpus/` holding `.brocken` seed files read at fuzzer init
- [ ] **History tracking** - Record which seeds triggered new coverage (IR opcode, MIR opcode, lowering path) and prioritize them for re-fuzzing
- [ ] **Deterministic replay** - Expose `seed` in `test_program` result hashes so each failure can be reproduced with `Brocken::Fuzz->new(seed => N)`

### Phase F5: Minimization & Regression
*Goal: Automatically reduce failing test cases to minimal reproducers and add them to the regression suite.*

- [ ] **Delta debugging** - Implement `_minimize(source, failing_stage)`: try removing/commenting statements, simplifying expressions, reducing constant values, while preserving the failure
- [ ] **Regression extractor** - After minimization, format output as a standalone `Test2` subtest block and suggest the seed + minimized source for placement in `t/5000_fuzz/5010_fuzz_regressions.t`
- [ ] **Regression API** - `Fuzz->new(seed => N)->replay($minimized_source, $expected)` that exports a ready-to-paste test
- [ ] **Automated regression commit** - Script that runs fuzzer for N minutes, collects unique failures, minimizes each, and writes regression subtests

### Phase F6: Pipeline Stage Coverage
*Goal: Distinguish which compiler stage crashed to speed triage.*

- [ ] **Stage tagging in `test_program`** - Return `stage` field: `lex`, `parse`, `lower_ir`, `lower_mir`, `codegen`, `link`, `exec`
- [ ] **Stage-specific fuzz modes** - Methods `fuzz_lex`, `fuzz_lower`, `fuzz_codegen` that generate inputs targeting each stage (e.g., syntactically valid but semantically wrong for parse testing; valid IR ops for codegen testing)
- [ ] **Compile-only mode** - Skip execution when testing codegen/linker (`test_compile` vs `test_program`), for features where exit-code comparison is impossible
- [ ] **Reference interpreter** - Add a `Brocken::Interpreter` that evaluates Brocken AST nodes in Perl and produces expected results; compare compiled output against interpreted output for any program shape

### Phase F7: Sanitizer & Stress
*Goal: Detect memory errors, undefined behavior, and performance regressions under fuzzer load.*

- [ ] **AddressSanitizer fuzz** - When available, link fuzzer output with `-fsanitize=address`; detect heap-buffer-overflow, use-after-free, stack-buffer-overflow
- [ ] **UndefinedBehaviorSanitizer** - Link with `-fsanitize=undefined` to catch signed overflow, shift-past-width, misaligned access
- [ ] **Valgrind fuzz** - On Linux, run fuzzer output under `valgrind --tool=memcheck`; stop on first error
- [ ] **Overnight stress** - `fuzz_until_time(3600)` (1 hour) CI job that runs nightly; collects unique failures
- [ ] **Memory leak regression CI** - Assert RSS stays below threshold after N fuzzer iterations (using `Win32::Process::Info` or `/proc/$$/status`) - prevents reintroduction of the reference-cycle leak
- [ ] **Throughput monitoring** - Track `iters/sec` in fuzzer output; alert on >20% drop (indicating perf regression)

### Phase F8: Cross-Platform Fuzzing
*Goal: Catch platform-specific bugs (linker format, ABI, calling convention) across all targets.*

- [ ] **Target selection** - `$fuzz->fuzz(target => 'x86_64-linux-gnu')` to compile/test against a non-host platform (requires cross-linker)
- [ ] **Triple fuzzing** - Given a program, compile it for all 4 native targets (X86_64, ARM64, RISCV64, Wasm) and verify the exit code is the same on each (exit code is a scalar i64, platform-independent)
- [ ] **Linker format rotation** - Fuzz ELF64, PE, Mach-O code paths with the same program; verify identical exit code (platform-permitting)
- [ ] **Wasm fuzzing** - Test Wasm output via `wasmtime` or `node` runner (separate execution path in `test_program`)

### Phase F9: Tooling & CI
*Goal: Make fuzzing a regular, trusted part of development workflow.*

- [ ] **`prove -lv t/5000_fuzz/5000_fuzz.t FUZZ_ITERATIONS=5000`** - Increase default iteration count; document how to run longer fuzz sessions
- [ ] **GitHub Actions fuzz workflow** - Daily cron job running fuzzer for 30 minutes on Linux, macOS, Windows; posts failure diffs to issue tracker
- [ ] **Fuzzer dashboard** - Parse fuzzer output logs to track: iterations, failures, stage breakdown, coverage (IR opcode histogram), throughput
- [ ] **Fuzz-friendly `skip` mechanism** - Add `FUZZ_SKIP_KNOWN` env var pointing to a file of known-bug seeds (skip gracefully instead of failing on known issues)
- [ ] **Fuzz test diff** - When a new fuzz regression test is added, show `prove` output diff to confirm it would have caught the bug

### Immediate Next Steps (Priority Order)
1. ~~F0: Add `<<`/`>>` shift ops to `_rand_binop` and `_eval_i64` (trivial, immediately exercises shift lowering)~~ **[DONE]**
2. F0: Add `bool` type generation (`my bool $b = 1; if ($b) { ... }`)
3. F0: Add multiple integer widths (`i32`, `u32`, `u8`, `u16`) with random values that fit the range
4. F1: Add while-loop generation with tracked induction variable
5. F2: Add multi-function generation (2-3 random subs, one calls another)
6. ~~F4: Ensure deterministic replay: `run_case(case, max_ops, max_vars)` method + `seed`/`case_num`/`max_ops`/`max_vars` in result hashes~~ **[DONE]**
7. F4: Implement minimal mutation framework (take last generated program, mutate 1-2 ops)
8. F5: Write delta-debugging minimizer
9. F6: Add stage tagging to result hashes

### Current Fuzzer Limitations Summary
| Dimension | Current | Target |
|-----------|---------|--------|
| Types | i64 only | bool, i8-u64, i128, f64, Int, String |
| Statements | assign, if/else | + while, for, nested if, break/continue |
| Functions | 1 (implicit entry) | N subroutines + calls + recursion |
| Operators | + - * / % & \| ^ | + << >> && \|\| ! ~ ternary |
| Memory | none | arrays, struct fields, strings |
| Pipeline tested | compile+codegen+link+exec | stage-identified failures |
| Generation | pure random | seed corpus + mutation + cross-over |
| Minimization | manual | automated delta debugging |
| CI duration | 20 iters (seconds) | 30-60 min nightly + quick smoke test |
