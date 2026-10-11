use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
#
class Brocken::Jenny::Linker v0.0.1 {
    use Brocken::Jenny::Linker::Layout;
    use Brocken::Katsuro::Platform;

    # Sizes (in bytes) of the initial thread's stack written into the executable image. Only a PE optional header can
    # express them today (SizeOfStackReserve/SizeOfStackCommit); the other linkers accept the fields and ignore them,
    # since an ELF or Mach-O image carries no thread-stack size of its own. The reserve has to stay comfortably above
    # the 2 MiB runway the F17 stack guard seeds in _BROCKEN_ENTRY, which is why the default commit is sized to cover
    # the 1 MiB entry-stub heap on top of the frames. Brocken->new overrides both per instance.
    use constant DEFAULT_STACK_RESERVE => 0x400000;    # 4 MiB
    use constant DEFAULT_STACK_COMMIT  => 0x200000;    # 2 MiB
    field $stack_reserve : param : reader = DEFAULT_STACK_RESERVE;
    field $stack_commit  : param : reader = DEFAULT_STACK_COMMIT;
    field $_layout        : reader(layout);
    field $type           : param : reader = 'exe';
    field $debug_data     : reader = {};
    field $func_ranges    : reader = [];
    field $labels         : reader = {};
    field $exported_funcs : reader = [];
    field $preserved_regs : reader = [];
    field $frame_size     : reader = 0;
    field $timestamp      : reader = undef;
    field $debug_level    : reader = 0;
    field $rodata         : reader = {};
    #
    method set_preserved_regs($r) { $preserved_regs = $r; }
    method set_frame_size($s)     { $frame_size     = $s; }
    method set_rodata($r)         { $rodata         = $r; }
    method set_timestamp($t)      { $timestamp      = $t; }
    method effective_timestamp()  { $timestamp // time() }
    method set_debug_data($d)     { $debug_data = $d; }
    method debug_section($name)   { return $self->debug_data->{$name} // ''; }
    method set_debug_level($l)    { $debug_level    = $l; }
    method set_func_ranges($r)    { $func_ranges    = $r; }
    method set_labels($l)         { $labels         = $l; }
    method set_exported_funcs($f) { $exported_funcs = $f; }
    #
    method entry_stub_len($platform) { return 0; }

    method rva_for($name) {
        return 0x1000 if $name eq '.text' && !defined $_layout;
        return $self->layout->get($name)->{rva};
    }
    method image_base() { return 0; }

    method brk_sym_size() {
        return 0 unless scalar $self->func_ranges->@*;
        my $count = scalar $self->func_ranges->@*;
        my $size  = 4 + 12 * $count;
        for my $fn ( $self->func_ranges->@* ) {
            $size += length( $fn->{name} ) + 1;
        }
        return $size;
    }

    method build_brk_sym() {
        return '' unless scalar $self->func_ranges->@*;
        my $count       = scalar $self->func_ranges->@*;
        my $strtab_base = 4 + 12 * $count;
        my $payload     = pack( 'V', $count );
        my $str_pool    = "";
        for my $fn ( sort { $a->{start} <=> $b->{start} } $self->func_ranges->@* ) {
            my $start_rva = $self->rva_for('.text') + $fn->{start};
            my $end_rva   = $self->rva_for('.text') + ( $fn->{end} // $fn->{start} );
            $payload  .= pack( 'V3', $start_rva, $end_rva, $strtab_base + length($str_pool) );
            $str_pool .= $fn->{name} . "\0";
        }
        return $payload . $str_pool;
    }

    # Prepares the memory and file layout for the binary.
    # This must handle different alignment requirements: - x86_64 ELF: 4KB (0x1000) - ARM64 ELF: 4KB (0x1000) on Linux,
    # 64KB (0x10000) on others for Android. - Mach-O (Apple Silicon): 16KB (0x4000). - PE (Windows): 512B (0x200) for
    # files, 4KB (0x1000) for memory.
    method pre_layout( $text_size, $data_size, $platform, $debug = 0 ) {
        my $page_align
            = $platform->is_macos ? ( $platform->is_arm64 ? 0x4000 : 0x1000 ) :
            $platform->is_windows ? 0x200 :
            $platform->is_arm64 ?
            ( $platform->is_linux ? 0x1000 : 0x10000 )    # 4KB for Linux ARM64, 64KB for others
            :
            0x1000;
        $_layout = Brocken::Jenny::Linker::Layout->new( file_align => $page_align, section_align => $page_align );
        $self->_setup_layout( $_layout, $text_size, $data_size, $platform, $platform->os, $debug );
        $_layout->calculate($page_align);
    }
    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 )           {...}
    method write_bin( $filename, $text, $data, $arch, $os, $type ) {...}
    method import_rva($name)                                       {...}
};
#
1;
