# Brocken Compiler Roadmap

Now that the foundational IR (Lindsay) and Platform abstraction (Katsuro) are in place, we need to bridge the gap between abstract SSA and executable machine code.

## CI Status

Matrix lives in `.github/workflows/ci.yml`; every leg delegates to the
`sanko/workflow-testing` reusable workflows. 21 legs: Linux x86_64/aarch64/riscv64,
macOS x86_64/aarch64, Windows x86_64/aarch64, FreeBSD x86_64/aarch64,
NetBSD x86_64/aarch64, OpenBSD x86_64/aarch64, DragonFly, OmniOS, Solaris, Haiku.

Runner labels must be real or the leg queues forever. There are **no Debian,
Fedora, or Alpine GitHub-hosted Linux runners** — only the Ubuntu family. RISC-V
comes from the RISE RISC-V Runners App (`ubuntu-24.04-riscv`), not from GitHub.
`ubuntu-26.04-riscv` appears in RISE's labels reference but their FAQ states
24.04 is the only routable label (26.04 is staged until RVA23 hardware lands), so
the matrix deliberately stays on 24.04 rather than queue a leg forever.

### Failing legs (as of run 36359673750)
- [ ] **All aarch64 legs are red** — FreeBSD/ARM, Linux/ARM, macOS/Apple Silicon, Windows/ARM. This is the ARM64 codegen catch-up, not a CI problem.
  - Narrow-slot width, `movsx` destination width, negative-displacement encodings and narrow negative constant materialization are fixed and verified by executing 154 generated programs under `qemu-aarch64` (`strb`/`ldrsb` for i8 slots, `sxtb/sxth/sxtw` x-forms, `ldur`/`stur` imm9, `movz`/`movk` covering the register rather than the type). Integer `abs` was selecting on stale flags — the `csneg` had no `cmp` in front of it, so it followed whatever the previous instruction left in NZCV and only agreed by luck; it now compares against zero first, which is also what makes `abs` of a constant and `abs` under spill pressure come out right. Still open: whatever the next re-run reports, since these tests only execute on a native ARM64 host and pass on x86_64 by testing the x86_64 encoder instead.
- [ ] **DragonFly BSD / Intel** and **NetBSD / Intel** — both x86_64, so not arch-specific.
- [x] OpenBSD and Solaris were pinned to perl 5.40.2, which cannot satisfy `use v5.42`. Bumped to 5.42.0 in `14fc284`; both need a re-run to confirm perl 5.42.0 builds there.
- [x] `cpanfile` claimed `v5.40.0` while ten modules require `v5.42`; corrected in `14fc284`. The follow-up note that "5 module files still carry no `use vX.Y` guard" was stale by the time it was written — all 84 files under `lib/` now carry a `use vX.Y` guard (re-verified this round).

### Workflow hygiene
- [x] Removed `blank.yml` (byte-identical duplicate of `c-thread-disassembly.yml`) and the orphaned `unix.yml`.
- [x] `debug-threading.yml` passed a `test_cmd` input that `cross.yml` does not declare — GitHub rejects unknown inputs, so the job could never run. Repointed at the real isolate/fiber tests via `test_files`/`diag`.
- [ ] `windows.yml` is also an orphaned `workflow_call` module (nothing calls it). Left in place pending a decision.
- [ ] `run-vm.yml` takes one `os_version` per job, so a second BSD release (e.g. FreeBSD 15.1 alongside 14.1) needs its own job rather than another matrix row.

## Active Sprint

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
- [x] Root-cause the fiber ctx_swap / isolate trampoline interaction on x86_64 Mach-O. — `r12` was being clobbered in the ctx_swap restore loop; skipped restore since r12 already holds target FCB (step 6 of x86_64 ctx_swap). Fixed in `202c0bd`.
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
- [x] **i128 call arguments**  split into lo/hi across two consecutive param registers in all 4 lowerers.
- [x] **i128 entry block parameters**  split into _lo/_hi virt_regs at the entry block, consuming two param regs.
- [x] **i128 call return capture (ARM64, RISCV64, Wasm)**  caller now reconstructs _lo/_hi from both return registers (x0/x1, a0/a1, Wasm stack) — was only done on X86_64.
- [x] **Signed i128 div/rem**  all targets use abs(inputs) + apply sign to output.
- [x] **i128 `min`/`max`**  implemented on all 4 targets (X86_64, ARM64, RISCV64, Wasm).
- [x] **Large-value i128 icmp tests**  added native (246 tests) and Wasm (328 tests) execution tests with Math::BigInt constants > 2^64.
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
- [x] **Isolate return value propagation**  `isolate_join` passes NULL retval; doesn't capture thread result — fixed by Mach-O import stub fix (stubs pointed to dlopen, not pthread_join)
- [x] Wasm isolate stubs (lowerer) — `isolate_create`/`isolate_join` return `i64_const 0` placeholder

## Active Sprint: Katsuro Frontend (Bootstrapping Subset v0.1)

### Completed: Language Features
- [x] **Subset spec:** `docs/spec.md §2.16` — formal Brocken v0.1 bootstrapping language spec
- [x] **Lexer:** Finite-state tokenizer with keywords, sigils, numbers, strings, operators
- [x] **AST nodes:** Program, VarDecl, Assign, Block, If, While, Return, BinOp, UnOp, Const,
      Var, Ident, Paren, Call, IntrinsicCall, SubDecl, ClassDecl, FieldDecl, ArrayDecl, ArrayIndex
- [x] **Parser:** Recursive descent (statements) + Pratt parser (expressions) —
      handles all v0.1 constructs including arrays, classes, methods, field access, `use feature`
- [x] **Compiler orchestrator:** `Brocken::Compiler` — lex → parse → AST
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
- [x] **ArrayDecl AST node** — parses `my i64 @arr = [10, 20, 30];`
- [x] **ArrayIndex AST node** — parses `$arr[0]` for both read and write
- [x] **Lowering** — alloca with element count, GEP for element access, load/store
- [x] **Alloca honours the element count on all 4 backends** — X86_64 sized the
      reservation from the element type alone, so `my [i64; 5] @a;` reserved 8
      bytes and every element past the first wrote into the neighbouring stack
      slot. A plain local declared after the array was silently overwritten
      (returned 33 instead of 123). ARM64/RISCV64/Wasm additionally called
      `->value` on the count without checking it was a `Constant`, so a
      non-literal size such as `my [i64; $n] @a;` read `undef` and reserved 0
      bytes on Wasm or died with a confusing internal error on the native
      backends; all four now reject it with a clear message.
      See `t/3000_jenny/3200_codegen/3285_alloca_count.t`.

### Completed: Class Methods & Auto-Generated Accessors
- [x] **Method declarations** — `method foo() -> TYPE { ... }` inside class, lowered as `ClassName::foo`
- [x] **`:reader` attribute** — auto-generates getter method
- [x] **`:writer` attribute** — auto-generates setter method (`set_<name>`)
- [x] **`:param` attribute** — auto-generates constructor (`ClassName->new(...)`)
- [x] **ADJUST block** — runs after constructor assigns :param fields
- [x] **`__CLASS__` expression** — compile-time class name constant
- [x] **MethodCall expression** — `$obj->method(args)` lowered to `ClassName::method($obj, args)`

### Completed: Implicit Entry Point
- [x] **`sub main` is just a function** — no special heap param, no automatic invocation
- [x] **Top-level code becomes `_BROCKEN_ENTRY`** — internal function with heap_base param
- [x] **All codegen/linker paths** — replaced `main` references with `_BROCKEN_ENTRY`
- [x] **Parser filters `use feature`** — returns `undef` statements filtered in `parse_program`

### Known Issues (Resolved)
- [x] **Duplicate block names in MIR codegen:** Fixed — Lowerer now generates unique block names via `$block_id` counter.
- [x] **`terminator` returned last instruction regardless of type:** Fixed — now checks `isa` for Ret/Br/CondBr.
- [x] **SSA name collisions on var ref:** Fixed — `lower_var_ref` no longer passes explicit names to `build_load`.
- [x] **`as_condition` i1 detection:** Fixed — now checks `bits == 1` instead of `kind eq 'i1'`.
- [x] **Class runtime ordering:** ClassDecls now generate before SubDecl bodies in Pass 2, so auto-generated methods exist when entry function body calls them.

### Upcoming
- [ ] **Dynamic (boxed) types at top level:** `my Int $x = 10` currently lowers like `i64`; needs actual box allocation
- [ ] **String support:** String literals, `say("hello")` with runtime string data, string concatenation
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

## Phase 4: Self-Hosted Runtime & Memory Management (`core.brocken`)
*Architecture Note: Brocken uses "Isolates" (share-nothing OS threads) and cooperative fibers. Because heaps are entirely thread-local, Garbage Collection and Reference Counting require **zero atomic locks**.*

- [x] **Fat Scalar Layout:** 16-byte dynamic value struct (refcount + gc_flags + type_tag + aux_data + payload). Implemented via `box`/`unbox` IR (stack-allocated for now).
- [ ] **Immediate RC:** Build the `Brocken::Runtime::incref`/`decref` module (currently placeholders in lowering).
- [ ] **Immix Cycle Detector:** Mark-region trace of the isolate's Immix heap to reclaim cyclic garbage. Replaces trial deletion.
- [ ] **RC Immix Allocator:** Implement 32KB block / 256-byte line bump-pointer allocation in the Perl subset. Replace the current `box`→`alloca` approach.
- [ ] **Perceus RC Elision:** Static analysis pass cancels redundant incref/decref pairs; enables in-place mutation when refcount==1.
- [ ] **Fiber Stack Scanning:** Walk stacks of suspended fibers to find live GC roots.
- [ ] **UTF-8 Everywhere Strings:** Native string operations assuming pure UTF-8 payloads.
- [ ] **Self-Hosted PerlIO:** Vtable-based layered I/O system (e.g., `:unix` raw bytes → `:utf8` validation).

## Phase 5: Optimization & GC Lowering (Lindsay Middle-end)
- [ ] **RC Insertion Pass:** Automatically insert `incref` and `decref` IR instructions around variable assignments. Utilize the Defer Stack to emit `decref` operations at scope exits.
- [ ] **RC Elision & Reuse (Perceus-lite):** Optimize away redundant `incref`/`decref` pairs. If an object is uniquely owned (RC==1), mutate it in place rather than allocating a copy.
- [ ] Constant Folding & Dead Code Elimination (DCE).
- [ ] **Stack Map Generation:** Update `Jenny::Linker` to emit a `.brocken_stackmaps` section so the GC knows exactly which physical registers and stack slots hold pointers during a fiber yield.

## Active Sprint: Type System Expansion

### Phase A: Type Infrastructure (Lowerer + IR)
- [x] Add `%TYPE_MAP` entries for `int`, `bool`, `u8`..`u128`
- [x] Fix `%TYPE_NATIVE_MAP` for `Int`/`Bool` (→ i64/i1, not dynamic)
- [x] Add signedness-aware widening to `maybe_convert_type` (zext/sext)
- [x] Add `zext`/`sext` IR instructions to `IR.pm` + `Builder.pm`
- [x] Backend: lower `zext`/`sext` on all 4 targets
- [ ] Backend: proper `movzx`/`movsx`/`UXTB`/`SXTB` encoding for zext/sext (currently plain `mov`) — **X86_64 fixed** in `ff8988a` (MOVSXD was emitted for every source width, truncating any 64-bit source to 32 bits and re-reading it signed; `sext` of `INT64_MIN` returned 0). **ARM64/RISCV64 fixed** in `8b98245` — the ARM64 UBFM/SBFM forms behind UXTB/UXTH/SXTB/SXTH/SXTW took the source from Rm instead of Rn, and both backends truncated a 64-bit source to 32 bits. **Wasm fixed** (this round, `3268_wasm_ext_widen.t`): both handlers emitted `i64_extend_i32_u`/`i64_extend_i32_s` whenever the destination was wider than 32 bits, without checking the source width. Those opcodes consume an i32, so a 64-bit source left an i64 on the stack and the validator rejected the module outright (`type mismatch: expected i32, found i64`). The widening is now gated on the source being at most 32 bits.

### Scalar integer min/max
- [x] X86_64 — `0460da8`, `3248_int_minmax.t`. The generic fallback emitted a `min`/`max` MIR op that x86 codegen dropped, so the result silently kept the left-hand operand.
- [x] **ARM64** — `fd0abbf`. Branchless `cmp` + `csel_le`/`csel_ge`; the only previous `min`/`max` block in the lowerer was the i128 path.
- [x] **RISCV64** — `fd0abbf`, then `8b98245`. The first expansion masked with the 0/1 that `slt` produces, which keeps only the low bit of `(lhs ^ rhs)` and returned garbage whenever the xor was even; the mask is now a full-width `-(lhs < rhs)`.
- [x] **Wasm** — this round. Audited by executing under `wasmtime`: correct as written. Wasm only has `f32.min`/`f64.min`, so integer min/max already lower to a `select` over `i32_lt_s`/`i64_lt_s`, matching the `select` operand ordering the codegen expects. Verified against negative operands, equal operands, and values differing only above bit 31.

### Scalar div/rem, shift, and compare audit
- [x] **ARM64/RISCV64** — `8b98245`. Found by compiling small programs and *executing* them under `qemu-aarch64`/`qemu-riscv64` rather than by reading disassembly: `sdiv` was never encoded (signed `div`/`rem` emitted `udiv`, so `-13/3` was `3074457345618258602`); ARM64 register `ashr` used `0x9AC02C00`, which is RORV, not ASRV (`0x9AC02880`); ARM64 `cmp` took its width from the i1 result, so 64-bit compares only looked at the low 32 bits and values differing solely above bit 31 compared equal; ARM64 UXTB/UXTH/SXTB/SXTH/SXTW read the source from Rm instead of Rn; the RISC-V M table had `mul` as funct7 0 (bit-identical to `add`) and `div`/`divu` in the wrong funct3 slots, so a rem silently became `divu;add;sub`; and 64-bit `zext`/`sext` truncated the source to 32 bits on both backends. The RISC-V XORI claim in that commit ("XORI needs funct7 0x20") was wrong and the change it made was reverted below.
- [x] **RISC-V XORI set bit 30, so every negated condition was true.**
      `8b98245` read bit 30 as a funct7 and set it on the I-type XORI the
      way SRAI does, on the belief that without it "the encoding is the
      register XOR, so the immediate landed in the rs2 field". Bits 31..25 of
      an OP-IMM instruction are imm[11:5] of the constant, not a funct7, and
      the register XOR is funct3 4 of the *other* opcode (0x33) — there is no
      rs2 field in an OP-IMM word and nothing to disambiguate. The constant
      became `0x400 | value` instead of `value`. The lowerer negates a
      comparison with `xori cond, 1` whenever a branch wants the opposite
      sense, and `0x401` is never zero, so the negated condition was true for
      every input. `if ($x)` took its then-arm with a false `$x`
      (`1050_integration.t`, 'else branch taken', answered 0 instead of 42),
      and the inverted exit test of `while ($i <= $n)` never became true, so
      the `Factorial` subtest in the same file never returned and hung the
      run. Regression: `3289_riscv_xori.t`, which asserts the encoding from the
      instruction words rather than executing, so it catches this off RISC-V
      too.
- [ ] Every RISC-V test in `3200_codegen` is guarded by `is_riscv64 &&
      is_native`, so the backend's encodings are only ever checked on real
      RISC-V hardware. Nothing in the suite validates an instruction word
      elsewhere, which is how a wrong bit in a single encoding survived
      review and a green run: the RISC-V half of the `8b98245` audit reported
      32/32 under qemu while `xori` was broken, so whatever those cases
      covered, they did not cover a negated comparison. Decoding emitted words
      on the host, as `3289_riscv_xori.t` now does for one instruction, would
      cover the rest.
- [x] **Wasm** — this round. Audited by executing under `wasmtime` (per-op modules, not a batched bitmask): signed/unsigned `div`/`rem`, `shl`/`lshr`/`ashr`, and all 10 `icmp` predicates are correct, including the `-13/3` sign case and operands differing only above bit 31 that the ARM64/RISC-V audit turned up. No bugs in this group.

### Wasm integer unary ops (neg / abs / sqrt)
- [x] **Wasm** — this round, `3267_wasm_int_neg.t`. Wasm has no integer `neg`/`abs` opcode (only `f32.neg`/`f64.neg`/`f32.abs`/`f64.abs`), and the lowerer died with "Wasm unary op neg requires float type" for every integer negation. Unary minus reaches the lowerer for any numeric type (`Brocken::Katsuro::Lowerer` emits `build_neg` for `-` on every numeric type), so a plain `return -x;` over an int failed to compile on Wasm while every other backend handled it. `neg(x)` is now `0 - x` and `abs(x)` is `x < 0 ? -x : x` via `select`, both from the generic i32/i64 ops. Integer `sqrt` is still rejected: Wasm has no integer square root, and silently miscompiling it would be worse than the die. `3239_int_neg.t` only exercised the host platform, which is why the gap went unnoticed.

### Sub-word load/store widths and C struct layout
- [x] **Every backend accessed an i8 or i16 field through a full 32-bit access.**
      Wasm chose the width from "is this 64-bit or not" and used a 4-byte
      `i32_load`/`i32_store`; x86-64 did the same with REX.W clear. Since a
      sub-word value is carried sign-extended, a *lone* sub-word access
      round-tripped correctly, which is why this survived so long: the obvious
      test cannot see it. It needs a neighbouring access, and the class layout
      made one certain, because fields were overlaid on top of each other.

      Wasm now uses `i32.load8_s`/`i32.load16_s` and `i32.store8`/`i32.store16`.
      x86-64 uses MOVSX r32, r/m8 and r/m16 (0F BE, 0F BF) to load, 0x88 and a
      66-prefixed 0x89 to store, and 0xC6 / a 66-prefixed 0xC7 for the
      immediate form, with the immediate truncated to the access width. MOVSX
      rather than MOVZX because arithmetic on a sub-word value is plain 32-bit
      arithmetic on a sign-extended register: zero-extending turned -7 into
      0xF9 and `abs()` of that into 249. Not the one-byte 0x8A either, which
      reads one byte but writes only the low 8 bits of the register and leaves
      the upper 56 stale.

      Two encoding details are easy to get wrong in a way that still produces
      plausible bytes: the `66` operand-size prefix is a legacy prefix and has
      to precede REX (a REX byte first also silently changes the meaning of
      register ids 0-3, and spl/bpl/dil/sil are unreachable without one); and
      in the immediate-store form the immediate *follows* the displacement, so
      it has to be emitted after the displacement bytes. Getting the second one
      wrong mis-encodes every access with a non-empty displacement at every
      width, including 32- and 64-bit.

      Regression: `3290_subword_widths.t`, 35 cases over both backends, plus
      the layout offsets below.
- [x] **Class fields were overlaid instead of laid out the way C lays them out.**
      `field i8 $a; field i16 $b;` put both at offset 0. It appeared to work
      only because every sub-word access was widened to overwrite the field it
      overlapped, so the two defects cancelled out. That also means an FFI
      caller, who allocates and indexes the struct by C's rules, would have read
      the wrong bytes for every field.

      Fields are now placed in declaration order at the next offset satisfying
      their natural alignment, and the struct size is rounded up to the struct's
      own alignment — `i8, i16` is offsets 0 and 2 with size 4. Allocation is
      rounded up to 8 bytes independently of the struct size, so a struct may
      have a non-8 size (a later `:pack`) without the bump allocator placing
      the next object inside its tail padding.

      Regression: the layout half of `3290_subword_widths.t` reads the offsets
      back out of each generated accessor's field GEP, so it checks the number
      the backend will use rather than a second computation of it.
- [x] `:pack` / `:pack(N)`, the C `__attribute__((packed))` and
      `__attribute__((aligned(N)))` pair. Bare `:pack` is `:pack(1)`, and
      `:pack(N)` sets the field's alignment to exactly N, replacing the natural
      alignment rather than combining with it. Replacing rather than taking a
      maximum is what makes `aligned(N)` able to *lower* a field's alignment, as
      C's does, and a minimum would have made `:pack` a no-op.

      The value is carried on a new `align` field of `FieldDecl` and not in
      `attrs`. Every attribute in `attrs` is a bare flag tested by name by the
      accessor and parameter passes, so a `pack` entry there would have been
      read as a request for a reader named `pack`, and `:pack(N)` would have had
      nowhere to put its argument. N has to be a positive power of two, since the
      layout rounds offsets up to a multiple of it; that is rejected in the
      parser so the diagnostic can point at the token.

      Regression: `3295_field_pack.t`, 40 cases over both backends — layout
      offsets, that `pack` stays out of `attrs`, the rejected alignments, and
      packed structs at run time including one smaller than the 8-byte
      allocation granularity and one that must not overrun its neighbour.

      Note that a class size is no longer necessarily a multiple of 8 now that a
      fully packed struct can be any size. The allocation size is rounded
      separately for exactly that reason, and a 3-byte struct must not be padded
      back to 4 just because the following field would prefer it.

- [x] **A field default value is ignored, on every backend.** Found while adding
      `3295_field_pack.t`; unrelated to `:pack` and reproducible at
      `field i8 $a :param :reader; field i16 $b :param :reader = 5;` followed by
      `P->new(3)` and a read of `b`. The default is not applied, so `b` reads
      back as 0 and the comparison fails. Present with and without `:pack`, at
      every width, and on both x86-64 and Wasm, where it surfaces earlier still
      as a validation error ("expected i32 but nothing on stack") because the
      default never put a value on the stack. Verified at `55fe87f` with the
      layout work stashed, so it predates it. The attribute is parsed and the
      default expression is built, so the loss is in lowering: the constructor
      stores each `:param` field unconditionally, and that `if`/`elsif` leaves
      the default branch unreachable for exactly the fields that carry one.

      Not `ADJUST` clobbering a default after the fact, as first guessed -- the
      constructor's own `elsif` is simply never reached. The default is applied
      for a field that is *not* a `:param` and was ignored for one that is, which
      is the opposite way round from an adjustment overwriting it.

      The fix is at the call site, because that is the only place that knows what
      the caller passed. A constructor's signature is fixed at one parameter per
      `:param` field, so it cannot tell an omitted argument from one passed as
      zero, and neither can it leave the slot alone. `register_class` now keeps
      each field's `default_ast` in the class table, and `new` fills every
      `:param` slot past the last supplied argument with that default, or a zero
      of the right width when the field has none. The default is kept
      unlowered on purpose: it has to be re-lowered in whichever function holds
      the call, and a value lowered at class-registration time would belong to
      whatever was being compiled then.

      Zero-filling is not a flourish -- it is the same missing operand. Without
      it, an omitted argument with no default at all is still an uninitialized
      read on native, and still a stack mismatch on Wasm.

      `3296_field_defaults.t`; 18 of its 29 assertions fail at `9117ecd`.

- [x] **A function reading four or more arguments read back its neighbours.**
      Found while adding `3297_entry_shuffle.t`. Worth stating plainly that this
      is *not* what the three CI failures were caused by -- those turned out to
      be the two defects below -- so it is recorded on its own terms rather than
      as their explanation. On SysV x86-64 a free function taking four or more
      `i64` parameters summed transposed arguments: arities one through three
      were right, four through six were wrong.

      The lowerer captures each incoming argument at the top of the function by
      copying it out of its calling-convention register, and those captures do
      not run in isolation. They all read the caller's registers before any of
      them is written, so together they are one parallel move, and the allocator
      is free to pick a destination that is still a pending source. With four
      integer parameters it produced exactly the worst case, a cycle:

          rcx <- rdi, rdx <- rsi, rsi <- rdx, rdi <- rcx

      `fix_entry_shuffle` resolved that by parking each clobbered source in the
      single spill register the allocator holds. It emitted every park before
      every consumer, so the second park overwrote the first and the fourth
      argument arrived holding the second. Handling the hazards one at a time is
      no better: the temp has to be free again before its next use. The same
      collector also swept up the trailing `retval from rax` move, which is not
      part of the shuffle at all.

      It now takes only the leading run of captures that read physical
      registers, resolves them as a parallel move, and breaks one cycle at a
      time so the temp is reloaded between a park and its consumer. Free
      function arities one through the register count pass on SysV.

      Regression: `3297_entry_shuffle.t`, which sweeps a free function by arity
      because the failing arity is whatever fills the argument register set --
      four on Win64, six on SysV -- plus a constructor at one field fewer.

- [x] **An `i8` store out of `rsi`, `rdi`, `rsp` or `rbp` wrote the wrong
      byte.** This is what `3295_field_pack.t` #34 and #36 and
      `3296_field_defaults.t` #24 were actually reporting. The failures looked
      like a sub-word store width problem and were not one. Found by dumping
      the constructor for a three-`i8` class and reading one field at a time:
      the first two fields read back correctly and only the third was wrong,
      and only when it landed in a register whose id is 4 or greater.

      The store encodes as `88 /r` with the source in the ModRM reg field. In
      64-bit mode byte-register ids 4-7 mean `AH`/`CH`/`DH`/`BH` unless a REX
      byte is present, and `SPL`/`BPL`/`SIL`/`DIL` when it is. The emitter added
      REX only when the id was 8 or greater, or when the memory operand needed
      an index or base extension, so a store out of `rsi` was emitted as a store
      out of `DH`: the high byte of whichever register held the neighbouring
      field. The first two fields had ids 1 and 2 and so were unaffected, which
      is why only the third ever showed it. The bytes were self-consistent the
      whole time -- `88 31` -- and only the absence of the REX prefix was wrong.

      The sibling cases were checked rather than changed. The sub-word `load`
      puts its byte operand on the memory side, so ids 4-7 never appear as a
      register there, and `movsx`/`movzx` already emit a REX base (`0x40 | ...`)
      unconditionally. The 16-bit form has no equivalent ambiguity. A REX byte
      is now emitted whenever the source id reaches 4, giving `40 88 31`, i.e.
      `mov %sil,(%rcx)`. Both tests pass on SysV.

- [x] **The caller-save area was laid out on top of the spill slots.** Found by
      the same sweep: a class with four `i8` constructor fields segfaulted
      before running any of its own code. Verified at `c3b0f9f` with the
      allocator work stashed, so it predates it. Three fields was clean, so it
      took the extra live argument to reach.

      `insert_caller_save_code` lays its save/restore slots out from a base
      index meant to sit above the allocator's spill slots, and
      `_caller_save_base` computes that base from the highest spill offset. It
      tested the maximum for truth, so a function whose only spill slot was at
      offset 0 -- one spilled value -- reported itself as having no spills at
      all and returned 0. The caller-save area then began at slot 0, on top of
      the spilled value, and saving `rdi` across a call overwrote the spilled
      object pointer with an argument. The following reload dereferenced it, and
      the program faulted writing through what had become a small integer. The
      base is now computed from `defined` rather than truth, so a single spill
      slot at offset 0 yields a base of 1.

- [x] **`insert_spill_code` reloads through a single temp, so a second live
      reload clobbers the first.** Also found by the sweep above: a class with
      five `i8` constructor fields still faults where four is clean. Five fields
      fills the SysV argument register set exactly, and from there the caller
      needs two simultaneously live spilled values.

      One instruction with both a spilled `mem` base and a spilled operand needs
      two values in registers at the same time, and `@load_offsets` emitted one
      `load` per offset through the same spill temp:

          load  r11, mem(rsp,0)    # the object address
          load  r11, mem(rsp,8)    # the value to store, clobbering the above
          store mem(r11,0), r11    # stores the value through the value

      This was the same single-temp hazard `fix_entry_shuffle` had, in a
      different pass, and it wanted the same kind of answer. `LinearScan` now
      reports `spill_temp_count` and a `spill_temps` list, so the number of
      temps tracks the largest set of simultaneously live spilled values rather
      than being fixed at one. A spilled `mem` base counts as a live value
      itself, which is what the middle case above needs: the base and the
      operand are two values, so they get two temps. `3297_entry_shuffle.t` now
      sweeps constructors to the argument register count rather than stopping at
      four, and the case it was skipping is the one that runs.

- [x] **Arguments past the register set are not implemented on x86-64.** Not
      reachable from any current test, and not what any of the three CI
      failures were, but it bounds what `3297_entry_shuffle.t` can claim. The
      x86-64 lowerer indexed its argument registers, and the caller's argument
      registers, positionally with no bounds check, so the fifth argument on
      Win64 (four registers) and the seventh on SysV (six) read past the end of
      the list. Observed as `Use of uninitialized value` warnings out of
      `Lowerer/X86_64.pm` and a wrong value, not a crash. `3297` swept a free
      function only up to the register count for this reason.

      Both directions are now placed by the ABI, which grew
      `stack_param_offset` and `caller_stack_param_offset` alongside
      `param_registers` (SysV `8 + 8*i` and `8*i`; Win64 `40 + 8*i` and
      `32 + 8*i`, the difference being the 32-byte shadow space and the saved
      return address). The callee captures the incoming argument and the caller
      stores the outgoing one, and an `i128` takes two consecutive slots and
      moves to the stack whole rather than straddling the boundary.

      The outgoing area is reserved at the bottom of the frame and never moved
      at run time, so it sits at a fixed displacement from the hardware stack
      pointer. Three things want to be positioned against that pointer -- the
      outgoing arguments, the allocator's spill and caller-save slots, and an
      alloca -- so the other two are shifted above the reserved area instead
      (outgoing first, then alloca and shadow space, then the allocator's own
      slots). That keeps the frame pointer out of the stack-passing path and
      keeps 16-byte call alignment without adjusting `rsp` around a call.

      A raw displacement is a hardware stack pointer, not a name the allocator
      owns, and it has to be encoded as one. It was reaching the allocator as a
      virtual register named `rsp`, which the allocator then assigned an
      unrelated register, after which every spill slot, caller-save slot and
      alloca in the same function was addressed through that register -- hence
      the fault observed here and the four CI failures it caused. The base is
      now kept out of the interval model and resolved directly at encode time.
      Verified by `3298_stack_args.t`, which sweeps free functions and
      constructors past the register count on whichever ABI is in use, and by
      mixed narrow-width arguments in the same region.

- [x] **Float literals cannot be materialised on x86-64, so a float argument
      cannot be passed.** The lowerer stored a float initialiser with
      `store_imm`, whose width is selected from the operand type and whose
      immediate is packed as an integer, so `my f64 $t = 3;` wrote the integer
      3 into eight bytes and read it back as a denormal rather than 3.0.

      The cause was one level up, in the frontend. A literal carries the type it
      was written with, so `3` is an i64 and knows nothing about the `f64` slot
      it is stored into, and nothing in the IR recovers that: the store is
      void-typed and its destination a plain `ptr`, so the pointee type is
      invisible exactly where the value is written. Re-tagging the literal in
      `maybe_convert_type` and in `lower_binop` covers the three places one
      reaches a float -- a local initialiser, a bare return, and an arithmetic
      operand. The return case was not a miscompile but a hard failure: nothing
      coerced it at all, so a float function returning a literal emitted
      `ret i64` and the comparison died with `Unexpected operand kind: imm`.
      Verified by `3299_float_literals.t`, which also carries a value past
      2**52 so that a fix which only got the width right cannot pass.

      The stack-argument half of this still stands: the lowerer emits `fstore`
      for a float argument that reaches the stack area, and the float sweep in
      `3298_stack_args.t` is still waiting on the AArch64/RISCV64 stack-argument
      work below.

- [x] **Comparing a float call result against a literal gives the wrong answer.**
      Found while writing `3299_float_literals.t`. With the callee provably
      correct -- `sub f() -> f64 { my f64 $t = 3; return $t; }` lowers to
      `mov ..., 0x4008000000000000` / `fmov_gp2f` / `fstore` / `fload` /
      `fmov xmm0` -- the caller still takes the false branch on `if (f() == 3)`.
      The caller's MIR is right too: `call_func`, `fmov %f_res, xmm0`,
      materialise the constant, `fcmp %f_res, %const`, `setnp`/`sete`/`and`.
      The same comparison inside the same function, on an `fload`ed value,
      passes. So the difference is what defines the compared register: here it
      is a `fmov` from a physical register rather than a load. Most likely the
      FP side of allocation, which is a separate pass from the integer one and
      is the part that has to notice a virtual register defined by a move out of
      a call's return register.

      The FP allocation was innocent. `fmov` takes its width from its
      *destination*, and the destination for a returned float is the physical
      return register, which the `Ret` lowering builds without a type. Untyped,
      the move defaulted to 32 bits: the callee emitted `movss %xmm1, %xmm0`,
      so four bytes of an eight-byte value arrived over the top of whatever
      xmm0 had held and the caller compared a denormal against its literal.
      Every other float `fmov` had a typed operand on one end or the other,
      which is why nothing else was affected, and why the callee looked
      correct in isolation -- the value only ever appeared in the return
      register, so a test that checked the callee on its own passed. The
      operand carries the returned type now. `3300_float_params.t` covers all
      six ordered and unordered operators in both directions, since the fault
      was in the move and not in the comparison and a single operator would
      not have said so.

      The same fault was in three encoders, and it is the reason five float
      parameters were needed to see it: see the REX entry below.

- [x] **`!=` between two float locals is false when it should be true.**
      `my f64 $a = 1; my f64 $b = 2; if ($a != $b)` takes the false branch. The
      lowering is correct on paper -- `ucomisd`, `setp` for unordered, `setne`,
      `or` -- and so is the MIR; `setne` is 0x95 and encodes. This was masked
      until the literal fix above: before it, `1` and `2` were stored as two
      *different* denormals, so the comparison was accidentally true and the
      bug read as a pass. A case that happens to be wrong in the right direction
      is worse than one that is not tested at all.

      The lowering was never wrong. What this entry recorded as a fault was the
      literal bug above wearing a second hat, and it cleared with that fix.

- [x] **`<`, `>`, `<=` and `>=` on floats emit an integer predicate.**
      The frontend picks the predicate from `$lhs->type->is_signed`, so a float
      comparison gets `slt`/`sgt`/`sle`/`sge`, but the backend's float
      comparison table is keyed `lt`/`gt`/`le`/`ge`. The lookup misses, and the
      emitted opcode is `'set' . undef`:
      `Use of uninitialized value $fcond{"slt"} in concatenation (.) or string
      at lib/Brocken/Jenny/Lowerer/X86_64.pm line 2240`. It warns loudly rather
      than corrupting silently, which is the only reason it was found. The
      predicate has to be chosen from the operand kind, not from signedness.

      The predicate is now chosen from the operand kind rather than from
      signedness: a float compares ordered and has no signedness to ask about,
      so it gets `lt`/`gt`/`le`/`ge`, which is what the backend's float table is
      keyed on. Fixing the frontend rather than widening the backend table to
      accept both spellings matters because the miss was silent in the sense
      that it produced a plausible-looking opcode string -- adding `slt` to the
      table would have left the frontend still reporting a signed predicate for
      something that has no signedness, one layer further from the type that
      would have explained it.

- [ ] **`fmov` and its neighbours put the REX byte in front of the legacy
      prefix.** `F2` and `F3` select single and double precision and `0x66` the
      operand size, and a REX byte is only a REX byte as the *last* prefix before
      the opcode. A REX byte in front of one of them is discarded, and the
      instruction decodes without it -- so REX.R, the bit that is the only way to
      reach xmm8 to xmm15, never took effect, and any move involving one of those
      registers read or wrote a register below it.

      This is a silent fault with no warning, and it took five f64 parameters to
      reach it: the eighth floating-point register is the first to need the bit,
      and every smaller arity computed the right answer by accident. The same
      inversion was in `fload`, `fstore`, `fmov`, `fmov_gp2f` and the scalar
      float arithmetic group, so the fix was to emit the prefix first everywhere
      rather than to patch the one opcode a test happened to hit. Verified by the
      arity sweep in `3300_float_params.t`, which runs the full register count
      for the ABI in use; a single high-register case would have been enough to
      catch it but would not have said which encoders share the fault.

- [ ] **Decimal float literals do not parse at all.**
      `my f64 $t = 3.0;` fails with `Expected ';' after variable declaration`,
      while `my f64 $t = 3;` parses. The lexer recognises the integer and stops
      at the `.`, so the whole class of float literals a reader would reach for
      first is unavailable, and the integer spelling that does work is the one
      carrying the bug above. Nothing in the test suite uses a decimal literal,
      which is how a parser that cannot read them went unnoticed.

- [ ] **A negative literal in a float context is a hard error.**
      `my f64 $t = -3;` lowers unary minus to an instruction rather than folding
      it, so the value arrives as a computed int and the new coercion refuses
      it: `Cannot implicitly convert a computed int:64 to float:64`. It used to
      miscompile quietly, so the error is an improvement, but a negative float
      literal is ordinary code and folding `-` applied to a constant into the
      constant is the whole fix.

- [ ] **There is no integer-to-float conversion instruction.**
      `my f64 $t = $i;` where `$i` is an `i32` is refused, because the IR has
      `zext`/`sext`/`trunc`/`ptrcast` and no `sitofp`, and none of the four
      backends has a lowering for one. Storing integer bits through a float slot
      is wrong for everything past 2**52, so refusing it is right, but it does
      mean an int cannot be assigned to a float at all. Wasm already has the
      instruction (`f64.convert_i32_s`) if the native side ever grows one.

- [x] **Converting a float to an integer yields 0, silently.**
      `my f64 $t = 3; my i64 $i = $t;` leaves `$i` at 0 rather than 3, with no
      diagnostic. This is the mirror of the entry above and is arguably worse:
      that one refuses, and this one answers. Any program that sums floats and
      then uses the total as a count is wrong without saying so, and the value
      0 is plausible enough to survive inspection.

      It is not the same fix. There is no `fptosi` in the IR either, but a
      conversion is a single instruction on all four backends -- `cvttsd2si` on
      x86-64, `fcvtzs` on AArch64 and RISCV64, `i64.trunc_f64_s` on Wasm -- so
      unlike `sitofp` there is no reason to refuse it. The missing piece is the
      IR node and the four lowerings, not a backend decision.

      Found while narrowing down the slot bug below, which is masked by it: a
      three-local float sum read back through an integer always compared equal
      to zero, so the first symptom pointed here. Fixing the slot did not clear
      it -- a single local still converts to 0 -- so the two are separate and the
      one below was not what was hiding this.

      Fixed this round by adding one signed truncating instruction rather than a
      pair, so every width combination is covered: `fptosi` in the IR with a
      `target_type`, emitted as `CVTTSD2SI`/`CVTTSS2SI` on x86-64, `FCVTZS` on
      AArch64, `FCVT.W.S`/`FCVT.L.S` on RISCV64, and
      `i32/i64.trunc_f32/f64_s` on Wasm. The AArch64 and RISCV64 encodings were
      checked instruction by instruction against `aarch64-linux-gnu-as` and
      `riscv64-linux-gnu-as`, since nothing here can run either target. Wasm
      turns out to be runnable after all -- `wasmtime` is not in the WSL path,
      but it is on Windows, which is why the two platforms report a different
      test count -- and running it was worth the detour, because the Wasm
      lowering had no `local_set`. Every value on that backend lives in a local,
      so the truncation computed its result onto the stack and nothing stored it;
      the function returned the uninitialised local 0 and the module still
      validated. `3303_wasm_float_to_int.t` builds the four combinations through
      the IR, since the frontend folds a constant conversion before it reaches a
      backend, and runs them.

      The truncation direction is pinned with negative values, so -3.5 has to
      become -3 and not -4, and a float constant is folded to its truncated
      integer here rather than left for the instruction. `3302_float_to_int.t`
      covers both on the host, and all 16 of its cases fail with the lowering
      reverted.

      The three native opcode dispatch chains also gained a terminal `else` that
      dies. A `fptosi` that reached a backend without an encoder emitted nothing
      at all and left a silently truncated function behind, which is the same
      shape of fault as this entry.

- [ ] **An unknown physical register name silently becomes register 0.**
      `reg_id` in all three native codegens ends in a bare `return 0`, so a name
      it does not recognise encodes as `rax`/`xmm0` on x86-64, `x0`/`v0` on
      AArch64, and `x0`/`f0` on RISCV64. Register 0 is a real register on every
      target, so the instruction still assembles and the program still runs.

      Found while checking the AArch64 and RISCV64 `fptosi` encodings. A probe
      asked for `ft10`, the RISC-V psABI name for `f30`, and instead of being
      rejected it was encoded as register 0, which is how a test of this kind
      quietly starts asserting against the wrong thing. The backend does not use
      those names -- `Brocken::Katsuro::Platform::ABI::RISCV64` numbers the
      argument registers `f0`-`f31` and `reg_id` matches those -- so nothing is
      broken today, but the failure mode is the reason a naming mistake costs an
      afternoon instead of a diagnostic.

      The floor is `die` on an unrecognised name. The named-register tables are
      also worth a check of their own, since the RISCV64 one hand-maps `zero`,
      `ra` and the rest and can only be right by being kept right by hand.

- [x] **Two live f64 locals can be given the same stack slot.**
      `my f64 $a = 1; my f64 $b = 2; my f64 $c = 3; if ($b == 2)` was false:
      `$b` read back 3.0, the value of `$c`. `a + b + c` gave 7.0, not 6.0.

      It needs three simultaneously live f64 locals to show, and two worked
      correctly, which is why the arithmetic tests in `3299_float_literals.t`
      passed -- they either use one local or add literals.

      It was not the frame slot assignment. The pre-allocation MIR was right,
      the live intervals were right, and the scan separated the two locals
      correctly. What happened is that a float constant reaches an XMM register
      as its bit pattern in a GPR, and MOVD/MOVQ from R8-R15 is wrong on AMD
      Zen 4, so the workaround parks the GPR in memory and reads the XMM back
      from there. It named that parking place as a literal `rsp+0x20`, which is
      where the second local is put: outgoing arguments sit at the frame bottom,
      then the locals, then the spill and caller-save area. Storing through it
      overwrote the local with the bit pattern being moved, so the local read
      back as whichever constant was moved last. Two locals stayed clear of it
      by luck, which is why the two-local cases never showed it.

      The slot is now reserved at the top of the alloca area, above every local,
      and addressed with a displacement the frame is sized to hold. The sweep in
      `3301_float_locals.t` runs three locals up to twelve for f32 and f64 and
      names the offending local by its exit status; twelve also pushes the slot
      past what a one-byte displacement can express, so the wide form of the
      addressing is covered too.

      Found by the arity sweep in `3300_float_params.t` growing into a local
      sweep: the sweep that found the REX fault hid this one, because a function
      with many parameters and no locals never allocates a local frame.

- [ ] **AArch64 and RISCV64 cannot pass arguments on the stack at all.** This is
      what the seven ARM64 CI failures actually are: all of `3298_stack_args.t`,
      plus the eight-field constructor in `3297_entry_shuffle.t`. Only the x86-64
      lowerer and codegen gained the machinery -- capturing past the register
      count in the entry block, storing the overflow at the call, reserving the
      outgoing area at the frame bottom, and the entry bias for the loads. The
      ARM64 and RISCV64 lowerers have none of it, and their ABI classes inherit
      `stack_param_offset` from the base, which returns `undef`. Both ABIs use
      eight integer registers and no shadow space, so the offsets are the SysV
      ones (callee `8 + 8i`, caller `8i`), but the frame work has to be redone
      per backend, including the same raw-stack-base trap that x86-64 hit: on
      these the base is `sp`, and it must stay out of the interval model.

- [x] **Wasm could not compile any program that declares a local variable.**
      Every frontend program with at least one `my` local was rejected by the
      Wasm validator, even `my i32 $x = 123; return $x;`. Found while adding
      `3285_alloca_count.t`; the emitted module was byte-identical before and
      after that fix, so it was a separate pre-existing defect. The Wasm tests
      that did pass build their IR by hand and keep values in virtual
      registers, which is why this went unnoticed. Compiling a frontend program
      pulls in `Brocken::Runtime::_init` and `bump_alloc`, and those exposed
      five distinct type errors; all of them were in the emitted bytes rather
      than in a missing encoder, and each one had to be found and fixed in turn
      because a validator stops at the first:
      - A literal pushed for a typed op took its width from the literal's own
        type, so an `i64.const` fed an `i32.add` in pointer arithmetic.
      - The op width came from the result type alone, so the runtime's
        `ptr + i64` picked `i32_add` and fed it an i64 local. The width now
        comes from the widest operand, the narrow one is extended, and an i64
        result landing in a pointer is wrapped back to i32.
      - A void function was declared as returning i32, so `_init` demanded a
        value its body never pushed. The frontend gives an unannotated
        function a real type object whose kind is `void`, so testing only for
        a missing return type was not enough.
      - `return 0` in a function declared `-> ptr` pushed an i64 literal into a
        function the type section declared as returning i32. `maybe_convert_type`
        had no int/ptr path, so a new `ptrcast` instruction was added and
        lowered on all four backends (a move on the native three, an explicit
        extend or truncate on Wasm).
      - An i64 value assigned to a ptr local was stored without truncation,
        leaving an i64 in an i32 local. `Wasm::_wasm_push` only re-types
        constants, so a vreg conversion has to be explicit.
      Regression: `3286_wasm_locals.t`, which compiles frontend programs with
      locals and executes them under `wasmtime`, asserting the returned value.
      The Wasm half of the alloca audit is unblocked. The sub-word-load audit
      has since been done; see "Sub-word load/store widths and C struct layout"
      above.

### Wasm call results and branch depths
- [x] **Two calls to the same function in one expression were miscompiled.**
      The frontend named every call result after the callee, so two calls to
      `g` both produced `%g_res` and the second shadowed the first. The IR is
      supposed to be SSA, and every backend maps values to registers or locals
      by name, so the two values collapsed into one and `g(20) + g(1)`
      computed `2 + 2` and answered 4 instead of 42. Call results now go
      through a Builder helper that appends a counter to a repeated name.
- [x] **The Wasm linker misplaced every call fixup after the first.**
      A `call` placeholder is five bytes and the LEB128 index that replaces it
      is one or two, so each substitution shortened the buffer, but the offsets
      recorded by the encoder assumed nothing had been rewritten yet. The
      second call in a function therefore overwrote the wrong bytes and left
      four continuation bytes in front of its index, which the validator read
      as the five-byte index `0x30000000` and rejected as out of function
      range. Any function with two calls failed to compile. Fixups are now
      applied in ascending offset order while tracking the shift.
      Regression: `3287_wasm_call_results.t`, which checks the two call results
      get distinct names and that repeated calls return the right value.
- [x] **Wasm could not compile a loop, or any branch out of a non-entry block.**
      The encoder gave each non-entry basic block a `block`/`end` pair and
      computed every branch depth as `num_non_entry - target_index`, which is
      only right for a branch out of the entry block, so any `if` failed
      validation with an unknown label and any `loop` with "branch depth too
      large". Three separate mistakes had to be fixed together. A back edge
      needs a `loop` to target, because branching to a `block` resumes after
      its `end` rather than restarting at its head, and the branch that enters
      the loop from outside needs a second plain `block` that ends just before
      the `loop` begins; neither existed. A natural loop has to stop at its
      header, or walking predecessors from the back edge pulls in the preheader
      and a loop inside an `if` swallows the `if` along with its condition, so
      `if ($i < 1) { while ($i < 3) {...} }` iterated four times instead of
      three. And the emitted order has to place a join after every arm that
      reaches it while keeping each loop's blocks in one unbroken run, which
      reverse postorder does neither of: it inserted an `if`'s continuation
      between a loop header and its body, and laid an `else` arm out *after* the
      join that arm branches back to, which no stack of labels can express
      because a label that has closed cannot be branched to again. The encoder
      now finds back edges with a depth-first walk, computes reachability-
      restricted natural loops, and emits one region at a time, placing a block
      only once all of its non-back-edge predecessors are placed. Branch depths
      come from the live label stack, so a loop header entered from outside and
      re-entered by a back edge resolve to different depths.
      Reordering blocks invalidated the call fixups recorded above: the encoder
      measured each `call` placeholder against the start of its own block, but
      the linker rewrites the whole function body, where the same call sits
      after however many `block`/`loop` opcodes the layout put in front of it.
      For an `if`, whose entry block is preceded by one `block` per target, the
      `_init` call landed on the `call` opcode itself and left the entry
      function calling itself; fixups are now collected per block and rebased
      onto the final body offset.
      Regression: `3288_wasm_control_flow.t`, twelve programs executed under
      `wasmtime` and asserting the returned value: `if`/`else`, `while`,
      division in a loop, two and three levels of nesting, a loop inside an
      `if`, a loop after an `if`, an `if`/`else` inside a loop, an `if` inside a
      nested loop, and a return from inside a loop. Ten of the twelve fail
      against the previous encoder.
- [x] **Two self-calls to the same function in one expression are miscompiled.**
      *The "values lost in the frontend" diagnosis below was wrong; the real
      cause is the Wasm heap pointer and it is still open — see the next
      entry. Recording the correction so nobody re-derives it.*
      `sub fib(i64 $n) { if ($n < 2) { return $n; } return fib($n - 1) + fib($n - 2); }`
      used to lower to `local_get(UNDEF) | local_get(UNDEF) | i32_add |
      local_set(%v<virt_reg:void/0>) | ret`, so both call results were undefined
      and the add was typed `i32`/`void` regardless of the function's result
      type. `61df315` fixed it: the call results now come out of
      `Lindsay::IR::Builder::_unique_name` as `%fib_res_1` and `%fib_res_2`, and
      all four backends emit a correct `call_func` / result pair for each. The
      earlier claim that the values were gone before MIR existed was never
      checked against the current frontend — dumping the IR now shows both
      calls present, correctly typed `i64`, and `X86_64`/`ARM64`/`RISCV64`
      produce correct MIR. The IR was right all along; the broken encoder on top
      of it is what produced the `UNDEF`.
- [x] **The Wasm heap bump pointer was a function local, so every invocation
      started it at 0 and recursion aliased every frame's spill slot.**
      `Codegen::Wasm::_encode` gave `%heap_ptr` a local index
      (`$vreg_map{'%heap_ptr'} = $next_local++`) instead of a module global.
      Wasm locals start at zero and `_init` cannot write another function's
      local, so nothing ever initialised it: the prologue of `fib` is literally
      `local.get 1` / `local.set 2` / `local.get 1` / `i32.const 8` /
      `i32.add` / `local.set 1`, and the parameter spill address is 0 in *every*
      frame. The MIR is correct and so is the instruction selection — the
      damage is only visible in the encoded bytes, which is why reading the IR
      or the MIR does not find it.
      It stays hidden while each frame reads its parameter before recursing and
      never reads it again, so `fact` (`$n * fact($n - 1)`, one call) computes
      correctly and passes for n=10. It breaks as soon as a frame re-reads a
      spilled slot *after* a recursive call, which is what
      `fib(n-1) + fib(n-2)` does: the second argument's `i64.load` sits after
      the first `call`, so it reads a slot the callee has already overwritten.
      `fib(10)` returned -80, `fib(15)` -195, `fib(20)` -360, all stable
      regardless of heap size.
      Now a mutable i32 **global** (section 6, `HEAP_BASE_GLOBAL`) read with
      `global.get`/`global.set`, seeded by the linker from the `%__heap_base`
      argument. The seed is spliced in after the function's locals declaration,
      since a body is `locals` followed by the expression, and after the call
      fixups, whose offsets are already resolved. `fib(10)` = 55, `fib(15)` = 610,
      `fib(17)` = 1597. Regression: `3290_wasm_recursion.t`.
      **Superseded in part by the second-cursor entry below.** This global used to
      hold the allocator's own cursor, seeded at `heap_base + 16` so it would sit
      clear of the cursor/limit pair in the header — the wrong layout, and the
      wrong owner. There is no per-module cursor any more: the global carries the
      raw heap base with no displacement, and the single runtime `bump_alloc` owns
      the cursor. Keeping the global rather than a function parameter is still
      required, because a spill slot can be allocated in a helper.
- [x] **Scalars were spilled to a bump cursor that is never decremented, so
      memory scaled with the total number of calls instead of the live depth.**
      Even with the cursor shared, the model was wrong: every frame copied its
      locals into linear memory and nothing ever gave the space back, so a
      recursive call tree needed `8 * (2*fib(n+1) - 1)` bytes for `fib(n)` —
      `fib(17)` = 41336 bytes, `fib(18)` = 66888, `fib(30)` = 33.2MB. The
      ceiling was therefore a function of *call count*, not stack depth, and
      raising the page count would only have slid the cliff.
      A wasm local is the engine's own per-invocation slot, reclaimed on return,
      so a slot whose address is never taken does not belong in linear memory at
      all. `Lowerer::Wasm::_promotable_allocas` promotes such a slot: a
      single-element, non-aggregate alloca whose address appears only as the
      address operand of a `load`/`store`. The alloca then emits nothing, and the
      `load`/`store` become `local.get`/`local.set` against a local typed with the
      *element* type. This is the same thing LLVM's wasm backend does for a
      whole-function `alloca`; the shadow stack is only the fallback for allocas
      that escape. Promotion applies in **any** block, not just the entry block,
      because a wasm local is per-invocation rather than per-block.
      `fib(20)` = 6765 and `fib(25)` = 75025 now run in a 1-page module that
      previously trapped, because recursion no longer touches memory at all.
      The aliasing bug above also becomes structurally impossible, since there is
      no shared spill memory left to alias. And with scalars gone from the bump
      cursor, the two-cursor overlap resolves itself: `Point->new(7)->x() * 6`
      returns **42** (it returned 6240 before), because the instance now comes
      from the runtime allocator alone.
      Regression: `3290_wasm_recursion.t` asserts at the MIR level that `fib`
      emits no alloca and no `i64_load`/`i64_store`, that an array base still
      allocates, and executes `fib(20)`, `fib(25)` and the class case.
- [x] **A slot declared inside a loop body was the last shape still spilling to
      the bump cursor, and it silently returned garbage.** Promotion was first
      restricted to the entry block, so `my ptr $p = P->new($i);` inside a `while`
      body still took a spill slot -- and that slot landed at `heap_base + 16`,
      the same address `bump_alloc` hands the instance out from. The pointer and
      the object occupied the same bytes, so a loop summing `$p->x()` over 10
      iterations returned **10760** instead of 45, with no trap and no error.
      Correct on x86_64, so it was Wasm-specific and silent. Promoting in any
      block fixes it, since a local is per-invocation and does not need a fresh
      reservation per iteration.
- [x] **A variable array index produced an invalid module.** `getelementptr` pushed
      the index at its IR width (i64) and then scaled and added it with `i32.mul`
      / `i32_add`, so wasmtime rejected the module with "type mismatch: expected
      i32, found i64". A *constant* index was folded into a displacement and
      worked, which is why `$a[3] = 10` was fine and `$a[$i] = 10` was not --
      an entire loop over an array could not be compiled. The index is now
      narrowed with `i32_wrap_i64`, matching what the pointer arithmetic in
      `Runtime::_init` already did.
- [x] **A class pointer could not be passed to a function and used there.**
      `Cannot determine class for field or method access`, from the lowerer
      before any backend runs, so it affected x86_64/ARM64/RISCV64/Wasm equally
      and was a language gap rather than a backend bug.
      `Katsuro::Lowerer::resolve_class_name` already inferred a receiver's class
      four ways: a literal class name (`P->new`), a local in `$var_class` that
      was assigned from a constructor, a call listed in
      `$function_return_class`, and finally the enclosing `$current_class` so
      that `$self` works inside a method. A `ptr` **parameter** matched none of
      them — it is a `Var` with no `$var_class` entry, and a plain `sub` has no
      `$current_class` — so `sub g(ptr $q) { return $q->x(); }` croaked. The
      machinery for "a class travels with a value" was half-built: it existed for
      return types and not for parameters.
      Promoted over the Wasm memory work because it blocked ordinary
      object-oriented code (handing a class instance to a helper is not exotic)
      on every target at once, whereas the page declaration only misbehaved past
      64KB.
      **Done as a signature annotation, not an inference.** A class name is now
      accepted in a parameter's type position, exactly as it already was in a
      return type position: `sub g(P $q)`. The parser takes a bare `IDENT` there
      as a class name, and `param_type_for` lowers it to a `ptr` while recording
      it in a new `$param_class` table alongside `$function_return_class`, which
      `resolve_class_name` consults for a receiver that is a parameter of the
      function being lowered. Keying on the current function is what makes this
      sound: two functions can each have a `$q` and only one of them is
      class-typed, so the table cannot leak by name.
      Nothing about the ABI changes — the class was always a pointer at runtime.
      What changed is that the lowerer now knows what the pointer points at.
      Kept as an explicit annotation on purpose: a bare `ptr` parameter still
      fails, and its error now names the fix rather than leaving the reader to
      work out why inference failed.
      Verified: a field read through a class-typed parameter, two parameters of
      two different classes, a class parameter mixed with a plain one, a class
      parameter forwarded to another function, one that is never used as an
      object, one passed to a class method, the per-function keying, and the two
      negative cases — all on both native and Wasm. Regression:
      `1080_class_params.t`.
- [x] **A `:reader` is registered after the explicit methods that call it, so
      `$self->field()` dies inside a method.** `generate_class_runtime` lowered
      the explicit methods in the same loop that registered them, and the
      `:reader` methods were only registered further down. `lower_method`
      resolves a callee through `$functions` and returns silently if the name is
      not there yet, so `$self->x()` inside a declared method was lowered against
      a class that had no `x` yet: "Undefined method 'x' in class 'P'". The same
      class compiled fine with no explicit method, and `$obj->x()` worked from
      outside, which is what made it look like the reader was missing rather
      than merely late. Bare `$x` was never affected — that is a field GEP
      pre-populated by `populate_field_geps`, so it never consults `$functions` —
      which is what made it easy to miss. Fixed by splitting
      `generate_class_runtime` into a registration pass and a lowering pass:
      every method the class can have (ADJUST, declared methods, readers,
      writers, constructor) is registered first, and only then is any body
      lowered, so a body can reach every method of its own class regardless of
      the order bodies are lowered in. A declared method also now wins over a
      generated accessor of the same name, so a later registration cannot
      overwrite `$functions` and leave two functions sharing one name.
      Verified: a method calling one reader, two readers, its own writer, and
      another declared method, a call and a field read agreeing, ADJUST ordering,
      a class with no fields, and the no-collision case — on native and Wasm.
      Regression: `1085_self_reader_calls.t`.
- [x] **Wasm declares one 64KB page but the runtime is told the heap is 1MB —
      for the object allocator.** `Linker::Wasm` emits `1 page, no maximum` while
      `Katsuro::Lowerer` passes `0x100000` as the heap size to `Runtime::_init`,
      so any program that allocates past 64KB traps with "out of bounds memory
      access" no matter what heap base the host hands in — the size argument is
      not honoured. Note that the two numbers are not directly comparable: the
      runtime's limit is `heap_base + 0x100000`, so honouring a 1MB heap at base
      1024 needs `ceil((1024 + 0x100000) / 65536)` = **17** pages, not 16. The
      usual fix is to declare a small minimum and grow with `memory.grow` (0x40)
      when `bump_alloc` runs out of room.
      **Done by growing on demand** (`3295_wasm_memory_growth.t`). The two
      numbers are now reconciled by a third heap field rather than by growing
      eagerly: `_init` stores `cursor`/`limit`/`cap` instead of
      `cursor`/`limit`, starts `limit` at what `memory.size` actually reports
      rather than at the 1MB that was only ever hoped for, and keeps the 1MB in
      `cap` as the ceiling. `bump_alloc` grows only when a block runs past
      `limit`, asks for exactly enough pages rounded up, and refuses past `cap`.
      A new `memory_grow`/`memory_size` intrinsic pair carries this through
      `Katsuro::Lowerer`; Wasm emits the real `memory.grow` (0x40) and
      `memory.size` (0x3F), and the three native backends answer `memory_size`
      with 0 and `memory_grow` with a constant -1, so a fixed host-carved region
      takes the same refusal path instead of a walk off the end of the heap.
      Two things were load-bearing and are worth not undoing:
      * `limit` must not start at `cap`. Seeding it at the requested 1MB is the
        original bug in a new place: every block between 64KB and 1MB fits under
        that limit, so the grow path is never reached and the write lands in
        memory the module does not own.
      * growth is bounded by `cap` on purpose. Letting a runaway program ask the
        host for whatever it wants turns a trap into memory exhaustion.
      Verified: 30000 eight-byte objects (240KB, 4x the declared page) allocate
      and sum correctly, a single 900KB block is backed and round-trips, a 2MB
      block is refused, and an object loop past the cap fails instead of
      quietly succeeding.
      **This now covers the whole heap, not just objects** — see the second-cursor
      item below, which routed arrays, escaping allocas and boxes through the same
      `bump_alloc`.
- [x] **Arrays and objects allocate from two cursors that overlap, and only the
      object one can grow.** `bump_alloc` walks a `cursor` stored in the heap,
      but an alloca whose address escapes — an array, or a scalar passed on — was
      served by a separate `%heap_ptr` Wasm global, with no limit and no growth.
      The object cursor starts at `heap_base + 24` and the global was seeded into
      the same address range, so the two hands of the allocator handed out the
      same bytes. Two failures, both confirmed:
      * `my [i64; 16384] $a;` (128KB) trapped with "out of bounds memory access
        at wasm address 0x10000 in linear memory of size 0x10000" — growth above
        did not reach it.
      * a 4-element array holding 111 and 222, followed by 5000 `P->new` calls,
        read back 111 and 0: the object allocations overwrote the array.
      **Fixed by making it one allocator.** The `%heap_ptr` global is gone; the
      module global now carries the *base* rather than a cursor, and every
      escaping block — array slots, escaping allocas, and the 16-byte `box` cell —
      is allocated by calling `Brocken::Runtime::bump_alloc` and then
      `check_alloc`, exactly as a `->new` is. One cursor, one growth path, one
      cap, one failure mode. The base has to be reachable from *any* function
      (a slot can be allocated in a helper, not just the entry), so it stays in a
      module global seeded by the entry stub; the cursor, limit and cap stay in
      the heap header where the runtime can update them.
      The element count is still required to be a literal, but that is no longer
      a Wasm limitation — it is a call argument now, so a computed count is a
      lowering question rather than something the alloca opcode cannot express.
      Verified: a 4-element array keeps 111/222 across 30000 objects, a 128KB
      array is backed, a 1.6MB array is refused rather than writing past the heap,
      and the object cases still pass. Regression: `3295_wasm_memory_growth.t`.
- [ ] **Allocation failure was unchecked, so out-of-memory was a wild write.**
      `bump_alloc` signals exhaustion by returning 0, and the class call site
      passed that straight to the constructor, which stored through a null
      pointer — a wild write rather than the allocation failure it is. Now
      routed through `Runtime::check_alloc`. It traps by storing through the null
      pointer, because the IR has no `trap`/`abort` instruction to lean on yet
      (see below), so the failure is loud but has no diagnostic message. A real
      trap instruction would make this say what actually went wrong.
- [x] **Comparing an i32 against a negative literal is false.**
      `my i32 $g = -1; if ($g == -1)` is false, and `!=` is true, on every
      target. Found while asserting that native `memory_grow` refuses: the
      refusal is correct, but the equality test for it could not be written
      without tripping this. It is in the literal comparison rather than in any
      one backend, since a plain constant in a local fails the same way, and it
      matters well beyond diagnostics — any guard written as `x == -1` silently
      takes the wrong branch.
      **Fixed in the comparison, not in a backend.** The literal is materialized
      at the wider of the two operand types, and the narrower side is promoted to
      match: `sext` for a signed source, `zext` for an unsigned one, so `-1`
      reaching an `i32` as `0xFFFFFFFF` compares against the same `0xFFFFFFFF`
      and the result is true. Narrowing the other way needed the same treatment,
      so `maybe_convert_type` now emits a real `trunc` rather than silently
      dropping high bits: added the `Trunc` IR instruction and `build_trunc`, and
      lowered it on Wasm, X86_64, ARM64 and RISCV64. A literal still has to be a
      literal, but its width no longer has to match the local's exactly.
      Verified: `my i32 $g = -1; $g == -1` and `$g != -1`, the same for `i64`,
      a narrow local against a negative literal, a wider-local-against-narrower
      narrowing case, and mixed-sign ordering all give the right answer on both
      native and Wasm. Regression: `1070_type_promotion.t`.



### Wasm entry ABI
- [x] **The heap-base argument is a real parameter, not a leftover.**
      `Katsuro::Lowerer::register_function` prepends a `%__heap_base` pointer to
      `_BROCKEN_ENTRY`, matching `docs/spec.md` 2.9: the runtime is a bump
      allocator and the host hands it the base of the region to hand out. The
      native linkers supply it from an entry stub (ELF64 carves the heap off
      the stack and passes `rsp`); the Wasm linker emits no stub and exports the
      function directly, so `wasmtime run --invoke _BROCKEN_ENTRY` needs the
      address as a trailing argument, after the module path. This is what
      unblocked executing Wasm output in `3286`/`3287`.
- [ ] **The Wasm module has no `_start` or `main` export, so
      `wasmtime run module.wasm` cannot run it as a WASI command** and every
      invocation has to name `--invoke _BROCKEN_ENTRY` and pass a heap base as a
      trailing argument. A real entry stub that calls `_BROCKEN_ENTRY` with the
      `__heap_base` global would match the other three backends, which all get
      their heap base from a linker-supplied stub. Two knock-on effects worth
      deciding in the same change: the `--invoke`-plus-argument convention is
      baked into every Wasm test, and a `_start` cannot take a heap-base
      parameter at all, so the base has to come from a data-segment or global
      initialiser instead — which also decides what the default heap size is for
      a module run without arguments.
- [ ] **The Wasm linker has two independent memory-section emitters that must be
      kept in step.** `Linker::Wasm::write_executable` builds the multi-function
      module (memory section at `Wasm.pm:96-98`, the heap-base global at
      `:110-118`, entry-stub seed at `:128-144`) and a single-function path
      emits its own (memory section at `:183`, global at `:191-199`, seed at
      `:201-208`). Any change to the declared memory — initial page count, a
      maximum, growth — or to the runtime's heap header size has to be applied
      twice, and the single-function path is the one that is easy to forget
      because the multi-function tests cover the other. This is not
      hypothetical, and it has now bitten twice:
      * adding a third heap word took the header from 16 to 24 bytes, and the
        `i32.const 16` in both stubs then seeded the global on top of `cap`,
        which silently stopped growth for every program that used an array. Both
        were fixed by hand to `0x18`.
      * routing arrays through the runtime allocator removed the seeding offset
        entirely — the global now holds the *raw* base, so both stubs seed it
        with `local.get 0` and no displacement, while the `+24` that skips the
        header moved into `bump_alloc` where the layout is known. The single
        function path was updated in the same change, which is the only reason
        the two agree today.
      Worth folding into one helper, or adding a test that asserts both paths emit
      byte-identical memory sections and identical seeds. Note that the
      single-function path cannot run the `box`/`unbox` case any more: the
      allocator it would need is not linked into it, which is why `3240` now
      builds a real five-function module.

### Phase B: Int/Bool native alias support
- [x] Lower `Int` and `Bool` as native types (i64/i1)
- [x] Update `maybe_convert_type` for Int→int aliasing
- [x] Constant lowering for `Int`/`Bool`
- [x] Parser: add `int`, `bool`, `u8`..`u128` keywords

### Phase C: String Constants & .rodata
- [ ] Add `.rodata` section to linkers (ELF64, PE, MachO, Wasm)
- [ ] Lower string literals to `.rodata` (length-prefixed, null-terminated)
- [ ] Emit `lea`/ADRP+ADD to reference `.rodata` addresses
- [ ] Wire `say`/`print` to `.rodata` strings (replace alloca+store)

### Phase D: Struct Types (IR level)
- [ ] Add structural type to IR: `Type::struct([field_types...], [field_names...])`
- [ ] Extend GEP for struct field access (byte offset from struct layout)
- [ ] Lower field access to struct-aware GEP

### Phase E: Signedness in Binop Lowering
- [x] Default signedness for `int` type (signed i64; same for `Int`)
- [x] Propagate signedness through `lower_binop`:
  - `/` → `div` (signed) or `udiv` (unsigned)
  - `%` → `rem` (signed) or `urem` (unsigned)
  - `<`/`>`/`<=`/`>=` → signed predicates (`slt`/`sgt`/`sle`/`sge`) or unsigned (`ult`/`ugt`/`ule`/`uge`)
- [ ] Add `<<`/`>>` shift operators to parser + lexer; `>>` → `ashr` (signed) or `lshr` (unsigned)
