
# Brocken Compiler Architecture

## What This Compiler Does

Brocken takes Brocken source code, chews through a few phases, and spits out a native executable. No GCC. No LLVM. No JIT library. Just Perl 5 and raw machine code bytes.

The supported output formats are Windows PE, Linux ELF, WebAssembly, or macOS Mach-O, for x64, ARM64, or RISCV64.

This project serves two kinds of readers:
- **Perl programmers** curious about how compilers work.
- **Compiler devs** who want to contribute new features, ports, or optimizations.

## The Pipeline

The compiler is divided into three major namespaces: **Katsuro** (Frontend & Platform), **Lindsay** (Middle-end IR), and **Jenny** (Backend & Linker).

```text
Source Code (Brocken) + core.brocken (Runtime)
    │
    ▼
┌─────────────┐  Katsuro Lexer: characters → tokens
│  Frontend   │  Katsuro Parser: tokens → AST
└─────────────┘
    │
    ▼
┌─────────────┐  Lindsay Lowering: AST → IR
│ Middle-end  │  (Translates `Brocken::` pseudo-namespace to raw memory ops)
│             │  Lindsay Optimizer: IR → optimized IR (DCE, Constant Folding)
└─────────────┘
    │
    ▼
┌─────────────┐  Jenny Codegen: IR → MIR (Machine IR)
│  Backend    │  RegAlloc: Linear Scan (with Spill & Caller-Save handling)
│             │  Jenny Lowerer: MIR → Machine Code Bytes
└─────────────┘
    │
    ▼
┌─────────────┐  Jenny Linker: Machine Code → .exe / .elf / .macho / .wasm
│   Format    │  (Resolves labels, computes RVAs, emits DWARF)
└─────────────┘
    │
    ▼
Native Executable
```

## Core Namespaces

**`Brocken::Katsuro` (Frontend & Platform)**
Handles the Lexer, Parser, AST generation, and Platform Abstraction (OS/ABI detection, syscall numbers, register sets).

**`Brocken::Lindsay` (Middle-end IR)**
Handles the Abstract Syntax Tree (AST), the SSA-like Intermediate Representation (`IR::Instruction`), and optimization passes. The `Builder` emits the linear instructions.

**`Brocken::Jenny` (Backend Codegen & Linker)**
Lowers Lindsay IR into Machine IR (MIR), performs Register Allocation, emits native x64/ARM64/RISCV64/Wasm machine code, and packages it into executable formats (ELF, PE, Mach-O).

## Design Decisions That Matter

### Self-Hosted Runtime (`libbrocken`)
We do not link against an external C runtime. The runtime (GC, Fibers, I/O) is written in a subset of Brocken itself (`core.brocken`). The Katsuro frontend silently parses this file and prepends its AST to the user's code before lowering.

### Share-Nothing Isolates & Cooperative Fibers
Brocken implements concurrency via OS-level Isolates and user-level Fibers. Because an Isolate shares absolutely no memory with other Isolates, the heap is completely thread-local. This means **Garbage Collection and Reference Counting require zero atomic locks**, ensuring massive performance gains.

### Deterministic RC + Immix Allocation
Brocken relies on **Immediate Reference Counting** to guarantee deterministic scope-based destruction (`DESTROY`). To solve the circular reference problem, it uses the **Bacon & Rajan Trial Deletion** algorithm. Under the hood, memory is grabbed using an **Immix Bump-Allocator** (32KB blocks) for C-like allocation speeds.

### Unsafe Native Subset
To self-host the runtime, Brocken exposes raw machine types (`i64`, `f64`, `ptr`) and the `Brocken::` pseudo-namespace. Calling `Brocken::load_i64($ptr)` bypasses function overhead entirely and emits a raw `load` IR instruction.

### Tagged Variants for Gradual Typing
`my $x` without a type gets **Any** - a 16-byte Fat Scalar containing the Reference Count, GC Flags, a Type Tag, and a Payload. `my i64 $x` gets a raw, unboxed machine integer.

## Running It

```bash
perl brocken.pl
```
