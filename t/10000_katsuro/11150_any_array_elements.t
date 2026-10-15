use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Test2::Tools::Brocken qw[answers];

# A local array whose element type is managed (`Any`) owns its elements. Such an array is heap-forced so it is
# RC-tracked; its body is zeroed at allocation so the owning store's load-old-then-decref sees a null box first; a store
# into an element takes a reference and releases what it displaces; and scope exit releases every element before the
# block. Before this, an element store was a plain store, so a loop that overwrote an element leaked one box per pass.

subtest 'overwriting an element releases the box it displaces' => sub {

    # One leaked 16-byte box per iteration walks the Immix bump cursor past a 4 KiB guard within 1000 iterations. A
    # cursor that stays inside the guard means the displaced box was reclaimed rather than stranded.
    answers(
        'my ptr $hb = Brocken::heap_base(); my [Any; 1] @a;'
            . ' my ptr $before = Brocken::Runtime::immix_cursor($hb);'
            . ' my i64 $i = 0;'
            . ' while ($i < 1000) { @a[0] = $i; $i = $i + 1; }'
            . ' my ptr $after = Brocken::Runtime::immix_cursor($hb);'
            . ' if (Brocken::ptr_cmp_gt($after, Brocken::ptr_add($before, 4096))) { return 1; }'
            . ' return 0;',
        0, 'a loop that overwrites one Any element stays bounded'
    );
};

subtest 'elements are addressed at the element size, not the value width' => sub {

    # `dynamic` carries a 128-bit width for ABI reasons, but a dynamic value in memory is one 8-byte box pointer. The
    # element GEP scaled by `bits / 8`, so slot 1 began 16 bytes in while the allocator and the zeroing loop used 8:
    # slot 1 aliased the first box and later slots ran off the body.
    answers(
        'my [Any; 4] @a; @a[0] = 10; @a[1] = 20; @a[2] = 30; @a[3] = 40;'
            . ' return @a[0] + @a[1] + @a[2] + @a[3];',
        100, 'four distinct Any slots keep four distinct values'
    );
    answers(
        'my i64 $n = 3; my [Any; $n] @a; @a[0] = 5; @a[2] = 7; return @a[0] * @a[2];',
        35, 'a runtime-sized Any array addresses its slots correctly'
    );
};

subtest 'an unwritten element reads as undefined' => sub {

    # The body is zeroed so an absent element reads as undef rather than a stale slab pointer.
    answers( 'my [Any; 2] @a; return defined(@a[1]) ? 1 : 0;', 0, 'a never-written Any element reads as undefined' );
};

subtest 'an owned store keeps the new value' => sub {
    answers( 'my [Any; 1] @a; @a[0] = 1; @a[0] = 2; return @a[0];', 2, 'overwriting an Any element keeps the new value' );
    answers( 'my [Any; 1] @a; @a[0] = 0; @a[0] ||= 3; return @a[0];', 3, '`||=` replaces a false Any element' );
    answers( 'my [Any; 1] @a; @a[0] //= 5; @a[0] //= 9; return @a[0];', 5, '`//=` on an absent element stores once' );
};

subtest 'an element holds its own reference to a stored value' => sub {

    # The element store takes a reference, so the box survives the source local's release at scope exit.
    answers( 'my [Any; 1] @a; { my Any $x = 20; @a[0] = $x; } return @a[0];', 20,
        'a box stored into an element outlives the local it came from' );
};

subtest 'a computed index writes and reads the right slot' => sub {
    answers(
        'my [Any; 4] @a; my i64 $i = 0;'
            . ' while ($i < 4) { @a[$i] = $i + 1; $i = $i + 1; }'
            . ' return @a[0] + @a[1] + @a[2] + @a[3];',
        10, 'slots written through a computed index read back'
    );
};

done_testing;
