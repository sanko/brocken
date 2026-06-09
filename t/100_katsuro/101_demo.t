use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', 'blib/lib', '../../blib/lib';
use Brocken;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
$|++;

class Brocken::Compiler { }

class Brocken::Katsuro::Platform {

    #~ https://wiki.osdev.org/Target_Triplet
    #~ https://github.com/ziglang/zig/issues/20690
    #~ https://mcyoung.xyz/2025/04/14/target-triples/
    #~ https://llvm.org/doxygen/Triple_8h_source.html
    field $arch     : reader : param;
    field $vendor   : reader : param;
    field $os       : reader : param = ();
    field $env      : reader : param = ();
    field $friendly : reader : param //= 'sand that does math';
    #
    field $bin_ext : reader;
    field $lib_ext : reader;
    #
    class Brocken::Katsuro::Platform::Arch { }

    class Brocken::Katsuro::Platform::OS { }

    class Brocken::Katsuro::Platform::API { }

    class Brocken::Katsuro::Platform::ABI { }

    #~ <arch>[.<cpu>[+~feats]]
    #~ -<os>[.<ver>]
    #~ [-<api>[.<ver>]
    #~ [-<abi>[+~opts]]]
    my %hold;
    sub get_hold() { \%hold }
    use Config;

    sub get_cmd_output {
        my ($cmd) = @_;

        # Hide stderr appropriately for the host OS shell
        my $redirect = ( $^O =~ /MSWin32/i ) ? '2> NUL' : '2> /dev/null';
        my $output   = `$cmd $redirect`;

        # If the command succeeded and returned text
        if ( $? == 0 && defined $output && $output !~ /^\s*$/ ) {
            chomp $output;
            return $output;
        }
        return undef;
    }

    sub normalize_triple {
        my ($raw) = @_;
        my @parts = split( /-/, $raw );
        if ( @parts == 4 ) {
            return $raw;
        }

        # Convert common 3-field compiler outputs into 4-field standard formats
        if ( @parts == 3 ) {
            my ( $p1, $p2, $p3 ) = @parts;

            # e.g., x86_64-apple-darwin21.0.0 -> x86_64-apple-darwin21.0.0-macho
            if ( $p2 eq 'apple' && $p3 =~ /darwin/i ) {
                return join( '-', $p1, $p2, $p3, 'macho' );
            }

            # e.g., x86_64-linux-gnu -> x86_64-pc-linux-gnu
            elsif ( $p2 eq 'linux' ) {
                return join( '-', $p1, 'pc', $p2, $p3 );
            }

            # e.g., x86_64-w64-mingw32 -> x86_64-pc-windows-gnu
            elsif ( $p2 =~ /w64/i && $p3 =~ /mingw/i ) {
                return join( '-', $p1, 'pc', 'windows', 'gnu' );
            }

            # Fallback padding: Assume vendor is missing
            else {
                return join( '-', $p1, 'unknown', $p2, $p3 );
            }
        }

        # Brute force padding for 1, 2, or 5+ parts
        push @parts, 'unknown' while @parts < 4;
        return join( '-', @parts[ 0 .. 3 ] );
    }

    sub gen_triple() {
        my $clang_out = get_cmd_output('clang --print-target-triple');
        if ($clang_out) {
            return normalize_triple($clang_out);
        }

        # 2. Ask GCC directly (Excellent fallback, highly likely to be installed)
        my $gcc_out = get_cmd_output('gcc -dumpmachine');
        if ($gcc_out) {
            return normalize_triple($gcc_out);
        }
        my $arch   = 'unknown';
        my $vendor = 'unknown';
        my $os     = 'unknown';
        my $env    = 'unknown';
        if ( $^O =~ /MSWin32|msys|cygwin/i ) {
            $vendor = 'pc';
            $os     = 'windows';
            $env    = ( $Config{cc} =~ /cl(\.exe)?$/i ) ? 'msvc' : 'gnu';

            # PROCESSOR_ARCHITEW6432 reveals the true host if running under WoW64 emulation
            my $win_arch = $ENV{PROCESSOR_ARCHITEW6432} || $ENV{PROCESSOR_ARCHITECTURE} || '';
            if ( $win_arch =~ /^ARM64$/i ) {
                $arch = 'aarch64';
            }
            elsif ( $win_arch =~ /^ARM$/i ) {
                $arch = 'arm';
            }
            elsif ( $win_arch =~ /^AMD64$/i ) {
                $arch = 'x86_64';
            }
            elsif ( $win_arch =~ /^x86$/i ) {
                $arch = 'i386';
            }
        }
        else {
            eval {
                require POSIX;
                my @uname = POSIX::uname();
                $arch = $uname[4];    # 'machine' hardware identifier
            };
            if ( $arch eq 'unknown' || $@ ) {
                $arch = $Config{archname};
                $arch =~ s/-.*//;
            }

            # Normalize architectures
            $arch = lc($arch);
            $arch = 'x86_64'  if $arch eq 'amd64';
            $arch = 'aarch64' if $arch eq 'arm64';
            $arch = 'i386'    if $arch =~ /^i[3456]86$/;
            if ( $^O eq 'linux' ) {
                $vendor = 'pc';
                $os     = 'linux';
                $env    = 'gnu';
                my $ldd_output = `ldd --version 2>/dev/null` || '';
                if ( -f '/etc/alpine-release' || $ldd_output =~ /musl/i ) {
                    $env = 'musl';
                }
                if ( $arch =~ /^arm/ ) {
                    $env = 'gnueabihf';
                }
            }
            elsif ( $^O eq 'darwin' ) {
                $vendor = 'apple';
                $os     = 'darwin';
                $env    = 'macho';
            }
            elsif ( $^O =~ /bsd/i ) {
                $vendor = 'pc';
                $os     = $^O;
                $env    = 'elf';
            }
        }
        join '-', $arch, $vendor, $os, $env;
    }

    sub parse( $platform //= gen_triple() ) {
        my ( $arch, $vend, $os, $env ) = $platform =~ m[^(.+?)-(.+?)(?:-(.+?)(?:-(.+?))?)?$];

        #~ use Data::Dump;
        #~ ddx [ $arch, $vend, $os, $env ];
        $hold{$vend}{$arch}{ $os // '_' }{ $env // '_' } = $platform;
        my $friendly;
        if ( $vend eq 'apple' ) {
            if ( $arch eq 'aarch64' ) {
                if    ( $os eq 'darwin' )   { $friendly = 'macOS on Apple Silicon' }
                elsif ( $os eq 'ios' )      { $friendly = 'iOS' }
                elsif ( $os eq 'tvos' )     { $friendly = 'Apple TV' }
                elsif ( $os eq 'visionos' ) { $friendly = 'Apple Vision' }
                elsif ( $os eq 'watchos' )  { }
            }
            elsif ( $arch eq 'x86_64' ) {
                if    ( $os eq 'darwin' )  { $friendly = 'macOS on Intel' }
                elsif ( $os eq 'ios' )     { }
                elsif ( $os eq 'tvos' )    { }
                elsif ( $os eq 'watchos' ) { $friendly = 'Apple Watch Simulator' }
            }
            elsif ( $arch eq 'arm64_32' && 0 ) {
                if ( $os eq 'watchsimulator' ) {
                    $friendly = 'Apple Watch Simulator on an Apple Silicon mac';
                }
                else {
                    $friendly = 'Apple Watch';
                }
            }
        }
        elsif ( $vend eq 'pc' ) {
            if ( $arch eq 'aarch64' ) {
            }
            elsif ( $arch eq 'i686' )   { }
            elsif ( $arch eq 'x86_64' ) { }
        }
        elsif ( $vend eq 'unknown' ) {
            if ( $arch eq 'aarch64' ) {
            }
            elsif ( $arch eq 'i686' )   { }
            elsif ( $arch eq 'x86_64' ) { }
            elsif ( $arch eq 'wasm32' ) { }
            elsif ( $arch eq 'wasm64' ) { }
        }
        __PACKAGE__->new( arch => $arch, vendor => $vend, os => $os, env => $env, friendly => $friendly );
    }
}

class Brocken::Katsuro { }

class Brocken::Lindsay { }

class Brocken::Jenny { }
#
my $compiler = Brocken::Compiler->new();
my $platform = Brocken::Katsuro::Platform::parse();

#~ for ( split /\r?\n/, `rustc --print target-list` ) {
#~ my $platform = Brocken::Katsuro::Platform::parse($_);
#~ warn $platform->operating_system;
#~ }
my $x = Brocken::Katsuro::Platform::parse();
diag $x->os;
diag $x->friendly;
isa_ok $x, ['Brocken::Katsuro::Platform'], 'parsed';

#~ x86_64-linux-gnu
#~ x86_64-pc-linux-gnu
#~ x86_64-unknown-linux-gnu
done_testing;
