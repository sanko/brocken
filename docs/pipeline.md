# The Brocken Compilation Pipeline

Seven phases. Each one transforms the program into a different representation.

## Phase 1: Platform Detection (`Brocken::Katsuro::Platform`)
Figures out what OS and CPU we're on (e.g., `x86_64-pc-linux-gnu`) and calculates ABI constraints, syscall numbers, and register sets.

## Phase 2: Lexer (`Brocken::Katsuro::Lexer`)
Turns source text into an array of tokens (`NUM`, `STRING`, `KEYWORD`, `IDENT`, `VAR`, `OP`).

## Phase 3: Parser (`Brocken::Katsuro::Parser`)
A Pratt Parser (top-down operator precedence) that turns tokens into an Abstract Syntax Tree (AST). It recognizes standard Perl logic as well as the Unsafe Native types (`my ptr $x`, `Brocken::load_i64()`) required for the self-hosted runtime.

## Phase 4: Lowering (`Brocken::Lindsay::Lowering`)
Walks every AST node and emits linear `Brocken::Lindsay::IR` instructions.
*   **Runtime Integration:** Parses `core.brocken` and prepends its AST so the runtime compiles directly into the executable.
*   **GC Injection:** Injects `incref` operations on assignment and utilizes the Defer Stack to emit `decref` operations at scope exit.

## Phase 5: Optimizer (`Brocken::Lindsay::Optimizer`)
Performs Middle-end IR transforms.
*   **Constant Folding:** Folds static operations at compile time.
*   **Dead Code Elimination (DCE):** Removes unreachable instructions.
*   **RC Elision (Perceus-lite):** Removes redundant `incref`/`decref` pairs.

## Phase 6: Code Generation (`Brocken::Jenny::Codegen`)
Translates IR to Machine IR (MIR).
*   **Register Allocation:** Performs Fixed-Point Liveness Analysis and Linear Scan allocation, handling spills and Caller-Saved registers.
*   **Instruction Dispatch:** Maps MIR to raw `x86_64`, `aarch64`, `riscv64`, or `wasm` instruction bytes.

## Phase 7: Format & Linker (`Brocken::Jenny::Linker`)
Packages the raw machine code + data into an executable binary (`PE`, `ELF`, `Mach-O`, `Wasm`). Computes layout offsets, RVAs, cross-function call fixups, and DWARF debug information.
