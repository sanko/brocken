use v5.42;
use feature qw[class];
no warnings qw[experimental::class];

class Brocken::Jenny::Linker::Layout {

=pod

=head1 NAME

Brocken::Jenny::Linker::Layout - Binary Section Alignment and Placement

=head1 DESCRIPTION

This class calculates the physical file offsets and relative virtual addresses (RVAs) for binary sections.

=cut

    field $file_align    : param : reader = 0x200;
    field $section_align : param : reader = 0x1000;
    field @sections;
    field $header_size : reader = 0;

    method add_section( $name, $size, $flags ) {
        push @sections, { name => $name, size => ( $size || 1 ), flags => $flags, rva => 0, off => 0 };
    }

    # Computes the alignment-corrected offsets and RVAs.
    # Ensures off % section_align == rva % section_align so any LOAD
    # segment boundary maintains p_offset == p_vaddr (mod p_align).
    method calculate($min_hdr) {
        $header_size = ( $min_hdr + $section_align - 1 ) & ~( $section_align - 1 );
        my $curr_off = $header_size;
        my $curr_rva = $header_size;
        for my $s (@sections) {
            $s->{off} = $curr_off;
            $s->{rva} = $curr_rva;
            $curr_off += ( $s->{size} + $section_align - 1 ) & ~( $section_align - 1 );
            $curr_rva += ( $s->{size} + $section_align - 1 ) & ~( $section_align - 1 );
        }
        return $curr_rva;
    }

    method get($n) {
        for (@sections) { return $_ if $_->{name} eq $n }

        #~ warn "Layout Error: Section $n not found";
    }
    method sections() {@sections}
}
1;
