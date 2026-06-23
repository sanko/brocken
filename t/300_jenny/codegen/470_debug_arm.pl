use v5.42;
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Jenny::MIR;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $host = Brocken::Katsuro::Platform::parse();
die "Not ARM64 native" unless $host->is_arm64 && $host->is_native;
my $b      = Brocken::Lindsay::IR::Builder->new();
my $p      = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => 'x' );
my $helper = Brocken::Lindsay::IR::Function->new( name => 'helper', return_type => Brocken::Lindsay::IR::Type::i32(), params => [$p] );
$b->position_at_end( $helper->append_block('entry') );
$b->build_ret( $b->build_add( $p, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 1 ) ) );
my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32(), params => [] );
$b->position_at_end( $main->append_block('entry') );
$b->build_ret( $b->build_call( $helper, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 41 ) ] ) );
my $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
my $funcs   = $codegen->emit_functions( [ $main, $helper ] );

for my $f ( $funcs->@* ) {
    warn "=== Function: $f->{name} (" . length( $f->{bytes} ) . " bytes) ===\n";
    my $bytes = $f->{bytes};
    for ( my $i = 0; $i < length $bytes; $i += 16 ) {
        my $chunk = substr( $bytes, $i, 16 );
        my $hex   = join( ' ', map { sprintf '%02X', ord $_ } split( //, $chunk ) );
        my $pad   = 16 - length($chunk);
        $hex .= '   ' x $pad if $pad;
        my $ascii = join( '', map { ord $_ >= 32 && ord $_ < 127 ? $_ : '.' } split( //, $chunk ) );
        warn sprintf( '%08x: %-48s %s', $i, $hex, $ascii ) . "\n";
    }
    for my $fix ( $f->{fixups}->@* ) {
        warn "  fixup: offset=$fix->{offset} type=$fix->{type} target=$fix->{target}\n";
    }
}

# Link and run with disassembly
my $linker
    = $host->is_macos ? Brocken::Jenny::Linker::MachO->new() :
    $host->is_windows ? Brocken::Jenny::Linker::PE->new() :
    Brocken::Jenny::Linker::ELF64->new();
my $output_file = 'multi_func_debug' . $host->bin_ext;
$linker->write_executable( $output_file, $funcs, $host );

# Disassemble if available
if ( $host->is_linux ) {
    system("objdump -d --architecture=aarch64 $output_file 2>/dev/null || true");
}
system( $host->is_windows ? $output_file : "./$output_file" );
my $exit_code = $? >> 8;
warn "EXIT CODE: $exit_code (expected 42)\n";

# Also run with strace to see syscalls
if ( $host->is_linux ) {
    warn "=== strace output ===\n";
    system("strace -e trace=exit_group ./$output_file 2>&1 || true");
}
unlink $output_file;
