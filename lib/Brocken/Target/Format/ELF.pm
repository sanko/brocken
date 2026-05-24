use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
#
class Brocken::Target::Format::ELF : isa(Brocken::Target::Format) {

    method _detect_elf_info ( $ref = undef ) {
        my @candidates = $ref ? ($ref) : ( '/bin/sh', '/sbin/init', '/usr/bin/env', '/boot/system/bin/sh', '/boot/system/bin/env' );
        for my $candidate (@candidates) {
            next if !-e $candidate || !-r _;
            open my $fh, '<:raw', $candidate or next;
            my $bytes = read( $fh, my $ehdr, 64 );
            close $fh;
            next if $bytes != 64;
            next if substr( $ehdr, 0, 4 ) ne "\x7fELF";
            my $osabi    = ord( substr( $ehdr, 7, 1 ) );
            my $ei_class = ord( substr( $ehdr, 4, 1 ) );
            next if $ei_class != 1 && $ei_class != 2;
            my ( $e_phoff, $e_phentsize, $e_phnum );

            if ( $ei_class == 2 ) {
                $e_phoff     = unpack( 'Q', substr( $ehdr, 32, 8 ) );
                $e_phentsize = unpack( 'S', substr( $ehdr, 54, 2 ) );
                $e_phnum     = unpack( 'S', substr( $ehdr, 56, 2 ) );
            }
            else {
                $e_phoff     = unpack( 'L', substr( $ehdr, 28, 4 ) );
                $e_phentsize = unpack( 'S', substr( $ehdr, 42, 2 ) );
                $e_phnum     = unpack( 'S', substr( $ehdr, 44, 2 ) );
            }
            next if !$e_phnum || !$e_phentsize;
            open my $fh2, '<:raw', $candidate or next;
            seek( $fh2, $e_phoff, 0 );
            my $ph_bytes = $e_phentsize * $e_phnum;
            my $read_ok  = read( $fh2, my $phdrs, $ph_bytes );
            close $fh2;
            next if !$read_ok;
            my ( $note_data, $has_pintable ) = ( '', 0 );

            for my $i ( 0 .. $e_phnum - 1 ) {
                my $phdr   = substr( $phdrs, $i * $e_phentsize, $e_phentsize );
                my $p_type = unpack( 'L', substr( $phdr, 0, 4 ) );
                if ( $p_type == 4 && !$note_data ) {
                    my ( $p_offset, $p_filesz );
                    if ( $ei_class == 2 ) {
                        $p_offset = unpack( 'Q', substr( $phdr, 8,  8 ) );
                        $p_filesz = unpack( 'Q', substr( $phdr, 32, 8 ) );
                    }
                    else {
                        $p_offset = unpack( 'L', substr( $phdr, 4,  4 ) );
                        $p_filesz = unpack( 'L', substr( $phdr, 16, 4 ) );
                    }
                    open my $fh3, '<:raw', $candidate or next;
                    seek( $fh3, $p_offset, 0 );
                    read( $fh3, $note_data, $p_filesz );
                    close $fh3;
                }
                elsif ( $p_type == 0x65a3dbe9 && !$has_pintable ) {
                    $has_pintable = 1;
                }
            }
            return ( $osabi, $note_data, $has_pintable );
        }
        return ( 0, '', 0 );
    }

    method write_bin ( $filename, $text, $data, $arch, $os = 'linux' ) {
        my $base     = 0x400000;
        my $text_off = 0x1000;
        my $data_off = 0x2000;
        my $machine  = ( $arch eq 'arm64' ) ? 183 : ( $arch eq 'riscv64' ) ? 243 : 62;
        my ( $osabi, $note_data, $has_pintable ) = $self->_detect_elf_info();
        my $align_f       = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded   = $text . ( "\0" x ( $align_f->( length($text), 0x1000 ) - length($text) ) );
        my $data_padded   = $data . ( "\0" x ( $align_f->( length($data), 0x1000 ) - length($data) ) );
        my $pintable_data = '';

        if ($has_pintable) {
            my $pos = 0;
            if ( $arch eq 'x64' ) {
                while ( ( my $idx = index( $text, "\x0F\x05", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_off + $idx;
                    $pintable_data .= pack( 'LL', $vaddr, 1 );
                    $pintable_data .= pack( 'LL', $vaddr, 4 );
                    $pos = $idx + 2;
                }
            }
            else {
                while ( ( my $idx = index( $text, "\x01\x00\x00\xd4", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_off + $idx;
                    $pintable_data .= pack( 'LL', $vaddr, 1 );
                    $pintable_data .= pack( 'LL', $vaddr, 4 );
                    $pos = $idx + 4;
                }
            }
        }
        my $num_ph  = 3 + ( $note_data ? 1 : 0 ) + ( $pintable_data ? 1 : 0 );
        my $elf_hdr = pack(
            'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
            "\x7fELF", 2, 1, 1,  $osabi, 0,       2, $machine, 1, $base + $text_off,
            64,        0, 0, 64, 56,     $num_ph, 0, 0,        0, 0
        );
        my $ph_hdrs = pack( 'LL Q Q Q Q Q Q', 1, 4, 0, $base, $base, $text_off, $text_off, 0x1000 );
        my $ph_text
            = pack( 'LL Q Q Q Q Q Q', 1, 5, $text_off, $base + $text_off, $base + $text_off, length($text_padded), length($text_padded), 0x1000 );
        my $ph_data
            = pack( 'LL Q Q Q Q Q Q', 1, 6, $data_off, $base + $data_off, $base + $data_off, length($data_padded), length($data_padded), 0x1000 );
        my $ph_note     = '';
        my $ph_syscalls = '';
        my $extra_off   = 64 + ( $num_ph * 56 );

        if ($note_data) {
            $ph_note = pack( 'LL Q Q Q Q Q Q', 4, 4, $extra_off, $base + $extra_off, $base + $extra_off, length($note_data), length($note_data), 4 );
            $extra_off += length($note_data);
        }
        if ($pintable_data) {
            $ph_syscalls = pack( 'LL Q Q Q Q Q Q',
                0x65a3dbe9, 4, $extra_off,
                $base + $extra_off,
                $base + $extra_off,
                length($pintable_data), length($pintable_data), 4 );
            $extra_off += length($pintable_data);
        }
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        my $header_block = $elf_hdr . $ph_hdrs . $ph_text . $ph_data . $ph_note . $ph_syscalls . $note_data . $pintable_data;
        print $fh $header_block;
        print $fh ( "\0" x ( $text_off - length($header_block) ) );
        print $fh $text_padded, $data_padded;
        close $fh;
        chmod 0755, $filename;
        return $filename;
    }

    method write_lib ( $filename, $text, $data, $arch, $os, $exports ) {
        my $base        = 0x400000;
        my $text_off    = 0x1000;
        my $dyn_off     = 0x3000;
        my $align_f     = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
        my $text_padded = $text . ( "\0" x ( $align_f->( length($text), 0x1000 ) - length($text) ) );
        my $data_padded = $data . ( "\0" x ( $align_f->( length($data), 0x1000 ) - length($data) ) );
        my $machine     = ( $arch eq 'arm64' ) ? 183 : ( $arch eq 'riscv64' ) ? 243 : 62;
        my ($osabi)     = $self->_detect_elf_info();
        my $num_exports = scalar keys %$exports;
        my $dynsym_size = 24 * ( $num_exports + 1 );
        my $dynstr      = "\0";
        my %dynstr_offs;

        for my $name ( sort keys %$exports ) {
            $dynstr_offs{$name} = length($dynstr);
            $dynstr .= $name . "\0";
        }
        my $dynsym = "\0" x 24;
        for my $name ( sort keys %$exports ) {
            $dynsym .= pack( 'L C C S Q Q', $dynstr_offs{$name}, 0x12, 0, 12, $base + $text_off + $exports->{$name}, 0 );
        }
        my $dynsec_off  = length($text_padded) + length($data_padded);
        my $dynsec_size = $dynsym_size + length($dynstr);
        my $dynsym_off  = $dynsec_off;
        my $dynstr_off  = $dynsec_off + $dynsym_size;
        my $elf_hdr     = pack(
            'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
            "\x7fELF", 2, 1, 1,  $osabi, 0, 3, $machine, 1, $base + $text_off,
            64,        0, 0, 64, 56,     3, 0, 0,        0
        );
        my $ph_text = pack( 'LL Q Q Q Q Q Q', 1, 5, 0, $base, $base, $text_off + length($text_padded), $text_off + length($text_padded), 0x1000 );
        my $ph_data = pack( 'LL Q Q Q Q Q Q',
            1, 6,
            $dyn_off - 0x1000,
            $base + $dyn_off - 0x1000,
            $base + $dyn_off - 0x1000,
            length($data_padded), length($data_padded), 0x1000 );
        my $ph_dyn = pack( 'LL Q Q Q Q Q Q', 6, 1, $dynsec_off, $base + $dynsec_off, $base + $dynsec_off, $dynsec_size, $dynsec_size, 0x1000 );
        my $sh_off = 64 + 3 * 56;
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        print $fh $elf_hdr, $ph_text, $ph_data, $ph_dyn;
        print $fh ( "\0" x ( $text_off - 64 - 3 * 56 ) );
        print $fh $text_padded, $data_padded;
        print $fh $dynsym;
        print $fh $dynstr;
        my $shdr_off = tell($fh);
        print $fh ( "\0" x 64 );
        print $fh pack( 'LLQQQQLLQQ', 0,  0, 0, 0,                         0,                 0,                    0, 0, 0,  0 );
        print $fh pack( 'LLQQQQLLQQ', 11, 1, 6, $base + 0x1000,            0x1000,            length($text),        0, 0, 16, 0 );
        print $fh pack( 'LLQQQQLLQQ', 14, 1, 6, $base + $dyn_off - 0x1000, $dyn_off - 0x1000, length($data_padded), 0, 0, 32, 0 );
        print $fh pack( 'LLQQQQLLQQ', 0,  0, 0, 0,                         0,                 0,                    0, 0, 0,  0 );
        seek( $fh, 40, 0 );
        print $fh pack( 'Q', $sh_off );
        seek( $fh, 60, 0 );
        print $fh pack( 'S', 4 );
        seek( $fh, 62, 0 );
        print $fh pack( 'S', 0 );
        close $fh;
        chmod 0755, $filename;
        return $filename;
    }
}
1;
