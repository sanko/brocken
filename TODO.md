# Language Milestones & TODO

Here is your roadmap for the Pulse Language transition to self-hosting.

## **Milestone 0: The Binary Foundation**
- [x] Pure Perl X64 Emitter.
- [x] PE64 (Windows) Formatter.
- [x] ELF64 (Linux) Formatter.
- [x] Position Independent Code (ASLR support).
- [x] Basic System Calls / WinAPI Imports.
- [ ] Low level jmp, mov, and relocation support

## Milestone 1: Stage setting
- [ ] Early IR to replace manually building the exe from scratch
- [ ] Tail call optimization
- [ ] Leaf optimization
- [ ] Allocator spilling tests (Cheney)
- [ ] Implement a simple mark-and-sweep or Cheney copier.
- [ ] Pointer handling and complex chaining
- [ ] Arithmetic (IMUL)

## **Milestone 2: The Logic Engine**
- [ ] Add `mul`, `div`, and floating point (SSE/AVX).
- [ ] Stack Frames. Proper `push rbp; mov rbp, rsp` for subroutines.
- [ ] Scalar variables (strings and numerics):
    - Global (Data section offsets).
    - Local (RBP-relative stack offsets).
- [ ] Subroutines: Implement `call` and `ret` with parameter passing (Win64 vs SysV ABI).
- [ ] Closures
- [ ] Namespaces
- [ ] Operators
- [ ] Inequalities, precidence, if/elsif/else, etc.
- [ ] Futhark-style map merging (might be in milestone 1 if I'm feeling it) and parallelized map and grep

## **Milestone 3: Data Structures (The "Perl" Experience)**
- [ ] Arrays: Heap-allocated contiguous memory with bounds checking.
- [ ] Hashes: Built-in DJB2 or MurmurHash implementation in assembly.
- [ ] Classes: first class based on perlclass (no bless) with method dispatch, inheritence, roles, etc.
- [ ] Tuples: Stack-allocated fixed-size structures.

## **Milestone 4: Advanced Runtime**
- [ ] Fibers: Context switching by saving/restoring `rsp` and registers.
- [ ] OS Threads: Wrapping `CreateThread` (Win) and `clone` (Linux).
- [ ] Regex Engine: A recursive descent or backtracking engine compiled to machine code.
- [ ] FFI: Integrate `Affix` logic with direct infix use
- [ ] Systemcall: should handle exceptions
