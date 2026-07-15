package Brocken::Layout;
use v5.42;
use strict;
use warnings;

# System V AMD64 ABI alignment rules.
# All targets in Brocken are 64-bit; ptr = 8 bytes.
my %ALIGNMENT = (
    i1   => 1,
    i8   => 1,
    i16  => 2,
    i32  => 4,
    i64  => 8,
    i128 => 16,
    u8   => 1,
    u16  => 2,
    u32  => 4,
    u64  => 8,
    u128 => 16,
    f32  => 4,
    f64  => 8,
    ptr  => 8,
);
my %SIZE = (
    i1   => 1,
    i8   => 1,
    i16  => 2,
    i32  => 4,
    i64  => 8,
    i128 => 16,
    u8   => 1,
    u16  => 2,
    u32  => 4,
    u64  => 8,
    u128 => 16,
    f32  => 4,
    f64  => 8,
    ptr  => 8,
);

sub align ( $offset, $alignment ) {
    return $offset if $alignment <= 1;
    my $mod = $offset % $alignment;
    return $mod == 0 ? $offset : $offset + $alignment - $mod;
}

sub type_alignment ($type) {
    return $ALIGNMENT{$type} // die "Layout: unknown type '$type'";
}

sub type_size ($type) {
    return $SIZE{$type} // die "Layout: unknown type '$type'";
}

# layout_fields(@fields) -> { fields => [...], size => N, alignment => N }
#
# Each element of @fields is a hashref with at least:
#   name   => 'field_name'
#   type   => 'i64' | 'ptr' | ...
#
# Optional keys preserved on output:
#   desc   => 'description'
#   id     => 'identifier' (e.g. ERR_OK)
#   value  => 0           (literal value for err_codes)
#
# Returns a layout hashref with:
#   fields    => [ { name, type, offset, size, alignment, ... } ]
#   size      => total size in bytes (tail-padded to max alignment)
#   alignment => max field alignment
sub layout_fields (@fields) {
    my $offset    = 0;
    my $max_align = 1;
    my @result;
    for my $f (@fields) {
        my $name  = $f->{name}      // die "Layout: field has no name";
        my $type  = $f->{type}      // die "Layout: field '$name' has no type";
        my $size  = $f->{size}      // type_size($type);
        my $align = $f->{alignment} // type_alignment($type);
        $offset = align( $offset, $align );
        my %out = ( name => $name, type => $type, offset => $offset, size => $size, alignment => $align, );

        # Preserve extra keys
        $out{desc}  = $f->{desc}  if exists $f->{desc};
        $out{id}    = $f->{id}    if exists $f->{id};
        $out{value} = $f->{value} if exists $f->{value};
        push @result, \%out;
        $offset += $size;
        $max_align = $align if $align > $max_align;
    }

    # Tail padding: round total size up to struct alignment
    $offset = align( $offset, $max_align );
    return { fields => \@result, size => $offset, alignment => $max_align, };
}
1;
