# Brocken Compiler Roadmap

Now that the foundational IR (Lindsay) and Platform abstraction (Katsuro) are in place, we need to bridge the gap between abstract SSA and executable machine code.

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
- [x] Spill code insertion integrated into all 3 native codegens (X86_64, ARM64, RISCV64) — handles reload-before-use, spill-after-def, and `mem` operand base vregs.
- [x] `mem` operand bases tracked in liveness analysis (fixed the float crash bug).
- [x] `_vreg_names_from_mem_operands` extracts vreg names from `mem(base="%vreg")`.

### Calling Conventions
- [x] **Proper unified stack frame** — single-frame allocation combining callee-saves + spill slots, aligned to 16 bytes.
- [x] **Spill slot offsets** — relative to `$stack_reg` (RSP/SP), correct.
- [x] **RISCV64 prologue/epilogue** — integrates allocator's `used_callee` list; saves/restores int + FP registers.
- [x] **ARM64 leaf detection** — skips `x30` save/restore for leaf funcs.
- [ ] **Leaf function optimization** — partial on ARM64/RISCV64 (only link reg), missing on X86_64. Should skip all callee-save save/restore for leaf functions.
- [x] **Caller-save register handling** — `insert_caller_save_code` called in all 3 native codegen pipelines, skipping return registers (`rax`/`xmm0`, `x0`/`v0`, `a0`/`fa0`).
- [x] **Move coalescing** — `remove_redundant_moves` called in all 3 native codegen pipelines, eliminates `mov` where src/dst map to the same physical register.
- [ ] **Floating-point callee-save on X86_64** — SysV ABI marks all XMM as caller-saved; codegen only uses `PUSH` (GP-only). Would need `MOVUPS`/`MOVDQA` stack save/restore for non-SysV ABI variants.

### ABI Integration
- [x] All 4 Lowerers query `param_registers()`, `return_register()`, `fp_return_register()` from `Platform::ABI`.
- [ ] **Wide-type register pairs** — no `param_pair_registers()` or equivalent exists. i128 returns hard-code the second register (`rdx`/`x1`/`a1`) instead of querying the ABI.

### 128-bit Numerics (i128)
- [x] i128 binops (add/sub/and/or/xor/shl/lshr/ashr/mul) — all 4 targets.
- [x] i128 return values — correctly split into lo/hi across two registers on native targets.
- [x] i128 load/store — all 4 targets, via `_split_i128`.
- [ ] **i128 call arguments** — not split; passes single i128 values through registers designed for 64-bit scalars.
- [ ] **i128 entry block parameters** — not split; same issue as call arguments.
- [ ] **Signed i128 div/rem** — all targets use unsigned algorithm; no sign-extension or absolute-value handling.
- [ ] **i128 `min`/`max`** — not implemented on any target for i128 width.
- [ ] **Large-value i128 tests** — all test values fit in 64 bits; no hi-part carry/borrow exercised.
- [ ] **Endianness** — no handling for big-endian targets.

## Phase 3: The Frontend (Parser & AST)
- [ ] Implement a lexer and parser for a subset of Perl syntax (`for`, `if`, `sub`, `my`).
- [ ] Create an AST (Abstract Syntax Tree).
- [ ] Implement a `Codegen` visitor that traverses the AST and uses `Lindsay::IR::Builder` to emit IR.

## Phase 4: Runtime & Builtins
- [ ] Create a minimal `libbrocken` (likely in C or Assembly) for basic I/O (printing scalars).
- [ ] Implement the "Fat Scalar" memory layout (Type Tag + Payload).
- [ ] Basic memory management (a simple bump allocator or integrating `malloc`).

## Phase 5: Optimization (The "Lindsay" Middle-end)
- [ ] Constant Folding pass.
- [ ] Dead Code Elimination (DCE).
- [ ] Simple Inlining.
