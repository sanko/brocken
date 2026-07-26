# lib/Brocken/ICB.pm — Isolate Control Block layout constants.
# Field definitions and offsets computed by Brocken::Layout at compile time.
# This is the single source of truth for ICB offsets used by Perl code.
# The Brocken runtime (core.brocken) has its own accessor functions.
package Brocken::ICB;
use v5.42;
use strict;
use warnings;

BEGIN {
    require Brocken::Layout;
    my @FIELD_DEFS = (
        { name => 'heap_cursor',         type => 'ptr' },
        { name => 'current_fcb',         type => 'ptr' },
        { name => 'fiber_head',          type => 'ptr' },
        { name => 'immix_cursor',        type => 'ptr' },
        { name => 'immix_limit',         type => 'ptr' },
        { name => 'free_blocks',         type => 'ptr' },
        { name => 'free16_head',         type => 'ptr' },
        { name => 'suspect_buffer_head', type => 'ptr' },
        { name => 'fuel',                type => 'i64' },
        { name => 'err_code',            type => 'i64' },
        { name => 'current_block',       type => 'ptr' },
        { name => 'memory_limit',        type => 'i64' },
        { name => 'memory_used',         type => 'i64' },
        { name => 'capabilities',        type => 'i64' },
        { name => 'gate_table',          type => 'ptr' },
        { name => 'host_icb',            type => 'ptr' },
    );
    my $layout    = Brocken::Layout::layout_fields(@FIELD_DEFS);
    my %ERR_CODES = ( OK => 0, OOM => 1, NO_FUEL => 2, SECURITY => 3, DIV_ZERO => 4 );
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
our @EXPORT_OK = qw(
    HEAP_CURSOR CURRENT_FCB FIBER_HEAD IMMIX_CURSOR IMMIX_LIMIT
    FREE_BLOCKS FREE16_HEAD SUSPECT_BUFFER_HEAD FUEL ERR_CODE
    CURRENT_BLOCK MEMORY_LIMIT MEMORY_USED CAPABILITIES
    GATE_TABLE HOST_ICB
    SIZE ERR_OK ERR_OOM ERR_NO_FUEL ERR_SECURITY ERR_DIV_ZERO
);
1;
