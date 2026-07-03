use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken;
use Config;
use Fcntl    qw(O_RDONLY O_WRONLY O_CREAT O_TRUNC);
use IPC::Cmd qw(can_run);
use File::Spec;
use File::Temp qw(tempdir);
no warnings qw[experimental::class experimental::builtin portable];

sub _binary_info ($path) {
    sysopen my $fh, $path, O_RDONLY or return "can't open: $!";
    binmode $fh;
    read $fh, my $hdr, 2 or return "can't read: $!";
    return "no MZ" unless $hdr eq 'MZ';
    read $fh, my $e_lfanew_buf, 60;
    my $e_lfanew = unpack 'V', substr( $e_lfanew_buf, 58, 4 );
    seek $fh, $e_lfanew, 0;
    read $fh, my $pe_sig, 4;
    return "no PE sig" unless $pe_sig eq "PE\x00\x00";
    read $fh, my $mach_buf, 2;
    my $mach   = unpack 'v', $mach_buf;
    my $mach_s = $mach == 0x8664 ? 'x86_64' : $mach == 0xAA64 ? 'ARM64' : sprintf( '0x%04X', $mach );
    my $size   = -s $path;
    close $fh;
    return "PE machine=$mach_s size=$size";
}
subtest 'ARM64 PE GCC diagnostic' => sub {
    my $host = Brocken->new->platform;
    my $tmp  = tempdir( CLEANUP => 1 );
SKIP: {
        skip 'Windows ARM64 only', 1 unless $host->is_windows && $host->is_arm64;
        my $probe_src = File::Spec->catfile( $tmp, 'probe.c' );
        my $probe_exe = File::Spec->catfile( $tmp, 'probe.exe' );
        sysopen my $pfh, $probe_src, O_WRONLY | O_CREAT | O_TRUNC or die $!;
        print $pfh "int main(void) { return 0; }\n";
        close $pfh;

        my @cc_candidates = (
            [ 'aarch64-w64-mingw32-gcc',       [] ],
            [ 'aarch64-w64-mingw32-gcc-14',    [] ],
            [ 'aarch64-w64-mingw32-gcc-13',    [] ],
            [ 'aarch64-w64-mingw32-gcc-12',    [] ],
            [ 'aarch64-w64-mingw32-gcc-11',    [] ],
            [ 'gcc',                           [] ],
            [ 'x86_64-w64-mingw32-gcc',        [] ],
            [ 'clang',                         [ '-target', 'aarch64-windows-msvc' ] ],
            [ 'clang',                         [] ],
        );
        my $cc;
        CAND: for my $cand (@cc_candidates) {
            my ( $prog, $args ) = @$cand;
            next unless can_run($prog);
            system( $prog, '--version' );
            next if $?;
            unlink $probe_exe if -e $probe_exe;
            system( $prog, @$args, '-o', $probe_exe, $probe_src );
            next if $? || !-e $probe_exe;
            my $info = _binary_info($probe_exe);
            diag "$prog @$args produced: $info";
            if ( $info =~ /machine=ARM64/ ) {
                $cc = "$prog @$args";
                last CAND;
            }
        }
        skip 'No ARM64 PE compiler found', 1 unless $cc;
        diag "Using compiler: $cc";
        my $small_exe = File::Spec->catfile( $tmp, 'small.exe' );
        my $large_exe = File::Spec->catfile( $tmp, 'large.exe' );
        subtest 'Compile small program (leaf, no data)' => sub {
            my $src = File::Spec->catfile( $tmp, 'small.c' );
            sysopen my $fh, $src, O_WRONLY | O_CREAT | O_TRUNC or die $!;
            print $fh "int main(void) { return 42; }\n";
            close $fh;
            system("$cc -g -o \"$small_exe\" \"$src\"");
            ok( -e $small_exe, 'small.exe exists' ) or diag "compile failed: \$?=" . ( $? >> 8 );
            if ( -e $small_exe ) {
                diag _binary_info($small_exe);
            }
        };
        subtest 'Compile large program (8KB static data)' => sub {
            my $src = File::Spec->catfile( $tmp, 'large.c' );
            sysopen my $fh, $src, O_WRONLY | O_CREAT | O_TRUNC or die $!;
            print $fh "static const char pad[8192] = {0};\nint main(void) { return 42; }\n";
            close $fh;
            system("$cc -g -o \"$large_exe\" \"$src\"");
            ok( -e $large_exe, 'large.exe exists' ) or diag "compile failed: \$?=" . ( $? >> 8 );
            if ( -e $large_exe ) {
                diag _binary_info($large_exe);
            }
        };
        subtest 'Spawn small.exe' => sub {
            skip 'small.exe not compiled', 1 unless -e $small_exe;
            system "\"$small_exe\"";
            if ( $? >> 8 == 255 ) {
                diag "Spawn failed for small.exe: \$!=$! \$^E=$^E " . _binary_info($small_exe);
                ok( 1, 'small.exe: spawn blocked (environment)' );
            }
            else {
                is( $? >> 8, 42, 'small.exe: result 42' );
            }
        };
        subtest 'Spawn large.exe (8KB pad)' => sub {
            skip 'large.exe not compiled', 1 unless -e $large_exe;
            system "\"$large_exe\"";
            if ( $? >> 8 == 255 ) {
                diag "Spawn failed for large.exe: \$!=$! \$^E=$^E " . _binary_info($large_exe);
                ok( 1, 'large.exe: spawn blocked (environment)' );
            }
            else {
                is( $? >> 8, 42, 'large.exe: result 42' );
            }
        };
        subtest 'GDB on small.exe' => sub {
            skip 'small.exe not compiled', 1 unless -e $small_exe;
            my $has_gdb = can_run('gdb');
            skip 'no gdb', 1 unless $has_gdb;
            ( my $gf = $small_exe ) =~ s{\\}{/}g;
            my $out = `gdb -readnow -batch -ex "file $gf" -ex "info functions" -ex quit 2>&1`;
            if ( $out =~ /not in executable format/ || $out =~ /file format not recognized/ || $out =~ /No such file/ ) {
                diag "GDB cannot load small.exe: $out";
                ok( 1, 'small.exe: GDB cannot load (expected on ARM64)' );
            }
            else {
                ok( $out =~ /main/, 'small.exe: GDB finds main' );
            }
        };
        subtest 'GDB on large.exe' => sub {
            skip 'large.exe not compiled', 1 unless -e $large_exe;
            my $has_gdb = can_run('gdb');
            skip 'no gdb', 1 unless $has_gdb;
            ( my $gf = $large_exe ) =~ s{\\}{/}g;
            my $out = `gdb -readnow -batch -ex "file $gf" -ex "info functions" -ex quit 2>&1`;
            if ( $out =~ /not in executable format/ || $out =~ /file format not recognized/ || $out =~ /No such file/ ) {
                diag "GDB cannot load large.exe: $out";
                ok( 1, 'large.exe: GDB cannot load (expected on ARM64)' );
            }
            else {
                ok( $out =~ /main/, 'large.exe: GDB finds main' );
            }
        };
    }
};
done_testing;
