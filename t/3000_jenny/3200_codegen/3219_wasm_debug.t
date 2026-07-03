use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../../../lib';
use Brocken::Lindsay;
use Brocken::Jenny::Codegen::Wasm;
use Brocken::Jenny::Linker::Wasm;
use Brocken::Katsuro::Platform;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
subtest 'Wasm source_map and DWARF source_locs accuracy' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
    my $codegen  = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
    my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
    my $builder  = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $v1 = $builder->build_add(
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 ),
        Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 20 ),
        '%v1', 10, 1
    );
    my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 5 ), '%v2', 20, 5 );
    my $v3 = $builder->build_mul( $v2, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ), '%v3', 30, 10 );
    $builder->build_ret( $v3, 40 );
    my $ir_funcs = [$func];
    my $funcs    = $codegen->emit_functions($ir_funcs);
    ok( scalar @$funcs == 1, 'One function blob emitted' );
    my $blob = $funcs->[0];
    ok( exists $blob->{source_map}, 'source_map present in function blob' );
    my $source_map = $blob->{source_map};
    my $num_source = scalar( keys %$source_map );
    is( $num_source, 4, 'source_map has 4 entries (add, sub, mul, ret)' );
    my $func_bytes  = $blob->{bytes};
    my $func_length = length($func_bytes);
    ok( $func_length > 0, 'Function bytes non-empty' );
    my $debug_data = $codegen->build_debug_data( $ir_funcs, $funcs, 'test.wasm', 0, {}, 5 );
    ok( exists $debug_data->{'.debug_line'}, '.debug_line section present' );
    ok( exists $debug_data->{'.debug_info'}, '.debug_info section present' );
    my @expected    = ( { line => 10, col => 1 }, { line => 20, col => 5 }, { line => 30, col => 10 }, { line => 40, col => 0 }, );
    my $prev_offset = -1;

    for my $i ( 0 .. $#expected ) {
        my $e = $expected[$i];
        ok( $source_map->{$i} // -1 >= 0, "source_map entry for inst_idx $i is defined" );
        my $so = $source_map->{$i};
        ok( $so < $func_length, "source_map offset $so < func_length $func_length" );
        cmp_ok( $so, '>', $prev_offset, "source_map offsets monotonically increasing ($so > $prev_offset)" );
        $prev_offset = $so;
    }
    my $dwarf_source_locs = $debug_data->{_source_locs};
    if ( defined $dwarf_source_locs ) {
        ok( scalar @$dwarf_source_locs == 4, 'DWARF source_locs has 4 entries' );
        my $prev_off = -1;
        for my $sl ( $dwarf_source_locs->@* ) {
            ok( $sl->{offset} < $func_length, "source_loc offset $sl->{offset} < $func_length" );
            cmp_ok( $sl->{offset}, '>', $prev_off, 'source_loc offsets increasing' );
            $prev_off = $sl->{offset};
        }
    }
    else {
        note 'DWARF object not exposing _source_locs; validating via .debug_line instead';
        my $line_data = $debug_data->{'.debug_line'};
        ok( length($line_data) > 0, '.debug_line has content' );
        my $unit_len = unpack( 'L<', substr( $line_data, 0, 4 ) );
        is( $unit_len, length($line_data) - 4, '.debug_line unit_length consistent' );
        my $version = unpack( 'S<', substr( $line_data, 4, 2 ) );
        is( $version, 5, '.debug_line version == 5' );
    }
};
done_testing;
