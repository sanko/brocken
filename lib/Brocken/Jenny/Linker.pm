use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Jenny::Linker::Layout;
use Brocken::Katsuro::Platform;

class Brocken::Jenny::Linker {

=pod

=head1 NAME

Brocken::Jenny::Linker - Unified Binary Executable Generator

=head1 DESCRIPTION

The Linker class provides a platform-agnostic interface for taking machine code and data segments and packaging them
into a final executable or shared library.

It handles:

=over 4

=item * B<Layout Calculation>: Assigning file offsets and Virtual Addresses (RVAs).

=item * B<Symbol Resolution>: Mapping internal labels to RVAs.

=item * B<Debug Information>: Generating DWARF sections for source-level debugging.

=item * B<FFI Stubbing>: Generating Import Tables (GOT/PLT) for calling external functions.

=back

=cut

    field $_layout        : reader(layout);
    field $type           : param : reader = 'exe';
    field $debug_data     : reader = {};
    field $func_ranges    : reader = [];
    field $labels         : reader = {};
    field $exported_funcs : reader = [];
    field $preserved_regs : reader = [];
    field $frame_size     : reader = 0;
    field $timestamp      : reader = undef;
    #
    method set_preserved_regs($r) { $preserved_regs = $r; }
    method set_frame_size($s)     { $frame_size     = $s; }
    method set_timestamp($t)      { $timestamp      = $t; }

    # Default to the current time when not explicitly set. Pass 0 to
    # write a deterministic build (e.g. for reproducible-build tests).
    method effective_timestamp() { $timestamp // time() }
    method set_debug_data($d)    { $debug_data = $d; }
    method debug_section($name)  { return $self->debug_data->{$name} // ''; }
    method set_func_ranges($r)   { $func_ranges = $r; }
    method set_labels($l)        { $labels      = $l; }

    # shared lib
    method set_exported_funcs($f) { $exported_funcs = $f; }
    #
    method rva_for($name) {
        return $self->layout->get($name)->{rva};
    }
    method image_base() { return 0; }

    # Prepares the memory and file layout for the binary.
    # This must handle different alignment requirements:
    # - x86_64 ELF: 4KB (0x1000)
    # - ARM64 ELF: 64KB (0x10000) for compatibility with Android/modern kernels.
    # - Mach-O (Apple Silicon): 16KB (0x4000).
    # - PE (Windows): 512B (0x200) for files, 4KB (0x1000) for memory.
    method pre_layout( $text_size, $data_size, $platform, $debug = 0 ) {
        my $page_align
            = $platform->is_macos ? ( $platform->is_arm64 ? 0x4000 : 0x1000 ) :
            $platform->is_windows ? 0x200 :
            $platform->is_arm64 ?
            0x10000    # 64KB alignment for ARM64 ELF
            :
            0x1000;
        $_layout = Brocken::Jenny::Linker::Layout->new( file_align => $page_align, section_align => $page_align );
        $self->_setup_layout( $_layout, $text_size, $data_size, $platform, $debug );
        $_layout->calculate($page_align);
    }
    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 )           {...}
    method write_bin( $filename, $text, $data, $arch, $os, $type ) {...}
    method import_rva($name)                                       {...}
}
1;
