# Code Generation and Backends (Jenny)

The backend pipeline consists of three layers:
- `Brocken::Jenny::Codegen` - Orchestrates lowering, register allocation, and encoding.
- `Brocken::Jenny::Lowerer` - Lowers Lindsay IR to Machine IR (MIR) for a specific target.
- `Brocken::Jenny::RegAlloc` - Linear scan register allocator.

## Intermediate Representation (Lindsay IR)

Each instruction is an object with an `opcode`, `type`, `dest`, and `operands`.

### Memory & GC Lifecycle
- `incref` - Increments the reference count of a Fat Scalar or Heap Pointer.
- `decref` - Decrements the reference count. If 0, frees. Otherwise, buffers for cycle collection.
- `alloca` - Allocates stack memory.
- `load` / `store` - Read/Write memory.
- `store_imm` - Store an immediate directly to memory.
- `getelementptr` - Compute a memory address (base + index * scale + disp).

### Control Flow
- `label` - Code location marker.
- `jmp` - Unconditional jump.
- `cond_br` - Conditional branch.
- `call` - Call a function (handles arguments via ABI registers).
- `ret` - Return from a function.

### Arithmetic / Logic
- `add`, `sub`, `mul`, `div`, `rem` - Integer math.
- `fadd`, `fsub`, `fmul`, `fdiv` - Floating-point math.
- `and`, `or`, `xor`, `shl`, `lshr`, `ashr` - Bitwise operations.
- `icmp` - Integer comparisons (`eq`, `ne`, `slt`, `ult`, etc.).

### Fat Scalars
- `box` - Wraps a native type into a 16-byte dynamic Fat Scalar.
- `unbox` - Extracts a native type from a Fat Scalar.

## Register Allocator (`Jenny::RegAlloc`)

The allocator uses a **Linear Scan** algorithm directly on the MIR.

1. **Liveness Analysis:** Uses fixed-point backward dataflow to determine exact live ranges (aware of CFG branches/loops).
2. **Allocation:** Iterates over live intervals, assigning available physical registers.
3. **Spilling:** If it runs out of registers, it spills the interval with the furthest end point to a local stack slot, inserting `load`/`store` operations.
4. **Caller-Save Insertion:** Wraps function calls with saves/restores for active caller-saved registers.

The register pool is fetched dynamically via the `Brocken::Katsuro::Platform::ABI` layer (e.g., `x86_64` vs `aarch64`).

## Target Lowerers

Files: `lib/Brocken/Jenny/Lowerer/*.pm`

The lowerers convert abstract Lindsay IR into target-specific MIR.
*   **X86_64:** Utilizes complex addressing modes (SIB). Handles `umulh` and `div` mapping to RDX/RAX logic.
*   **ARM64:** Maps to pure RISC load/store architecture.
*   **RISCV64:** Similar to ARM64, utilizes standard 32-bit/64-bit integer extensions.
*   **Wasm:** Converts linear IR into the Wasm stack-machine format, emitting `local_get` and `local_set`.

## Adding a New Architecture

1. Create `lib/Brocken/Katsuro::Platform::ABI::YourArch.pm` to define register mapping and calling conventions.
2. Create `lib/Brocken/Jenny/Lowerer/YourArch.pm` to map Lindsay IR to MIR.
3. Create `lib/Brocken/Jenny/Codegen/YourArch.pm` to encode the MIR down to raw machine bytes.
