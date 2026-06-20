# Brocken Internals

This document covers the internal structure of the Brocken compiler and debugging tips.

## Debugging the Pipeline

### IR Dump
```perl
$lowering->builder->dump_ir("AFTER LOWERING");
```
Prints every Lindsay IR instruction with its assigned virtual registers.

### GDB (Linux)
```bash
gdb ./brocken_out
(gdb) break *0x140001000
(gdb) run
(gdb) info registers
```

### Common Pitfalls
- **Stack alignment**: x64 ABI needs RSP 16-byte aligned before `call`. `Jenny::RegAlloc` calculates the `unified_frame` size to handle this automatically, but custom assembly hooks must respect it.
- **Missing labels**: Jump to 0x0 usually means you referenced a label that wasn't resolved by the Linker.

## Key Namespaces & Files

| File | Purpose |
|------|---------|
| `Brocken::Katsuro::Platform` | OS, ABI, architecture constraints |
| `Brocken::Katsuro::Lexer` | Tokenizer |
| `Brocken::Katsuro::Parser` | Pratt parser -> AST |
| `Brocken::Lindsay::IR` | IR Builder and Node definitions |
| `Brocken::Lindsay::Lowering` | AST → IR translation |
| `Brocken::Lindsay::Optimizer` | IR transforms (DCE, Folding) |
| `Brocken::Jenny::Codegen` | Orchestrator for MIR |
| `Brocken::Jenny::RegAlloc` | Liveness Analysis & Linear Scan Allocator |
| `Brocken::Jenny::Lowerer::*` | MIR emitters (x64, ARM64, RISCV64, Wasm) |
| `Brocken::Jenny::Linker::*` | Executable Format writers (PE, ELF, Mach-O) |

## Data Structures

**Isolate Control Block** (R14-relative on x64):
Isolates are share-nothing OS threads. All memory state is kept here to prevent atomic locks.
```perl
iso_offset => {
    state_ptr             => 0,   # Runtime flags
    current_fcb           => 8,   # Active Fiber Control Block
    fiber_head            => 16,  # Head of fiber linked list
    immix_cursor          => 24,  # Current bump-allocation pointer
    immix_limit           => 32,  # End of current Immix block
    free_blocks           => 40,  # Free 32KB block list
    suspect_buffer_head   => 48,  # Start of RC cycle suspect list
    suspect_buffer_tail   => 56,  # End of RC cycle suspect list
}
```

**Fiber Control Block**:
Fibers are cooperative coroutines. They contain no shadow stack, just raw machine stack boundaries.
```perl
fcb_offset => {
    sp           => 0,    # Saved RSP when suspended
    stack_base   => 8,    # Stack allocation base
    stack_limit  => 16,   # Stack end (guard page)
    caller       => 24,   # FCB that called transfer()
    next         => 32,   # Next FCB in Isolate's fiber list
}
```
