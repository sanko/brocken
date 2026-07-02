use v5.42;
use lib 'lib', '../lib';
use Test2::V0;
use Test2::Tools::Brocken qw[run_exec temp_path];
use Brocken;
use Brocken::Lindsay;
use Brocken::Katsuro::Platform;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Detect platform from Perl's $^O
my %os2triple = (
    MSWin32   => 'x86_64-pc-windows-msvc',
    linux     => 'x86_64-pc-linux-gnu',
    freebsd   => 'x86_64-pc-freebsd-elf',
    dragonfly => 'x86_64-pc-dragonflybsd-elf',
    netbsd    => 'x86_64-pc-netbsd-elf',
    openbsd   => 'x86_64-pc-openbsd-elf',
    darwin    => 'x86_64-apple-macosx',
);
my $triple   = $os2triple{$^O} or plan skip_all => "Unknown OS: $^O";
my $platform = Brocken::Katsuro::Platform::parse($triple);
plan skip_all => 'DragonFly BSD threading not supported' if $platform->is_dragonflybsd;
note("Platform: $triple");
my $i32 = Brocken::Lindsay::IR::Type::i32();

# Minimal worker: just return 42
my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
my $wb     = Brocken::Lindsay::IR::Builder->new();
$wb->position_at_end( $worker->append_block('entry') );
$wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );

# Main: create isolate, join, return 99
my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
my $mb   = Brocken::Lindsay::IR::Builder->new();
$mb->position_at_end( $main->append_block('entry') );
my $iso = $mb->build_isolate_create( $worker, [], '%iso' );
$mb->build_isolate_join($iso);
$mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );

# Compile
my $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
my $funcs   = $codegen->emit_functions( [ $main, $worker ] );
diag('Functions:');
for my $f ( $funcs->@* ) {
    diag( "  $f->{name}: " . length( $f->{bytes} ) . " bytes" );
}

# Link ELF/PE
my $linker   = $platform->is_windows ? Brocken::Jenny::Linker::PE->new() : Brocken::Jenny::Linker::ELF64->new();
my $out_file = temp_path('test_prog');
$linker->write_executable( $out_file, $funcs, $platform );
ok( -f $out_file, "Binary created for $triple" );

# Dump full ELF structure for the generated binary on DragonFly
if ( $platform->is_dragonflybsd ) {
    my $readelf_out = `readelf -a '$out_file' 2>&1`;
    diag("Brocken binary readelf -a:\n$readelf_out");
}

# Run it
my $dbg = $platform->is_dragonflybsd || $platform->is_netbsd ? 1 : 0;
run_exec( $out_file, expected_exit => 99, name => "minimal isolate exit 99 on $triple", platform => $platform, keep => 1, gdb => $dbg );
done_testing;
