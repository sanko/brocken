# Brocken Compiler Roadmap

Now that the foundational IR (Lindsay) and Platform abstraction (Katsuro) are in place, we need to bridge the gap between abstract SSA and executable machine code.

Completed work has been removed from this file: every finished task lives with its regression
test under `t/` and in the git history that names the fix.

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

## Known Bugs

- [ ] **A sum of many mixed integer and floating-point arguments comes back wrong on the x86-64 Linux ELF target**  a function taking both files at once, `sub g(i64 $i8, ..., f64 $f1) -> f64 { return $i8 + ... + $f1; }`, returns a sum that is not the sum. 7+7 is correct, 8+8 returns 75 instead of 72, 10+10 returns 111 instead of 110. The same source is correct on `x86_64-pc-windows-gnu` at every count tried, so the frame and the argument files are not the whole of it. The wrong answer tracks register pressure and nothing else: taking one register out of the pool at the baseline, with no change to any reload code, reproduces the 8+8 wrong answer exactly, and produces a third wrong answer at 10+10, so this is not a fault in the spill-reload path added with `spill_addr_temp`. Only observable when a foreign target is actually executed, which needs `BROCKEN_SYSROOT*` to be set; `t/3000_jenny/3200_codegen/3300_stack_arguments.t` covers it and fails on this target at 10+10 today. Not investigated further; the allocator change is not the cause and the two need to be tracked apart.

## Calling Conventions

- [ ] **Floating-point callee-save on X86_64**  SysV ABI marks all XMM as caller-saved; codegen only uses `PUSH` (GP-only). Would need `MOVUPS`/`MOVDQA` stack save/restore for non-SysV ABI variants.

## 128-bit Numerics (i128)

- [ ] **Endianness**  no handling for big-endian targets.

## Katsuro Frontend (Bootstrapping Subset v0.1)

### Known Issues (Remaining)

- [ ] **ARM64 macOS: int-to-string via `sprintf` varargs** - ARM64 AAPCS requires 64-byte register save area for variadic calls. Fixed in Codegen/ARM64.pm (`sub sp, #64` / `add sp, #64` around `call_func`/`call_indirect`). Needs testing on Apple Silicon.

### Upcoming
- [ ] **Dynamic (boxed) types at top level:** `my Int $x = 10` currently lowers like `i64`; needs actual box allocation
- [ ] **Debug info:** Source location tracking through the pipeline (line numbers in errors)
- [ ] **Better error messages:** Report source line + column for parse/lower/codegen errors
- [ ] **Hash support:** `%` hashes, basic key-value storage
- [ ] **Write `core.brocken`:** Start implementing runtime primitives (allocator, channels) using v0.1 subset

## Deferred (post-frontend)

### Channels (blocked until Immix allocator)
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

## Debug Info / DWARF Gaps

### Gap 9: No split DWARF / type units / DWARF compression
**Description:** All debug data is emitted inline in the executable. No `.debug_types` (type units), `.debug_cu_index`, or DWARF compression (`.zdebug_*`). This increases binary size for projects with many types or large source files.
**Impact:** Future optimization. Not relevant for current v0.1 subset.
**Priority:** Future
**Dependencies:** Would require linker changes (section name mapping for compressed sections) and structural changes to DWARF.pm to emit type units separately.

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

### Open

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
- [ ] **A boxed `f32` cannot be represented at all** - the payload is one 8-byte slot and the IR
      has no `fptrunc`/`fpext`, so a float of one width cannot be stored in a slot of the other.
      An `f32` payload writes 4 bytes and the unbox reads 8, or the unbox reads 4 of an 8-byte `f64`.
      Every decimal literal is an `f64`, so nothing reaches a box as an `f32` unless it is declared
      one on purpose. This is the gap tracked under `Brocken::Lindsay`, not here.
- [ ] **Every conversion width is spelled as a literal byte or a shift arithmetic** - `Encodings.pm`
      holds the opcodes and the fuzzer and tests spell widths out inline, so a wrong constant or a
      transposed subtraction is invisible until a module fails to validate. Extract these into named
      constants and utility functions for shift amounts and destination masks, so that reading the
      lowering says what the machine does without counting bits. This is what let the two Wasm
      conversion entries above sit undetected: both were a correct-looking shape with the wrong width
      baked in, and neither `wasm2wat` nor a byte-pattern grep would have flagged them.

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
type pool now generates only signed `i128`. A 400-iteration run reported 5 miscompiles and 1
Windows spawn failure. Two of the five have since been fixed and no longer need tracking here:
case 100 (float-to-bool assignment is not normalized) and case 295 (mixed-width signed/unsigned
comparison compares at 32 bits); each is fixed in the frontend's conversion path and covered by
`1076_float_conversion.t` and `1040_lowerer.t`. What remains:

- cases 117, 195 - `i128` mixed with `f64`; not yet reduced to a minimal repro.
- case 301 - ternary with a `u64` and a `bool` arm; not yet reduced.
- case 335 - `system()` failed to spawn the child ("Inappropriate I/O control operation").
  `_system_retry` already retries up to five times with backoff, which removes the transient
  instances; this one survived them. Still open.

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
1. F0: Add `bool` type generation (`my bool $b = 1; if ($b) { ... }`)
2. F0: Add multiple integer widths (`i32`, `u32`, `u8`, `u16`) with random values that fit the range
3. F1: Add while-loop generation with tracked induction variable
4. F2: Add multi-function generation (2-3 random subs, one calls another)
5. F4: Implement minimal mutation framework (take last generated program, mutate 1-2 ops)
6. F5: Write delta-debugging minimizer
7. F6: Add stage tagging to result hashes

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
