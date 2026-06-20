# Memory Management & The Self-Hosted Runtime

Brocken does not link against an external C runtime. The runtime (`libbrocken`) is written in a subset of Brocken itself (`core.brocken`). The Katsuro frontend silently parses this file and combines it with your code during compilation.

Because Brocken natively compiles this runtime, memory management is tightly integrated into the final binary.

## Isolates & Cooperative Fibers

Brocken's concurrency model dictates its memory model:
*   **Isolates (OS Threads):** Share-nothing execution contexts. Memory cannot be shared across isolates without explicit serialization.
*   **Fibers (Green Threads):** Cooperative, stackful coroutines.

**The Golden Rule:** Because heaps are entirely thread-local to an Isolate, Garbage Collection and Reference Counting require **zero atomic locks**, ensuring massive performance gains.

### Isolate Control Block
Accessible via a pinned register (e.g., `R14` on x64).

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

## Memory Management (RC Immix + Bacon & Rajan)

Brocken uses a hybrid memory management model to achieve C-like allocation speeds while preserving exact, deterministic `DESTROY` semantics. It does **not** use a standard tracing Garbage Collector or a Shadow Stack.

### 1. The Fat Scalar (`Any`) Layout
Dynamically typed variables use a 16-byte struct:

```text
Offset  Size    Purpose
0       2       Reference Count (max 65535, overflows pin the object)
2       1       GC Flags (Bit 0: Cycle Suspect, Bit 1: Buffered, Bit 2: Leaf)
3       1       Type Tag (0=Int, 1=String, 2=Array, 3=Class...)
4       4       Padding / Aux (e.g., String cached char length)
8       8       Payload (Raw 64-bit Int/Float, or Pointer to Heap Data)
```

### 2. Immediate Reference Counting
When a variable is assigned, the Lindsay middle-end injects an `incref` instruction. When a variable goes out of scope, a `decref` instruction is fired.
*   **Deterministic Destruction:** If `RC == 0`, the object's `DESTROY` block runs immediately, and its memory is reclaimed.

### 3. Bacon & Rajan Trial Deletion (Cycle Collection)
Standard RC leaks memory when objects form circular references. Brocken solves this using Trial Deletion:
*   If `RC > 0` after a decrement, the object *might* be part of an isolated cycle. The runtime pushes the pointer to the Isolate's **Suspect Buffer**.
*   Periodically, the runtime scans the Suspect Buffer to identify and delete true circular references.

### 4. RC Immix Allocation
To avoid the overhead of `malloc`, Brocken uses the **Immix** algorithm for allocating heap data (arrays, strings, objects).
*   The OS provides 32KB Blocks.
*   Blocks are divided into 256-byte Lines.
*   Allocation is a simple pointer bump (`cursor += size`).
*   When a block is full, the runtime finds a partially empty block or requests a new one.

## The Unsafe Subset (Self-Hosting)

To write the Immix Allocator and RC engine in Brocken, we must bypass the Fat Scalar overhead. The Katsuro frontend exposes Native Types and pseudo-namespaces.

```perl
# src/runtime/gc.brocken
package Brocken::Runtime::Immix {
    use feature 'brocken_native_types';

    sub allocate_raw( i64 $size ) : NativeReturn(ptr) {
        my ptr $cursor = $Brocken::Runtime::immix_cursor;
        my ptr $next   = Brocken::ptr_add($cursor, $size);

        if (Brocken::ptr_cmp_gt($next, $Brocken::Runtime::immix_limit)) {
            return gc_alloc_slow($size);
        }

        $Brocken::Runtime::immix_cursor = $next;
        return $cursor;
    }
}
```
Calls to the `Brocken::` namespace do not compile to function calls; they are lowered directly to raw machine instructions.
