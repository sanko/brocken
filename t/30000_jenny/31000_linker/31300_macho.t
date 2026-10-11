use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Mach-O executable
{
    my $brocken   = Brocken->new();
    my $platform  = $brocken->platform;
    my $module    = Brocken::Lindsay::IR::Module->new( name => 'standalone_macho' );
    my $func_main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_main);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_main->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen       = $brocken->codegen;
    my $machine_bytes = $codegen->emit_function($func_main);
    my $output_file   = $brocken->tmpdir . '/test_prog';
    my $linker        = Brocken::Jenny::Linker::MachO->new();
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'Mach-O executable created successfully';
SKIP: {
        skip 'Mach-O binary execution test requires macOS (x64 or ARM64)', 1 unless $platform->is_macos;
        system($output_file);
        my $exit_code = $? >> 8;
        is $exit_code, 42, 'Standalone Mach-O binary executed natively and returned the correct exit code!';
    }
    unlink $output_file;
}

# Mach-O shared library
{
    my $brocken  = Brocken->new();
    my $platform = $brocken->platform;
    my $module   = Brocken::Lindsay::IR::Module->new( name => 'shared_macho' );
    my $func_ext = Brocken::Lindsay::IR::Function->new( name => 'my_func', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
    $module->add_function($func_ext);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func_ext->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
    my $codegen       = $brocken->codegen;
    my $machine_bytes = $codegen->emit_function($func_ext);
    my $output_file   = $brocken->tmpdir . '/libtest_prog.dylib';
    my $linker        = Brocken::Jenny::Linker::MachO->new( type => 'shared' );
    $linker->set_exported_funcs( ['my_func'] );
    $linker->set_labels( { E_my_func => 0 } );
    $linker->write_executable( $output_file, $machine_bytes, $platform );
    ok -e $output_file, 'Mach-O Shared library created successfully';
SKIP: {
        skip 'Shared library loading test requires macOS native host', 1 unless $platform->is_macos && $platform->is_native;
        require DynaLoader;
        require File::Spec;
        my $abs_path = File::Spec->rel2abs($output_file);
        my $libref   = DynaLoader::dl_load_file($abs_path);
        ok $libref, 'Loaded Mach-O shared library natively via DynaLoader';
        if ($libref) {
            my $symref = DynaLoader::dl_find_symbol( $libref, 'my_func' );
            ok $symref, 'Successfully resolved exported symbol "my_func"';
            DynaLoader::dl_unload_file($libref);
        }
    }
    unlink $output_file;
}

# The entry stub's exit() call is emitted before the import stubs are appended. Appending them grows .text, which can
# push .__const (and therefore .got) a page, leaving the entry stub's exit reference pointing at the stale slot. Verify
# the reference always resolves inside the final __got, sweeping text sizes so at least one forces the shift.
sub _macho_sections {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die $!;
    local $/;
    my $d = <$fh>;
    close $fh;
    my $ncmds = unpack 'V', substr( $d, 16, 4 );
    my $off   = 32;
    my %sec;
    while ( $ncmds-- > 0 ) {
        my ( $cmd, $sz ) = unpack 'V2', substr( $d, $off, 8 );
        if ( $cmd == 0x19 ) {
            my $so = $off + 72;
            my $ns = unpack 'V', substr( $d, $off + 64, 4 );
            for ( 1 .. $ns ) {
                my $sn = substr( $d, $so, 16 );
                $sn =~ s/\0.*//s;
                my ( $addr, $size ) = unpack 'Q2', substr( $d, $so + 32, 16 );
                my $sectoff = unpack 'V', substr( $d, $so + 48, 4 );
                $sec{$sn} = { addr => $addr, size => $size, off => $sectoff };
                $so += 80;
            }
        }
        $off += $sz;
    }
    return \%sec;
}

sub _macho_entry_exit_target {
    my ( $path, $platform ) = @_;
    my $sec = _macho_sections($path);
    my ( $addr, $off ) = ( $sec->{__text}{addr}, $sec->{__text}{off} );
    open my $fh, '<:raw', $path or die $!;
    local $/;
    my $d = <$fh>;
    close $fh;
    if ( $platform->is_arm64 ) {
        my $adrp  = unpack 'V', substr( $d, $off + 12, 4 );
        my $immlo = ( $adrp >> 29 ) & 3;
        my $immhi = ( $adrp >> 5 ) & 0x7FFFF;
        my $imm   = ( $immhi << 2 ) | $immlo;
        $imm -= 0x200000 if $imm & 0x100000;
        my $page  = ( ( $addr + 12 ) & ~0xFFF ) + ( $imm << 12 );
        my $ldr   = unpack 'V', substr( $d, $off + 16, 4 );
        my $imm12 = ( $ldr >> 10 ) & 0xFFF;
        return $page + ( $imm12 << 3 );
    }
    my $disp = unpack 'l<', substr( $d, $off + 24, 4 );
    return $addr + 28 + $disp;
}

subtest 'Mach-O entry-stub exit() GOT reference survives a .got shift' => sub {
    my $tmp = Brocken->new->tmpdir;
    for my $triple (qw[x86_64-apple-darwin-macho aarch64-apple-darwin-macho]) {
        my $platform = Brocken::Katsuro::Platform::parse($triple);
        my $linker   = Brocken::Jenny::Linker::MachO->new();
        my $page     = $platform->page_size;                # 4 KiB Intel, 16 KiB Apple Silicon
        my $esize    = $linker->entry_stub_len($platform);  # bytes the entry stub adds to .text
        my $stub     = $platform->is_arm64 ? 12 : 6;        # one import stub
        my $out      = $tmp . '/entry_got_' . ( $platform->is_arm64 ? 'arm' : 'x64' );
        my @bad;

        # Sweep .text sizes that straddle a page boundary by less than one import stub, so the stub append moves
        # .__const (and hence .got) a page while the already-emitted entry stub still holds the pre-shift RVA.
        for my $pad ( ( $page - $esize - $stub - 2 ) .. ( $page - $esize + 2 ) ) {
            my $funcs = [
                {   name   => '_BROCKEN_ENTRY',
                    bytes  => "\x90" x $pad,
                    fixups => [ { type => 'call_rel32', target => 'puts', offset => 0 } ],
                }
            ];
            my $lnk = Brocken::Jenny::Linker::MachO->new();
            $lnk->write_executable( $out, $funcs, $platform );
            my $sec    = _macho_sections($out);
            my $target = _macho_entry_exit_target( $out, $platform );
            my $got    = $sec->{__got};
            push @bad, sprintf( 'pad=%#x target=%#x not in .got [%#x,%#x)', $pad, $target, $got->{addr}, $got->{addr} + $got->{size} )
                unless $target >= $got->{addr} && $target < $got->{addr} + $got->{size};
        }
        is \@bad, [], "$triple: entry exit() reference lands inside .got across the page boundary";
    }
    unlink glob "$tmp/entry_got_*";
};
done_testing;
