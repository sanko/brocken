use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::Wasm;
use Test2::Tools::Brocken qw[temp_path answers validates];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Untyped `my` variables on the Wasm target.
#
# `my $x = 42;` is the most ordinary statement in the language, and Wasm could
# not emit it. An untyped variable is a boxed dynamic value, so all of these
# faults were in the `box`/`unbox` path and all of them had to clear before the
# module would even validate:
#
# 1. `Codegen/Wasm.pm` declared each local from the MIR function's `%ir_types`
#    table. `%heap_ptr` is created by `Lowerer/Wasm.pm` and never appears in
#    that table, so it was declared i32 while every use of it is i64, and the
#    validator rejected the module. The declared type now falls back to the
#    operand's own type when the table has no entry.
#
# 2. The box payload push built an instruction that was then never
#    `add_instruction`'d onto the block, so the payload came from whatever was
#    left on the stack.
#
# 3. The box payload store and the matching unbox load were hardcoded to
#    `i32.store`/`i32.load` while an untyped variable is i64 by default, so the
#    value was truncated to four bytes. This is the fault that made a *valid*
#    module return the wrong number rather than fail: `$x` read back 0.
#
# 4. The store width came from the box rather than from the value being stored,
#    so an f32 or f64 payload was written as an integer. Hence the float cases
#    below as well as the integer ones.
#
# With those fixed, a second fault appeared that no amount of lowering could
# have masked: the linker reserved one 64KB page of linear memory while the
# entry preamble tells `_init` it has 1MB. One boxed variable fit in the page
# that was really there; a second allocated past the end of linear memory and
# trapped, at an address that tracked the box's type tag because the allocator
# had been handed a range it should never have believed in. A native target gets
# away with the same mismatch because its mmap grows on demand.
# `Brocken::ICB::HEAP_SIZE` is now the single source of truth for that 1MB.
my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $brocken  = Brocken->new( platform => $platform );
my $null     = $host->is_windows ? 'NUL'                  : '/dev/null';
my $wasmtime = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime if $wasmtime;
my $node = $host->is_windows ? `where node 2>NUL` : `which node 2>/dev/null`;
chomp $node if $node;
my $runner = $wasmtime && -x $wasmtime ? 'wasmtime' : ( $node && -x $node ? 'node' : undef );

# The declared memory has to cover the heap the entry preamble promises _init,
# or the allocator will eventually hand out an address past the end of it.
sub memory_covers_heap ($name) {
    my $file = temp_path('wasm_box') . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $file, $brocken->codegen->emit_functions( $brocken->compile('return 42;')->functions ),
        $platform );
    my $bytes = do { open my $fh, '<:raw', $file or die $!; local $/; <$fh> };
    unlink $file if -e $file;

    # Walk to the memory section (id 5) and read the initial page count out of
    # its limits vector. A single page is the fault this guards: the entry
    # preamble tells `_init` it has Brocken::ICB::HEAP_SIZE.
    my $pages;
    my $pos = 8;
    while ( $pos < length $bytes ) {
        my $id = ord substr $bytes, $pos, 1;
        ( $pos, my $size ) = _uleb( $bytes, $pos + 1 );
        if ( $id == 5 ) {
            my $count = ord substr $bytes, $pos, 1;
            my $flags = ord substr $bytes, $pos + 1, 1;
            ( $pos, $pages ) = _uleb( $bytes, $pos + 2 );
            last;
        }
        $pos += $size;
    }
    ok( defined $pages, 'the module has a memory section' );
    cmp_ok( $pages * 65536, '>=', Brocken::ICB::HEAP_SIZE, "$name (${pages} page(s))" );
    return;
}

sub _uleb ( $bytes, $pos ) {
    my $result = 0;
    my $shift  = 0;
    while (1) {
        my $byte = ord substr $bytes, $pos++, 1;
        $result |= ( $byte & 0x7F ) << $shift;
        last unless $byte & 0x80;
        $shift += 7;
    }
    return ( $pos, $result );
}
SKIP: {
    skip 'Neither wasmtime nor node are installed', 1 unless $runner;
    subtest 'a single untyped variable' => sub {
        answers( 'return 42;',                             42, 'the simplest program runs' );
        answers( 'my $x = 42; return 42;',                 42, 'a boxed variable is never read' );
        answers( 'my $x = 42; return $x;',                 42, 'a boxed 64-bit value reads back whole' );
        answers( 'my $x = 42; my i64 $y = $x; return $y;', 42, 'a boxed value widens to i64' );
    };
    subtest 'two or more untyped variables allocate' => sub {

        # Each of these needs a second heap allocation. One fit inside the page
        # that was really reserved; the second did not.
        answers( 'my $a = 3; my $b = 4; return $a + $b;', 7,  'two untyped variables add' );
        answers( 'my $a = 3; my $b = 4; return $a;',      3,  'the first of two reads back' );
        answers( 'my $a = 3; my $b = 4; return $b;',      4,  'the second of two reads back' );
        answers( 'my $a = 3; my $b = 4; return 42;',      42, 'two untyped variables, neither read' );
    };
    subtest 'many untyped variables' => sub {
        for my $n ( 1 .. 6 ) {
            my $decls = join ' ',   map {"my \$v$_ = 1;"} 1 .. $n;
            my $sum   = join ' + ', map {"\$v$_"} 1 .. $n;
            answers( "$decls return $sum;", $n, "$n untyped variables sum to $n" );
        }
    };
    subtest 'untyped and typed variables mix' => sub {
        answers( 'my $a = 3; my i64 $b = 7; return $a + $b;', 10, 'untyped then typed' );
        answers( 'my i64 $a = 3; my $b = 1; return $a + $b;', 4,  'typed then untyped' );
    };

    # Assigning one box to another used to trap: the store increfs the box it is
    # about to replace and decrefs the old payload, and with the source and the
    # destination the same box, or with a chain of moves, the two orderings
    # disagreed about a block that was still live and the free list handed it
    # out again. These are the shapes TODO.md recorded as still trapping.
    subtest 'assignment between untyped variables' => sub {
        answers( 'my $a = 3; my $b = 4; $b = $b; return $a;',                               3, 'self-assignment leaves the other value' );
        answers( 'my $a = 1; $a = $a; $a = $a; return $a;',                                 1, 'repeated self-assignment' );
        answers( 'my $a = 3; my $b = 4; $b = $a; return $b;',                               3, 'one untyped variable assigned from another' );
        answers( 'my $x = 3; my $y = $x; return $y;',                                       3, 'initialising one box from another' );
        answers( 'my $a = 1; my $b = 2; my $c = 3; $c = $a; return $c;',                    1, 'assignment into a third box' );
        answers( 'my $a = 1; my $b = 2; my $c = 3; $a = $b; $b = $c; return $a + $b + $c;', 8, 'a chain of moves' );
        answers( 'my $x = 2.5; my $y = $x; return $y == 2.5 ? 1 : 0;',                      1, 'a float box copied between variables' );
    };
    subtest 'the payload is stored at the width of the value' => sub {
        answers( 'my $x = 42; return $x + 1;',             43, 'an i64 payload is 8 bytes wide' );
        answers( 'my $x = 0; my $y = 42; return $y - $x;', 42, 'subtraction through two boxes' );

        # A 64-bit value that does not fit in the low half, which is what a
        # 4-byte store would have truncated to zero.
        answers( 'my $x = 4294967296; return $x >> 32;', 1, 'a payload above 32 bits survives' );
    };

    # Returning a boxed value transfers ownership to the caller, so the box has to
    # outlive the callee's own locals. The exit path increfs the return value
    # before running the cleanup, but the incref was gated on a type kind of `any`
    # while the IR spells it `dynamic`, so it never ran: the exit decref dropped
    # the box to the free list and the caller read a slot that had been overwritten
    # with the list link. This was a frontend lifetime fault, not a Wasm one -- the
    # same programs returned 0 on native -- and it is why every returned list
    # element looked like a freed pointer even after the frame region was separated
    # from the arena.
    subtest 'a box returned from a function survives the callee' => sub {
        answers( 'sub mk() -> Any { my $u = 7; return $u; } my $a = mk(); return $a + 1;', 8, 'return a local, use it in the caller' );
        answers( 'sub mk() -> Any { my $u = 7; my $v = 9; return $u + $v; } my $a = mk(); return $a - 6;',
            10, 'the returned box holds a computed value' );
        answers( 'sub id(Any $v) -> Any { return $v; } my $x = 5; return id($x);', 5, 'a box passed through an Any parameter' );
        answers( 'sub mk() -> Any { my $u = 3; return $u; } my $a = mk(); my $b = mk(); return $a + $b;',
            6, 'two Any returns do not free each other' );
        answers( 'sub mk() -> ptr { my $u = 7; return ($u, 2); } my ($a, $b) = mk(); return $a + $b;',
            9, 'an untyped list element survives its maker' );
    };
    subtest 'the generated modules validate' => sub {
        validates( 'my $x = 42; return $x;',                'one untyped variable validates' );
        validates( 'my $a = 3; my $b = 4; return $a + $b;', 'two untyped variables validate' );
        validates( 'my $x = 4294967296; return $x >> 32;',  'a wide untyped value validates' );
    };
    subtest 'the declared memory covers the promised heap' => sub {
        memory_covers_heap('the memory section reserves the whole heap');
    };
}

# Deliberately NOT asserted here: `my $x = 1.5;`. An untyped variable holding a
# float is broken on every backend, not just this one -- the frontend boxes the
# f64 and then unboxes it to i64, so the float-ness is gone before any backend
# sees it, and x86-64 truncates to an integer where Wasm returns the raw bits.
# That is a frontend gap, recorded in TODO.md; asserting either behaviour here
# would only pin down which way it is currently wrong.
done_testing;
