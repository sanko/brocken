#!perl
# Brocken equivalent of gcc pthread_create/join test for both platforms.
# Verifies ELF structure matches GCC convention.
use v5.42;
use lib 'lib';
use Brocken;
use Brocken::Lindsay;
use Brocken::Katsuro::Platform;
use File::Temp qw[tempdir];
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $i32 = Brocken::Lindsay::IR::Type::i32();

sub make_prog {
    my $triple   = shift;
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $brocken  = Brocken->new( platform => $platform );
    my $worker   = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
    my $wb       = Brocken::Lindsay::IR::Builder->new();
    $wb->position_at_end( $worker->append_block('entry') );
    $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
    my $mb   = Brocken::Lindsay::IR::Builder->new();
    $mb->position_at_end( $main->append_block('entry') );
    my $iso = $mb->build_isolate_create( $worker, [], '%iso' );
    $mb->build_isolate_join($iso);
    $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
    my $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
    my $funcs   = $codegen->emit_functions( [ $main, $worker ] );
    my $linker  = Brocken::Jenny::Linker::ELF64->new();
    my $dir     = tempdir( CLEANUP => 1 );
    my $out     = "$dir/test_prog";
    $linker->write_executable( $out, $funcs, $platform );
    open my $fh, '<:raw', $out or die;
    my $bytes;
    read $fh, $bytes, -s $out;
    close $fh;
    return $bytes;
}

sub parse_notes {
    my ( $bytes, $offset, $size ) = @_;
    my $end = $offset + $size;
    my @notes;
    while ( $offset + 12 <= $end ) {
        my $namesz = unpack( 'V', substr( $bytes, $offset,     4 ) );
        my $descsz = unpack( 'V', substr( $bytes, $offset + 4, 4 ) );
        my $type   = unpack( 'V', substr( $bytes, $offset + 8, 4 ) );
        $offset += 12;
        my $name = substr( $bytes, $offset, $namesz );
        $name =~ s/\0.*$//;
        $offset += ( $namesz + 3 ) & ~3;
        my $desc = substr( $bytes, $offset, $descsz );
        $offset += ( $descsz + 3 ) & ~3;
        push @notes, { namesz => $namesz, descsz => $descsz, type => $type, name => $name, desc => $desc };
    }
    return @notes;
}
for my $triple (qw(x86_64-pc-dragonflybsd-elf x86_64-pc-freebsd-elf)) {
    my $bin = make_prog($triple);
    printf "\n### %s (%d bytes) ###\n", $triple, length($bin);

    # Parse ELF header
    my $ei_osabi = unpack( 'C', substr( $bin, 0x07, 1 ) );
    my $machine  = unpack( 'v', substr( $bin, 0x12, 2 ) );
    my $phoff    = unpack( 'Q', substr( $bin, 0x20, 8 ) );
    my $phnum    = unpack( 'v', substr( $bin, 0x38, 2 ) );
    printf "  OSABI: %d, Machine: 0x%04x, PHdr count: %d\n", $ei_osabi, $machine, $phnum;

    # Parse program headers
    my $phesz = 56;
    for my $i ( 0 .. $phnum - 1 ) {
        my $off = $phoff + $i * $phesz;
        my ( $p_type, $p_flags, $p_offset, $p_vaddr, $p_paddr, $p_filesz, $p_memsz, $p_align )
            = unpack( 'L< L< Q< Q< Q< Q< Q< Q<', substr( $bin, $off, 56 ) );
        my $typestr = do {
            $p_type == 0     ? 'NULL' :
                $p_type == 1 ? 'LOAD' :
                $p_type == 2 ? 'DYNAMIC' :
                $p_type == 3 ? 'INTERP' :
                $p_type == 4 ? 'NOTE' :
                $p_type == 6 ? 'PHDR' :
                $p_type == 7 ? 'TLS' :
                "type=$p_type";
        };
        my $flagstr = ( $p_flags & 4 ? 'R' : '' ) . ( $p_flags & 2 ? 'W' : '' ) . ( $p_flags & 1 ? 'X' : '' );
        printf "  %s %s offset=0x%x vaddr=0x%x filesz=%d memsz=%d align=%d\n", $typestr, $flagstr, $p_offset, $p_vaddr, $p_filesz, $p_memsz, $p_align;
    }

    # Parse notes
    for my $i ( 0 .. $phnum - 1 ) {
        my $off = $phoff + $i * $phesz;
        my ( $p_type, $p_offset, $p_filesz, ) = unpack( 'L< L< Q< Q< Q< Q< Q< Q<', substr( $bin, $off, 56 ) );
        next unless $p_type == 4;
        printf "  Notes at offset 0x%x, size %d:\n", $p_offset, $p_filesz;
        for my $n ( parse_notes( $bin, $p_offset, $p_filesz ) ) {
            printf "    namesz=%d descsz=%d type=0x%04x name='%s' desc=%s\n", $n->{namesz}, $n->{descsz}, $n->{type}, $n->{name},
                join( ' ', map { sprintf '%02x', ord $_ } split( //, $n->{desc} ) );
        }
    }
}
