# Brocken Compiler Roadmap

Now that the foundational IR (Lindsay) and Platform abstraction (Katsuro) are in place, we need to bridge the gap between abstract SSA and executable machine code.

## Open work by namespace

The sections below are ordered by when the work was found and why. This is the same
open work seen from the other side: which namespace owns it. Each line points at the
section carrying the detail, so nothing here is stated twice.

### `Brocken::Katsuro` — front end

Lexer, parser, AST, `Katsuro::Lowerer`, and the `Platform`/`ABI` classes. A fix here
changes what every target is handed.

- Dynamic (boxed) types at top level — [Upcoming](#upcoming)
- Hash support — [Upcoming](#upcoming)

### `Brocken::Lindsay` — the IR

Types, values, instructions, blocks, functions, and the builder. Work here needs an
instruction or an IR pass, not a change to any one target.

- Perceus: borrow inference, RC elision, reuse analysis, FBIP — [R4](#r4-perceus-rc-elision--reuse-lindsay-optimizer-pass)
- `fptrunc`/`fpext`, so mixing `f32` and `f64` is not a hard error — [Open](#open)
- `fptoui`, plus a chosen NaN and overflow rule for float→int — [Open](#open)
- Source locations carried through to diagnostics — [Upcoming](#upcoming)
- Channel instructions stay stubs until the data structure exists — [Channels](#channels-blocked-until-immix-allocator)

### `Brocken::Jenny` — back end

MIR, the per-target lowerers, register allocation, codegen, and the linkers. Work here
is per architecture or per object format.

- Big-endian targets, which no lowering handles — [128-bit Numerics](#128-bit-numerics-i128)
- Mixed integer/floating arguments wrong on x86-64 Linux ELF — [Known Bugs](#known-bugs)
- Wasm: a call result is lost when the same expression calls again — [Known Bugs](#known-bugs)
- Wasm: no float bitwise, shift or remainder — a float is truncated in the frontend, so this target is handed an integer operation; see [Fixed](#fixed)
- Wasm: a returned box/list outlives its frame and traps at run time — fixed, see [Known Bugs](#known-bugs)
- x86-64: a value above 2^32 loses its high half — [Known Bugs](#known-bugs)
- x86-64: a 64-bit dividend under a small non-power-of-two divisor — corrected: measurement artifact from exit code masking; no general typed-i64 div bug found (see probe sweep). [Known Bugs](#known-bugs)
- Floating-point callee-save on X86_64 — [Calling Conventions](#calling-conventions)
- Channel lowering past the stubs — [Channels](#channels-blocked-until-immix-allocator)
- ARM64 macOS varargs register save area, needs a run on Apple Silicon — [Known Issues (Remaining)](#known-issues-remaining)
- illumos isolate segfaults — [Untouched by this series](#untouched-by-this-series)
- A stack map section for GC root enumeration — [R5](#r5-future-runtime-work)

### Runtime and fuzzer

Neither is a stage of the compiler, so neither is a namespace.

- Fiber stack scanning, UTF-8 strings, self-hosted PerlIO — [R5](#r5-future-runtime-work)
- Fuzzer expansion, phases F0–F9 — [Fuzzer Expansion Plan](#fuzzer-expansion-plan)
- How these bugs are found and what the tests have to execute — [Test-process lessons](#test-process-lessons)

## Active Sprint: Compiler Audit Fixes (2026-10)

A pass over the back end, front end, linkers and fuzzer turned up the faults below.
Each entry records the fix, where it lands, and the regression test that holds it.
One commit per fix. The audit's own numbering is kept so a finding can be traced back.

### P0 — code generation and the allocator
- [x] **1.1 x86-64 `div128_64` fast path is malformed**  the codegen took operand 0 as the divisor, never loaded `RAX`/`RDX`, and never stored the quotient, and the lowerer's fast path dropped the two remainder captures, so a spilled divisor and `r_hi` reloaded into the same scratch. Codegen is back to `[dst, src_lo, src_hi, src_div]` with a memory operand allowed in every slot, the lowerer captures `r_hi`/`r_lo` into `rdx` between the two `DIV`s, and the spiller no longer maps every reloaded operand onto one scratch. Covered by `t/3000_jenny/3200_codegen/3268_i128_unsigned_divrem_native.t`.
- [x] **1.2 Wasm scalar integer `min`/`max` name opcodes that do not exist**  integer `min`/`max` now lower to a signed compare plus `select` (float still uses the real `f32`/`f64` opcodes). Covered by `t/3000_jenny/3200_codegen/3300_wasm_integer_minmax.t`.
- [x] **1.3 `fix_call_shuffle` wipes the `lea_rodata` label**  the re-emit guarded the operand-1 rewrite behind the opcode and a non-empty read list, so a `lea_rodata` item keeps its label. Covered by `t/3000_jenny/3200_codegen/3301_call_shuffle_rodata.t`.

### P0 — architecture and ABI
- [x] **2.1 RISC-V codegen dies on a spilled memory source**  the spiller rewrites a spilled source to a `mem` operand for the arithmetic ops, which ARM64 loads into a scratch but `Codegen::RISCV64` handed to `$resolve`, which died. The encoder now pulls the value into a scratch (tracking the reserved spill registers so it cannot clobber a spilled destination) before the register form. Covered by `t/3000_jenny/3200_codegen/3302_riscv_mem_source.t`.
- [x] **2.2 ARM64 `_build_create_thread_fn` is dead and incomplete**  it leaves `x2`/`x3` uninitialized and nothing calls `_create_thread`; the Windows isolate path calls `CreateThread` directly. Drop the thunk and its emission. Covered by `t/3000_jenny/3200_codegen/3303_arm64_drop_create_thread_thunk.t`.
- [x] **2.3 `_brocken_gate_dispatch` does not forward stack arguments**  the trampoline builds its own frame, so an `a4`/`a5` the callee reads comes from the trampoline's frame, not the caller's. Copy the incoming stack arguments into the outgoing slots before `call_indirect`. All three backends now read `a4`/`a5` from the entry stack (frame-relative on x86-64) and store them into the outgoing argument area, which the call frame reserves. Covered by `t/3000_jenny/3200_codegen/3304_gate_dispatch_stack_args.t`.

### P0 — register allocation
- [x] **3.1 spill temp selection can return undef**  `$spill_temp = pop @caller_regs` with an exhausted pool now falls back to the callee set (recorded in `used_callee` so the prologue saves it), and croaks when nothing is left. Covered by `t/3000_jenny/3200_codegen/3305_spill_temp_exhaustion.t`.
- [x] **3.2 the call-shuffle floating-point scratch can be an argument register**  `fix_call_shuffle` no longer takes the FP spill temp (`v7` on ARM64, an argument register); the ARM64 backend passes `$platform->abi->fp_entry_shuffle_temp` (`v31`) so a parallel move whose sources cross a parameter register is still scheduled. Covered by `t/3000_jenny/3200_codegen/3306_arm64_call_shuffle_fp_temp.t`.
- [x] **3.3 a self-move hides a needed caller-restore**  `remove_redundant_caller_restores` now drops the reload only when the following copy's source is a *different* register; `mov R, R` preserves the already-clobbered value, so the reload survives. Covered by `t/3000_jenny/3200_codegen/3307_caller_restore_self_move.t`.

### P1 — linkers
- [x] **4.1 ELF64 entrance stub keeps a stale `$got_exit`**  the stub is built before the import/setjmp stubs grow `.text` and shift `.got`; nothing rebases the baked-in displacement. The entrance stub is rebuilt and the import-stub displacements recomputed once the final layout is in. Covered by `t/3000_jenny/3100_linker/3160_elf_got_rebase.t`.
- [x] **4.2 DragonFly ELF entry stub calls with a misaligned stack**  the two init calls ran at `rsp%16==8` between the `push rdi`/`pop rdi`; the entry stub now dips the stack 8 bytes before the push and raises it again after the pop, so every call executes 16-aligned. Covered by `t/3000_jenny/3100_linker/3165_dragonfly_entry_alignment.t`.
- [x] **4.3 PE omits the COFF string table below debug level 5**  long section names were written as `/N` offsets while the string table was emitted only at `debug_level >= 5` (gated on the COFF symbol table). The writer now appends the string table whenever any long name is used. Covered by `t/3000_jenny/3100_linker/3170_pe_string_table.t`.
- [x] **4.4 Wasm single-function path leaves call fixups unpatched**  the hashref branch never scanned `fixups`, so `call` placeholders stayed `\x80\x80\x80\x80\x00`. It now applies the same sorted single-pass patch as the array path, replacing each placeholder with the function index 0. Covered by `t/3000_jenny/3100_linker/3175_wasm_single_function_fixups.t`.

### P1 — memory management
- [x] **5.1 class instances have no 8-byte object header**  `register_class` starts fields at offset 0 and `new` allocates `total_size`, so `decref` reads field 0 as the refcount. Start fields at 8, allocate `8 + total_size`, and initialize the header. Covered by `t/1000_katsuro/1097_class_object_header.t`.
- [x] **5.2 `//=` treats integer `0` as undefined**  only a null pointer is undefined on a native scalar. Branch on the type: keep the null test for `ptr`/`dynamic`, otherwise store unconditionally. Covered by `t/1000_katsuro/1098_defined_or_assign.t`.
- [x] **5.3 assigning to an array variable dies**  declarations key `'@'.name` but `lower_assign` looks up `name`. Include the sigil. Covered by `t/1000_katsuro/1099_array_assign.t`.
- [x] **5.4 Wasm string concatenation calls libc `malloc`**  the linker has no imports and dies on the undefined symbol. Route `.` through the managed allocator (or WASI imports). `Brocken::Runtime::str_concat` in `core.brocken` allocates from the managed heap and copies/NUL-terminates both byte strings; the frontend calls it instead of strlen/malloc/strcpy/strcat. Covered by `t/1000_katsuro/1101_wasm_string_concat.t`.
- [x] **5.5 a non-constant array size crashes the allocator**  `alloca` lowering calls `$inst->count->value` when `count` is an instruction. The four lowerers now fold only a constant count and otherwise emit `alloca_dyn`, which scales the runtime count by the element size and adjusts the live stack (Windows probes guard pages; RISCV64/ARM64 anchor the fixed frame off the frame pointer), and the IR `render` prints the count as its SSA name instead of calling `->value`. An untyped (`my $n = 6`) size is unboxed to `i64` before the alloca so a box pointer is never fed to the count arithmetic. Covered by `t/3000_jenny/3200_codegen/3308_dynamic_array_alloca.t`: `alloca_dyn` presence/absence, small and large arrays executing on the host, the untyped-count unbox, and the IR render with an instruction count.

### P2 — front end
- [x] **6.1 string literals are not unescaped**  the lexer now decodes `\n`, `\t`, `\r`, `\0`, `\\`, `\"` and `\'` and leaves unknown escapes untouched. Covered by `t/1000_katsuro/1020_lexer.t`.
- [x] **6.2 a fat comma collapses the whole argument list into one hash**  the parser now keeps the positional prefix and appends the hash, and the constructor lowering binds positionals to `:param` fields in declaration order before applying named overrides. Covered by `t/1000_katsuro/1090_hash.t`.
- [x] **6.3 scientific notation and a leading-dot float are not lexed**  the float rule now accepts `1e-5`, `2.5E10`, `.5` and `3.0e2`. Covered by `t/1000_katsuro/1020_lexer.t`.

### P2 — fuzzer
- [x] **7.1 stale `.rodata` persists between fuzz cases**  `test_program` now always calls `set_rodata( $rodata // {} )`, so a case with no strings cannot reuse the previous table. Covered by `t/5000_fuzz/5010_fuzz_regressions.t`.
- [x] **7.2 the fuzzer never emits an immediate RHS**  `_gen_binop_assign` now draws one value that can select an integer literal instead of a variable, keeping the random stream length unchanged. Covered by `t/5000_fuzz/5010_fuzz_regressions.t`.

## Active Sprint: Memory Management Runtime (R0–R1)

### R0: Fix Fat Scalar Box Layout
- [x] Change `box` in all 4 MIR lowerers: store header word (packed refcount+flags+tag+pad) at `[ptr+0]`, payload at `[ptr+8]` instead of payload at `[ptr+0]` and tag at `[ptr+8]` — all four lowerers already do this; each packs the header as `_type_tag << 24` over a zeroed word and stores the payload at `[ptr+8]`, and `box` no longer uses `alloca` (see R2).
- [x] Change `unbox` to load payload from `[ptr+8]` instead of `[ptr+0]` — the runtime's `unbox_i64`/`unbox_f64` read `[ptr+8]`, and the direct `unbox` instruction loads from `[ptr+8]` on all 4 lowerers.
- [x] Update `_type_tag` and related metadata — all 4 lowerers return the same tag for each type kind, and the runtime dispatches on it; the numbering actually in use is now the one in the layout table below.
- [x] Tests in `t/4000_runtime/` — the box layout itself is covered by `t/2000_lindsay/2050_boxing.t` and the returned-box subtest in `t/3000_jenny/3200_codegen/3306_wasm_box_untyped_locals.t`; `t/4000_runtime/` covers the runtime side that reads the header.

### R1: Immediate Reference Counting
- [x] Implement `Brocken::Runtime::incref`/`decref` in `core.brocken` (load u16 at `[ptr+0]`, inc/dec, store; decref to 0 → free) — both are in `core.brocken`; `decref` returns the block to `free_blocks` when its `live_count` reaches 0, and pushes the object to the suspect buffer when the count is still positive (see R3).
- [x] Wire RC injection in frontend Lowerer (`Katsuro/Lowerer.pm`) - `build_incref` on assignment, `build_decref` on scope exit — assignment, scope exit, and `lower_return` all inject, including the incref of a returned value.
- [x] Change `box` from `alloca` to heap allocation via `bump_alloc` — all three native backends and Wasm call `Brocken::Runtime::bump_alloc` when the frontend supplies a `heap_base` operand; the `%heap_ptr` frame bump is kept only for hand-built IR with no `heap_base`.
- [x] Tests in `t/4000_runtime/` — `4010_runtime_incref.t` for the RC operations and `4000_any_var.t` for the frontend's injection.

## Earlier Completed Sprints

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
- [x] Root-cause the fiber ctx_swap / isolate trampoline interaction on x86_64 Mach-O. - `r12` was being clobbered in the ctx_swap restore loop; skipped restore since r12 already holds target FCB (step 6 of x86_64 ctx_swap). Fixed in `202c0bd`.
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

### Known Bugs
- [x] **Wasm: a call result is lost when the same expression calls again**  `sub fib(i64 $n) -> i64 { if ($n < 2) { return $n; } return fib($n - 1) + fib($n - 2); } return fib(10);` returned 176 where the native target returns 55. The diagnosis on record was that a call result cannot live in a plain local across a later call, because a recursive callee reuses the caller's locals, and it proposed a per-call-site temporary or a shadow stack in linear memory. That was the wrong mechanism: the call results were in distinct locals and stayed there. `fib` has three spilled parameter slots and each activation bumps `%heap_ptr` by 24, so the real fault was where the bump started -- at `%__heap_base` itself, which is the ICB, 144 bytes of runtime state with the Immix block header immediately after it. The frames were being carved over the runtime's own fields, and the one that changed the answer was the fuel counter at `base+64`, which every function reads to decide whether to keep recursing. Eight frames of 24 bytes reach the end of the header, so `fib(8)` was right and `fib(9)` onwards returned 0; 176 is what is left when the fuel the call was about to read has been overwritten. Seeding the bump pointer at the arena base (`base + 144 + 16`, where `Brocken::Runtime::_init` puts the heap cursor) fixes it, and `fib(10)` returns 55. Note the threshold is a function of the frame size, which is why adding an `& 255` to an expectation hides it: the mask is one more instruction and one more slot, which moves every address off the counter. Covered by `t/3000_jenny/3200_codegen/3312_wasm_frame_reclaim.t`.
- [x] **Wasm frames are never reclaimed, so the bump pointer runs off the heap**  the bump pointer was a module global, so a callee carries on from where its caller stopped, but nothing ever lowered it again: every frame a call allocated stayed allocated for the life of the program. A loop calling a function forty thousand times walked the pointer past the end of the 1MB heap and trapped with "out of bounds memory access", however little the program itself needed -- 24 bytes a call against a megabyte. Sharing the global fixed the collision between a callee's frame and its caller's but not the growth. Each function now keeps the pointer it was called with and restores it before returning, so a frame is released when its call returns and recursion nests rather than accumulating; the caller's frame is below the saved pointer and is untouched. The restore goes after the return value is on the operand stack, and `global.set` does not touch that stack. `_BROCKEN_ENTRY` keeps its own frame, having no caller to hand it back to. 100000 calls and a 5000 deep recursion are covered by `t/3000_jenny/3200_codegen/3312_wasm_frame_reclaim.t`. What this does *not* settle is the interaction with `box`, which allocates from the same pointer: a box returned out of a function is handed an address that the restore immediately declares free. That case is already broken independently -- `sub mk() -> Any { my $a = 7; return $a; } my $x = mk(); return $x == 7 ? 1 : 0;` returns 0 on the native targets and, now that the fuel-exit return-width fault is fixed, validates on Wasm but traps there when run -- so nothing that worked stopped working, but a box that outlives its frame needed boxes moved to real heap allocation. That is now done: `box` allocates from the Immix arena via `Brocken::Runtime::bump_alloc` on all four backends, the Wasm frame region is reserved above the arena so the bump never starts over the runtime state, and the exit path increfs a returned box -- the incref had been gated on a type kind of `any` while the IR spells it `dynamic`, so the exit decref freed the box before the caller read it. `sub mk() -> Any { my $a = 7; return $a; } my $x = mk(); return $x == 7 ? 1 : 0;` is 1 on native and Wasm. Covered by `t/1000_katsuro/1086_boxed_return.t` and the returned-box subtest in `3306_wasm_box_untyped_locals.t`.
- [x] **Wasm: a returned box/list outlives its frame and traps at run time**  a `sub mk() -> Any { my $u = 7; return $u; }` handed the caller a pointer onto the free list. Two faults produced it. The Wasm frame bump pointer was seeded at `base+160`, the same address `_init` sets `immix_cursor`, so the first `bump_alloc` overwrote the frame holding `%__heap_base.addr` and a later `decref` read that box header back as the heap base and faulted at `tag+48`: the trap address tracked the box tag, `0x2000031` for an i64 and `0x7000030`/`0x7000058` for a list. The frame region now sits above the arena (`base + 144 + HEAP_SIZE`) and the linker reserves it (`FRAME_RESERVE`). The second fault was frontend RC: `lower_return` increfed the return value only when its type kind was `any`, but the IR spells it `dynamic`, so the incref never ran, the exit decref freed the box, and the free-list link overwrote the payload -- the caller read 0. It reproduced on native, so it was never Wasm-specific. Both fixed; covered by `t/1000_katsuro/1086_boxed_return.t` (native) and the returned-box subtest in `3306_wasm_box_untyped_locals.t` (Wasm).
- [x] **Wasm has no float bitwise, shift or remainder**  `and`, `or`, `xor`, `shl`, `lshr`, `ashr` and `rem` on an `f32`/`f64` are refused by name in the lowerer, which maps them onto opcodes such as `f32_rem_u` that no encoder can accept, so the failure would otherwise surface as "no encoding for" in the code generator rather than as a statement about the target. A float does not reach that check: `lower_binop` truncates a float operand toward zero before an integer-only operator applies, so Wasm is handed an integer operation and `my f64 $a = 12.7; my f64 $b = 10.3; $a | $b` is `12 | 10` on every backend. The check remains for IR that reaches the backend by another route. See the float-operator entries under [Fixed](#fixed).
- [ ] **A sum of many mixed integer and floating-point arguments comes back wrong on the x86-64 Linux ELF target**  a function taking both files at once, `sub g(i64 $i8, ..., f64 $f1) -> f64 { return $i8 + ... + $f1; }`, returns a sum that is not the sum. 7+7 is correct, 8+8 returns 75 instead of 72, 10+10 returns 111 instead of 110. The same source is correct on `x86_64-pc-windows-gnu` at every count tried, so the frame and the argument files are not the whole of it. The wrong answer tracks register pressure and nothing else: taking one register out of the pool at the baseline, with no change to any reload code, reproduces the 8+8 wrong answer exactly, and produces a third wrong answer at 10+10, so this is not a fault in the spill-reload path added with `spill_addr_temp`. Only observable when a foreign target is actually executed, which needs `BROCKEN_SYSROOT*` to be set; `t/3000_jenny/3200_codegen/3300_stack_arguments.t` covers it and fails on this target at 10+10 today. Not investigated further; the allocator change is not the cause and the two need to be tracked apart.
- [x] **x86-64 loses the high half of a value above 2^32** — fixed in Jenny::Codegen::X86_64 store_imm: when storing a 64-bit immediate whose value is outside signed 32-bit, write it as two 32-bit halves instead of letting mov imm32 sign-extend to the full 64-bit payload. This corrects boxed constant payloads (e.g. 2^32) on x86-64 host.
- [x] **x86-64 miscompiles a 64-bit dividend under a small non-power-of-two divisor** — corrected: full-value sweep comparing $x % $n and $x / $n against exact integer results shows no discrepancies on x86-64 host; the earlier reported `% 1000` difference was a measurement artifact (process exit code masked to 0..255). The real cause for boxed constants > 2^32 losing high half was the x86-64 `store_imm` sign-extending a 32-bit immediate; fixed to use 64-bit store halves for wide immediates.
- [x] **A list cannot hold a value that is already untyped** — fixed in lower_list_expr: increment refcount for existing dynamic elements stored into list slots (avoid releasing boxes that the list now owns). The slot holds a box pointer; reader already increfs Any targets. Decref on list destruction remains to be handled by GC/RC passes.
- [x] **Wasm rejects any list at link time**  a list of any elements failed to validate with "type mismatch: expected i64, found i32", including the two-element integer list that the native targets get right, so it predated the list-slot change. The recorded diagnosis pointed at `Jenny::Lowerer::Wasm`'s `Store` opcode selection, but the store was never the fault: every list element was stored with `i64.store` and a correctly typed value. The real cause was the fuel-exit block every function gets when `$has_hidden_heap_base`: it returns a zero constant of the function's return type, and `_wasm_push` chose the constant width from `int` alone, so a `ptr` or `dynamic` zero became `i32_const 0` against an i64 return signature. A list is normally built in a helper declared `-> ptr`, which is why lists were the visible symptom; a bare `sub f() -> ptr { return 0; }` failed the same way. The width now comes from `_scalar_bits`, which already counts a pointer and a boxed value as 64 bits. The earlier "top-level lists trap at run time but validate" observation fits this too: `_BROCKEN_ENTRY` returns i64, so it never took the i32 path. Covered by `t/3000_jenny/3200_codegen/3313_wasm_list_validate.t`. Running such a list was broken for a separate reason -- Wasm reclaimed a function's bump region on return, so the boxes in the slots were freed before the caller read them -- and that is now settled too: `box` allocates from the arena via `bump_alloc`, the frame region is reserved above the arena, and `lower_list_expr` increfs an untyped element so the list owns it. Covered by the untyped-element case in `t/1000_katsuro/1085_list_return.t` and the returned-box subtest in `3306_wasm_box_untyped_locals.t`.

### Fixed
- [x] **A typed float meeting an integer-only operator is truncated toward zero first**  `lower_binop` applied `&`, `|`, `^`, `<<`, `>>` and `%` to a float operand as it stood, so the operation ran on the operand's raw IEEE-754 bits and produced a number that was neither the value, nor the truncated value, nor the bit pattern. Only `&` on a whole-number pair could be read either way; `my f64 $a = 12.0; my f64 $b = 10.0; $a | $b` was 12.0 where the answer is 14.0, and `^`, `<<`, `>>` and `%` missed as well. Wasm refuses the same MIR, so the operator had no single meaning across targets. A float operand is now truncated toward zero before the operator applies, which is Perl's rule: `12.7 & 10.3` is `12 & 10`, `-3.9 & 7.0` is `-3 & 7` rather than `-4 & 7`, and `1.0 << 2.9` shifts by 2. The truncation happens before the mixed int/float unification, which would otherwise promote the integer side back up to float. Covered by `t/1000_katsuro/1087_float_integer_only_ops.t`.
- [x] **A float is true or false by whether it is zero, not by its truncation**  `&&` and `||` belong to the same operator list but are a truth test, so a float operand is compared against `0.0` rather than truncated. Truncation gets that backwards: `my f64 $a = 0.5; my f64 $b = 1.0; $a && $b` is true because 0.5 truncates to 0. An untyped operand is read as `f64` for these two operators so that one comparison covers either kind of box: `unbox_f64` widens an integer payload, so `my $x = 5; $x && $y` is `5.0 != 0.0` and `my $x = 0; $x && $y` is false. Both cases are in `t/1000_katsuro/1087_float_integer_only_ops.t`.
- [x] **A mixed integer/float operation truncated the float instead of promoting the integer**  `lower_binop` converted whichever operand did not already match the other's type, so in fully typed code `my i64 $a = 1; my f64 $b = 1.5; $a == $b` compared 1 with 1 and answered true, `$a < $b` answered false, and `my i64 $a = 2; $a * $b` computed 2. Nothing untyped was involved and the fraction was discarded in the lowering. An integer meeting a float is now widened to the float, which is what the source says in every language the syntax borrows from. `t/1000_katsuro/1077_untyped_float.t` asserts all three shapes.
- [x] **Two untyped operands were unboxed to `i64` before anything knew what they were meeting**  `my $x = 1.5; my $y = 2.5; $x + $y` read both payloads as integer bit patterns, and `$x >> 32` could not be told apart from `$x / 32`. A dynamic operand now unboxes to whatever the context asks for: `Brocken::Runtime::unbox_f64` widens an integer payload, `unbox_i64` truncates a float payload toward zero, and both read the box tag first, so `my $x = 3; my f64 $y = $x;` is 3.0 and `my $x = 2.5; my i64 $y = $x;` is 2. Arithmetic on an untyped operand is computed in `f64`, which is Perl's scalar rule -- the box might hold a float and nothing in the expression says otherwise. The cost is deliberate and is the same one Perl makes: an untyped value above 2^53 is no longer exact. `<< >> & | ^` and `%` keep an `i64` target, because a float has no bits to shift and Perl truncates one before an integer-only operator applies. `&&` and `||` are a truth test and read the operand as `f64` to compare it against zero; they are listed separately because truncation would make `my $x = 0.5; $x && $y` false. See `t/1000_katsuro/1087_float_integer_only_ops.t`. The direct `unbox` instruction still handles `f32` and `i128`, which have no tag to widen.
- [x] **A list could not hold a float**  a list slot is one untagged eight-byte cell and the reader had no way to know what an element was written as, so the bits of 1.5 came back as the integer 4607182418800017408. Every element is now boxed on the way in, which puts the tag next to the payload, and the reader loads the slot as a dynamic rather than reading it as an `i64` and boxing it a second time. This is the representation `gc_scan_list` and the `Any` incref on the reading side already assumed. Seven failures in `t/1000_katsuro/1085_list_return.t` were this and now pass; ownership of a box stored in a slot is a separate fault and is listed under [Known Bugs](#known-bugs).
- [x] **Signed division and remainder used the unsigned opcode on Wasm**  `div` and `rem` are the signed operations and the opcode map sent both to `_div_u`/`_rem_u`, so `i64 -20 / 3` divided two's complement bits and returned a quotient near 2^64 instead of -6. Every positive operand agrees with the signed answer, which is why the existing arithmetic tests passed; `i64 -20 % 3` returned 2 where the dividend was negative. `div` now picks `_div_s` and `rem` picks `_rem_s`. Covered at every width in `t/3000_jenny/3200_codegen/3305_wasm_signed_div_rem.t`.
- [x] **`i32_div_s`, `i32_div_u` and `i64_div_s` had no encoding on Wasm**  the three constants existed in `Encodings.pm` but no case in the code generator emitted them. Because signed `div` had been routed to `i32_div_u`, every division at or below 32 bits asked for the one that was missing and died with "no encoding for 'i32_div_u'", so `i8`, `i16`, `i32` and their unsigned forms could not be divided for this target at all, and `i64` signed division had nowhere to go either. All three are now emitted.
- [x] **Wasm loaded every narrow value zero-extended**  the load opcode was chosen from the bit width alone and hardcoded `i32_load8_u`/`i32_load16_u`/`i64_load8_u`/`i64_load16_u`/`i64_load32_u`, never consulting the sign of the stored type, and the signed forms had no encoding either. A signed `i8` or `i16` came back from memory as its unsigned twin, so `i8 -20 / 3` divided 236 by 3 instead of -20 by 3 and `i8 -20 >> 2` shifted 236. This sat under the division fault above, so fixing only the opcode map would still have divided the wrong number at these widths. The sign now comes from the stored type, and the five `_s` encodings were added with their spec byte values.
- [x] **A store through a spilled address reloaded its value over the address (all backends)**  every parameter is given an `alloca` cell, and the cell's address is a virtual register that is live for the whole body when several parameters are read in one expression. Past about 14 live ones the allocator spills most of those addresses, and there was a single scratch register for all reloads, so a store that needed both a reloaded address and a reloaded value loaded the value over the address and then wrote through it; the address was usually a small integer, so the program took an access violation. Boundary on x86-64: a sum of 14 live parameters is correct, 15 crashes. The allocator now reserves a second scratch, `spill_addr_temp`, alongside `spill_temp`. The reserve is made on a second pass, and only when the first pass actually produced a collision, because taking a register out of the pool unconditionally shrinks it for every function and changes assignments that were already correct. When there is no register outside the pool left to use, the reserve falls back to the callee set and is reported in `used_callee`, which costs an extra prologue save. Covered by `t/3000_jenny/3200_codegen/3301_spilled_address_store.t`.
- [x] **RISC-V floating-point arguments and return were placed in `ft0`, not `fa0`**  `RISCV64::fp_param_registers` began at `f0` and `fp_return_register` was `f0`, but under LP64D the floating-point arguments arrive in `fa0`-`fa7` (spelled `f10`-`f17`) and a result returns in `fa0`. `f0`-`f7` are the scratch registers `ft0`-`ft7`, which the callee is free to clobber, so an argument could be overwritten and an interop call reached a register external code did not use. Nothing failed internally because both halves of the call agreed on the wrong register; the lowerer already indexes the two register files independently, so only the declared register names were wrong. They now start at `fa0`, and `t/3000_jenny/3200_codegen/3302_riscv_float_argument_registers.t` reads the lowering to check the caller places and the callee reads `f10`/`f11` and returns in `f10`.
- [x] **Win64 parameter registers are not positional**  `X86_64_Win64::param_registers` returned 4 GP registers and `fp_param_registers` 4 XMM registers as two independently sized files, so a mixed argument list used the second xmm before the first argument position was reached and the 5th argument of either class overflowed to the stack. The real Microsoft x64 convention numbers positions 1-4 across both classes  the first argument is `rcx` or `xmm0`, the second `rdx` or `xmm1`, and so on, and the fifth and later arguments go on the stack whatever their class. The placement rule now lives on `Platform::ABI::argument_locations`, which takes the class of each argument and returns the register pair or stack slot it goes to; the base implementation keeps the independent per-class counters SysV, AArch64, and RISC-V use, and `X86_64_Win64` sets `positional_arguments` so the x86-64 lowerer numbers positions across both files. Both the entry-parameter walk and the call-argument walk in `Jenny::Lowerer::X86_64` consume that result, so the two halves of a call cannot disagree. `t/3000_jenny/3200_codegen/3303_win64_argument_positions.t` checks the Win64 and SysV placements against each other and reads the lowering to verify the callee captures and the caller passes an f64 that follows the hidden parameters in `xmm3`.

### Calling Conventions
- [x] **Proper unified stack frame**  single-frame allocation combining callee-saves + spill slots, aligned to 16 bytes.
- [x] **Spill slot offsets**  relative to `$stack_reg` (RSP/SP), correct.
- [x] **RISCV64 prologue/epilogue**  integrates allocator's `used_callee` list; saves/restores int + FP registers.
- [x] **ARM64 leaf detection**  skips `x30` save/restore for leaf funcs.
- [x] **Leaf function optimization**  X86_64 now skips all prologue/epilogue for leaf functions without a frame (no calls, no callee saves, no spills, no alloca). Shadow space only allocated on Windows for non-leaf functions.
- [x] **Caller-save register handling**  `insert_caller_save_code` called in all 3 native codegen pipelines, skipping return registers (`rax`/`xmm0`, `x0`/`v0`, `a0`/`fa0`).
- [x] **Move coalescing**  `remove_redundant_moves` called in all 3 native codegen pipelines, eliminates `mov` where src/dst map to the same physical register.
- [x] **X86_64 outgoing stack arguments**  the area was not counted anywhere: the caller wrote them through a captured `%rsp.N` virtual register, so `_compute_spill_frame` never saw them and the spill/alloca/callee-save area began at the bottom of the frame, directly underneath. A call that overflowed the register file wrote its arguments over the caller's own saved registers, and it took 9 arguments before that was visible. The lowerer now emits them against the physical `rsp` tagged `raw => 'stack'`, `_compute_call_arg_frame` reserves them at the bottom of the frame, and `_compute_spill_frame` ignores raw operands so the two sets of displacements are disjoint by construction. Reserved in the prologue rather than pushed at the call, which is what keeps the allocator's spill slots valid across the call and rsp 16-byte aligned.
- [x] **Physical `rsp` is not a vreg**  `_vreg_names_from_mem_operands` treated a memory operand based on the stack register as naming a virtual register, which could hand the name an interval and a spill slot. It now skips the platform's stack register, and `mem_modrm` resolves a raw operand's stack base physically instead of looking it up in the allocation table.
- [x] **X86_64 incoming stack arguments tagged `raw => 'entry'`**  they were read through the `%__frame_base` capture with no tag, so they were indistinguishable from allocator-placed slots. Tagging them is what lets `_compute_spill_frame` and `_compute_call_arg_frame` tell the convention's displacements from the allocator's.
- [ ] **Floating-point callee-save on X86_64**  SysV ABI marks all XMM as caller-saved; codegen only uses `PUSH` (GP-only). Would need `MOVUPS`/`MOVDQA` stack save/restore for non-SysV ABI variants.

### ABI Integration
- [x] All 4 Lowerers query `param_registers()`, `return_register()`, `fp_return_register()` from `Platform::ABI`.
- [x] **Wide-type register pairs**  `Platform::ABI` now answers both halves of a 128-bit register pair: `param_pair_registers($spent)` returns the consecutive parameter registers a wide argument takes once `$spent` integer registers are in use, and `return_pair_registers()` returns the pair a wide result comes back in. The base class derives the parameter pair from `param_registers` and defaults the return pair to the single `return_register`; `X86_64` (and so `X86_64_Win64`), `AArch64`, and `RISCV64` name `rax:rdx`, `x0:x1`, and `a0:a1`. The entry-parameter and call-argument walks in the ARM64 and RISC-V lowerers and the i128 return paths in all three native lowerers query the ABI instead of naming the second register themselves. `t/3000_jenny/3200_codegen/3304_wide_return_register_pairs.t` checks the pairs and reads the lowering on every backend from any host.

### 128-bit Numerics (i128)
- [x] i128 binops (add/sub/and/or/xor/shl/lshr/ashr/mul)  all 4 targets.
- [x] i128 return values are correctly split into lo/hi across two registers on native targets.
- [x] i128 load/store on all 4 targets, via `_split_i128`.
- [x] **i128 call arguments**  split into lo/hi across two consecutive param registers in all 4 lowerers.
- [x] **i128 entry block parameters**  split into _lo/_hi virt_regs at the entry block, consuming two param regs.
- [x] **i128 call return capture (ARM64, RISCV64, Wasm)**  caller now reconstructs _lo/_hi from both return registers (x0/x1, a0/a1, Wasm stack) - was only done on X86_64.
- [x] **Signed i128 div/rem**  all targets use abs(inputs) + apply sign to output.
- [x] **i128 `min`/`max`**  implemented on all 4 targets (X86_64, ARM64, RISCV64, Wasm).
- [x] **Large-value i128 icmp tests**  added native (246 tests) and Wasm (328 tests) execution tests with Math::BigInt constants > 2^64.
- [x] **Unsigned 128-bit div/rem**  `u128` division and remainder now take an unsigned path on all 4 targets: the abs prologue and the sign epilogue are gated on the signed opcodes, and the result select covers `udiv`. The shift-subtract loop needed no change on any target — it shifts and compares without looking at a sign bit — and x86_64's `div128_64` was already the unsigned `DIV`, though its fast remainder path left the intermediate `hi % divisor` in the high half and had to clear it. RISCV64, Wasm, and ARM64 were selecting the remainder for `udiv` because their result select tested only `div`; that was the answer-changing bug. `t/3000_jenny/3200_codegen/3268_i128_unsigned_divrem_native.t` (42 assertions over 14 constant pairs) and `3269_i128_unsigned_divrem_lowering.t` (88 assertions over all 4 lowerers, including the signed path) cover it.
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
- [x] **Isolate return value propagation**  `isolate_join` passes NULL retval; doesn't capture thread result - fixed by Mach-O import stub fix (stubs pointed to dlopen, not pthread_join)
- [x] Wasm isolate stubs (lowerer) - `isolate_create`/`isolate_join` return `i64_const 0` placeholder

## Active Sprint: Katsuro Frontend (Bootstrapping Subset v0.1)

### Completed: Language Features
- [x] **Subset spec:** `docs/spec.md §2.16` - formal Brocken v0.1 bootstrapping language spec
- [x] **Lexer:** Finite-state tokenizer with keywords, sigils, numbers, strings, operators
- [x] **AST nodes:** Program, VarDecl, Assign, Block, If, While, Return, BinOp, UnOp, Const,
      Var, Ident, Paren, Call, IntrinsicCall, SubDecl, ClassDecl, FieldDecl, ArrayDecl, ArrayIndex
- [x] **Parser:** Recursive descent (statements) + Pratt parser (expressions) -
      handles all v0.1 constructs including arrays, classes, methods, field access, `use feature`
- [x] **Compiler orchestrator:** `Brocken` - lex → parse → AST
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
- [x] **ArrayDecl AST node** - parses `my i64 @arr = [10, 20, 30];`
- [x] **ArrayIndex AST node** - parses `$arr[0]` for both read and write
- [x] **Lowering** - alloca with element count, GEP for element access, load/store

### Completed: Class Methods & Auto-Generated Accessors
- [x] **Method declarations** - `method foo() -> TYPE { ... }` inside class, lowered as `ClassName::foo`
- [x] **`:reader` attribute** - auto-generates getter method
- [x] **`:writer` attribute** - auto-generates setter method (`set_<name>`)
- [x] **`:param` attribute** - auto-generates constructor (`ClassName->new(...)`)
- [x] **ADJUST block** - runs after constructor assigns :param fields
- [x] **`__CLASS__` expression** - compile-time class name constant
- [x] **MethodCall expression** - `$obj->method(args)` lowered to `ClassName::method($obj, args)`

### Completed: Implicit Entry Point
- [x] **`sub main` is just a function** - no special heap param, no automatic invocation
- [x] **Top-level code becomes `_BROCKEN_ENTRY`** - internal function with heap_base param
- [x] **All codegen/linker paths** - replaced `main` references with `_BROCKEN_ENTRY`
- [x] **Parser filters `use feature`** - returns `undef` statements filtered in `parse_program`

### Known Issues (Remaining)

- [ ] **ARM64 macOS: int-to-string via `sprintf` varargs** - ARM64 AAPCS requires 64-byte register save area for variadic calls. Fixed in Codegen/ARM64.pm (`sub sp, #64` / `add sp, #64` around `call_func`/`call_indirect`). Needs testing on Apple Silicon.

### Known Issues (Resolved)
- [x] **RISC-V `3125_rodata.t` failure - undef param name:** Entry param handler in all three lowerers (`X86_64.pm`, `ARM64.pm`, `RISCV64.pm`) used `$param->name` directly as the `virt_reg` value. When `Value->new(type => ptr())` is created without a name (as in test `3125_rodata.t`), `$param->name` is undef, creating a MIR operand with undef value. Fixed: all three lowerers now declare `$param_name` with a synthetic fallback (`%pN`) when name is undef, and use it consistently for all virt_reg creations (i128 split, entry temps, main virt_reg).
- [x] **RISC-V RodataRef routing:** Call handler, box-store, and incref/decref in Lowerer/RISCV64.pm now route `RodataRef` through `_materialize` instead of `_lower_opnd`, preventing undef virt_regs.
- [x] **RISC-V codegen defensive guards:** Codegen/RISCV64.pm added undef-value checks - `$reg_id` returns `0` if `$r` is undef; `$resolve` dies with `"resolve: operand value is undef"` if `$op->value` is undef. This caught the param_name bug above.
- [x] **macOS ARM unnamed-arg stack passing:** Lowerer/ARM64.pm passes `num_named`+`num_unnamed` as extra `call_func` operands on macOS ARM; Codegen/ARM64.pm emits `sub sp, #(N*8)`, `str` for each unnamed arg, BL, `add sp, #(N*8)` - only on macOS ARM. Non-macOS keeps original `sub sp, #64` / `add sp, #64`.
- [x] **Duplicate block names in MIR codegen:** Fixed - Lowerer now generates unique block names via `$block_id` counter.
- [x] **`terminator` returned last instruction regardless of type:** Fixed - now checks `isa` for Ret/Br/CondBr.
- [x] **SSA name collisions on var ref:** Fixed - `lower_var_ref` no longer passes explicit names to `build_load`.
- [x] **`as_condition` i1 detection:** Fixed - now checks `bits == 1` instead of `kind eq 'i1'`.
- [x] **Class runtime ordering:** ClassDecls now generate before SubDecl bodies in Pass 2, so auto-generated methods exist when entry function body calls them.

### Upcoming
- [ ] **Dynamic (boxed) types at top level:** `my Int $x = 10` currently lowers like `i64`; needs actual box allocation
- [x] **String support:** String literals, `say("hello")`, `.` concatenation (RodataRef fold + runtime CRT)
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

## Phase 4: Self-Hosted Memory Management (`core.brocken`)
*Architecture Note: Brocken uses "Isolates" (share-nothing OS threads) and cooperative fibers. Because heaps are entirely thread-local, Garbage Collection and Reference Counting require **zero atomic locks**.*

### Overview: Three-Layer Memory Architecture

```
┌──────────────────────────────────────────────┐
│  Layer 3: Perceus (RC Elision + Reuse)       │  Lindsay Optimizer
│  - Cancel redundant incref/decref pairs      │  (compile-time IR pass)
│  - In-place mutation when refcount == 1      │
│  - Borrow inference                          │
├──────────────────────────────────────────────┤
│  Layer 2: Bacon/Rajan Trial Deletion         │  runtime + ICB
│  - Suspect buffer in ICB (ptrs 48-56)        │
│  - Mark/Scan/Collect cycle detection         │
│  - Recovers cyclic garbage                   │
├──────────────────────────────────────────────┤
│  Layer 1: Immediate RC + Immix Allocator     │  core.brocken + ICB
│  - incref/decref on fat scalar refcount      │
│  - Immix: 32KB blocks / 256-byte lines       │
│  - Bump allocation within current line       │
└──────────────────────────────────────────────┘
```

### Fat Scalar Layout (Revised - MUST match spec)

The 16-byte dynamic value (`Any` type) layout, enforced by `box` lowering:

```
Offset  Size  Field
0       2     Reference Count (u16, max 65535; overflow pins object)
2       1     GC Flags (Bit 0: Cycle Suspect, Bit 1: Buffered, Bit 2: Leaf)
3       1     Type Tag (1=Int<=32, 2=i64, 3=Float, 4=Ptr, 5=Dynamic, 6=i128, 7=List, 8=Hash, 0=Other)
4       4     Padding / Aux (e.g., String cached char length)
8       8     Payload (Raw u64/i64/f64/ptr)
```

Total: 16 bytes. This is the layout the `box` lowering already produces in all 4 MIR lowerers: the header is packed as one u64 (`tag << 24` over a zeroed word, so the refcount, flags, and padding start at zero) and stored at `[ptr+0]`, with the payload at `[ptr+8]`. `unbox` and the runtime's `unbox_i64`/`unbox_f64` read the payload from `[ptr+8]`.

### Phase Plan

#### R0: Fix Fat Scalar Layout (prerequisite for all RC work)
- [x] Change `box` lowering in all 4 MIR lowerers: — the packed-header approach is what all 4 use; `alloca 16` became a heap allocation (see R1), and each lowerer packs `((padding << 32) | (tag << 24) | (flags << 16) | refcount)` as one u64 over a zeroed word and stores the payload at `[ptr+8]`.
  - `alloca 16` stays the same
  - Instead of `store payload at [ptr+0]` and `store tag at [ptr+8]`:
    - `store_imm 0 at [ptr+0]` (zero-initialize refcount + flags + tag + padding as u64)
    - `store payload at [ptr+8]`
    - `store_imm tag at [ptr+3]` (tag byte at offset 3)
  - Wait: storing individual bytes is complex in MIR. Simpler approach:
    - Pack the header: `((padding << 32) | (tag << 24) | (flags << 16) | refcount)` as one u64
    - `store_imm header at [ptr+0]` (zero header = all zeros initially)
    - `store payload at [ptr+8]`
- [x] Change `unbox` lowering to load from `[ptr+8]` instead of `[ptr+0]` — done on all 4 lowerers and in the runtime's `unbox_i64`/`unbox_f64`.
- [x] All 4 backends: X86_64, ARM64, RISCV64, Wasm

#### R1: Immediate Reference Counting (IR → Runtime)
- [x] `incref`/`decref` IR instructions defined in Lindsay IR
- [x] `build_incref`/`build_decref` in Builder API
- [x] All 4 MIR lowerers already handle `Incref`/`Decref` → emit `call_func @Brocken::Runtime::incref`/`decref`
- [x] **NEW:** Implement `Brocken::Runtime::incref(ptr)` and `Brocken::Runtime::decref(ptr)` in `core.brocken`: — both exist; `incref` saturates at 65535, and `decref` returns the object to `free16_head`, decrementing the owning block's `live_count` and recycling the block when it reaches 0.
  - `incref`: load u16 from `[ptr+0]`, if < 65535, increment by 1, store back
  - `decref`: load u16 from `[ptr+0]`, decrement by 1, store back; if result == 0, add to free list (or call DESTROY + free)
- [x] **NEW:** Wire RC injection in frontend Lowerer (`Katsuro/Lowerer.pm`): — all three sites inject: assignment, scope exit, and `lower_return`.
  - On variable assignment (`lower_assign`): emit `build_incref` on the new value
  - On scope exit (block end): emit `build_decref` for each local variable
  - On function return: emit `build_decref` for the return value's old binding
- [x] **NEW:** Change `box` lowering to use heap allocation (via `Brocken::Runtime::bump_alloc`) instead of `alloca` so RC-managed objects live on the heap — all four backends, with the frame region reserved above the arena on Wasm

#### R2: Immix Allocator
- [x] Implement Immix allocator in `core.brocken`: — `bump_alloc` is the allocator: it takes from `free16_head` first, then bumps inside the current line, calls `find_free_line`/`mark_line` for a new line, and `recycle_block` returns a block to `free_blocks` at `live_count` 0. The block layout is documented at the top of `core.brocken`.
- [x] Update ICB layout to track Immix state: — the accessors are in `core.brocken` and the field list is in `lib/Brocken/ICB.pm`, which is the source the accessors' offsets are checked against.
  - `immix_cursor` at ICB offset 24 (current bump pointer within current line)
  - `immix_limit` at ICB offset 32 (end of current block)
  - `free_blocks` at ICB offset 40 (linked list of free blocks)
  - `free16_head` at ICB offset 48, `suspect_buffer_head` at ICB offset 56 (the suspect buffer is a singly-linked list with no tail)
- [x] Update entry stub and `_init` to initialize ICB fields — `_init` sets the cursor, limit, both free heads, and the current block.
- [x] Replace `Brocken::Runtime::bump_alloc` with Immix `alloc` — done inside `bump_alloc` rather than under a new name: the name is the frontend's, and the body is now the line-aware Immix allocation described above.
- [x] Wire `box` → Immix allocator (instead of `alloca`) — the frontend supplies `heap_base`, and all 4 lowerers call `Brocken::Runtime::bump_alloc`.

#### R3: Bacon/Rajan Trial Deletion (Cycle Detection)
- [x] Suspect buffer operations: — `decref` pushes when the count is still positive after the decrement (guarded by the Cycle Suspect and Buffered flag bits), and `push_suspect_buffer`/`pop_suspect_buffer`/`suspect_count` maintain the singly-linked list.
- [x] Mark phase: for each suspect, increment an internal "gc_mark" counter — the trial-deletion mark is the GC flag byte's color bits rather than a separate counter: phase 1 of `gc_drain` tentatively scans each suspect and sets Gray.
- [x] Scan phase: trace references from each suspect, decrement marks — `gc_scan_obj` plus `gc_scan_list`/`gc_scan_hash` follow the references out of each candidate.
- [x] Collect phase: objects with mark == 0 are confirmed cyclic garbage - free them — phases 2 and 3 of `gc_drain` restore refs for the reachable (Black) ones and free the rest back to `free16`.
- [x] All implemented in `core.brocken` — `gc_drain` drives all three phases; covered by `t/4000_runtime/4040_gc_r3.t`.

#### R4: Perceus RC Elision & Reuse (Lindsay Optimizer Pass)
- [ ] **Borrow inference**: analyze function parameters to determine ownership (borrowed vs owned)
- [ ] **RC elision**: cancel redundant incref/decref pairs when a value is immediately used and dropped
- [ ] **Reuse analysis**: when constructing a new object, if the input is uniquely owned (RC==1), mutate in place instead of allocating
- [ ] **FBIP (Functional But In-Place)** fragment: linear type analysis guaranteeing no allocation at all for pure data transformations
- [ ] All implemented as Lindsay IR → IR optimization passes (no runtime changes)

#### R5: Future Runtime Work
- [ ] **Fiber Stack Scanning:** Walk stacks of suspended fibers to find live GC roots for accurate cycle detection
- [ ] **UTF-8 Everywhere Strings:** Native string operations assuming pure UTF-8 payloads
- [ ] **Self-Hosted PerlIO:** Vtable-based layered I/O system (e.g., `:unix` raw bytes → `:utf8` validation)
- [ ] **Stack Map Generation:** `.brocken_stackmaps` section for GC root enumeration

## Active Sprint: Type System Expansion

### Phase A: Type Infrastructure (Lowerer + IR)
- [x] Add `%TYPE_MAP` entries for `int`, `bool`, `u8`..`u128`
- [x] Fix `%TYPE_NATIVE_MAP` for `Int`/`Bool` (→ i64/i1, not dynamic)
- [x] Add signedness-aware widening to `maybe_convert_type` (zext/sext)
- [x] Add `zext`/`sext` IR instructions to `IR.pm` + `Builder.pm`
- [x] Backend: lower `zext`/`sext` on all 4 targets
- [x] Add signed/unsigned div/rem IR instructions (`udiv`/`urem`)
- [x] Backend: proper `movzx`/`movsx`/`UXTB`/`SXTB` encoding for zext/sext

### Phase B: Int/Bool native alias support
- [x] Lower `Int` and `Bool` as native types (i64/i1)
- [x] Update `maybe_convert_type` for Int→int aliasing
- [x] Constant lowering for `Int`/`Bool`
- [x] Parser: add `int`, `bool`, `u8`..`u128` keywords

### Phase C: String Constants & .rodata
- [x] Add `.rodata` section to linkers (ELF64, PE, MachO, Wasm)
- [x] Lower string literals to `.rodata` (length-prefixed, null-terminated)
- [x] Emit `lea`/ADRP+ADD to reference `.rodata` addresses
- [x] Wire `say`/`print` to `.rodata` strings (replace alloca+store)
- [x] `.` operator for compile-time string concat (RodataRef folding) + runtime concat (CRT calls via linker)
- [x] `.` operator with int/float operands - `_stringify` converts via `sprintf` with platform-appropriate format specifiers (`%lld`/`%I64d`)
- [x] `build_alloca` count wrapping - bare integer `$count` wrapped in `Constant` object (Builder.pm:226, fixes `"value" via package "64"` on ARM64/RISCV64/Wasm)

### Phase D: Struct Types (IR level)
- [x] Add structural type to IR: `Type::struct([field_types...], [field_names...])`
- [x] Extend GEP for struct field access (byte offset from struct layout) via `struct_field_idx` on GetElementPtr
- [x] Lower field access to struct-aware GEP: `build_struct_gep` in Builder; all field-access methods in Lowerer use it
- [x] Update all 4 codegen lowerers (X86_64, ARM64, RISCV64, Wasm) to handle struct-typed GEP

### Phase E: Signedness in Binop Lowering
- [x] Default signedness for `int` type (signed i64; same for `Int`)
- [x] Propagate signedness through `lower_binop`:
  - `/` → `div` (signed) or `udiv` (unsigned)
  - `%` → `rem` (signed) or `urem` (unsigned)
  - `<`/`>`/`<=`/`>=` → signed predicates (`slt`/`sgt`/`sle`/`sge`) or unsigned (`ult`/`ugt`/`ule`/`uge`)
- [x] Add `<<`/`>>` shift operators to parser + lexer; `>>` → `ashr` (signed) or `lshr` (unsigned)

## Debug Info / DWARF Gaps

### What's Implemented
- [x] DWARF v5 sections: `.debug_line`, `.debug_info`, `.debug_abbrev`, `.debug_frame`, `.debug_aranges`, `.debug_names`, `.debug_str`, `.eh_frame`, `.eh_frame_hdr`
- [x] Per-instruction byte offset tracking (`ir_inst_idx` → `source_map`)
- [x] Per-function `DW_AT_decl_file` attribute
- [x] Variable/parameter DIEs with name, type (`DW_AT_type` ref4), location (`DW_AT_location` exprloc `DW_OP_fbreg`), decl_line, decl_column, artificial
- [x] Struct type DIEs (`DW_TAG_structure_type` + `DW_TAG_member`) from `class_info`
- [x] Line/col on IR instructions (passed through `build_*` methods)
- [x] GDB backtrace end-to-end test (PE, `-readnow`)
- [x] All 4 backends (X86_64, ARM64, RISCV64, Wasm) with consistent DWARF output
- [x] Programmatic binary-structure validation test (`3218_dwarf_validate.t`)
- [x] Debug levels (0–5) controlling which DWARF sections are emitted
- [x] `DW_AT_producer` (`"Brocken v0.1"`) and `DW_AT_comp_dir` on compile_unit DIE
- [x] `DW_AT_linkage_name` on subprogram DIEs (same as function name)
- [x] `DW_AT_decl_line` (data2) and `DW_AT_decl_column` (data1) on variable/param DIEs
- [x] `DW_AT_artificial` (data1) on variable/param DIEs
- [x] `.eh_frame_hdr` generation with `DW_EH_PE_absptr` encoding (empty when `eh_frame_base` is 0)
- [x] `PT_GNU_EH_FRAME` program header pointing to `.eh_frame_hdr`

### Gap 9: No split DWARF / type units / DWARF compression
**Description:** All debug data is emitted inline in the executable. No `.debug_types` (type units), `.debug_cu_index`, or DWARF compression (`.zdebug_*`). This increases binary size for projects with many types or large source files.
**Impact:** Future optimization. Not relevant for current v0.1 subset.
**Priority:** Future
**Dependencies:** Would require linker changes (section name mapping for compressed sections) and structural changes to DWARF.pm to emit type units separately.

### Gap 10: Wasm source_map translation is fragile [x] Fixed
**Description:** The Wasm encoder records raw per-block offsets during encoding, but the flat `$bytes` buffer includes block headers (`0x02 0x40`), markers, and `0x0B` terminators that shift offsets. The translation in `build_debug_data` accounts for these, but the computation was complex and may not survive changes to Wasm block structure (e.g., adding new branch types).
**Status:** Fixed. The block_start computation is now inline with the assembly phase (tracks `$pos` during byte emission) instead of a separate post-phase calculation. A locals_size offset bug was also fixed (source_map offsets in `emit_functions` now include the locals prefix length so they align with the blob's `bytes` field). A comprehensive test (`3219_wasm_debug.t`) validates source_map offsets are within function byte range and monotonically increasing.
**Impact:** Low. Test provides regression coverage against block structure changes.
**Priority:** Low
**Dependencies:** Tied to Wasm encoder's block structure. Changing Wasm's structured control flow would require updating the inline offset tracking.

### Gap 11: Runtime functions share user source file for `DW_AT_decl_file` [x] Fixed
**Description:** All functions (user code + runtime helpers like `Brocken::Runtime::_init`) currently get `source_file => $source_file` in `build_debug_data`, so `DW_AT_decl_file` points to the user's source file for everything. Runtime functions should ideally reference a different source file (e.g., `core.brocken` or `<runtime>`).
**Status:** Fixed. Each backend's `build_debug_data` now checks `$fname =~ /^Brocken::Runtime::/` and sets `source_file => '<runtime>'` for those functions, including per-instruction source locations. The `source_files` array automatically picks up the distinct file name.
**Impact:** Low. GDB will now attribute runtime functions to `<runtime>` instead of the user's source file.
**Priority:** Low
**Dependencies:** None.

### Gap 12: All source_locs use implicit file index 0 [x] Fixed
**Description:** The line number program entries (source_locs) don't carry a file index. All source locations implicitly refer to the first file in the file table (index 0 → DWARF file index 1). If we ever have multiple source files contributing to one compilation unit, line entries can't distinguish them.
**Status:** Fixed. Added `file` field to source_locs entries in all 4 codegen backends. `build_debug_line` emits `DW_LNS_set_file` (opcode 0x04) when the file changes between consecutive entries, using a filename-to-index mapping built from the `source_files` list. A validation subtest in `3218_dwarf_validate.t` verifies multi-file line programs emit (0x04) with the correct file index. Entries without a `file` field default to `$source_file`.
**Impact:** Low. Enables multiple source files per compilation unit with correct line attribution.
**Priority:** Low
**Dependencies:** None. `source_files` / `file_idx` infrastructure was already in place.

### Gap 13: No GDB JIT interface for runtime-compiled (JIT) code
**Description:** Brocken supports loading new source at runtime (JIT compilation), but there is no mechanism to inform the debugger about the new code. GDB will not know about JIT'd functions, cannot set breakpoints in them, and backtraces through them will be opaque (no source lines, no variables).

The GDB JIT interface requires:
1. A `__jit_debug_register_code()` function - a no-op that acts as a GDB breakpoint target. GDB sets a breakpoint here and catches SIGTRAP when new code is registered.
2. A global `__jit_debug_descriptor` symbol of type `struct jit_descriptor`:
   ```c
   struct jit_code_entry {
       struct jit_code_entry *next_entry;
       struct jit_code_entry *prev_entry;
       const char *symfile_addr;   // pointer to in-memory ELF/DWARF image
       uint64_t    symfile_size;   // size of the image
   };
   struct jit_descriptor {
       uint32_t version;           // must be 1
       uint32_t action_flag;       // 0 = register, 1 = unregister
       struct jit_code_entry *relevant_entry;
       struct jit_code_entry *first_entry;
   };
   ```
3. The in-memory ELF image (`symfile_addr`) must be a valid ELF that GDB's BFD loader can parse. At minimum it needs:
   - ELF header (e_hdr) with correct e_machine, e_shoff pointing to section headers
   - At least one `.debug_info` section with valid DWARF CU pointing to the JIT code's PC range
   - `.debug_abbrev`, `.debug_line` sections referenced by the CU
   - Section header string table (`.shstrtab`) so GDB can find sections by name
   - `sh_size` must be actual data length (not padded allocation size) - see Gap 3 fix
   - `e_shoff` aligned to `e_shentsize` (64 bytes for ELF64) - see Gap 3 fix
4. Thread safety: the descriptor linked list must be updated under a lock (or atomically) since multiple threads may JIT simultaneously
5. CIE/FDE in `.eh_frame` or `.debug_frame` must use absolute addresses (`DW_EH_PE_absptr`) since relocations are not available at runtime - our current `.eh_frame_hdr` already uses absptr encoding

**Implementation plan:**
- Add a runtime helper function `__jit_debug_register_code()` (no-op, called by GDB breakpoint)
- Add a runtime global `__jit_descriptor` (initialized at program start)
- Add a `Brocken::Runtime::jit_register(elf_data)` function that:
  a. Allocates a `struct jit_code_entry`
  b. Appends it to the descriptor linked list
  c. Sets `action_flag = 0` (register)
  d. Sets `relevant_entry` to the new entry
  e. Calls `__jit_debug_register_code()`
- Modify `Brocken::Jenny::Linker::ELF64` (or add a new method) to produce a minimal in-memory ELF image containing only the DWARF sections for a given JIT unit, using `build_debug_data` output. This ELF image does NOT need a text section - GDB uses PC ranges from `.debug_aranges` / `DW_AT_low_pc`/`high_pc` to map addresses.
- The ELF image can be as small as the DWARF data plus minimal ELF/section headers (~4 KB typical for a small function)
- Test: create a minimal JIT ELF, feed it to GDB's `add-symbol-file` or the JIT interface, verify GDB can set breakpoints and backtrace through JIT'd code
- **Not required initially**: `.eh_frame` in the JIT ELF (runtime unwinding through JIT frames). `.debug_frame` is sufficient for GDB's `bt` command.

**Priority:** Medium (enables interactive debugging of JIT code)
**Dependencies:** All DWARF sections already JIT-ready (parameterized `text_base`, absolute encoding, proper section sizes). Needs a new ELF64 convenience method to wrap DWARF sections in a minimal in-memory ELF, plus the runtime glue (descriptor + registration function).

## Found Bugs: Float & Backend Correctness

Found while backporting float work from `dev` (branch `october2026`, 2026-09-30). Every item
here was reproduced against a natively compiled and executed binary, not read off the MIR.

### Fixed in this series

- [x] **Float literal stored at the wrong width** - a decimal literal is lexed as `f64`, so
      `my f32 $t = 1.5;` emitted a double-width store into a four-byte slot. The backends take
      a store/load/move width from an operand's type, so re-tagging the constant to the target
      type is the whole conversion (and where rounding to f32 happens). `aeb4e3f`
- [x] **`lower_binop` widened the wrong side** - when a literal and a value of different float
      widths met, it promoted the *value*, reinterpreting a four-byte pattern as eight. Now the
      literal is re-tagged instead. `aeb4e3f`
- [x] **Negative float literals were not folded** - `-1.5` became an `fneg` of a positive
      constant, and the result is not a `Constant`, so `my f32 $a = -1.0;` had nothing to
      re-tag and died. Folded for floats only; folding `-5` for an i64 is left alone since an
      unsigned neg is defined as wrapping. `aeb4e3f`
- [x] **Every ordered float comparison was false** - the frontend picked `slt`/`ult`/`sle`/...
      off `is_signed`, but neither backend's float table has those names (x86-64 `%fcond` at
      `Codegen/X86_64.pm:2434` is `lt/le/gt/ge`, ARM64 at `Lowerer/ARM64.pm:2974` is
      `cset_lt/...`). Affected `<`, `>`, `<=`, `>=` at *any* float width including f64.
      `==`/`!=` survived only because they are spelled the same for both. `1a8a713`
- [x] **x86-64 int<->float conversion always used the double form** - `cvtsi2sd`/`cvttsd2si`
      hardcoded the `F2` prefix, so an f32 was converted by reading or writing eight bytes of a
      four-byte value. The single-precision forms are the same opcodes under `F3`; the prefix is
      now taken from the float operand's type, matching how `fload`/`fstore`/`fmov` already
      choose. `cf4fef9`
- [x] **RISC-V int<->float conversion always used the double form** - the same bug as the x86-64
      one above, found by the RISC-V CI lane failing `1076_float_conversion.t` while x86-64
      passed. `Codegen/RISCV64.pm` hardcoded `FCVT_D_L`/`FCVT_L_D` (int64<->float64) for every
      `scvtf`/`fcvtzs`; the lowerer emits a bare opcode, so an f32 was converted as if its
      register held a double and returned 0. An f32 subtest failed and every f64 one passed,
      which is the signature of a width-selection bug. Now selects on both the float format
      (`S`/`D`) and the integer width (`W`/`L`), mirroring ARM64. New constants in
      `Codegen/RISCV64/Encodings.pm`; coverage in `t/3000_jenny/3200_codegen/3296_riscv_fcvt_width.t`
      (codegen-level, host-independent) plus the existing executing `1076_float_conversion.t`.
- [x] **The ELF64 linker warned when a probe compiler was absent** - every `write_executable` on
      the RISC-V lane printed `Can't exec "clang": No such file or directory at
      lib/Brocken/Jenny/Linker/ELF64.pm line 193`. `_cc_print_file_name` now resolves a bare
      compiler name with `IPC::Cmd::can_run` and returns early when it is not installed; an
      explicit path is still used as given so the stub-compiler test is unaffected.
- [x] **`fmov`/`mv` were not accepted by the entry-shuffle fixup** - `fix_entry_shuffle` in
      `lib/Brocken/Jenny/RegAlloc.pm` scanned only `mov`, so a run of float captures (an `fmov`)
      or RISC-V integer captures (an `mv`) was left unscheduled and a capture that wrote a
      register could land before one that read it, so an argument arrived as a copy of its
      neighbour. It now recognises `mov`, `mv` and `fmov`, partitions the captures by register
      class, and breaks a cycle with the spill temp of the matching class.
      Coverage: `t/3000_jenny/3200_codegen/3297_entry_shuffle.t` (integer, executing).
- [x] **The call arguments were not a parallel move either** - the lowerer emitted one copy per
      register argument just before a call in reverse order, on the theory that setting the first
      argument last keeps a later copy from clobbering it. That is only true while no copy's
      source is another copy's destination; with two floats allocated to xmm1 and xmm2 it wrote
      xmm1 first and destroyed the source of the copy into xmm0, so the earlier argument read
      back as its neighbour (a variable float argument is the case `dev`'s tests never reach,
      because they pass literals). New `fix_call_shuffle` schedules the run as a real parallel
      move, reusing the entry-shuffle algorithm and the same reserved spill temps; a run with no
      collision, or one with a stack store, immediate, spilled source or spill temp, is left as
      written. Coverage: `t/3000_jenny/3200_codegen/3298_float_param_registers.t` (float, variable
      arguments, executing).
- [x] **A float literal could not be passed directly as an argument** - the call path lowered
      every argument with `_lower_opnd`, which returns a float `Constant` as a raw immediate, and
      `fmov` cannot encode one, so `g(1.5)` died with `Unexpected operand kind: imm`. The return
      path already routed float constants through `_materialize` (bit pattern into a general
      register, then `fmov_gp2f`); the argument path now does the same on x86-64, ARM64 and
      RISC-V64. Materialising exposed a second fault: `RegAlloc`'s reserved-physical-register scan
      read the register class off the operand type, but a call-argument copy is a `fmov` with an
      untyped physical destination, so the argument's XMM stayed allocatable and a later literal's
      temporary landed on it (`1+2+3+4` arrived as 9). The class is now taken from the opcode when
      the type is absent. Coverage:
      `t/3000_jenny/3200_codegen/3299_float_literal_arguments.t` (codegen-level plus executing).
      `dev`'s literal-argument float parameter tests can now be adopted as-is.
- [x] **x86-64 `cmp` and ALU immediates were truncated to 32 bits** - every
      `cmp`/`add`/`sub`/`and`/`or`/`xor`/`mul` immediate was emitted as
      `pack('CCCV', ...)`, a 32-bit field, and the 64-bit forms sign-extend it, so
      any i64 constant outside signed 32 bits was read as a different number:
      `my i64 $x = 4294967296; return $x == 4294967296 ? 1 : 0;` answered false and
      `$x + 4294967296` lost the add. There is no 64-bit immediate form for these
      opcodes at all, so the constant has to go through a register. The lowerer now
      materialises one (`_materialize_wide_imm`) before the ALU or compare
      instruction and leaves in-range immediates untouched; the `mov` encoder
      already emitted `movabs`. The scalar `neg` path, which lowers `-C` to
      `sub dst, C`, had the same fault and is fixed the same way. Coverage:
      `t/1000_katsuro/1077_imm64.t` (executing: comparison boundary, add/sub/mul, a
      64-bit `and` mask, and a negative out-of-range literal).
- [x] **An f32 literal argument read back as NaN on RISC-V** - found by the RISC-V CI lane
      failing `3299_float_literal_arguments.t` (every `f32` subtest, no `f64`). The literal is
      retagged to the parameter's type, but `_place_float_constant` moved its bit pattern into the
      argument register through an *untyped* physical operand, so `Codegen/RISCV64.pm` took the
      move's width from `$dst->type`, defaulted to 64 bits, and emitted `fmv.d.x`. RISC-V reads a
      single-precision operand whose upper 32 bits are not all ones as a canonical NaN, so the
      callee saw NaN and the sum comparison failed. x86-64 already typed its destination
      (`_materialize_into`); RISC-V and ARM64 now do too. ARM64 has no NaN-boxing, so its
      double-register form was not observably wrong, but the width now comes from the literal
      there as well. Coverage: host-independent codegen-level checks in
      `3299_float_literal_arguments.t` that encode an f32 argument for RISC-V and ARM64 and require
      `fmv.w.x`/`fmov.s`, not `fmv.d.x`/`fmov.d`.

### Open

- [x] **Mixed-width signed/unsigned comparison compares at 32 bits** - the equal-width fix at
      `Katsuro/Lowerer.pm:1380` covers only `lbits == rbits`. When the widths differ, the narrower
      signed operand is promoted to the wider unsigned type (`i8` -> `u16`), but the value is still
      carried sign-extended in a 32-bit register, so the unsigned predicate sees `0xFFFFFFC3`
      instead of `0x0000FFC3`. `my i8 $a = -61; my u16 $b = 65509; return $a >= $b ? 1 : 0;` exits
      1; after the frontend's promotion it should be 0. Found by the fuzzer (case 295, seed
      20260713).
      Not the equal-width fix's fault after all: the promotion at `maybe_convert_type` picks sext
      from the *source* signedness, so it asked for a sign-extension into an **unsigned** type,
      which the IR cannot express. The backends size an extension from its source operand and
      sign-extend all the way out to 32 bits, with no way to stop at the destination width, so the
      sign survived into the compare. Now sign-extends to a signed type of the target width and then
      zero-extends that width, via a new `IR::Type::signed_for`. Fixes it on every backend at once,
      since all of them had the same blind spot. Covered in `1040_lowerer.t` at both levels across
      i8/u8, i8/u16, i8/u32, i16/u32 and i32/u64.
- [x] **f32 conversions are unverified on ARM64 and Wasm** - x86-64 and RISC-V64 were already fixed
      and covered (see above). Both of these are now executed and pass. ARM64 does encode the width in
      the instruction (`fcvtzs`, `scvtf`) and its codegen already selects on both widths, so the
      "probably fine" guess held. `1076_float_conversion.t` used to bail unless the host was native,
      which is the only reason these went unverified for so long; it now runs every case on the host,
      on aarch64/riscv64 when `BROCKEN_SYSROOT_*` makes them runnable, and on Wasm when `wasmtime` is
      installed, adding a target only when its tooling is actually present. 38 cases x 4 targets pass.
- [ ] **No float-width cast exists, by design** - `maybe_convert_type` croaks with "No
      float-to-float conversion ... the IR has no fptrunc or fpext" for a *non-constant*
      mismatch. This matches `dev`'s choice to fail loudly rather than silently reinterpret bits,
      but it does mean mixing `f32` and `f64` in one expression is a hard error unless one side
      is a literal. Adding `fptrunc`/`fpext` instructions is the real fix; until then the croak
      is the intended behaviour and should not be "fixed" by widening.
- [ ] **Float-to-unsigned-int conversion is absent** - the IR has `SIToFP`/`FPToSI` only. There
      is no `fptoui`, so `my u32 $j = $negative_float;` has no defined lowering.
- [ ] **Out-of-range and NaN float->int conversion is undefined** - `cvttss2si`/`cvttsd2si`
      return the "integer indefinite" value (all ones) for NaN and for overflow. No saturation or
      trap semantics have been chosen or tested.
- [x] **`i128` surface syntax is feature-gated, not absent** - `my i128 $x = 3;` fails to parse
      with "Expected variable name after 'my'", but only because `i128`/`u128` sit behind `use
      feature 'brocken_native_types'`; with the gate the declaration parses, the lowerer splits
      it across two registers, and the value executes. The gate is deliberate and documented in
      `Katsuro::Parser`. The stale claim that a 128-bit value cannot be declared in source, and so
      has no end-to-end test, is dropped: `t/1000_katsuro/1078_i128_surface_syntax.t` checks the
      rejection without the gate and runs a declare/widen/narrow round trip on the host.
- [x] **Wasm reserved 64KB of memory while telling the runtime it had 1MB** - the linker emitted a
      single page from `_initial_pages`, which covered `heap_base` (1024) plus the 24-byte runtime
      header and nothing more. The entry preamble separately passes `0x100000` to
      `Brocken::Runtime::_init`, so the ICB's cursors and limits were set across a megabyte that
      linear memory did not contain. A native target gets away with this because its mmap grows on
      demand; a Wasm module declares its memory once. Nothing noticed until a program needed a
      second heap allocation: one untyped (boxed) variable fit inside the page that was really
      there, a second trapped, and the fault address tracked the box's type tag - the allocator
      had been handed a range it should never have believed in. Fixed by sizing the initial memory
      from the heap the runtime is actually promised: `Brocken::ICB::HEAP_SIZE` is now the single
      source of truth for that 1MB, used both by the `_init` call in `Katsuro/Lowerer.pm` and by
      `_initial_pages` in `Linker/Wasm.pm`. `my $a = 3; my $b = 4; return $a + $b;` and a corpus of
      89 differential cases now agree with the host.
- [x] **An untyped `my` did not produce a loadable module** - `my $x = 42; return $x;` is the most
      ordinary statement in the language and the Wasm backend could not emit it. Four separate
      faults, all of which had to be fixed before the module validated, and all of them in the
      `box`/`unbox` path: (1) `Codegen/Wasm.pm` declared every local from the MIR function's
      `%ir_types` table, but `%heap_ptr` is created by `Lowerer/Wasm.pm` and never appears there,
      so it was declared i32 while its uses were i64 and the validator rejected the module;
      (2) the box payload push was built into an instruction that was then never
      `add_instruction`'d, so the box's payload came from whatever was on the stack;
      (3) the box payload store and the matching unbox load were hardcoded to
      `i32.store`/`i32.load`, while an untyped variable defaults to i64, so the value was
      truncated to 4 bytes; (4) the stores were selected by the box's type rather than the value
      being stored, so an f32 or f64 payload was written as an integer. All four are fixed in
      `Codegen/Wasm.pm` and `Lowerer/Wasm.pm`, and `my $x = 42;` now returns 42 under wasmtime
      where it previously produced an unloadable module. Found by differential smoke testing
      after a broad corpus (`my` locals throughout) turned up ~10 invalid-module failures at once;
      this is the class of bug the Phase F8b Wasm fuzz lane would have caught.
- [x] **An untyped variable could not hold a float** - `my $x = 1.5; return $x == 1.5;` was wrong
      everywhere, and no backend could have fixed it on its own. Two independent faults, each
      hiding the other on a different backend:
      (1) `lower_binop` unboxed a dynamic operand to `i64` before it knew what it was being compared
      against, so `$x == 1.5` was built as a comparison of two integers and the float-ness of the
      literal was gone before the comparison existed. A dynamic meeting a float operand now unboxes
      to that float type; integers still unbox to `i64` so the existing width promotion is
      untouched. (2) Every native backend's box payload store used `store_imm` for a constant, and
      `store_imm` picks a 64-bit GP move for a memory operand that is not an `int`, so
      `my $x = 1.5;` stored the integer `1`. All three now route a float payload through the FP
      store, the idiom they already used for float locals.
      These two faults used to cancel on x86-64 for the simplest case: it truncated the value and
      the literal identically, so `trunc(trunc(1.5)) == trunc(1.5)` was true and the bug looked
      like it worked. Fixing only the frontend turns that case **red**, which is why the integer
      half is asserted beside the float half in `t/1000_katsuro/1077_untyped_float.t`.
- [x] **A boxed value is read at whatever width the context asks for** - the remaining half of the
      float box work, and it needed the tag consulted at run time. The box header has carried a type
      tag since `e1e9423` and every backend writes it, but nothing read it, so a payload was loaded
      as whatever the context asked for. Two directions, both wrong:
      (1) a float payload read as an integer: `my $x = 2.5; return $x == 2;` read
      `0x4004000000000000` and compared that against `2`. (2) an integer payload read as a double:
      `my $x = 3; my f64 $y = $x; return $y == 3.0;` was false. Both are now fixed at the runtime
      boundary: `Brocken::Runtime::unbox_i64` and `unbox_f64` read the tag first and widen or
      truncate the payload to what the context asked for, so `my $x = 3; my f64 $y = $x;` is 3.0 and
      `my $x = 2.5; my i64 $y = $x;` is 2. The inline `Unbox` is kept only for `f32` and `i128`,
      which have no tag to dispatch on. Covered by the "a payload is read as what the box actually
      holds" subtest in `t/1000_katsuro/1077_untyped_float.t`.
- [x] **Arithmetic between two untyped variables has no float case** - `my $x = 1.5; my $y = 2.5;
      return $x + $y;` used to be `3` on every backend because with both sides dynamic there was
      nothing to unbox to and both defaulted to `i64`. Two dynamic operands now compute in `f64`
      (`lower_binop` interns both as `f64` when neither side pins a type), so `$x + $y` is 4.0 and
      `$x < $y` orders as floats. This is Perl's scalar rule and the cost is the same one Perl makes:
      an untyped value above 2^53 is no longer exact, documented in `docs/spec.md` §2.3.1. Covered by
      the "arithmetic between two untyped values" and "untyped value meeting an integer" subtests in
      `t/1000_katsuro/1077_untyped_float.t`.
- [ ] **A boxed `f32` cannot be represented at all** - the payload is one 8-byte slot and the IR
      has no `fptrunc`/`fpext`, so a float of one width cannot be stored in a slot of the other.
      An `f32` payload writes 4 bytes and the unbox reads 8, or the unbox reads 4 of an 8-byte `f64`.
      Every decimal literal is an `f64`, so nothing reaches a box as an `f32` unless it is declared
      one on purpose. This is the gap tracked under `Brocken::Lindsay`, not here.
- [x] **`my $a = 3; my $b = 4; $b = $b; return $a;` still traps** - self-assignment of a boxed
      variable, where the source and destination of the store are the same box. Assigning one box to
      another, `my $x = 3; my $y = $x;`, trapped the same way on Wasm, and both did it for an integer
      as readily as a float, so it was an aliasing fault and not a float one. The suspicion recorded
      here was the GC path: the store emits an `incref` on a box it is about to overwrite and a
      `decref` on the old payload, and if the two order against each other the free list can hand
      back a block that is still in use. The later frame-reclaim and box-payload work
      (`0dfa9a4`, `b5b34f4`) settled it: a ten-shape sweep now returns the right value for
      self-assignment, one box initialised from another, a chain of moves, and the float case, with
      no trap. The stack-bound box the old note worried about no longer outlives the frame it was
      read in for these shapes. Covered by the `assignment between untyped variables` subtest in
      `t/3000_jenny/3200_codegen/3306_wasm_box_untyped_locals.t`.
- [x] **Multi-block Wasm call fixups are rebased onto the assembled body** - a call index was
      recorded against its own block and never rebased, so a call from any block but the first
      pointed into the middle of the dispatch loop and the module did not validate. Fixed in
      `09e6d0a`: each fixup now has `$block_start[$fx->{block}]` added to it before the linker
      patches it. The rebase is needed even for a call in the entry block now that the dispatch
      prologue precedes that block. Covered by `t/3000_jenny/3200_codegen/3271_multiblock_call_wasm.t`,
      which calls a helper from `if.then` and runs the module under `wasmtime`; that test fails
      if the rebase is removed, as does `3270_multi_func.t`.
- [x] **The Wasm module now runs as a WASI command** - the linker named the entry export
      `_BROCKEN_ENTRY`, which takes a heap base as an i64 parameter, while a WASI reactor looks for
      a `_start` that takes nothing, so the module could not be run as a command at all. The
      multi-function path now appends a `_start` stub that pushes the link-time heap base in the
      entry's own parameter type, calls it, and drops the result. Dropping rather than exiting
      with the entry's value is deliberate: an exit status would mean importing
      `wasi_snapshot_preview1.proc_exit`, which would also break every caller that instantiates
      the module directly, so both 42 and 1 exit 0. `_BROCKEN_ENTRY` is still exported and still
      takes a heap base, for `--invoke`. Two smaller things came with it: the base is a
      signed LEB128 constant, where the unsigned form only happened to agree at 1024, and the
      memory section now covers the base plus the 24-byte runtime header it holds, so a base past
      64KB gets a second page instead of a header out of bounds.
- [x] **Float-to-bool assignment is not normalized to 0/1** - `my bool $b = false; my f64 $x = 24.0;
      $b = $x; return $b;` exited 24, not 0. The float->int conversion behind the assignment produced
      the integer value without masking it to the one-bit destination, so a `bool` could hold any int;
      an fptosi typed at a narrow destination still lowers to a full-width convert (a 32-bit
      `cvttsd2si`, an `fcvtzs` to `w`), which left the bits above the destination intact. Fixed in
      `Katsuro::Lowerer::maybe_convert_type`: the float->int branch now masks to the destination width
      the way the int->int branch already did, folded for a constant and an explicit `and` for
      everything else. A bool holds bit 0 of the truncated value, which is this compiler's existing
      convention for a one-bit destination and what the integer path does (`i64 24` gives 0) -- it is
      not truthiness, so `t/1000_katsuro/1076_float_conversion.t` asserts the integer cases beside the
      float ones to keep the two sources from drifting apart again. That file fails on six of its
      cases if the mask is removed. Checked on the host and under qemu on aarch64 and riscv64. The
      mask applies only below 32 bits: a 32- or 64-bit destination is already the width the
      conversion produces, and the 32-bit mask is not representable at all, since 0xFFFFFFFF is -1 as
      a signed i32 and emitting it as an i32 constant is rejected as too large.
- [x] **Wasm emits one conversion opcode for every int/float width pair** - a Wasm conversion names
      both widths, but `Lowerer/Wasm.pm` picked the opcode from the direction alone, so an f64 to i32
      was emitted as `i64.trunc_f64_s` and an f32 source was truncated as if it were f64. Both are
      modules wasmtime refuses to compile. The opcodes were also wrong in `Encodings.pm`:
      `I64_TRUNC_F64_S` was 0xA8, which is `i32.trunc_f32_s`, and `F64_CONVERT_I64_S` was 0xBB, which
      is `f64.promote_f32`. Both numbers were checked against `wat2wasm` rather than read off a table:
      `i64.trunc_f64_s` is 0xB0 and `f64.convert_i64_s` is 0xB9, with 0xAE being
      `i64.trunc_f32_s`. Fixed by naming a constant per width pair and letting the source and
      destination types choose it. Only the two f64/i64 shapes had ever produced a loadable module;
      all eight now validate and run.
- [x] **Signed narrowing to `i8` is wrong on Wasm** - `my i32 $k = 100; my i8 $j = $k;` reads back 0,
      while the same code with `u8` gives the right value, and `i32 300 -> i8` is 0 rather than 44.
      This is the int->int path, not the float one, and predates the entry above; float->i8 rides on
      it and still gives 0 for a value that fits. Wasm has no 8-bit locals, so an `i8` and a `u8`
      destination have to lower identically, and whatever distinguishes the two signed paths is where
      this goes wrong. Found by running the float conversions end to end through wasmtime.
      The narrowing was never the broken part: `Sext` in `Lowerer/Wasm.pm` shifted the value up so the
      sign bit reached bit 31 and stopped there, leaving the low bits clear, so any *positive* narrow
      value read back as 0. It surfaced on `my i8 $j = $k;` because the comparison that follows
      promotes the `i8` back to `i64` through exactly this path. Now masks to the source width, shifts
      up, and shifts back down with an arithmetic shift, which is what replicates the sign. Covered in
      `3290_numerics_width.t` at both levels, including negatives (`i8 -56`, `i8 -1`, `i16 -1`).
- [ ] **Every conversion width is spelled as a literal byte or a shift arithmetic** - `Encodings.pm`
      holds the opcodes and the fuzzer and tests spell widths out inline, so a wrong constant or a
      transposed subtraction is invisible until a module fails to validate. Extract these into named
      constants and utility functions for shift amounts and destination masks, so that reading the
      lowering says what the machine does without counting bits. This is what let the two Wasm
      conversion entries above sit undetected: both were a correct-looking shape with the wrong width
      baked in, and neither `wasm2wat` nor a byte-pattern grep would have flagged them.
- [x] **Wasm debugging needs `wabt`, which is not installed by default** - `apt install wabt` provides
      `wasm2wat`, `wasm-objdump` and `wasm-validate`. `wasm-objdump -d` on the emitted module, or
      `wasm2wat` into `.wat`, is the only practical way to see what a lowering actually produced:
      the `Sext` entry above was found by diffing two near-identical modules and reading the one
      instruction that differed. Hand-decoding the bytes is not reliable enough for this. Recorded
      under "Testing and Debugging Tools" in `CONTRIBUTING.md`.
- [ ] **`t/3000_jenny/3200_codegen/3280_sitofp_fptosi.t` could not have caught the two entries
      above** - it asserts on the *name* of a lowered opcode and never looks at its width, and it
      builds MIR rather than a module, so every one of its checks passed while all eight conversion
      shapes emitted an unloadable module. It now checks the opcode each width pair selects and,
      where wasmtime is present, compiles and runs a module for each. This is the general shape of the
      gap: CI has no wasmtime, so anything only a Wasm runtime can catch is uncaught there.

### Test-process lessons

- [ ] **MIR-level assertions give false confidence on float bugs** - `3280_sitofp_fptosi.t` and
      the other float tests assert on IR shape, and passed while the emitted code computed
      `0.0f`. Every float fix in this series is covered by a new test in `t/1000_katsuro/`
      (`1074_float_width.t`, `1075_float_ordering.t`, `1076_float_conversion.t`) that compiles,
      links, and **executes**, and each was confirmed to fail with its fix reverted.
- [ ] **Byte-pattern greps over emitted code are unreliable** - searching for `F3 0F 11` misses
      any encoding with a REX byte between the prefix and `0F`. This produced a false "no
      movss-store found" reading during the f32 investigation. Prefer instrumenting the lowerer
      and printing operand types, or disassembling with a real tool.

### Untouched by this series

- [ ] **illumos isolate segfaults are still unexplained** - the six skipped
      `t/3000_jenny/3500_isolate/` tests and the two `1050_integration.t` skips are masking a real
      crash, not fixing it. `Platform::Solaris` has no `libpthread_name` override and DT_NEEDED
      is still just `libc.so.1`, so the pthread probe has not found anything. Needs an
      illumos/OmniOS VM and gdb; not attempted here.

## Fuzzer Expansion Plan

The current fuzzer (`lib/Brocken/Fuzz.pm`) only exercises i64 arithmetic + if/else. Expansion is needed to cover the compiler's full language surface and catch regressions across all pipeline stages (lexer, parser, lowerer, codegen, linker, runtime).

### Known Findings (400-iteration run, seed 20260713)

The fuzzer's integer evaluator was rewritten to mirror the frontend's promotion rules, and its
type pool now generates only signed `i128`. A 400-iteration run reports 5 miscompiles and 1
Windows spawn failure:

- case 100 - float-to-bool assignment is not normalized (see Open bugs).
- case 295 - mixed-width signed/unsigned comparison compares at 32 bits (see Open bugs).
- cases 117, 195 - `i128` mixed with `f64`; not yet reduced to a minimal repro.
- case 301 - ternary with a `u64` and a `bool` arm; not yet reduced.
- case 335 - `system()` failed to spawn the child ("Inappropriate I/O control operation"). The
  fuzzer retries a few times, which removes the transient cases, but not this one.

### Phase F0: Type Diversity (Fuzzer Expansion: Types)
*Goal: Exercise code paths for all scalar types the compiler supports.*

- [ ] **Bool/i1** - Add `_rand_bool_val()` + `_gen_bool_decl()`, generate `my bool $b = true/false;` with `&&`/`||`/`!` ops
- [ ] **Fixed-width ints (u8-u64)** - Add `_rand_int_val(type)` that generates in-range values; declare vars of random fixed-width type (`u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `i64`, `u64`) and test cross-type assignment + implicit widening
- [ ] **i128** - Generate `my i128 $v = <big>;` using `Math::BigInt` for expected values; exercise `+` `-` `*` `/` `%` `&` `|` `^` `<<` `>>` with large operands
- [ ] **Float (f64)** - Track `_eval_f64` separately (Perl double vs x86_64 `cvtsi2sd`); generate mixed float/int expressions
- [ ] **Fat scalar (`Int`, `Bool`)** - Generate `my Int $x = 42;` (currently lowers as i64). Once box is heap-allocated, test boxing/unboxing round-trips
- [ ] **String** - Generate string literal assignment + `.` concatenation; compare length via `chars()` intrinsic or `say` output
- [ ] **Pointer types** - Test address-of (`&$var`) and pointer arithmetic, though this may be lower priority until manual memory ops are stable

### Phase F1: Control Flow & Structures
*Goal: Exercise IR/MIR control flow lowering, register allocation around branches, and CFG edge handling.*

- [ ] **While loops** - `_gen_while()`: generate `while ($v <op> $w) { <stmt>; <stmt>; }` with tracked expected value
- [ ] **Nested if/else** - `_gen_nested_if()`: if/else blocks containing further if/else trees (not just single assignments)
- [ ] **Chained comparisons** - `_gen_multi_cmp()`: `$v < $w && $x > $y` in conditions
- [ ] **Break/continue** - Once parsed, generate loops with `last`/`next` to exercise non-local control flow
- [ ] **Logical operators** - `$v && $w`, `$v || $w`, `!$v` in expression context (short-circuit lowering)
- [ ] **Ternary** - `$cond ? $then : $else` expression form

### Phase F2: Multi-Function Programs
*Goal: Exercise inter-procedural register allocation, calling convention, and stack frame management.*

- [ ] **Random subroutines** - Generate N random `sub foo() -> TYPE { ... return $val; }` with `_gen_sub($name, $n_params, $n_ops)`
- [ ] **Function calls** - `_gen_call()`: call a previously defined sub with random args, assign result to a var
- [ ] **Recursion** - Generate a simple recursive function (e.g., `sub fact(i64 $n) -> i64 { if ($n <= 1) { return 1; } return $n * fact($n - 1); }`) with deterministic expected value
- [ ] **Mutual recursion** - Even/odd pair or similar with multiple functions calling each other
- [ ] **The `main` function** - Test both implicit `_BROCKEN_ENTRY` and explicit `sub main` forms
- [ ] **Forward references** - Generate functions that call functions declared later in the source

### Phase F3: Memory & Aggregates (Frontend Lowerer)
*Goal: Exercise `alloca`/`load`/`store` codegen, GEP lowering, array bounds, and struct field access.*

- [ ] **Arrays** - Generate `my i64 @arr = [a, b, c];` with random element values; read/write `$arr[i]` with compile-time-constant index; track expected value
- [ ] **Array loops** - Populate array elements via loop over index, sum elements, verify total
- [ ] **Structs/classes** - Generate a class with random :param fields, construct with `MyClass->new(f1 => v1, ...)`, call a method that computes a return value
- [ ] **Auto-generated readers/writers** - Test `:reader` and `:writer` attribute access patterns
- [ ] **ADJUST blocks** - Generate classes with ADJUST that modifies a field; test the modified value
- [ ] **String ops** - `.` concat with string literals + int-to-string (`$i . "suffix"`)
- [ ] **`say`/`print` output** - Capture stdout and compare against expected output string (needs `capture_stdout` helper in test infrastructure)

### Phase F4: Mutation & Corpus Management
*Goal: Move from pure random generation to mutation-based fuzzing for deeper coverage.*

- [ ] **Seed corpus** - Collect interesting programs (edge cases, div-by-zero avoidance, large constants) as a reusable seed set; shuffle and mutate rather than regenerate from scratch each run
- [ ] **Mutations** - Implement operators: replace opcode, replace operand, swap operands, delete statement, duplicate statement, change constant value (including boundary values: 0, 1, -1, MAX_INT, MIN_INT), add dead code
- [ ] **Cross-over** - Take two programs from corpus, splice one statement from program A into program B at a random position
- [ ] **Corpus directory** - `t/5000_fuzz/corpus/` holding `.brocken` seed files read at fuzzer init
- [ ] **History tracking** - Record which seeds triggered new coverage (IR opcode, MIR opcode, lowering path) and prioritize them for re-fuzzing
- [ ] **Deterministic replay** - Expose `seed` in `test_program` result hashes so each failure can be reproduced with `Brocken::Fuzz->new(seed => N)`

### Phase F5: Minimization & Regression
*Goal: Automatically reduce failing test cases to minimal reproducers and add them to the regression suite.*

- [ ] **Delta debugging** - Implement `_minimize(source, failing_stage)`: try removing/commenting statements, simplifying expressions, reducing constant values, while preserving the failure
- [ ] **Regression extractor** - After minimization, format output as a standalone `Test2` subtest block and suggest the seed + minimized source for placement in `t/5000_fuzz/5010_fuzz_regressions.t`
- [ ] **Regression API** - `Fuzz->new(seed => N)->replay($minimized_source, $expected)` that exports a ready-to-paste test
- [ ] **Automated regression commit** - Script that runs fuzzer for N minutes, collects unique failures, minimizes each, and writes regression subtests

### Phase F6: Pipeline Stage Coverage
*Goal: Distinguish which compiler stage crashed to speed triage.*

- [ ] **Stage tagging in `test_program`** - Return `stage` field: `lex`, `parse`, `lower_ir`, `lower_mir`, `codegen`, `link`, `exec`
- [ ] **Stage-specific fuzz modes** - Methods `fuzz_lex`, `fuzz_lower`, `fuzz_codegen` that generate inputs targeting each stage (e.g., syntactically valid but semantically wrong for parse testing; valid IR ops for codegen testing)
- [ ] **Compile-only mode** - Skip execution when testing codegen/linker (`test_compile` vs `test_program`), for features where exit-code comparison is impossible
- [ ] **Reference interpreter** - Add a `Brocken::Interpreter` that evaluates Brocken AST nodes in Perl and produces expected results; compare compiled output against interpreted output for any program shape

### Phase F7: Sanitizer & Stress
*Goal: Detect memory errors, undefined behavior, and performance regressions under fuzzer load.*

- [ ] **AddressSanitizer fuzz** - When available, link fuzzer output with `-fsanitize=address`; detect heap-buffer-overflow, use-after-free, stack-buffer-overflow
- [ ] **UndefinedBehaviorSanitizer** - Link with `-fsanitize=undefined` to catch signed overflow, shift-past-width, misaligned access
- [ ] **Valgrind fuzz** - On Linux, run fuzzer output under `valgrind --tool=memcheck`; stop on first error
- [ ] **Overnight stress** - `fuzz_until_time(3600)` (1 hour) CI job that runs nightly; collects unique failures
- [ ] **Memory leak regression CI** - Assert RSS stays below threshold after N fuzzer iterations (using `Win32::Process::Info` or `/proc/$$/status`) - prevents reintroduction of the reference-cycle leak
- [ ] **Throughput monitoring** - Track `iters/sec` in fuzzer output; alert on >20% drop (indicating perf regression)

### Phase F8: Cross-Platform Fuzzing
*Goal: Catch platform-specific bugs (linker format, ABI, calling convention) across all targets.*

- [ ] **Target selection** - `Brocken::Fuzz->new()` hardcodes the host: its `ADJUST` block does
      `Brocken->new()` with no `platform`, and `test_program` then compiles, links and runs a
      native binary. There is no way to name a target, so this is the prerequisite for every other
      item in this phase. Add `Brocken->new( platform => $platform )` behind a `platform`/`target`
      option, taking the target string through `Brocken::Katsuro::Platform::parse` the way the
      tests do, and use `$fuzz->platform->ext` for the temp suffix (`.wasm` vs the host's) so a
      Wasm run does not try to execute a module as a binary.
- [ ] **Triple fuzzing** - Given a program, compile it for all 4 native targets (X86_64, ARM64, RISCV64, Wasm) and verify the exit code is the same on each (exit code is a scalar i64, platform-independent)
- [ ] **Linker format rotation** - Fuzz ELF64, PE, Mach-O code paths with the same program; verify identical exit code (platform-permitting)
- [ ] **Wasm fuzzing** - Test Wasm output via `wasmtime` or `node` runner (separate execution path in `test_program`). See the dedicated section below; this is the entry that leads there.

### Phase F8b: Wasm Fuzzing in CI
*Goal: fuzz the Wasm backend on every fuzz run, the way the host backend already is. Recorded
2026-10-02 after a differential smoke corpus found nine Wasm codegen bugs by hand that the fuzzer
would have caught for free: untyped locals producing invalid modules from the `box` lowering, a
boxed payload push dropped from the MIR, box stores hardcoded to 4 bytes against an 8-byte
default, signed `div`/`rem` emitted for unsigned operands, `i64.trunc_f64_s`/`f64.convert_i64_s`
named by direction instead of by width, `Sext` that cleared the low bits it was supposed to
preserve, `%heap_ptr` never seeded from the heap base, an initial memory section a third the size
of the heap the entry preamble promises `_init`, and a signed narrow load missing from the opcode
table. All nine were invisible to `t/` and to the existing fuzz CI.*

The host backend is fuzzed today by `.github/workflows/fuzz.yml`, which runs
`bin/fuzz_runner.pl --time-limit N` on ubuntu/windows/macos. None of those lanes ever touches the
Wasm codegen, lowerer or linker, so this whole backend is unfuzzed.

- [ ] **Separate execution path in `Brocken::Fuzz::test_program`** - for a Wasm platform, write the
      module with `Brocken::Jenny::Linker::Wasm->new->write_executable` and invoke
      `_BROCKEN_ENTRY` through `wasmtime run --invoke _BROCKEN_ENTRY <mod> 1024` (falling back to
      `node`), then read the entry's return value as the expected exit status. Do *not* use
      `wasmtime run <mod>` and the process exit status: the `_start` stub the linker emits calls the
      entry and deliberately drops its result (an exit status would mean importing
      `wasi_snapshot_preview1.proc_exit`), so both `42` and `1` exit 0 and the comparison would
      always trivially agree. This is the same invocation `t/1000_katsuro/1076_float_conversion.t`
      already uses for its Wasm lane; factor that runner out rather than writing a third copy.
- [ ] **Treat a Wasm trap as a failure, not a value** - a trap prints text (`wasm trap: out of
      bounds memory access`) on stderr and leaves no number to compare. Compared as a string it
      would bucket as an ordinary divergence with a useless expected/actual pair. Match the trap
      prefix, record `reason => 'wasm trap'` with the message, and fail. Most of the nine bugs above
      surfaced only as a trap, so this is the difference between a fuzz finding that is
      actionable and one that is not.
- [ ] **Install a Wasm runtime in the fuzz workflow** - `.github/workflows/fuzz.yml` needs
      wasmtime on every lane; `bytecodealliance/wasmtime-setup` is the usual action, or
      `cargo install wasmtime-cli`. Node is already present on the GitHub runners and covers the
      decode-and-instantiate path, but it will not report a trap the way wasmtime does, so it is a
      fallback for *validity* coverage rather than a replacement. A runner with neither should skip
      the lane rather than silently pass it.
- [ ] **Add a `wasm` entry to the fuzz job matrix** - the smallest change that gets the backend
      fuzzed at all: extend the existing `strategy.matrix` in `.github/workflows/fuzz.yml` with a
      `target` dimension (host plus `wasm32-unknown-wasi`) over the same OS list, and pass
      `--platform "${{ matrix.target }}"` through to `bin/fuzz_runner.pl`. Every host lane
      cross-checks Wasm against the host result, which is what makes the findings precise.
- [ ] **Prefer differential Wasm/host comparison over a reference interpreter** - for Wasm the
      expected value is already free: the host backend is the oracle, and the two must agree on the
      entry's return value. That makes the Wasm lane much cheaper than F6's
      `Brocken::Interpreter` and catches more, since it also covers the runtime and entry stub that
      an interpreter would not model.
- [ ] **Regression intake for Wasm fuzz findings** - Wasm failures should land in
      `t/3000_jenny/3200_codegen/` as executing wasmtime tests, matching how each of the nine fixes
      above got coverage, rather than only in the F5 minimizer output.

### Phase F9: Tooling & CI
*Goal: Make fuzzing a regular, trusted part of development workflow.*

- [ ] **`prove -lv t/5000_fuzz/5000_fuzz.t FUZZ_ITERATIONS=5000`** - Increase default iteration count; document how to run longer fuzz sessions
- [ ] **GitHub Actions fuzz workflow** - Daily cron job running fuzzer for 30 minutes on Linux, macOS, Windows; posts failure diffs to issue tracker. Extend this to the F8b `target` matrix so the same job covers the Wasm backend; the wasmtime setup belongs on the shared job, not a separate workflow.
- [ ] **Fuzzer dashboard** - Parse fuzzer output logs to track: iterations, failures, stage breakdown, coverage (IR opcode histogram), throughput
- [ ] **Fuzz-friendly `skip` mechanism** - Add `FUZZ_SKIP_KNOWN` env var pointing to a file of known-bug seeds (skip gracefully instead of failing on known issues)
- [ ] **Fuzz test diff** - When a new fuzz regression test is added, show `prove` output diff to confirm it would have caught the bug

### Immediate Next Steps (Priority Order)
1. ~~F0: Add `<<`/`>>` shift ops to `_rand_binop` and `_eval_i64` (trivial, immediately exercises shift lowering)~~ **[DONE]**
2. F0: Add `bool` type generation (`my bool $b = 1; if ($b) { ... }`)
3. F0: Add multiple integer widths (`i32`, `u32`, `u8`, `u16`) with random values that fit the range
4. F1: Add while-loop generation with tracked induction variable
5. F2: Add multi-function generation (2-3 random subs, one calls another)
6. ~~F4: Ensure deterministic replay: `run_case(case, max_ops, max_vars)` method + `seed`/`case_num`/`max_ops`/`max_vars` in result hashes~~ **[DONE]**
7. F4: Implement minimal mutation framework (take last generated program, mutate 1-2 ops)
8. F5: Write delta-debugging minimizer
9. F6: Add stage tagging to result hashes

### Current Fuzzer Limitations Summary
| Dimension | Current | Target |
|-----------|---------|--------|
| Types | i64 only | bool, i8-u64, i128, f64, Int, String |
| Statements | assign, if/else | + while, for, nested if, break/continue |
| Functions | 1 (implicit entry) | N subroutines + calls + recursion |
| Operators | + - * / % & \| ^ | + << >> && \|\| ! ~ ternary |
| Memory | none | arrays, struct fields, strings |
| Pipeline tested | compile+codegen+link+exec | stage-identified failures |
| Targets fuzzed | host backend only | + Wasm (differential against host), see Phase F8b |
| Generation | pure random | seed corpus + mutation + cross-over |
| Minimization | manual | automated delta debugging |
| CI duration | 20 iters (seconds) | 30-60 min nightly + quick smoke test |
