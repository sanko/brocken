# Brocken Compiler Roadmap

Now that the foundational IR (Lindsay) and Platform abstraction (Katsuro) are in place, we need to bridge the gap between abstract SSA and executable machine code.

## Phase 1: Lowering & Instruction Selection (Jenny Expansion)
Currently, `Brocken::Jenny` uses hardcoded byte stubs. We need a systematic way to lower IR to machine instructions.
- [x] Implement a `Lowerer` that converts SSA `Lindsay` IR into platform-specific "Machine IR" (MIR).
- [x] Support complex addressing modes in MIR (`[base + disp]` via `mem` operands).
- [x] Implement instruction selection (Lowerer + Encoder pipeline) for `X86_64`, `ARM64`, `RISCV64`, and `Wasm`.
- [x] Handle "Fat Scalar" (dynamic) operations in the backend (lowering `box`/`unbox`) for all 4 targets.
- [x] Implement memory ops (`alloca`/`load`/`store`/`store_imm`) for all 4 targets.
- [x] Fix operand size selection in encoders (32-bit vs 64-bit load/store) for x86_64, ARM64, RISCV64.
- [x] Support indexed addressing modes in MIR (`[base + index * scale + disp]`).
- [x] Implement `mul` lowering for `X86_64`, `ARM64`, `RISCV64` (currently only Wasm has it).
- [x] Implement control flow lowering (conditional branches, jumps) for If/Else and Loops.
- [x] Implement multi-function support (lower `call` IR to cross-function calls, link multiple functions) [all 4 backends + all 3 linkers + Wasm]

## Phase 2: Register Allocation
SSA uses infinite virtual registers; hardware does not.
- [x] Design Register Allocator interface (vreg_map in _encode).
- [x] Implement Linear Scan Register Allocator.
  - [ ] **Still needs work: spilling, multi-block liveness, proper register allocation** — allocator currently assigns all vregs to `rax` regardless of count.
- [ ] **Calling conventions (spilling, move-coalescing, stack frame)**
  - [ ] Move coalescing — remove redundant `mv`/`mov` where src and dst end up in same phys reg
  - [ ] Proper stack frame layout — unified frame size (callee saves + spills + allocas + alignment), prologue allocation, epilogue deallocation, frame pointer setup (x29/rbp)
  - [ ] Spill slot offsets relative to actual stack/frame pointer (currently from 0)
  - [ ] Multi-block liveness analysis — CFG-aware live ranges instead of global linear index
  - [ ] Leaf function optimization — skip callee-save save/restore for leaf functions (already detected for ARM64 x30, extend fully)
  - [ ] Caller-save register handling — teach allocator that `call_func` clobbers caller-save regs; insert spill/reload around calls or prefer callee-save for long-lived values
  - [ ] Floating-point callee-save on X86_64 — save/restore xmm6-xmm15 (SysV ABI); ARM64 already handles v8-v15
  - [ ] RISCV64 prologue/epilogue integration with allocator's `used_callee` list
- [ ] **Integrate `Katsuro::Platform::ABI`** — use ABI queries for arg/ret assignment (pair registers for wide types)
- [ ] **128-bit numerics** (full i128 support across all targets)
  - [ ] i128 call arguments — split i128 args into lo/hi and use two consecutive arg registers
  - [ ] i128 entry block parameters — split i128 params into lo/hi vregs from two consecutive phys regs
  - [ ] Signed i128 div/rem — absolute-value-and-adjust for ARM64, RISCV64, Wasm (X86_64 uses libgcc)
  - [ ] i128 `min`/`max` — add to ARM64/RISCV64/Wasm i128 handling, or remove from X86_64 for consistency
  - [ ] i128 ABI queries — `param_pair_registers()` or equivalent in `Platform::ABI` for wide types
  - [ ] Endianness — document or handle big-endian targets (aarch64_be) for i128 load/store
  - [ ] Large-value i128 tests — test values >2^64 to exercise hi-part arithmetic and carry chains

## Phase 3: The Frontend (Parser & AST)
We shouldn't be writing IR by hand in tests forever.
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
