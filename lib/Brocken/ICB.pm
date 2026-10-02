# lib/Brocken/ICB.pm — Isolate Control Block layout constants.
# Field definitions and offsets computed by Brocken::Layout at compile time.
# This is the single source of truth for ICB offsets used by Perl code.
# The Brocken runtime (core.brocken) has its own accessor functions.
package Brocken::ICB {
    use v5.42;

    BEGIN {
        require Brocken::Layout;
        my @FIELD_DEFS = (
            { name => 'heap_cursor',             type => 'ptr' },
            { name => 'current_fcb',             type => 'ptr' },
            { name => 'fiber_head',              type => 'ptr' },
            { name => 'immix_cursor',            type => 'ptr' },
            { name => 'immix_limit',             type => 'ptr' },
            { name => 'free_blocks',             type => 'ptr' },
            { name => 'free16_head',             type => 'ptr' },
            { name => 'suspect_buffer_head',     type => 'ptr' },
            { name => 'fuel',                    type => 'i64' },
            { name => 'err_code',                type => 'i64' },
            { name => 'current_block',           type => 'ptr' },
            { name => 'memory_limit',            type => 'i64' },
            { name => 'memory_used',             type => 'i64' },
            { name => 'capabilities',            type => 'i64' },
            { name => 'gate_table',              type => 'ptr' },
            { name => 'host_icb',                type => 'ptr' },
            { name => 'exception_handler_stack', type => 'ptr' },
            { name => 'thrown_value',            type => 'i64' }
        );
        my $layout    = Brocken::Layout::layout_fields(@FIELD_DEFS);
        my %ERR_CODES = ( OK => 0, OOM => 1, NO_FUEL => 2, SECURITY => 3, DIV_ZERO => 4, THROW => 5 );
        my @lines;
        for my $f ( $layout->{fields}->@* ) {
            push @lines, sprintf 'sub Brocken::ICB::%s () { %d }', uc $f->{name}, $f->{offset};
        }
        push @lines, sprintf 'sub Brocken::ICB::SIZE () { %d }', $layout->{size};
        for my $k ( sort keys %ERR_CODES ) {
            push @lines, sprintf 'sub Brocken::ICB::ERR_%s () { %d }', $k, $ERR_CODES{$k};
        }
        eval join "\n", @lines;
        die "ICB constant generation failed: $@" if $@;
    }
    use Exporter 'import';
    our @EXPORT_OK = qw[
        HEAP_CURSOR CURRENT_FCB FIBER_HEAD IMMIX_CURSOR IMMIX_LIMIT
        FREE_BLOCKS FREE16_HEAD SUSPECT_BUFFER_HEAD FUEL ERR_CODE
        CURRENT_BLOCK MEMORY_LIMIT MEMORY_USED CAPABILITIES
        GATE_TABLE HOST_ICB EXCEPTION_HANDLER_STACK THROWN_VALUE
        SIZE ERR_OK ERR_OOM ERR_NO_FUEL ERR_SECURITY ERR_DIV_ZERO ERR_THROW
        HEAP_SIZE
    ];

    # The heap the runtime is told it owns, in bytes. The entry preamble passes
    # this to Brocken::Runtime::_init, so any target whose memory has to be
    # reserved up front -- a Wasm initial memory section, unlike a native mmap
    # that grows on demand -- has to cover it. Wasm reserved one 64KB page while
    # asking for 1MB here, so the arena bookkeeping the runtime keeps ran past
    # the end of linear memory and a second boxed variable trapped.
    use constant HEAP_SIZE => 0x100000;
};
#
1;
