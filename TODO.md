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

## Phase 2: Register Allocation
SSA uses infinite virtual registers; hardware does not.
- [x] Design Register Allocator interface (vreg_map in _encode).
- [x] Implement Linear Scan Register Allocator.
- [ ] Handle calling conventions (spilling, move-coalescing).
- [ ] Integrate `Katsuro::Platform::ABI`.
- [ ] 128bit numerics

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
