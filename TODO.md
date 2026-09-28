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

### Wasm sub-word load/store widths
- [ ] Wasm loads and stores an i8/i16 through a full 32-bit `i32_load`/`i32_store` rather than `i32_load8_s`/`i32_store8` and friends. The lane holds a sign-extended value, so a single sub-word access round-trips correctly today, but any neighbouring access to the adjacent 3 bytes reads or writes the wrong cells. Needs an audit of struct field layout and byte-sized accesses before it can be called correct.
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
      The Wasm halves of the alloca and sub-word-load audits are unblocked.

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
- [ ] **Two self-calls to the same function in one expression are miscompiled.**
      `sub fib(i64 $n) { if ($n < 2) { return $n; } return fib($n - 1) + fib($n - 2); }`
      lowers to `local_get(UNDEF) | local_get(UNDEF) | i32_add |
      local_set(%v<virt_reg:void/0>) | ret`, so both call results are undefined
      and the add is typed `i32`/`void` regardless of the function's result
      type. `fib(15)` is rejected by the validator (`type mismatch: expected
      i64 but nothing on stack`) or returns a wrong answer, depending on the
      shape. Two calls to a *different* function are fine (that is
      `3287_wasm_call_results.t`), as is one self-call added to a constant; it
      is specifically two calls to the enclosing function that lose their
      values. Confirmed against `61df315` with the Wasm encoder stashed, so it
      predates the control-flow work and is not caused by it. The values are
      already lost in the frontend by the time MIR exists, so this affects every
      backend and cannot be fixed in the Wasm encoder.

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
- [ ] The Wasm module still has no `_start` or `main` export, so `wasmtime run
      module.wasm` cannot run it as a WASI command and every invocation has to
      name `--invoke _BROCKEN_ENTRY` and pass a heap base. A real entry stub
      that calls `_BROCKEN_ENTRY` with the `__heap_base` global would match the
      other three backends. The linker also still declares a single 64KB memory
      page, while the runtime is told the heap is 1MB, so a program that
      allocates more than one page traps.

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
