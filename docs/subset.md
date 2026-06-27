# Brocken v0.1 — Bootstrapping Subset

## Purpose

Define the minimum viable Brocken syntax needed to write `core.brocken`:
the Immix allocator, channel runtime, and GC. Everything outside this
subset is either delegated to the Perl host or deferred until after
self-hosting.

## 1. Variables, Gradual Typing & Arrays

Scalar (`$`) and array (`@`) variables are supported.

```perl
my $dynamic_var;              # Any (Fat Scalar) — default
my i64 $count = 0;            # Raw 64-bit integer
my ptr $cursor;               # Raw pointer (no arithmetic, use intrinsics)
my i32 $slot;                 # 32-bit unsigned
my i8 $byte;                  # 8-bit unsigned
my i64 @arr = [10, 20, 30];   # Fixed-size array (size from literal count)
```

Array elements are accessed by index; bounds are not checked yet:

```perl
$arr[0] = 42;                 # Array write
my i64 $x = $arr[1];          # Array read
```

Valid type keywords: `Any`, `Int`, `String`, `Bool`, `ptr`, `i8`, `i16`,
`i32`, `i64`, `i128`, `f32`, `f64`.

Variables without an explicit type are `Any`.

## 2. Subroutines

Strict signatures with arity and optional return type.

```perl
sub allocate_block(i64 $size) -> ptr {
    my ptr $cursor = $heap_ptr;
    $heap_ptr = Brocken::ptr_add($cursor, $size);
    return $cursor;
}

sub greet(i64 $n) {
    # implicit void return
}
```

- Parameters are `(TYPE $name, ...)`
- Return type is `-> TYPE`; omitted means void
- Last expression is NOT implicitly returned — must use `return`

## 3. Control Flow

```perl
if ($x > 0) {
    ...
} elsif ($x == 0) {
    ...
} else {
    ...
}

while ($cursor < $limit) {
    ...
}

return $value;
return;   # void return
```

- No statement modifiers (`say "hi" if $x`)
- No `unless`, `until`, `for`, `foreach`
- No `next`, `last`, `redo`

## 4. Classes

Corinna-style `class` with `field`, `method`, and `ADJUST` block.

```perl
class Point {
    field i64 $x :param;
    field i64 $y :param;

    ADJUST {
        $x = 10 if $x < 10;    # clamp minimum
    }

    method sum() -> i64 {
        return $x + $y;
    }
}
```

### Fields

Each `field` has an explicit type and optional attributes:
- `:param` — auto-generates a constructor (`Point->new($x, $y)`)
- `:reader` — auto-generates a getter (`$p->x`)
- `:writer` — auto-generates a setter (`$p->set_x(42)`)
- `:default(N)` — default value when omitted from constructor

Fields are laid out sequentially in memory (order-defined, no padding
guarantees in v0.1).

### Methods

Methods are functions that receive `$self` (a `ptr`) as the first
parameter. Method calls use `->` syntax:

```perl
my ptr $p = Point->new(10, 20);
my i64 $s = $p->sum();
```

### ADJUST

The `ADJUST` block inside a class runs after the constructor assigns
`:param` fields. It can enforce invariants (e.g., clamp values).

### Direct field access

Fields can be read and written directly without a reader/writer:

```perl
my i64 $x = $p->x;
$p->x = 42;
```

## 5. Intrinsics (`Brocken::*`)

The `Brocken::` pseudo-namespace maps directly to MIR instructions.

```perl
my ptr $next = Brocken::ptr_add($cursor, $size);

if (Brocken::ptr_cmp_gt($next, $limit)) { ... }

my i64 $val = Brocken::load_i64($addr);
Brocken::store_i64($addr, $val);
```

Known intrinsics:

| Intrinsic | MIR output |
|-----------|------------|
| `Brocken::ptr_add(p, off)` | `add` (pointer arithmetic) |
| `Brocken::ptr_sub(p, off)` | `sub` (pointer arithmetic) |
| `Brocken::ptr_cmp_gt(a, b)` | `icmp sgt` |
| `Brocken::ptr_cmp_lt(a, b)` | `icmp slt` |
| `Brocken::ptr_cmp_eq(a, b)` | `icmp eq` |
| `Brocken::load_i64(ptr)` | `load i64` |
| `Brocken::store_i64(ptr, val)` | `store i64` |
| `Brocken::load_i32(ptr)` | `load i32` |
| `Brocken::store_i32(ptr, val)` | `store i32` |
| `Brocken::syscall(n, ...)` | syscall instruction |

## 6. Built-in functions

| Function | Behaviour |
|----------|-----------|
| `say(...)` | Print (newline-terminated) — lowered to `write(1)` syscall |
| `print(...)` | Print (no newline) — lowered to `write(1)` syscall |

## 7. Entry Point

There is no special `sub main`. Top-level code is automatically compiled
into an implicit entry function that receives a heap-base pointer from
the OS entry stub. `sub main` defined explicitly is just a regular
function — it is not automatically called.

```perl
# This program:
my i64 $x = 42;
return $x;

# Is equivalent to the user writing:
sub _BROCKEN_ENTRY(i64 $__heap_base) -> i64 {
    my i64 $x = 42;
    return $x;
}
```

## 8. Feature Flags

Experimental features are gated behind `use feature`:

```perl
use feature 'brocken_native_types';   # enables i128, i16, f32, f64 types
```

## 9. Excluded (deferred)

| Feature | Reason |
|---------|--------|
| `%` hashes | Not needed for the runtime; can be built on top later |
| Strings | Needed eventually; for v0.1, `say("hello")` uses const data |
| Regex | Deferred entirely |
| `map`/`grep` | Defer until list primitives exist |
| `eval` | Blocks on dynamic codegen |
| `match` | Pattern matching sugar — defer |
| `defer` | Scope guard — defer |
| `try`/`catch` | Defer — unwinding is complex |
| Pod6 | Documentation — defer |
| Multiple dispatch | Not needed |
| Operator overloading | Not needed |
| `want` / context | Not needed |
| Inheritance | Classes as flat structs only — no `:isa` |
