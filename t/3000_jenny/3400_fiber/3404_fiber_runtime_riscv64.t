use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $brocken  = Brocken->new();
my $platform = $brocken->platform;
subtest 'RISCV64 fiber yield passes value to main exit code' => sub {
    my $i32    = Brocken::Lindsay::IR::Type::i32();
    my $i64    = Brocken::Lindsay::IR::Type::i64();
    my $worker = Brocken::Lindsay::IR::Function->new( name => 'worker_fn', return_type => $i32 );
    my $wb     = Brocken::Lindsay::IR::Builder->new();
    $wb->position_at_end( $worker->append_block('entry') );
    my $yield_val = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 99 );
    $wb->build_fiber_yield( $yield_val, '%yv' );
    $wb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 0 ) );
    my $main = Brocken::Lindsay::IR::Function->new( name => '_BROCKEN_ENTRY', return_type => $i32 );
    my $mb   = Brocken::Lindsay::IR::Builder->new();
    $mb->position_at_end( $main->append_block('entry') );
    my $fcb  = $mb->build_fiber_create( $worker, [], '%fcb' );
    my $send = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 42 );
    my $recv = $mb->build_fiber_transfer( $fcb, $send, '%recv' );
    $mb->build_ret($recv);
    my $codegen = $brocken->codegen;
    my $funcs   = $codegen->emit_functions( [ $main, $worker ] );
    ok( scalar @$funcs == 3, 'emit_functions produced 3 functions (main wrapper, _real_main, worker_fn)' ) or
        diag( 'got: ', [ map { $_->{name} } @$funcs ] );

    for my $f ( $funcs->@* ) {
        warn "=== Hex dump of function '$f->{name}' (" . length( $f->{bytes} ) . " bytes) ===\n";
        my $bytes = $f->{bytes};
        for ( my $i = 0; $i < length $bytes; $i += 16 ) {
            my $chunk = substr( $bytes, $i, 16 );
            my $hex   = join( ' ', map { sprintf '%02X', ord $_ } split( //, $chunk ) );
            my $pad   = 16 - length($chunk);
            $hex .= '   ' x $pad if $pad;
            my $ascii = join( '', map { ord $_ >= 32 && ord $_ < 127 ? $_ : '.' } split( //, $chunk ) );
            warn sprintf( '%08x: %-48s %s', $i, $hex, $ascii ) . "\n";
        }
    }
    warn "(end of hex dumps)\n";
SKIP: {
        skip 'Only for RISC-V 64 native hosts', 2 unless $platform->is_riscv64 && $platform->is_native;
        my $linker      = $brocken->linker;
        my $output_file = $brocken->tmpdir . '/fiber_test_riscv64' . $brocken->ext;
        $linker->write_executable( $output_file, $funcs, $platform );
        ok( -f $output_file, 'RISCV64 fiber test executable exists' ) or do { unlink $output_file if -f $output_file; skip 'no binary', 0 };
        system $output_file;
        my $exit_code = $? >> 8;
        is( $exit_code, 99, 'RISCV64 fiber test exited with 99' );
        unlink $output_file;
    }
};
done_testing;
