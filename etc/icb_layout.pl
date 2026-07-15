# etc/icb_layout.pl - Single source of truth for Isolate Control Block layout.
# Run bin/gen_icb.pl after modifying this file to regenerate:
#   - lib/Brocken/ICB.pm          (Perl constants module)
#   - src/runtime/core.brocken    (ICB header comment + _init function)
#
# All offsets are in bytes from heap_base.
# Types: ptr = 8-byte pointer, i64 = 8-byte integer.
# First Immix block starts at heap_base + size.
return {
    fields => [
        { name => 'heap_cursor',         offset => 0,   type => 'ptr', desc => 'legacy simple-bump pointer, unused after Immix full deployment' },
        { name => 'current_fcb',         offset => 8,   type => 'ptr', desc => 'active Fiber Control Block, 0 = no fiber' },
        { name => 'fiber_head',          offset => 16,  type => 'ptr', desc => 'head of fiber linked list' },
        { name => 'immix_cursor',        offset => 24,  type => 'ptr', desc => 'current bump-allocation pointer within current line' },
        { name => 'immix_limit',         offset => 32,  type => 'ptr', desc => 'end of current Immix line/block' },
        { name => 'free_blocks',         offset => 40,  type => 'ptr', desc => 'free 32KB block list' },
        { name => 'free16_head',         offset => 48,  type => 'ptr', desc => 'segregated free list for 16-byte reclaimed objects' },
        { name => 'suspect_buffer_head', offset => 56,  type => 'ptr', desc => 'GC suspect buffer linked list (via free16 nodes)' },
        { name => 'fuel',                offset => 64,  type => 'i64', desc => 'remaining instruction budget, set by compiler' },
        { name => 'err_code',            offset => 72,  type => 'i64', desc => 'termination reason code' },
        { name => 'current_block',       offset => 80,  type => 'ptr', desc => 'pointer to active Immix block' },
        { name => 'memory_limit',        offset => 88,  type => 'i64', desc => 'max heap bytes for this isolate, 0 = unlimited' },
        { name => 'memory_used',         offset => 96,  type => 'i64', desc => 'cumulative bytes allocated, enforced by bump_alloc' },
        { name => 'capabilities',        offset => 104, type => 'i64', desc => 'bitmask of allowed operations, checked before syscall/libc' },
    ],
    size      => 112,                                                   # first Immix block starts here (must be 16-byte aligned)
    err_codes => { OK => 0, OOM => 1, NO_FUEL => 2, SECURITY => 3, },
};
