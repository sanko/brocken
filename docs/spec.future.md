# The Brocken Language Specification (Future Edition)

**Document:** `docs/spec.future.md`
**Status:** Design Proposal & Target Architecture
**Author:** Sanko Robinson & Contributors
**Target Version:** v0.2.0+

> **Implementation Note:** This is the forward-looking companion to [`spec.md`](spec.md), which
> describes v0.0.1. It specifies the language and toolchain Brocken is building toward and is written
> ahead of the implementation: some of what follows ships today, some is agreed but unbuilt, and some
> is still a proposal. Read it as the design of record for the target architecture, not a status
> report; [`TODO.md`](../TODO.md) is the shipped-versus-outstanding checklist.

---

# Notation and Conformance

This document is the design of record for Brocken v0.2.0 and later. It specifies both the language
and the toolchain that compiles it.

## Scope

It specifies the surface syntax, the static semantics a conforming compiler **MUST** enforce, and the
observable behavior of a compiled program. It does not specify the internals of the toolchain —
which modules exist, how the register allocator picks a register, how a section is laid out — except
where those internals are observable. The memory layouts, the calling conventions, the diagnostics,
and the on-disk formats **are** part of this specification, because compiled programs, foreign code,
and existing binaries depend on them.

## Normative Language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHOULD**, **SHOULD NOT**,
**RECOMMENDED**, **MAY**, and **OPTIONAL** in this document are to be interpreted as described in
RFC 2119.

- Text marked *informative*, or shown in a note, is explanatory and imposes no requirement.
- All other text is **normative**.
- Code examples are illustrative unless the surrounding text states that a behavior is required.

A conforming implementation **MUST** accept every program this document accepts, and **MUST** reject
the programs it marks as ill-formed. Where this document leaves behavior unspecified, an
implementation **MAY** choose any behavior, but **SHOULD** document the choice.

## Grammar Notation

Grammars in this document use an extended BNF (EBNF) with the following metasyntax:

| Form | Meaning |
|---|---|
| `rule ::= ...` | Definition of a grammar rule |
| `A \| B` | Alternation |
| `( x )` | Grouping |
| `x?` or `[ x ]` | Optional: zero or one |
| `x*` or `{ x }` | Repetition: zero or more |
| `x+` | Repetition: one or more |
| `'text'` | A literal terminal |
| `Ident` | A non-terminal or a lexical class defined in prose |

Whitespace between tokens is not a token and carries no meaning outside string literals and
comments. The grammar is a summary; the token-level rules in [Syntax](#syntax) refine it.

---

# Development

## Installation

The Brocken toolchain (`bkn`) is distributed both as a standalone, zero-dependency static binary and
as an installable Perl distribution for toolchain development. Brocken compiles Ahead-Of-Time (AOT)
to native machine code without an external linker, GCC, LLVM, or C runtime (`libc`).

Brocken is bootstrapped with Perl 5.42+ using the `class` feature; the standalone `bkn` build embeds
the platform definitions and the self-hosted runtime (`src/runtime/core.brocken`), so an ordinary user
never needs Perl.

### Standalone Toolchain Binaries

```bash
# Unix-like (Linux, the BSDs, macOS)
curl -fsSL https://brocken.dev/install.sh | sh

# Windows (PowerShell 7+)
irm https://brocken.dev/install.ps1 | iex
```

### Installation from Source (Bootstrapping Environment)

```bash
git clone https://github.com/sanko/brocken.git
cd brocken

# Validate the host environment and run the compiler test suite
perl Makefile.PL
make
make test

# Install the bootstrap compiler and the bkn driver onto PATH
make install
```

### Verification

```bash
bkn --version
bkn target list
```

Expected output:

```text
bkn v0.2.0 (x86_64-pc-linux-gnu)
Host ABI: System V AMD64
Runtime: Self-Hosted Immix + Fiber Scheduler (core.brocken)
Toolchain Status: Independent (No GCC / No LLVM / No libc)
```

### The Compiler Pipeline

```text
       ┌────────────────────────────────────────────────────────┐
       │               Host Bootstrap / `bkn` Driver            │
       │      Perl 5.42+ bootstrap compiler or static binary    │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Parses user source + core.brocken
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │               Katsuro (Compiler Frontend)              │
       │       Lexer ──▶ Pratt Parser ──▶ AST Construction      │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Lowers to SSA
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │               Lindsay (Middle-End Optimizer)           │
       │    SSA ──▶ RC Insertion ──▶ Inlining ──▶ DCE           │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Lowers to architecture MIR
                                  ▼
       ┌────────────────────────────────────────────────────────┐
       │                 Jenny (Backend & Linker)               │
       │     Linear-Scan RegAlloc ──▶ Machine-Code Encoders     │
       │       ELF64 / PE32+ / Mach-O / Wasm Writers            │
       └──────────────────────────┬─────────────────────────────┘
                                  │ Emits
                                  ▼
                 Standalone native executable or Wasm module
```

---

## Quick Start

### 1. Initialize a Project

```bash
bkn new telemetry_daemon
cd telemetry_daemon
```

The scaffolding creates:

```text
telemetry_daemon/
├── Brocken.toml         # Manifest, capabilities, and optimization profiles
├── src/
│   └── main.brocken     # Main compilation unit
└── tests/
    └── smoke.t          # Native TAP test suite
```

### 2. Write Application Code

Edit `src/main.brocken`:

```perl
use feature 'class';

class SensorNode {
    field u64    $id      :param;
    field String $name    :param :reader;
    field f64    $reading :reader = 0.0;

    ADJUST {
        die("Invalid sensor ID: cannot be zero") if $id == 0;
    }

    method sample(f64 $value) :returns(void) {
        $reading = $value;
    }

    method is_hot() :returns(bool) {
        return $reading >= 80.0;
    }
}

my SensorNode $node = SensorNode->new(id => 7, name => "reactor-core");
$node->sample(94.5);

if ($node->is_hot()) {
    say($node->name . " is running hot at " . $node->reading . "C");
}
```

### 3. Build and Run

```bash
# Compile and run immediately, in a temporary image
bkn run

# Compile to a standalone, stripped native binary
bkn build --release

# Confirm the binary has no runtime dependencies
ldd bin/telemetry_daemon 2>&1 || true   # 'not a dynamic executable' on Linux
```

---

## Environment

Brocken binaries interact directly with host kernels through raw system calls and register
conventions; no runtime shim, dynamic loader, or C startup file (`crt1.o`) is used.

### Target Triples

A target is a normalized four-part triple,
$\text{architecture}-\text{vendor}-\text{os}-\text{environment}$:

```text
x86_64-pc-linux-gnu
x86_64-apple-darwin-macho
x86_64-pc-windows-msvc
aarch64-unknown-linux-gnu
aarch64-apple-darwin-macho
aarch64-pc-windows-msvc
riscv64-unknown-linux-gnu
wasm32-unknown-wasi
```

The code generator and the binary format are independent axes: one generator serves several formats.

| Architecture | Code Generator | Binary Format | Calling Convention | Pointer Width |
|---|---|---|---|---|
| **x86_64** | `Codegen::X86_64` | ELF64 / PE32+ / Mach-O 64 | System V AMD64 / Microsoft x64 / Apple x86_64 | 64-bit |
| **AArch64** | `Codegen::ARM64` | ELF64 / PE32+ / Mach-O 64 | AAPCS64 | 64-bit |
| **RISC-V 64** | `Codegen::RISCV64` | ELF64 | LP64D | 64-bit |
| **Wasm32** | `Codegen::Wasm` | Wasm Module | WASI Core | 32-bit index (64-bit types emulated) |

### Register Roles and ABI Conventions

The compiler maps parameters, returns, the isolate control block, and the current fiber to
architecture-specific registers:

| Semantic Role | x86_64 (SysV) | AArch64 (AAPCS64) | RISC-V 64 (LP64D) |
|---|---|---|---|
| **Return 0** | `rax` | `x0` | `a0` |
| **Return 1** | `rdx` | `x1` | `a1` |
| **FP Return** | `xmm0` | `v0` | `fa0` |
| **Integer Arguments** | `rdi rsi rdx rcx r8 r9` | `x0`–`x7` | `a0`-`a7` |
| **Float Arguments** | `xmm0`–`xmm7` | `v0`–`v7` | `fa0`–`fa7` |
| **Frame Pointer** | `rbp` | `x29` | `s0` |
| **Link Register** | (stack) | `x30` | `ra` |
| **Link Register / SP** | `rsp` | `sp` | `sp` |
| **Fiber Register** | `r12` | `x28` | `s11` |

The **fiber register** holds the address of the currently running **Fiber Control Block (FCB)**.
Because it is pinned, every isolate shares one control-block address convention across the runtime,
the code generators, and the stack guards. On AArch64 and RISC-V the fiber register is the same as the
one the OS uses to carry the isolate control block during a fiber switch; the FCB records the owning
isolate in its `os_thread` field.

### Environment Variables

| Variable | Type | Purpose | Default |
|---|---|---|---|
| `BROCKEN_SYSROOT_AARCH64` | Path | Sysroot for emulating foreign AArch64 targets under QEMU | Unset |
| `BROCKEN_SYSROOT_RISCV64` | Path | Sysroot for emulating foreign RISC-V targets under QEMU | Unset |
| `BROCKEN_DUMP_INTERVALS` | Boolean | Emit live-interval ranges and spill decisions to `stderr` | `0` |
| `SOURCE_DATE_EPOCH` | Integer | Fixed epoch timestamp for byte-reproducible output | Host clock |
| `BROCKEN_DEFAULT_FUEL` | Integer | Instruction budget granted to a freshly spawned isolate | `1000000` |
| `BROCKEN_MEM_LIMIT` | Bytes | Hard ceiling for an isolate's heap (`0` = unconstrained) | `0` |
| `BROCKEN_LOG` | String | Log verbosity filter (`error`, `warn`, `info`, `trace`) | `warn` |

---

## Configuration

Project dependencies, compiler profiles, memory guarantees, and capability sandboxing live in
`Brocken.toml`.

```toml
[package]
name = "hyperion"
version = "0.2.0"
authors = ["Sanko Robinson <sanko@cpan.org>"]
entry = "src/main.brocken"
edition = "2026"

[profile.release]
opt_level = 3              # 0 = debug, 1 = size, 2 = speed, 3 = aggressive
strip = true               # Strip local symbols and non-essential sections
debug_level = 0            # 0 = none, 1 = line tables .. 4 = full DWARF v5
reproducible = true        # Sort every hash traversal for bitwise-identical output
lto = true                 # Cross-module SSA inlining and dead-code elimination

[profile.debug]
opt_level = 0
strip = false
debug_level = 4
asan = false               # Memory-layout bounds checker
stack_guard = true         # Emit prologue stack-limit checks

[isolate.defaults]
initial_fuel = 5_000_000   # Fuel decrements at entries, calls, and loop back-edges
initial_heap = "2MB"       # First Immix block allocation
max_heap = "512MB"         # Exceeding this raises ERR_OOM
stack_budget = "2MB"       # Guard runway below the hardware stack pointer

[capabilities]
fs_read = true             # Permit filesystem reads
fs_write = false           # Deny filesystem writes
net = true                 # Permit socket operations
system = false             # Forbid process spawns
ffi = false                # Forbid raw syscall / libc imports
```

---

# Fundamentals

## Syntax

Brocken uses modern Perl syntax while removing historical parsing ambiguities and irregular
grammatical forms.

### Source Text

A compilation unit is a sequence of Unicode scalar values encoded as UTF-8. A byte-order mark is
permitted and ignored. Source files **MUST** be valid UTF-8; a byte sequence that is not is a
well-formedness error reported before parsing. Tabs, carriage returns, and the several Unicode line
separators are not significant except as whitespace.

### Whitespace and Line Structure

Brocken is newline-terminated, not newline-sensitive: a statement ends at its `;`, not at a line
break, so an expression **MAY** span lines. Space, horizontal tab, carriage return, and newline
separate tokens and are otherwise ignored.

### Comments

| Form | Scope |
|---|---|
| `# ...` | A line comment, to the end of the line. |
| `=begin ... =end` | A block of embedded documentation (Pod6), discarded by the compiler. |
| `#\| ...` | A declarator comment attached to the declaration that follows it. |

```perl
# A line comment.
#| Attached to the next declaration; surfaced by the language server and `bkn fmt`.
sub checksum(ptr $buffer, i64 $len) :returns(u32) { ... }
```

### Identifiers and Namespaces

An identifier matches `/[a-zA-Z_][a-zA-Z0-9_]*/` and is case-sensitive. A qualified name uses the
namespace separator `::` (`Net::HTTP::Client`). A leading underscore is a convention, not a rule: a
single leading underscore is stripped when a field name is used to derive a constructor parameter or
accessor name (see [Classes](#classes)).

| Item | Convention |
|---|---|
| Types, classes, roles, packages | `UpperCamelCase` |
| Subroutines, methods, fields, variables | `snake_case` |
| Constants | `UPPER_SNAKE_CASE` |
| Native machine types | `lowercase` (`i32`, `f64`, `ptr`) |
| Managed scalar types | `Capitalized` (`Int`, `String`, `Any`) |

### Punctuation and Separators

Statements terminate with `;`. Blocks are delimited by `{ ... }`. Parentheses group expressions and
delimit call arguments; brackets `[ ... ]` index arrays and construct array references; braces
`{ ... }` index hashes and construct hash references. A comma `,` separates items in lists,
arguments, and declarations.

### Keywords

Keywords are reserved and **MUST NOT** be used as identifiers.

```text
ADJUST  DESTROY  adjoin  and  as  async  await  catch  class  const
decorator  defer  die  else  elsif  false  field  finally  for  foreach
if  isolate  last  method  my  next  not  or  our  package  print  ptr
redo  return  role  say  state  sub  throw  true  try  undef  unless
until  use  while  xor  yield
```

The built-in type names are **not** keywords: they are ordinary identifiers in the type namespace
and **MAY** be shadowed by a user declaration.

```text
i8   i16   i32   i64   i128      u8   u16   u32   u64   u128
f32  f64   bool  int   ptr       Any  Int  Float  Bool  String  Array  Hash
```

`true`, `false`, and `undef` are keyword literals. `async` and `await` are reserved by the
[execution policies](#execution-policies) surface.

### Numeric Literals

| Form | Example | Notes |
|---|---|---|
| Decimal | `1234` | |
| Underscore-separated | `1_000_000` | Ignored; for readability only |
| Hexadecimal | `0xDEAD_beef` | Case-insensitive digits |
| Octal | `0o755` | A lone leading `0` is not octal |
| Binary | `0b1010_0101` | |
| Floating point | `3.14159` | A digit is required on both sides of `.` |
| Scientific | `5e+10`, `1.5e-3` | The exponent sign is optional |
| 128-bit | `170141183460469231731687303715884105727` | Typed by context |

### String Literals and Escapes

A double-quoted string is delimited by `"..."` and interpolates. The following escapes are
recognized within it:

| Escape | Meaning |
|---|---|
| `\n` `\r` `\t` `\f` `\b` | Newline, carriage return, tab, form feed, backspace |
| `\a` `\e` `\0` | Alert, escape, NUL |
| `\\` `\"` | Literal backslash, literal double quote |
| `\$` `\@` `\%` | Suppress interpolation of the following sigil |
| `\x{HH}` | A Unicode scalar by code point (1–6 hex digits) |
| `\N{NAME}` | A named Unicode character |

A single-quoted string (`'...'`) does not interpolate and recognizes only `\\` and `\'`. The exact
interpolation rules are specified under [UTF8](#utf8).

### Grammar (EBNF)

```ebnf
Program         ::= Declaration* Statement* EOF ;

Declaration     ::= ClassDecl | SubDecl | PackageDecl | UseDecl | DecoratorDecl ;

ClassDecl       ::= 'class' Ident ( Version )? ( ClassAttr )* '{' ClassBody '}' ;
ClassBody       ::= ( FieldDecl | MethodDecl | AdjustDecl | DestroyDecl )* ;
FieldDecl       ::= 'field' Type ( Sigil | '[' Type ';' Const ']' Sigil ) Ident
                    ( FieldAttr )* ( FieldInit )? ';' ;
FieldInit       ::= ( '=' | '//=' | '||=' ) Expr ;
MethodDecl      ::= 'method' Ident Signature ( MethodAttr )* Block ;
AdjustDecl      ::= 'ADJUST' Block ;
DestroyDecl     ::= 'DESTROY' Block ;

SubDecl         ::= 'sub' Ident Signature ( SubAttr )* Block ;
Signature       ::= '(' ( ParamList )? ')' ;
ParamList       ::= Param ( ',' Param )* ;
Param           ::= ( ':' )? Type Sigil Ident ( '=' Expr )? ;

Statement       ::= VarDecl | AssignStmt | IfStmt | WhileStmt | ForStmt
                  | ReturnStmt | ThrowStmt | TryCatchStmt | LoopControlStmt
                  | DeferStmt | ExprStmt | Block | ';' ;

VarDecl         ::= 'my' ( Type )? Sigil Ident ( ( '=' | '//=' | '||=' ) Expr )? ';'
                  | 'my' '(' TargetList ')' '=' Expr ';' ;
AssignStmt      ::= Target ( '=' | '+=' | '-=' | '*=' | '/=' | '//=' | '||=' ) Expr ';' ;
Target          ::= Var | FieldAccess | DerefExpr | IndexExpr ;

IfStmt          ::= 'if' '(' Expr ')' Block ( 'elsif' '(' Expr ')' Block )* ( 'else' Block )? ;
WhileStmt       ::= 'while' '(' Expr ')' Block ;
ForStmt         ::= 'for' ( 'my' ( Type )? Sigil Ident )? '(' Expr ')' Block ;
ReturnStmt      ::= 'return' ( ExprList )? ';' ;
ThrowStmt       ::= ( 'throw' | 'die' ) Expr ';' ;
TryCatchStmt    ::= 'try' Block ( 'catch' '(' Sigil Ident ')' Block )? ( 'finally' Block )? ;
LoopControlStmt ::= ( 'last' | 'next' | 'redo' ) ';' ;
DeferStmt       ::= 'defer' Block ;

Expr            ::= BinaryExpr | UnaryExpr | PrimaryExpr ;
PrimaryExpr     ::= Const | Var | CallExpr | MethodCall | ConstructExpr | ParenExpr | Lambda ;
Lambda          ::= 'sub' Signature Block | 'method' Signature Block ;
```

### Operator Precedence and Associativity

Operators are listed from highest precedence (Level 1) to lowest (Level 20):

| Level | Operator | Fixity | Associativity | Description |
|---|---|---|---|---|
| **1** | `->` `->[]` `->{}` `->$*` `->@*` `->%*` | Postfix | Left | Dereference, invocation, indexing |
| **2** | `++` `--` | Postfix | Non-assoc | Post-increment / decrement |
| **3** | `**` | Binary | Right | Exponentiation |
| **4** | `!` `~` `\` `+` `-` | Prefix | Right | Logical/bitwise NOT, ref-take, unary signs |
| **5** | `=~` `!~` | Binary | Left | Pattern binding |
| **6** | `*` `/` `%` `x` | Binary | Left | Multiplicative, repetition |
| **7** | `+` `-` `.` | Binary | Left | Additive, string concatenation |
| **8** | `<<` `>>` | Binary | Left | Shifts |
| **9** | `<` `>` `<=` `>=` `lt` `gt` `le` `ge` | Binary | Left | Relational comparisons |
| **10** | `==` `!=` `<=>` `eq` `ne` `cmp` | Binary | Left | Equality and three-way comparisons |
| **11** | `&` | Binary | Left | Bitwise AND |
| **12** | `\|` `^` | Binary | Left | Bitwise OR / XOR |
| **13** | `&&` | Binary | Left | Short-circuit AND |
| **14** | `\|\|` `//` | Binary | Left | Short-circuit OR, defined-or |
| **15** | `..` `...` | Binary | Non-assoc | Range / flip-flop |
| **16** | `? :` | Ternary | Right | Conditional |
| **17** | `=` `+=` `-=` `*=` `/=` `//=` `\|\|=` | Binary | Right | Assignment and compound assignment |
| **18** | `not` | Prefix | Right | Low-precedence logical NOT |
| **19** | `and` | Binary | Left | Low-precedence logical AND |
| **20** | `or` `xor` | Binary | Left | Low-precedence logical OR / XOR |

---

## Variables

### Invariant Sigils

Sigils are **invariant**: the sigil denotes the storage container and never mutates with access
dimension or evaluation context.

| Sigil | Container | Element Access | Reference | Full Deref |
|---|---|---|---|---|
| `$` | Scalar / native primitive / object | `$x` | `\$x` | `$ref->$*` |
| `@` | Sequential indexed array | `@arr[0]` | `\@arr` | `$ref->@*` |
| `%` | Associative dictionary | `%map{"key"}` | `\%map` | `$ref->%*` |

```perl
# Arrays keep their @ sigil on element access
my @numbers = (10, 20, 30);
my i64 $first = @numbers[0];     # correct
@numbers[1] = 25;                # direct mutation

# Hashes keep their % sigil on element access
my %config = (host => "localhost", port => 8080);
my String $host = %config{"host"};
%config{"port"} = 9090;
```

### Storage Classes

```perl
# Lexical (register or local stack slot), dropped at block exit
my i64 $counter = 0;

# Persistent lexical: allocated once per isolate, survives scope exits
state u64 $call_count = 0;
$call_count++;

# Package-scoped global: lives in the isolate-local .data segment
our String $GLOBAL_NAME = "Primary Worker";

# Compile-time constant: evaluated at compile time, emitted into .rodata
const f64 $PI = 3.141592653589793;
```

### Truthiness

A value is **false** if and only if it is one of:

1. Numeric `0` or `0.0`
2. The string `"0"`
3. The empty string `""`
4. Undefined (`undef`, a null pointer, or Type Tag 0)

Everything else is **true**, including `"00"`, `"false"`, `0.5`, negative numbers, references, and
object pointers. A dynamic `Any` in boolean context is routed through
`Brocken::Runtime::is_truthy(ptr)` rather than being truncated blindly.

### Defined-Or and Conditional Assignment

```perl
# `//` is defined-or: eager (both operands evaluate), no short-circuit
my Any $a;
my Any $b = $a // "default";

# `//=` stores only when the slot is undefined (null pointer / null box)
my String $token;
$token //= generate_token();   # assigned
$token //= generate_token();   # skipped: the slot is now defined

# `||=` stores when the slot is false
my i64 $retries = 0;
$retries ||= 3;                # 3, because zero is false
```

On a native `int`/`float`/`bool`, which can never be `undef`, `//=` degrades to a plain `=`. In a
`my` declaration the conditional forms take the initializer unconditionally, because a fresh variable
has no prior value to test.

---

## Functions

Subroutines are declared with `sub` and require typed signatures. Return types are declared with the
`:returns(...)` attribute.

### Signatures and Register Tuples

A subroutine may return several values as a tuple, mapped directly onto the architecture's return
registers with no heap allocation:

- **x86_64:** `rax`, then `rdx`
- **AArch64:** `x0`, then `x1`
- **RISC-V 64:** `a0`, then `a1`

```perl
sub divide(i64 $numerator, i64 $denominator) :returns(i64, bool) {
    if ($denominator == 0) {
        return (0, false);           # no allocation
    }
    return ($numerator / $denominator, true);
}

my ($quotient, $ok) = divide(42, 6);
```

### Typing Judgements

Static typing is expressed with the usual inference relation $\Gamma \vdash e : \tau$:

$$
\frac{\Gamma(x) = \tau}{\Gamma \vdash x : \tau}\;[\text{Var}]
\qquad
\frac{\Gamma \vdash e_1 : \text{i64} \quad \Gamma \vdash e_2 : \text{i64}}{\Gamma \vdash e_1 + e_2 : \text{i64}}\;[\text{IntAdd}]
$$

$$
\frac{\Gamma \vdash e_1 : \tau \quad \Gamma[x \mapsto \tau] \vdash e_2 : \tau'}{\Gamma \vdash (\text{my } \tau\ x = e_1;\ e_2) : \tau'}\;[\text{Let}]
\qquad
\frac{\Gamma \vdash f : (\tau_1,\dots,\tau_n) \to (\sigma_1,\dots,\sigma_m) \quad \Gamma \vdash a_i : \tau_i}{\Gamma \vdash f(a_1,\dots,a_n) : (\sigma_1,\dots,\sigma_m)}\;[\text{Call}]
$$

### Parameter Defaults

Positional parameters may carry defaults. Omitted **trailing** arguments are filled at the call site,
in the caller's scope; a default may reference any earlier parameter:

```perl
sub connect(String $host, i64 $port = 8080, i64 $timeout = $port > 1024 ? 30 : 60) :returns(ptr) {
    # ...
}

my ptr $a = connect("127.0.0.1");        # port = 8080, timeout = 30
my ptr $b = connect("127.0.0.1", 80);    # port = 80,   timeout = 60
```

### Named Parameters

A parameter prefixed with `:` is passed at the call site by name with `=>`:

```perl
sub spawn_server(String $bind, :i64 $workers = 4, :bool $tls = false) :returns(void) {
    # ...
}

spawn_server("0.0.0.0", workers => 8, tls => true);
```

### Closures and Environment Records

A subroutine that captures no outer lexical lowers to a bare function pointer in `.text`. A
capturing subroutine allocates an Immix-managed **Environment Record** holding the captured slots,
passed to the closure as a hidden environment pointer and governed by the Caller-Borrows contract.

```perl
sub make_accumulator(i64 $start) :returns(ptr) {
    my i64 $total = $start;
    return sub (i64 $delta) :returns(i64) {
        $total += $delta;
        return $total;
    };
}
```

---

## Classes

Brocken implements encapsulation through Corinna-style classes (`use feature 'class'`).

### Fields, Attributes, and the Constructor

```perl
class BankAccount {
    field u64    $account_id :param;
    field String $owner_name :param :reader;
    field i64    $balance    :reader = 0;
    field bool   $is_frozen  = false;

    ADJUST {
        die("Invalid account ID: cannot be zero") if $account_id == 0;
    }

    method deposit(i64 $amount) :returns(i64) {
        die("Account is frozen") if $is_frozen;
        die("Amount must be positive") if $amount <= 0;
        $balance += $amount;
        return $balance;
    }

    DESTROY {
        # Runs immediately when the reference count reaches zero
    }
}
```

`Class->new(...)` is synthesized from the `:param` fields. When no explicit name is given, `:param`,
`:reader`, and `:writer` derive their name by stripping **exactly one** leading underscore:

- `field $_timeout :param;`  $\Rightarrow$ `new(timeout => 30)`
- `field $_timeout :reader;` $\Rightarrow$ `$obj->timeout()`
- `field $_timeout :writer;` $\Rightarrow$ `$obj->set_timeout(60)`
- `field $__private :reader;` $\Rightarrow$ `$obj->_private()` (one underscore remains)

### Field Attributes

| Attribute | Parameter | Semantics |
|---|---|---|
| `:param` | None or `(name)` | Exposes the field as a constructor argument. |
| `:reader` | None or `(name)` | Synthesizes a getter `$obj->name()`. |
| `:writer` | None or `(name)` | Synthesizes a chaining setter `$obj->set_name($v)` returning `$self`. |
| `:accessor` | None or `(name)` | Combines a reader with a chaining writer. |
| `:weak` | None | Stores the pointer without taking refcount ownership (breaks cycles). |

### Inheritance and Static Dispatch

Single inheritance is declared with `:isa(Parent)`. A subclass instance is the parent's field block
followed by the child's:

```perl
class PremiumAccount :isa(BankAccount) {
    field i64 $credit_limit :param = 1000;

    method deposit(i64 $amount) :returns(i64) {
        say("Premium deposit");
        return $self->SUPER::deposit($amount);
    }
}
```

Method dispatch is resolved **statically** at compile time: no vtable, no runtime method lookup, no
indirect branch. Fields are lexically private to the class that declares them and are **not**
inherited; methods are public and are.

### Physical Instance Layout

A class instance is a contiguous Immix allocation. The 8-byte header packs the reference count and
the type tag; fields begin at offset 8, in superclass-then-subclass order, with natural alignment:

```text
Offset  Size  Field
--------------------------------------------------------------------------------
 0      2     Reference Count (u16, saturated at 65535 = pinned)
 2      1     GC Flags (cycle suspect, buffered, leaf, BRC color)
 3      1     Type Tag
 4      4     Auxiliary / padding
 8      8     Superclass field: $account_id (u64)
16      8     Superclass field: $owner_name (managed string pointer)
24      8     Superclass field: $balance (i64)
32      1     Superclass field: $is_frozen (bool)
33      7     Alignment padding
40      8     Subclass field:   $credit_limit (i64)
Total: 48 bytes (8-byte naturally aligned)
```

---

## Modules

A module is a namespace that maps to a file on disk.

```perl
# lib/Math/Geometry.brocken
package Math::Geometry 1.0.0;

use feature 'brocken_native_types';

sub distance(f64 $x1, f64 $y1, f64 $x2, f64 $y2) :export :returns(f64) {
    my f64 $dx = $x2 - $x1;
    my f64 $dy = $y2 - $y1;
    return sqrt($dx * $dx + $dy * $dy);
}
```

Consuming modules:

```perl
# src/main.brocken
use Math::Geometry;

my f64 $dist = Math::Geometry::distance(0.0, 0.0, 3.0, 4.0);
```

During the Lindsay middle-end pass, symbols that are neither exported nor referenced are pruned from
the program (tree-shaking). A `package NAME;` declaration prefixes the declarations that follow, so a
module need not spell its full name on every `sub`.

---

## Attributes

Attributes are compile-time directives to the parser, middle end, and code generator.

### Subroutine Attributes

- `:returns(Type, ...)` — Return type, or a tuple mapped to return registers.
- `:inline` — Request inlining into caller blocks.
- `:noinline` — Forbid inlining.
- `:pure` — Guarantee no memory side effects (enables CSE).
- `:export` — Emit the symbol in the dynamic symbol table for C ABI interop.

### Variable Attributes

- `:aligned(N)` — Enforce N-byte alignment on a stack slot or static address.
- `:const` — Assert single assignment; mutation is a compile-time diagnostic.

---

## Decorators

Decorators are compile-time macro wrappers around subroutines, methods, and classes.

```perl
decorator timed(Sub $target) {
    return sub (*@args) {
        my i64 $start = Brocken::monotonic_clock();
        my @res = $target->(@args);
        my i64 $elapsed = Brocken::monotonic_clock() - $start;
        say("" . $target->name . " took ${elapsed}ns");
        return @res;
    };
}

@timed
sub execute_matrix_multiplication(ptr $a, ptr $b) :returns(ptr) {
    # ...
}
```

---

# Advanced

## Concurrency

Brocken's concurrency is modeled on Hoare's Communicating Sequential Processes and Plan 9's Alef. It
has two layers: heavy **isolates** (OS threads with strictly disjoint heaps) and lightweight
**fibers** (cooperative green threads multiplexed inside an isolate). They communicate over typed
**channels**.

```text
┌─────────────────────────────────────────────────────────────┐
│                         ISOLATE 1                           │
│  OS Thread (pthread / CreateThread)                         │
│  Pinned fiber register (r12 / x28 / s11) -> FCB              │
│  Thread-Local Immix Heap (zero-lock reference counting)     │
│                                                             │
│   ┌──────────────┐   ctx_swap    ┌──────────────┐           │
│   │   Fiber A    │ <===========> │   Fiber B    │           │
│   │ Stack (64KB) │               │ Stack (64KB) │           │
│   └──────────────┘               └──────────────┘           │
└──────────────────────────────┬──────────────────────────────┘
                               │
                Bounded channel ring buffer (CCB)
             deep-copy across the isolate boundary
                               │
┌──────────────────────────────┴──────────────────────────────┐
│                         ISOLATE 2                           │
│  Disjoint Immix heap and control block                      │
└─────────────────────────────────────────────────────────────┘
```

### Isolates (Share-Nothing OS Threads)

An isolate is an independent OS thread with its own heap and its own control block.
Because heaps never overlap, reference counting is a local load-modify-store sequence: **no atomic
instructions, no bus locks**. The isolate control block address is held in a pinned register for the
duration of the thread.

```perl
my ptr $iso = isolate(sub () {
    say("Running on an independent OS thread with its own heap");
});

isolate_join($iso);
```

### Fibers (Cooperative Coroutines)

A fiber is an M:N cooperative coroutine with a private 64 KiB stack, switched with the
architecture-specific `ctx_swap` sequence and recorded in a **Fiber Control Block** (FCB). The fiber
register holds the address of the currently running FCB.

```perl
my ptr $worker = fiber(sub ($seed) {
    say("Fiber step 1: received $seed");
    my Any $reply = yield($seed * 10);
    say("Fiber step 2: received $reply");
    return $reply + 5;
});

my i64 $out1 = transfer($worker, 5);   # step 1; returns 50
my i64 $out2 = transfer($worker, 15);  # step 2; returns 20
```

### Fiber Control Block (FCB) Layout

`ctx_swap` spills one 8-byte slot per callee-saved register, in save order; the fiber register's slot
doubles as `self`. Named fields follow the register region. The stack pointer keeps its place in the
register region on AArch64 and RISC-V (which spill `sp`), and takes the first named slot on x86_64.

```text
Offset (AArch64 / RISC-V / x86_64)  Field          Description
-------------------------------------------------------------------------
 0..              (13/14/6 slots)   saved_regs     Callee-saved register spill array
 self*8                              self           FCB self-pointer (fiber-register slot)
 96 / 104 / 48   saved_sp           Hardware stack pointer at the last switch
104 / 112 / 56   parent             FCB address of the parent / yielder fiber
112 / 120 / 64   resume_pc          Code address to jump to on resumption
120 / 128 / 72   os_thread          Owning isolate's control block
128 / 136 / 80   stack_limit        Stack guard boundary for this fiber (sp - runway)
136 / 144 / --   transfer_value     Fiber hand-off value (AArch64 and RISC-V only)
144 / 152 / 88   size               FCB size for the architecture
```

### Channels (CSP)

Channels are typed, synchronized, bounded ring buffers (`chan_create`, `chan_send`, `chan_recv`,
`chan_close`):

```perl
my ptr $chan = chan_create(16);   # capacity 16

isolate(sub () {
    for my $i (1 .. 10) {
        chan_send($chan, $i * 100);
    }
    chan_close($chan);
});

while (my ($value, $open) = chan_recv($chan)) {
    last unless $open;
    say("Received: $value");
}
```

**Data-transfer invariants:**

1. **Primitives** (`i8`..`i128`, `f32`, `f64`, `bool`) are copied by value through the ring buffer.
2. **Aggregates** (Strings, arrays, hashes, objects) are deep-copied into the receiving isolate's
   heap, preserving the thread-local heap invariant. Zero-copy ownership transfer (`move $var` with a
   scoped affine checker and a global message arena) is a later optimization.

### Primitive Reference

The concurrency surface is a small set of intrinsics; everything in this section is defined in terms
of them. They carry no hidden allocation and never block while holding the isolate lock.

| Intrinsic | Signature | Semantics |
|---|---|---|
| `isolate` | `(Code) -> ptr` | Spawns an OS thread with a fresh heap and runs `Code` on it. Returns an opaque thread handle. |
| `isolate_join` | `(ptr) -> Any` | Blocks the caller until the isolate finishes and returns its result; the heap is reclaimed afterwards. |
| `fiber` | `(Code) -> ptr` | Creates a suspended fiber with a 64 KiB stack. Does not run until first `transfer`. |
| `transfer` | `(ptr, Any) -> Any` | Switches to `fiber`, delivering the second argument as the value of that fiber's pending `yield`/`transfer`, and returns the value the fiber hands back. |
| `yield` | `(Any) -> Any` | Suspends the running fiber and hands its value to the resumer; resumes with the value passed to `transfer`. |
| `chan_create` | `(i64) -> ptr` | Allocates a bounded channel with the given capacity (must be `> 0`). |
| `chan_send` | `(ptr, Any) -> bool` | Enqueues a value, blocking while the ring is full; returns false if the channel is closed. |
| `chan_recv` | `(ptr) -> (Any, bool)` | Dequeues a value, blocking while the ring is empty; the flag is false once the channel is drained and closed. |
| `chan_close` | `(ptr) -> bool` | Marks the channel closed; further sends fail and receives drain the remaining values before signaling closed. |

### Scheduling and Memory Model

- **Preemptive between isolates.** Isolates are OS threads scheduled by the kernel; the runtime does
  not intervene.
- **Disjoint heaps.** Each isolate owns an Immix heap. There is no shared mutable state, so
  reference counting needs no atomics and cache lines are never shared across cores.
- **Copy across boundaries.** Every value crossing an isolate boundary is deep-copied; pointers into
  an isolate's heap **MUST NOT** be observed from another isolate. A channel is the only sanctioned
  crossing point.
- **Structured teardown.** An isolate that returns or is joined reclaims its heap. An isolate that
  panics runs its deferred blocks and unwinds, and the handle reports the failure to `isolate_join`.

The `async`/`await` surface is sugar over `fiber`/`transfer`; see
[Execution Policies](#execution-policies) for how a program selects its scheduling discipline.

---

## Exceptions

Exceptions are zero-cost landing dispatchers backed by an SJLJ (`setjmp`/`longjmp`) handler chain
recorded on the isolate control block (`ICB::EXCEPTION_HANDLER_STACK`).

```perl
try {
    die("Database transaction aborted");
}
catch ($err) {
    warn("Recovered from exception: $err");
}
finally {
    say("Releasing transaction locks");
}
```

### The Landing Dispatcher

To guarantee that a `finally` block runs exactly once under every exit path — normal completion,
caught exception, early `return`, `last`, or `next` — the compiler lowers `try` into a state machine:

```text
[try_setup]  ──▶ push the jmp_buf onto ICB::EXCEPTION_HANDLER_STACK
      │
[try_body]   ──▶ normal exit pops the handler ──▶ [finally] ──▶ [merge]
      │
      └── (throw / die)
            │
            ▼
[landing]    ──▶ pop the handler, load the thrown value
            │
            ├──▶ [catch_body] ──▶ [finally] ──▶ [merge]
            └──▶ (no catch)   ──▶ [finally] ──▶ rethrow
```

Because the `longjmp` path restores only callee-saved registers, the register allocator keeps
caller-saved registers out of the pool for any function that calls `setjmp`, so a value live across
the `setjmp` cannot be clobbered by the unwind.

---

## Resources

Deterministic cleanup is expressed with scope destructors and `defer`:

```perl
sub process_file(String $path) :returns(void) {
    my ptr $fh = open_file($path);
    defer { close_file($fh); }   # runs on every block exit

    # ... use $fh ...
}
```

The `defer` body runs when the enclosing block exits, whether by normal completion, `return`,
`last`/`next`, or a thrown exception.

---

## Iterators

An iterator is a zero-allocation cursor object conforming to the iterator protocol: a `next` method
returning a `(value, bool)` register tuple.

```perl
class NumberSequence {
    field i64 $current :param = 0;
    field i64 $limit   :param;

    method next() :returns(i64, bool) {
        return (0, false) if $current >= $limit;
        my i64 $value = $current++;
        return ($value, true);
    }
}

for my $number (NumberSequence->new(limit => 5)) {
    say("Sequence: $number");
}
```

A range in a `for` header lowers to a zero-allocation register induction loop:

```perl
for my i64 $i (0 .. 1000) {
    # $i is a register counter; no array is allocated
}
```

---

## Type System

Brocken separates **unboxed raw machine types** (lowercase) from **managed fat scalars**
(capitalized), both syntactically and physically.

```text
                               Type Universe
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           ▼                                                   ▼
Unboxed Machine Types                                Managed Fat Scalars
(CPU registers / raw stack slots)                    (16-byte Immix fat scalar)
 - i8 .. i128  (signed integers)                      - Any
 - u8 .. u128  (unsigned integers)                    - Int, Float, Bool
 - f32, f64    (IEEE 754 floats)                      - String
 - bool        (1-bit flag)                           - Array, Hash
 - ptr         (64-bit address)                       - Class instances
```

### Unboxed Machine Types

Enabled with `use feature 'brocken_native_types';`. These bypass the fat-scalar header, never
participate in reference counting, and map directly to registers and machine instructions:

```perl
use feature 'brocken_native_types';

my i32  $index    = 0;
my f64  $pi       = 3.141592653589793;
my bool $ready    = true;
my ptr  $raw_addr = Brocken::heap_base();
```

Unboxed types **cannot be `undef`**; uninitialized, they default to `0`, `0.0`, or `false`.

### Managed Fat Scalars (`Any`)

A value without an explicit unboxed type defaults to `Any`, a 16-byte tagged scalar:

```text
Offset  Size  Field
--------------------------------------------------------------------------------
 0      2     Reference Count (u16, saturated at 65535 = pinned)
 2      1     GC Flags (cycle suspect, buffered, leaf, BRC color)
 3      1     Type Tag (0=Undef, 1=Int, 3=Float, 4=Ptr, 5=Dynamic, 7=List, 8=Hash)
 4      4     Auxiliary Data (e.g. cached UTF-8 length) / padding
 8      8     Payload (raw bits of an i64, f64, or pointer)
```

The tag is read from the top byte of the header word. A class instance uses the same header encoding
but places its fields at offset 8 instead of a payload word.

Managed values **default to `undef`** (Type Tag 0, null payload).

### Coercion and Unboxing

- `unbox_i64(ptr)` — reads the tag; a float payload truncates toward zero, an int payload returns directly.
- `unbox_f64(ptr)` — widens an int payload to a double, or returns a float payload directly.
- `box(value)` — allocates a 16-byte slot via the Immix bump allocator, writes the tag, and stores the payload.

---

## UTF8

Strings are immutable, length-prefixed, NUL-terminated byte sequences guaranteed to contain valid
UTF-8.

```perl
my String $greeting = "こんにちは世界";
say(length($greeting));   # character count
say(bytes($greeting));    # raw byte count
```

### Strict Interpolation

Inside double quotes:

1. Scalars interpolate: `"Value is $var"`
2. Disambiguated scalars interpolate: `"Total: ${count}kg"`
3. Container elements interpolate: `"Item: @arr[0]"`, `"Value: %map{key}"`
4. **Method calls do not interpolate**: `"($obj->value)"` prints the stringified object followed by
   the literal `->value`. Method calls must be concatenated: `"(" . $obj->value . ")"`.

### ASCII-Magical String Increment

Applying `++` to a string follows Perl's ASCII-carry rules:

- Applies only to strings matching `/^[a-zA-Z]*[0-9]*\z/` (`"az"++` $\to$ `"ba"`, `"99"++` $\to$ `"100"`).
- Otherwise the string coerces to numeric `0` and increments to `1`.
- Decrement (`--`) is never magical: it coerces to numeric and subtracts `1`.

---

## Execution Policies

Execution boundaries are enforced by the capability bitmask and instruction budget carried in the
isolate control block.

### Isolate Control Block (ICB) Layout

The ICB is a 160-byte structure at the base of an isolate's heap. Generated once from
`Brocken::Layout`, it holds everything the runtime needs:

```text
Offset  Field                      Description
--------------------------------------------------------------------------------
  0     heap_cursor                Bump pointer for legacy heap allocations
  8     current_fcb                Currently running Fiber Control Block
 16     fiber_head                 Head of the active fiber list (GC root)
 24     immix_cursor               Bump pointer within the current Immix line
 32     immix_limit                End of the usable region in the current line
 40     free_blocks                Head of the reusable Block list
 48     free16_head                Hot path: 16-byte segregated free list
 56     suspect_buffer_head        Head of the suspect cycle ring buffer
 64     fuel                       Remaining instruction budget
 72     err_code                   Abort reason (see below)
 80     current_block              Base of the active Immix block
 88     memory_limit               Heap byte ceiling (0 = unlimited)
 96     memory_used                Current heap byte consumption
104     capabilities               Permission bitmask
112     gate_table                 Gate check dispatch table
120     host_icb                   Parent isolate's control block
128     exception_handler_stack    Head of the SJLJ handler chain
136     thrown_value               Payload carried by throw / die
144     free_big_head              Reusable variable-sized array slabs
152     stack_limit                Stack guard floor (sp - runway)
160     SIZE                       Size to reserve for an isolate
```

### Error Codes

| Code | Value | Meaning |
|---|---|---|
| `ERR_OK` | 0 | No error |
| `ERR_OOM` | 1 | Out of memory against `MEMORY_LIMIT` |
| `ERR_NO_FUEL` | 2 | Fuel exhausted |
| `ERR_SECURITY` | 3 | A capability check refused the operation |
| `ERR_DIV_ZERO` | 4 | Integer division by zero |
| `ERR_THROW` | 5 | An uncaught `throw` / `die` reached the top |
| `ERR_STACK` | 6 | Stack guard tripped |

### Capabilities

Privileged operations consult the bitmask at `ICB::CAPABILITIES`:

| Capability | Bit | Guards |
|---|---|---|
| `CAP_FS_READ` | `1 << 0` | Filesystem reads |
| `CAP_FS_WRITE` | `1 << 1` | Filesystem writes |
| `CAP_NET` | `1 << 2` | Socket creation, bind, connect |
| `CAP_SYSTEM` | `1 << 3` | Process spawning |
| `CAP_FFI` | `1 << 4` | Raw `syscall`, `syscall_by_name`, `libc` |

The FFI intrinsics are the only place the capability mask is consulted today. When fuel reaches zero,
execution halts immediately with `ERR_NO_FUEL`.

---

## Performance

### Memory Management Architecture

```text
Layer 3: Perceus (compile-time IR)
  ├── Borrow inference: drop redundant incref/decref at call boundaries
  ├── RC elision: cancel adjacent incref/decref on local bindings
  └── In-place reuse: mutate unique objects (RC == 1) without reallocating

Layer 2: Bacon & Rajan trial deletion (runtime cycle collector)
  ├── Suspect buffer: tracks non-leaf objects whose RC dropped but stayed > 0
  └── 3-phase color sweep: purple (suspect) -> gray -> white (garbage) / black

Layer 1: Reference counting + Immix bump allocation (hot path)
  ├── Hot path: freed 16-byte scalars are pushed to a segregated free16 list
  └── Immix: 32 KiB blocks divided into 256-byte lines
```

### The Caller-Borrows Contract

Passing an argument does not touch a reference count. A callee borrows its parameters and must not
decrement them on exit; it emits an `incref` only when it stores the value into an array, hash, class
field, or global.

### Immix Block Geometry

A block is exactly 32768 bytes and begins on a 32 KiB boundary:

```text
[block + 0 .. 15]:      128-bit line-availability bitmap (bit N = line N in use)
[block + 16 .. 255]:    Line 0   (240 usable bytes; first 16 hold the bitmap)
[block + 256 .. 511]:   Line 1   (256 usable bytes)
...
[block + 32512..32751]: Line 127 (240 usable bytes)
[block + 32752..7]:     live_count (i64) -- live object count in this block
[block + 32760..767]:   next_free (i64) - scan cursor for the next free line
```

Blocks tile a single `BLOCK_SIZE` grid anchored at the first block; a freed object is charged to the
block that *contains its address*, found by masking rather than by trusting the current allocator
block:

$$
\text{block\_base} = \text{arena\_base} + ((\text{obj} - \text{arena\_base})\ \&\ \sim\text{0x7FFF})
$$

When a block's `live_count` reaches zero it is returned to `ICB::FREE_BLOCKS`.

---

## Language Server

The compiler integrates a Language Server Protocol daemon (`bkn lsp`) for diagnostics, completion,
symbol navigation, and type inference.

```bash
bkn lsp --stdio
```

### DWARF v5 Debug Generation

The backend emits DWARF v5 during binary generation:

- **`.debug_line`** — machine-code offset to source line/column mapping.
- **`.debug_info`** — compilation units, subprograms, variables, and class layouts.
- **`.debug_names`** — DWARF v5 accelerated symbol lookup using case-folding DJB hashing.
- **`.debug_frame`** — call-frame information for unwinding.

### Native Backtraces (`.brk_sym`)

The linker can also emit a compact `.brk_sym` section so a stripped release binary can produce
backtraces without external debug files:

```text
word     count
count ×  { start_rva, end_rva, name_offset }
byte[]   NUL-terminated symbol name pool
```

---

## FFI

The `Brocken::` pseudo-namespace is the unsafe native subset. Its intrinsics lower directly to MIR
and never allocate:

| Intrinsic | MIR output |
|---|---|
| `Brocken::ptr_add(p, off)` / `ptr_sub(p, off)` | `add` / `sub` |
| `Brocken::ptr_cmp_gt(a, b)` / `_lt` / `_ge` / `_le` / `_eq` | `icmp sgt` / `slt` / `sge` / `sle` / `eq` |
| `Brocken::load_i64(ptr)` / `store_i64(ptr, val)` | `load i64` / `store i64` |
| `Brocken::load_i32(ptr)` / `load_i8(ptr)` / `load_u16(ptr)` | `load i32` / `i8` / `i16` |
| `Brocken::load_f64(ptr)` / `store_f64(ptr, val)` | `load f64` / `store f64` |
| `Brocken::i64_add(a, b)` / `i64_sub(a, b)` | `add` / `sub` |
| `Brocken::band` / `bor` / `bxor` / `shl` / `shr` | `and` / `or` / `xor` / `shl` / `lshr` |
| `Brocken::syscall(number, ...)` | `syscall` instruction, guarded by `CAP_FFI` |
| `Brocken::syscall_by_name(name, ...)` | `syscall` with the number resolved for the target |
| `Brocken::libc(name, ...)` | `call` to a link-time-resolved symbol |
| `Brocken::heap_base()` | load of `__heap_base` |

```perl
use feature 'brocken_native_types';

my ptr $addr;
my i64 $value = Brocken::load_i64($addr);
Brocken::store_i64($addr, $value + 1);

my i64 $written = Brocken::syscall_by_name("write", 1, "hello\n", 6);
my f64 $root    = Brocken::libc("sqrt", 144.0);
```

`syscall_by_name` and `libc` require a literal string, so the name resolves before linking.

### Bind Gates

Bind gates let guest Brocken code run inside a host process without corrupting memory:

1. Arguments are deep-copied into the host's Immix heap.
2. The pinned control-block register is swapped to the host's.
3. The host function executes.
4. The return value is deep-copied back to the guest heap, and the guest register is restored.

---

# Toolkit

The `bkn` executable is the consolidated toolchain driver: compiler, runtime, test harness,
benchmarker, package manager, formatter, linter, task runner, and language server.

## Commands

```text
bkn build [options] [path]    Compile source into a standalone native executable
bkn run [options] [path]      Compile and execute the program
bkn test [options] [path]     Run the test harness with native TAP output
bkn bench [options] [path]    Run performance microbenchmarks
bkn fmt [options] [files...]  Format sources according to the style spec
bkn lint [options] [files...] Run static analysis and borrow checks
bkn lsp                       Launch the language server
bkn clean                     Clear build caches and temporary artifacts
bkn new <project>             Scaffold a new project directory
bkn target <cmd>              Query and install target triples
bkn vendor                    Vendor dependencies for reproducible builds
bkn task <name>               Execute a declared build task
bkn upgrade                   Update the toolchain
```

### `bkn build`

Compiles source into a standalone native executable. Runs the full pipeline: lex, parse, check,
type, lower to Machine IR, optimize, allocate registers, emit, and link against the runtime archive.

```text
--release                 Optimize and strip (profile.release)
--target <triple>         Cross-compile for a target triple
--opt-level <0..3>        Override the optimization level
--debug-level <0..4>      DWARF emission detail
--reproducible            Byte-identical output for a fixed SOURCE_DATE_EPOCH
--emit <kind>             Stop early: exe | obj | asm | mir
-o, --output <path>       Write the artifact to a specific path
--jobs <n>                Parallel codegen units (default: CPUs)
-v, --verbose             Print each pipeline stage and its timing
```

### `bkn run`

Builds and immediately executes the program, passing any trailing arguments to it.

```text
--release                 Run the optimized build
--emit <kind>             Interpret `mir` directly instead of native code
-v, --verbose             Print each pipeline stage
-- <args>...              Arguments forwarded to the program's ARGV
```

### `bkn test`

Runs the test harness and reports native TAP to standard output.

```text
--filter <pattern>        Only run tests whose path matches
--jobs <n>                Parallel test processes (default: CPUs)
--no-capture              Interleave test output with the harness
--target <triple>         Run tests under the target's emulator (qemu-user)
-v, --verbose             Show each harness invocation
```

### `bkn bench`

Runs performance microbenchmarks and reports timing distributions.

```text
--filter <pattern>        Only run matching benchmarks
--samples <n>             Samples per benchmark (default: 100)
--warmup <n>              Warm-up iterations before sampling (default: 10)
--json                    Emit machine-readable results
```

### `bkn fmt`

Formats sources according to the [formatter](#formatter) style. Writes in place unless `--check`.

```text
--check                   Exit non-zero if any file would change
--diff                    Print a unified diff instead of writing
--stdin                   Read from standard input, write to standard output
--edition <year>          Formatting rules for a language edition
```

### `bkn lint`

Runs static analysis and the borrow/escape checks without producing an executable.

```text
--deny <lint>             Promote a lint to an error (repeatable)
--allow <lint>            Silence a lint (repeatable)
--forbid <lint>           Forbid a lint even if a `deny` attribute allows it
--json                    Emit diagnostics as JSON for editor consumption
```

### `bkn lsp`

Launches the [language server](#language-server) over the requested transport.

```text
--stdio                   Speak LSP over standard input/output (default)
--socket <addr>           Listen on a TCP socket
--pipe <path>             Listen on a named pipe
--log-level <level>       trace | debug | info | warn | error
```

### `bkn clean`

Removes build caches and intermediate artifacts.

```text
--all                     Also remove downloaded toolchains and vendored sources
--target <triple>         Only clean the given target's cache
--dry-run                 Print what would be removed
```

### `bkn new`

Scaffolds a new project directory with a manifest, a source tree, and a test directory.

```text
--lib                     Create a library project (no main entry point)
--bin                     Create an executable project (default)
--vcs <system>            git | none (default: git)
--edition <year>          Language edition for the manifest
```

### `bkn target`

Queries and installs cross-compilation target triples.

```text
bkn target list                    Show installed and available triples
bkn target add <triple>            Register a sysroot for a triple
bkn target install <triple>        Download and unpack a prebuilt runtime
bkn target remove <triple>         Forget a registered triple
```

### `bkn vendor`

Copies every dependency into `vendor/` so builds are reproducible without network access.

```text
--path <dir>              Vendor directory (default: vendor/)
--frozen                  Fail if the lockfile would change
```

### `bkn task`

Executes a task declared in `Brocken.toml` under `[tasks]`.

```text
bkn task <name>           Run the named task
bkn task --list           List every declared task and its description
```

### `bkn upgrade`

Updates the installed toolchain.

```text
--version <x.y.z>         Install a specific version instead of the latest
--check                   Report whether a newer version exists, without installing
```

Every subcommand accepts `--help` for its own usage text; `bkn --version` prints the toolchain
version and the supported target triples.

---

## Runtime

The runtime is written in Brocken's unsafe native subset (`src/runtime/core.brocken`). When a project
compiles, `core.brocken` is parsed and its declarations are prepended to the user's AST. It provides
the Immix allocator, the reference-counting helpers, the trial-deletion collector, the fiber
scheduler, channels, and the intrinsics that the middle end lowers.

```perl
package Brocken::Runtime;

use feature 'brocken_native_types';

sub alloc_raw(ptr $hb, i64 $size) :returns(ptr) {
    my ptr $cursor = Brocken::Runtime::get_immix_cursor($hb);
    my ptr $next   = Brocken::ptr_add($cursor, $size);
    if (Brocken::ptr_cmp_gt($next, Brocken::Runtime::get_immix_limit($hb))) {
        return Brocken::Runtime::bump_alloc($hb, $size);
    }
    Brocken::Runtime::set_immix_cursor($hb, $next);
    return $cursor;
}
```

---

## Testing

Brocken programs emit Test Anything Protocol (TAP) output natively:

```perl
# tests/math.t
use Test::More;

sub add(i64 $a, i64 $b) :returns(i64) {
    return $a + $b;
}

ok(add(2, 3) == 5, "2 + 3 == 5");
is(add(-1, 1), 0,  "-1 + 1 == 0");

done_testing();
```

```bash
bkn test
```

```text
1..2
ok 1 - 2 + 3 == 5
ok 2 - -1 + 1 == 0
# Result: PASS
```

The test harness builds each fixture once and runs it on every available backend. Cross-target
fixtures are executed under QEMU when `BROCKEN_SYSROOT_AARCH64` or `BROCKEN_SYSROOT_RISCV64` is set,
and skipped otherwise.

---

## Benchmarking

Microbenchmarks use high-resolution hardware timestamps:

```perl
# bench/allocation.brocken
use Benchmark;

timethis(1_000_000, sub () {
    my Point $p = Point->new(x => 10, y => 20);
});
```

---

## Bundler

Dependencies are recorded in `Brocken.lock`, content-addressed by digest for reproducible, air-gapped
builds:

```toml
[[package]]
name = "Crypt::SipHash"
version = "1.0.2"
source = "registry+https://pkg.brocken.dev"
digest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
```

```bash
bkn vendor   # copy dependencies into ./vendor
```

---

## Formatter

`bkn fmt` operates on the parsed AST, so it is semantics-preserving. The canonical style:

- 4-space indentation, no tabs
- K&R braces
- A single space around binary operators
- A trailing comma in multi-line lists
- One blank line between declarations

```bash
bkn fmt --check src/
```

---

## Linting

`bkn lint` reports borrow-rule violations, unreachable code, unhandled tuple returns, implicit type
narrowing, and other statically detectable hazards.

```bash
bkn lint src/
```

---

## Tasks

Build automation is declared directly in `Brocken.toml`:

```toml
[tasks.generate_tables]
command = "bkn run scripts/gen_tables.brocken"

[tasks.pre_release]
dependencies = ["lint", "test", "generate_tables"]
```

```bash
bkn task pre_release
```

---

## Upgrade

```bash
bkn upgrade --channel stable
```

---

# Examples

## Hello, World!

```perl
use feature 'class';

class Application {
    field String $message :param;

    method run() :returns(i64) {
        say($message);
        return 0;
    }
}

my Application $app = Application->new(message => "Hello, World!");
exit($app->run());
```

---

## Fibonacci

An iterative version that allocates nothing, and a recursive version for comparison:

```perl
sub fib_iterative(i64 $n) :returns(i64) {
    my i64 $a = 0;
    my i64 $b = 1;
    for my i64 $i (0 .. $n - 1) {
        my i64 $next = $a + $b;
        $a = $b;
        $b = $next;
    }
    return $a;
}

sub fib_recursive(i64 $n) :returns(i64) {
    return 0 if $n <= 0;
    return 1 if $n == 1;
    return fib_recursive($n - 1) + fib_recursive($n - 2);
}

my i64 $n = 30;
say("fib_iterative($n) = " . fib_iterative($n));
say("fib_recursive($n) = " . fib_recursive($n));
```

---

## Leibniz

The Gregory-Leibniz series converges to $\pi$:
$\pi = 4 \sum_{k=0}^{\infty} \frac{(-1)^k}{2k+1}$.

```perl
use feature 'brocken_native_types';

sub estimate_pi(i64 $terms) :returns(f64) {
    my f64 $acc  = 0.0;
    my f64 $sign = 1.0;

    for my i64 $k (0 .. $terms) {
        my f64 $denominator = 2.0 * $k + 1.0;
        $acc  += $sign / $denominator;
        $sign  = -$sign;
    }

    return $acc * 4.0;
}

my i64 $iterations = 10_000_000;
my f64 $pi         = estimate_pi($iterations);

say("Estimated value of PI over $iterations iterations: $pi");
```

---

# Glossary

| Term | Definition |
|---|---|
| **Isolate** | An OS thread with its own Immix heap and its own ICB. Heaps never overlap, so no mutable state is shared. See [Concurrency](#concurrency). |
| **Fiber** | A cooperative green thread inside an isolate, switched by `ctx_swap`; it shares the isolate's heap. See [Concurrency](#concurrency). |
| **ICB** | Isolate Control Block: heap limit, fuel budget, capability bits, and the exception handler chain; addressed from a pinned register. See [Runtime](#runtime). |
| **FCB** | Fiber Control Block: spilled callee-saved registers, saved stack pointer, resume PC, parent, and transfer slot. See [Concurrency](#concurrency). |
| **CCB** | Channel Control Block: a shared, bounded ring buffer guarded by a mutex and condition variable. See [Concurrency](#concurrency). |
| **Fat Scalar** | The 16-byte `Any` representation: a refcount word, GC flags, a type tag, and a payload. See [Type System](#type-system). |
| **Immix** | A bump allocator over 32 KiB blocks divided into 256-byte lines, with segregated free lists. See [Performance](#performance). |
| **Reference counting** | The primary reclamation strategy, performed without atomics because heaps are isolate-local. |
| **Perceus** | Compile-time reference-count optimization (borrow inference, RC elision, allocation reuse). Planned. See [Performance](#performance). |
| **Linear scan** | The register allocator used by the code generator. See [Performance](#performance). |
| **MIR** | Machine IR: the target-independent IR between typing and instruction selection. See [Performance](#performance). |
| **SJLJ** | `setjmp`/`longjmp` landing dispatch used to implement exceptions at zero steady-state cost. See [Exceptions](#exceptions). |
| **Fuel** | A per-isolate step budget in the ICB, decremented at safepoints, used to bound runaway execution. See [Execution Policies](#execution-policies). |
| **Capability bits** | Per-isolate bits in the ICB that gate privileged runtime operations (spawning, FFI, syscalls). See [Runtime](#runtime). |
| **Attribute** | Compile-time metadata attached to a declaration with `:name(value)`. See [Attributes](#attributes). |
| **Decorator** | A program transformation applied to the declaration that follows a `decorator` declaration. See [Decorators](#decorators). |
| **Role** | An abstract, composable behavior fragment that a class `adjoin`s. See [Classes](#classes). |
| **Profile** | A named bundle of build settings (`dev`, `release`) selected by `bkn build`. See [Commands](#commands). |
| **Target triple** | An architecture/vendor/OS tuple such as `riscv64-unknown-linux-gnu`. See [Commands](#commands). |
| **Edition** | A dated language version a project opts into via the manifest. See [Modules](#modules). |

---

# Index

| Topic | Where |
|---|---|
| ABI and calling conventions | [Functions](#functions), [FFI](#ffi), [Performance](#performance) |
| Attributes and decorators | [Attributes](#attributes), [Decorators](#decorators) |
| Bit-widths and native types | [Variables](#variables), [Type System](#type-system) |
| Channels and message passing | [Concurrency](#concurrency) |
| Classes, fields, methods, roles | [Classes](#classes) |
| Command reference | [Toolkit](#toolkit), [Commands](#commands) |
| Exceptions and unwinding | [Exceptions](#exceptions), [Performance](#performance) |
| FFI and foreign calls | [FFI](#ffi) |
| Fibers and scheduling | [Concurrency](#concurrency), [Execution Policies](#execution-policies) |
| Formatter and linter | [Formatter](#formatter), [Linting](#linting) |
| Grammar and notation | [Notation and Conformance](#notation-and-conformance), [Syntax](#syntax) |
| Iterators and generators | [Iterators](#iterators) |
| Manifest and profiles | [Modules](#modules), [Commands](#commands) |
| Memory and garbage collection | [Type System](#type-system), [Performance](#performance) |
| Modules and imports | [Modules](#modules) |
| Operator precedence | [Syntax](#syntax) |
| Resources and `defer` | [Resources](#resources) |
| Reproducible builds | [Commands](#commands), [Bundler](#bundler) |
| Testing and benchmarking | [Testing](#testing), [Benchmarking](#benchmarking) |
| Unicode and strings | [UTF8](#utf8), [Syntax](#syntax) |
| Language server | [Language Server](#language-server) |
