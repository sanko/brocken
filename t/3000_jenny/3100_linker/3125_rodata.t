use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken;
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Read a PE section table and return {name, vaddr, vsize, raw_ptr, raw_size}
sub _pe_sections {
    my ($file) = @_;
    open my $fh, '<:raw', $file or die "Cannot open $file: $!";
    my $bytes = do { local $/; <$fh> };
    close $fh;
    my $e_lfanew     = unpack( 'V', substr( $bytes, 0x3C,           4 ) );
    my $num_sections = unpack( 'v', substr( $bytes, $e_lfanew + 6,  2 ) );
    my $opt_hdr_size = unpack( 'v', substr( $bytes, $e_lfanew + 20, 2 ) );
    my $sect_start   = $e_lfanew + 24 + $opt_hdr_size;
    my @sections;

    for my $i ( 0 .. $num_sections - 1 ) {
        my $off  = $sect_start + $i * 40;
        my $name = substr( $bytes, $off, 8 );
        $name =~ s/\0.*//;
        my ( $vsize, $vaddr, $raw_size, $raw_ptr ) = unpack( 'x8 V V V V', substr( $bytes, $off, 40 ) );
        push @sections, { name => $name, vaddr => $vaddr, vsize => $vsize, raw_ptr => $raw_ptr, raw_size => $raw_size };
    }
    return @sections;
}

# Read an ELF section table and return {name, addr, offset, size}
sub _elf_sections {
    my ($file) = @_;
    open my $fh, '<:raw', $file or die "Cannot open $file: $!";
    my $bytes = do { local $/; <$fh> };
    close $fh;
    my ( $ei_class, $ei_data, $shoff, $shentsize, $shnum, $shstrndx );
    if ( substr( $bytes, 0, 4 ) eq "\x7f" . 'ELF' ) {
        $ei_class = unpack( 'C', substr( $bytes, 4, 1 ) );
        $ei_data  = unpack( 'C', substr( $bytes, 5, 1 ) );
        my $le = $ei_data == 1;
        if ( $ei_class == 2 ) {    # 64-bit
            $shoff     = $le ? unpack( 'Q<', substr( $bytes, 0x28, 8 ) ) : unpack( 'Q>', substr( $bytes, 0x28, 8 ) );
            $shentsize = $le ? unpack( 'v',  substr( $bytes, 0x3A, 2 ) ) : unpack( 'n',  substr( $bytes, 0x3A, 2 ) );
            $shnum     = $le ? unpack( 'v',  substr( $bytes, 0x3C, 2 ) ) : unpack( 'n',  substr( $bytes, 0x3C, 2 ) );
            $shstrndx  = $le ? unpack( 'v',  substr( $bytes, 0x3E, 2 ) ) : unpack( 'n',  substr( $bytes, 0x3E, 2 ) );
        }
        else {                     # 32-bit
            $shoff     = $le ? unpack( 'V', substr( $bytes, 0x20, 4 ) ) : unpack( 'N', substr( $bytes, 0x20, 4 ) );
            $shentsize = $le ? unpack( 'v', substr( $bytes, 0x2E, 2 ) ) : unpack( 'n', substr( $bytes, 0x2E, 2 ) );
            $shnum     = $le ? unpack( 'v', substr( $bytes, 0x30, 2 ) ) : unpack( 'n', substr( $bytes, 0x30, 2 ) );
            $shstrndx  = $le ? unpack( 'v', substr( $bytes, 0x32, 2 ) ) : unpack( 'n', substr( $bytes, 0x32, 2 ) );
        }

        # Read section name string table
        my $shstr_off = $shoff + $shstrndx * $shentsize;
        my ( $shstr_addr, $shstr_offset, $shstr_size );
        if ( $ei_class == 2 ) {
            $shstr_offset = $le ? unpack( 'Q<', substr( $bytes, $shstr_off + 0x18, 8 ) ) : unpack( 'Q>', substr( $bytes, $shstr_off + 0x18, 8 ) );
            $shstr_size   = $le ? unpack( 'Q<', substr( $bytes, $shstr_off + 0x20, 8 ) ) : unpack( 'Q>', substr( $bytes, $shstr_off + 0x20, 8 ) );
        }
        else {
            $shstr_offset = $le ? unpack( 'V', substr( $bytes, $shstr_off + 0x10, 4 ) ) : unpack( 'N', substr( $bytes, $shstr_off + 0x10, 4 ) );
            $shstr_size   = $le ? unpack( 'V', substr( $bytes, $shstr_off + 0x14, 4 ) ) : unpack( 'N', substr( $bytes, $shstr_off + 0x14, 4 ) );
        }
        my $shstrtab = substr( $bytes, $shstr_offset, $shstr_size );
        my @sections;
        for my $i ( 0 .. $shnum - 1 ) {
            my $so = $shoff + $i * $shentsize;
            my ( $name_idx, $addr, $offset, $size );
            if ( $ei_class == 2 ) {
                $name_idx = unpack( 'V', substr( $bytes, $so + 0x00, 4 ) );
                $addr     = $le ? unpack( 'Q<', substr( $bytes, $so + 0x10, 8 ) ) : unpack( 'Q>', substr( $bytes, $so + 0x10, 8 ) );
                $offset   = $le ? unpack( 'Q<', substr( $bytes, $so + 0x18, 8 ) ) : unpack( 'Q>', substr( $bytes, $so + 0x18, 8 ) );
                $size     = $le ? unpack( 'Q<', substr( $bytes, $so + 0x20, 8 ) ) : unpack( 'Q>', substr( $bytes, $so + 0x20, 8 ) );
            }
            else {
                $name_idx = $le ? unpack( 'V', substr( $bytes, $so + 0x00, 4 ) ) : unpack( 'N', substr( $bytes, $so + 0x00, 4 ) );
                $addr     = $le ? unpack( 'V', substr( $bytes, $so + 0x0C, 4 ) ) : unpack( 'N', substr( $bytes, $so + 0x0C, 4 ) );
                $offset   = $le ? unpack( 'V', substr( $bytes, $so + 0x10, 4 ) ) : unpack( 'N', substr( $bytes, $so + 0x10, 4 ) );
                $size     = $le ? unpack( 'V', substr( $bytes, $so + 0x14, 4 ) ) : unpack( 'N', substr( $bytes, $so + 0x14, 4 ) );
            }
            my $name = substr( $shstrtab, $name_idx );
            $name =~ s/\0.*//;
            push @sections, { name => $name, addr => $addr, offset => $offset, size => $size } if $size > 0;
        }
        return @sections;
    }
    return ();
}
my $brocken  = Brocken->new();
my $platform = $brocken->platform;

# Simple function for test binary
sub build_test_func {
    my $module = Brocken::Lindsay::IR::Module->new( name => 'rodata_test' );
    my $func   = Brocken::Lindsay::IR::Function->new(
        name        => '_BROCKEN_ENTRY',
        return_type => Brocken::Lindsay::IR::Type::i32(),
        params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ) ],
    );
    $module->add_function($func);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    return $brocken->codegen->emit_function($func);
}
my $machine_bytes = build_test_func();

# Test 1: PE linker emits .rdata section when set_rodata is called
{
    my $output_file = temp_path('test_pe_rodata.exe');
    my $linker      = Brocken::Jenny::Linker::PE->new();
    $linker->set_labels( { E__BROCKEN_ENTRY => 0 } );
    $linker->set_rodata( { str_hello        => "Hello\x00", str_world => "World\x00" } );
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'PE with .rdata created';
    my @secs  = _pe_sections($output_file);
    my @rdata = grep { $_->{name} eq '.rdata' } @secs;
    ok scalar(@rdata) == 1, '.rdata section present in PE binary';

    if (@rdata) {
        open my $fh, '<:raw', $output_file or die;
        seek $fh, $rdata[0]->{raw_ptr}, 0;
        read( $fh, my $data, $rdata[0]->{raw_size} );
        close $fh;
        like $data, qr/Hello/, '.rdata contains "Hello"';
        like $data, qr/World/, '.rdata contains "World"';
    }
    unlink $output_file;
}

# Test 2: ELF64 linker emits .rodata section when set_rodata is called
SKIP: {
    skip 'ELF64 rodata test: Brocken::Jenny::Linker::ELF64 not available', 3 unless eval { require Brocken::Jenny::Linker::ELF64; 1 };
    my $output_file = temp_path('test_elf_rodata');
    my $linker      = Brocken::Jenny::Linker::ELF64->new();
    $linker->set_labels( { E__BROCKEN_ENTRY => 0 } );
    $linker->set_rodata( { str_hello        => "Hello\x00" } );
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'ELF with .rodata created';
    my @secs   = _elf_sections($output_file);
    my @rodata = grep { $_->{name} eq '.rodata' } @secs;
    ok scalar(@rodata) == 1, '.rodata section present in ELF binary';

    if (@rodata) {
        open my $fh, '<:raw', $output_file or die;
        seek $fh, $rodata[0]->{offset}, 0;
        read( $fh, my $data, $rodata[0]->{size} );
        close $fh;
        like $data, qr/Hello/, '.rodata contains "Hello"';
    }
    unlink $output_file;
}

# Test 3: MachO linker emits __const section when set_rodata is called
{
    my $output_file = temp_path('test_macho_rodata');
    my $linker      = Brocken::Jenny::Linker::MachO->new();
    $linker->set_labels( { E__BROCKEN_ENTRY => 0 } );
    $linker->set_rodata( { str_hello        => "Hello\x00" } );
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'MachO with __const created';

    # Parse MachO section headers to verify __const content
    my $macho_hdr_size = 32;
    open my $fh, '<:raw', $output_file or die "Cannot open $output_file: $!";
    my $bytes = do { local $/; <$fh> };
    close $fh;
    my ( $magic, $cputype, $cpusubtype, $filetype, $ncmds, $sizeofcmds, $flags ) = unpack( 'L<7', substr( $bytes, 0, 28 ) );
    is( $magic, 0xfeedfacf, 'MachO magic is MH_MAGIC_64' );
    my $offset      = $macho_hdr_size;
    my $const_found = 0;

    for my $cmd_idx ( 1 .. $ncmds ) {
        my ( $cmd, $cmdsize ) = unpack( 'L<2', substr( $bytes, $offset, 8 ) );
        last if $cmd != 0x19;    # LC_SEGMENT_64
        my $segname = substr( $bytes, $offset + 8, 16 );
        $segname =~ s/\0.*//;
        my ( $vmaddr, $vmsize, $fileoff, $filesize, $maxprot, $initprot, $nsects ) = unpack( 'Q<4 L<4', substr( $bytes, $offset + 24, 48 ) );
        my $sect_offset = $offset + 72;
        for my $sect_idx ( 1 .. $nsects ) {
            my $sectname = substr( $bytes, $sect_offset, 16 );
            $sectname =~ s/\0.*//;
            my $segname2 = substr( $bytes, $sect_offset + 16, 16 );
            $segname2 =~ s/\0.*//;
            if ( $sectname eq '__const' && $segname2 eq '__TEXT' ) {
                $const_found = 1;
                my ( $sect_addr, $sect_size, $sect_off ) = unpack( 'Q<2 L<', substr( $bytes, $sect_offset + 32, 20 ) );
                my $sect_data = substr( $bytes, $sect_off, $sect_size );
                like( $sect_data, qr/Hello/, '__const contains "Hello"' );
            }
            $sect_offset += 80;
        }
        $offset += $cmdsize;
    }
    ok $const_found, '__const section present in MachO binary';
    unlink $output_file;
}
done_testing;
