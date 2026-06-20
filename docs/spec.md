# The Brocken Language Specification

## 0. About
This is version 0.01 of the Brocken spec. I'm still sorting it out.
## 1. Philosophy & Overview
Brocken is a statically/dynamically typed, AOT compiled language. It utilizes strict invariant sigils, built-in cooperative multitasking (Fibers), a fast Mark-Region GC (RC Immix), and modern Object-Oriented features.

## 2. Lexical Structure & Core Types

### 2.1 Variables & Invariant Sigils
*   `$` - **Scalar/Object**: A single value, reference, or object.
*   `@` - **Array/List**: Indexed as `@items[0]`.
*   `%` - **Hash/Dictionary**: Accessed as `%map{"key"}`.

### 2.2 Built-in Types (Gradual Typing)
If a type is omitted, it defaults to `Any` (a 16-byte Fat Scalar).
*   `Int`: 64-bit signed integer.
*   `String`: Immutable, UTF-8 encoded text.
*   `Bool`: `true` (1) and `false` (0).
*   `Array` / `Hash`: Collections.
*   `Class`: Object blueprint.

### 2.3 Native Types (The "Unsafe" Subset)
To allow Brocken's runtime and Garbage Collector to be written in Brocken itself, the compiler exposes raw, unboxed machine types. These types bypass the "Fat Scalar" tagging, carry zero runtime overhead, and are strictly ignored by the Reference Counting engine.

*   `i8`, `i16`, `i32`, `i64`: Raw machine integers.
*   `f32`, `f64`: Raw floating-point numbers.
*   `ptr`: A raw memory address.

**The `Brocken::` Pseudo-Namespace**
Instead of writing inline assembly, Brocken exposes raw IR instructions via the `Brocken::` pseudo-namespace. The parser recognizes these and translates them directly into single Lindsay IR instructions.

```perl
use feature 'brocken_native_types';
my ptr $heap_cursor;
my i64 $size = 32;
my ptr $next = Brocken::ptr_add($heap_cursor, $size);
```

## 3. Variable Scoping & Declarations
*   `my`, `our`, `local`, `state`, `const`, `type`.

## 4. Operators
*   **Numeric:** `==`, `!=`, `<`, `>`, `<=`, `>=`, `<=>`
*   **String:** `eq`, `ne`, `lt`, `gt`, `le`, `ge`, `cmp`
*   **Logical:** `&&`, `||`, `!`, `//` (Defined-OR)
*   **Bitwise:** `&`, `|`, `^`, `~`, `<<`, `>>`

## 5. Control Flow
*   `if` / `elsif` / `else` / `unless`
*   `given` / `when` / `default` (Strict pattern matching)
*   `while` / `until` / `for`
*   `next` / `last` / `redo`

## 6. Fibers & Isolates
*   `isolate`: Spawns a fully isolated execution context (OS thread). Memory cannot be shared between isolates without explicit serialization.
*   `fiber`: Spawns a lightweight, green thread with its own independent stack.
*   `yield`: Pauses the execution of the current fiber.
*   `transfer($fiber, expr)`: Resumes a fiber.

## 7. Exceptions & Cleanup
*   `try` / `catch` / `finally`
*   `throw`
*   `defer`: Pushes a block of code onto a LIFO stack executed when the lexical scope exits.

## 8. Object-Oriented Programming
*   `class` / `role` / `method` / `has` (field).
*   Lifecycle Hooks: `new`, `ADJUST`, `DESTROY` (Deterministic due to Immediate RC).

## 9. Strings (UTF-8 Everywhere)
Brocken strings are strictly UTF-8 encoded byte payloads.
*   Operations like `length($str)` (character count) and `substr($str, 50, 1)` are **O(N)** operations.
*   For **O(1)** byte-level access, use the `bytes` operator or the `Buffer` type.

## 10. System & I/O (Layered VTable PerlIO)
I/O in Brocken is layered. A filehandle is a pointer to a struct of Native function pointers (a VTable).
When you execute `open(my $fh, "<:utf8", "data.txt")`, the runtime instantiates a `:unix` layer and pushes a `:utf8` layer on top of it. This allows entirely custom, self-hosted I/O layers (like `:gzip` or `:mmap`) to be written in Brocken.
