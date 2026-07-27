#!/usr/bin/env perl
# t/2000_lindsay/2098_layout.t - Tests for Brocken::Layout struct/aggregate layout calculator.
use v5.42;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Brocken::Layout;

# -- align() -----------------------------------------------------------
subtest 'align basic' => sub {
    is( Brocken::Layout::align( 0,  1 ),  0,  'align(0,1)=0' );
    is( Brocken::Layout::align( 1,  1 ),  1,  'align(1,1)=1' );
    is( Brocken::Layout::align( 0,  8 ),  0,  'align(0,8)=0' );
    is( Brocken::Layout::align( 1,  8 ),  8,  'align(1,8)=8' );
    is( Brocken::Layout::align( 7,  8 ),  8,  'align(7,8)=8' );
    is( Brocken::Layout::align( 8,  8 ),  8,  'align(8,8)=8' );
    is( Brocken::Layout::align( 9,  8 ),  16, 'align(9,8)=16' );
    is( Brocken::Layout::align( 0,  16 ), 0,  'align(0,16)=0' );
    is( Brocken::Layout::align( 1,  16 ), 16, 'align(1,16)=16' );
    is( Brocken::Layout::align( 15, 16 ), 16, 'align(15,16)=16' );
    is( Brocken::Layout::align( 16, 16 ), 16, 'align(16,16)=16' );
    is( Brocken::Layout::align( 17, 16 ), 32, 'align(17,16)=32' );
};
subtest 'align alignment=1 is no-op' => sub {
    for my $o ( 0, 1, 3, 7, 13, 255 ) {
        is( Brocken::Layout::align( $o, 1 ), $o, "align($o,1)=$o" );
    }
};

# -- type_size / type_alignment ----------------------------------------
subtest 'type_size known types' => sub {
    is( Brocken::Layout::type_size('i1'),   1 );
    is( Brocken::Layout::type_size('i8'),   1 );
    is( Brocken::Layout::type_size('i16'),  2 );
    is( Brocken::Layout::type_size('i32'),  4 );
    is( Brocken::Layout::type_size('i64'),  8 );
    is( Brocken::Layout::type_size('i128'), 16 );
    is( Brocken::Layout::type_size('u8'),   1 );
    is( Brocken::Layout::type_size('u32'),  4 );
    is( Brocken::Layout::type_size('u64'),  8 );
    is( Brocken::Layout::type_size('f32'),  4 );
    is( Brocken::Layout::type_size('f64'),  8 );
    is( Brocken::Layout::type_size('ptr'),  8 );
};
subtest 'type_alignment known types' => sub {
    is( Brocken::Layout::type_alignment('i1'),   1 );
    is( Brocken::Layout::type_alignment('i8'),   1 );
    is( Brocken::Layout::type_alignment('i16'),  2 );
    is( Brocken::Layout::type_alignment('i32'),  4 );
    is( Brocken::Layout::type_alignment('i64'),  8 );
    is( Brocken::Layout::type_alignment('i128'), 16 );
    is( Brocken::Layout::type_alignment('f32'),  4 );
    is( Brocken::Layout::type_alignment('f64'),  8 );
    is( Brocken::Layout::type_alignment('ptr'),  8 );
};
subtest 'type_size dies on unknown type' => sub {
    eval { Brocken::Layout::type_size('nope') };
    like( $@, qr/unknown type 'nope'/ );
};

# -- layout_fields() ---------------------------------------------------
subtest 'single i64 field' => sub {
    my $L = Brocken::Layout::layout_fields( { name => 'x', type => 'i64' } );
    is( $L->{size},                 8, 'size=8' );
    is( $L->{alignment},            8, 'alignment=8' );
    is( $L->{fields}[0]{offset},    0, 'offset=0' );
    is( $L->{fields}[0]{size},      8, 'field size=8' );
    is( $L->{fields}[0]{alignment}, 8, 'field alignment=8' );
};
subtest 'two i64 fields - no padding' => sub {
    my $L = Brocken::Layout::layout_fields( { name => 'a', type => 'i64' }, { name => 'b', type => 'i64' }, );
    is( $L->{size},              16, 'size=16' );
    is( $L->{fields}[0]{offset}, 0,  'a offset=0' );
    is( $L->{fields}[1]{offset}, 8,  'b offset=8' );
};
subtest 'i8 then i64 - alignment padding' => sub {
    my $L = Brocken::Layout::layout_fields( { name => 'flag', type => 'i8' }, { name => 'data', type => 'i64' }, );
    is( $L->{size},              16, 'size=16 (1 + 7 pad + 8)' );
    is( $L->{fields}[0]{offset}, 0,  'flag offset=0' );
    is( $L->{fields}[0]{size},   1,  'flag size=1' );
    is( $L->{fields}[1]{offset}, 8,  'data offset=8 (aligned)' );
    is( $L->{alignment},         8,  'struct alignment=8 (max member)' );
};
subtest 'i64 then i8 - no trailing padding needed for single field' => sub {
    my $L = Brocken::Layout::layout_fields( { name => 'data', type => 'i64' }, { name => 'flag', type => 'i8' }, );
    is( $L->{size},              16, 'size=16 (tail-padded to 8-byte alignment)' );
    is( $L->{fields}[0]{offset}, 0,  'data offset=0' );
    is( $L->{fields}[1]{offset}, 8,  'flag offset=8' );
    is( $L->{alignment},         8,  'struct alignment=8' );
};
subtest 'i128 field alignment' => sub {
    my $L = Brocken::Layout::layout_fields( { name => 'big', type => 'i128' }, { name => 'small', type => 'i8' }, );
    is( $L->{size},              32, 'size=32 (16 + 1 + 15 tail pad)' );
    is( $L->{fields}[0]{offset}, 0,  'big offset=0' );
    is( $L->{fields}[0]{size},   16, 'big size=16' );
    is( $L->{fields}[1]{offset}, 16, 'small offset=16' );
    is( $L->{alignment},         16, 'struct alignment=16 (i128)' );
};
subtest 'i8 then i128 - padding to 16' => sub {
    my $L = Brocken::Layout::layout_fields( { name => 'pad', type => 'i8' }, { name => 'big', type => 'i128' }, );
    is( $L->{size},              32, 'size=32 (1 + 15 pad + 16)' );
    is( $L->{fields}[0]{offset}, 0,  'pad offset=0' );
    is( $L->{fields}[1]{offset}, 16, 'big offset=16 (aligned to 16)' );
};
subtest 'mixed types: i8, i32, i64, ptr' => sub {
    my $L = Brocken::Layout::layout_fields(
        { name => 'a', type => 'i8' },
        { name => 'b', type => 'i32' },
        { name => 'c', type => 'i64' },
        { name => 'd', type => 'ptr' },
    );
    is( $L->{fields}[0]{offset}, 0,  'a offset=0 (i8)' );
    is( $L->{fields}[1]{offset}, 4,  'b offset=4 (aligned to 4)' );
    is( $L->{fields}[2]{offset}, 8,  'c offset=8 (aligned to 8)' );
    is( $L->{fields}[3]{offset}, 16, 'd offset=16 (aligned to 8)' );
    is( $L->{size},              24, 'size=24 (tail-padded to 8)' );
    is( $L->{alignment},         8,  'alignment=8' );
};
subtest 'empty field list' => sub {
    my $L = Brocken::Layout::layout_fields();
    is( $L->{size},              0, 'empty size=0' );
    is( $L->{alignment},         1, 'empty alignment=1' );
    is( scalar $L->{fields}->@*, 0, 'no fields' );
};
subtest 'extra keys preserved' => sub {
    my $L = Brocken::Layout::layout_fields( { name => 'x', type => 'i64', desc => 'the value', id => 'X_FIELD', value => 42 }, );
    is( $L->{fields}[0]{desc},  'the value', 'desc preserved' );
    is( $L->{fields}[0]{id},    'X_FIELD',   'id preserved' );
    is( $L->{fields}[0]{value}, 42,          'value preserved' );
};
subtest 'desc not present when omitted' => sub {
    my $L = Brocken::Layout::layout_fields( { name => 'x', type => 'i64' }, );
    ok( !exists $L->{fields}[0]{desc}, 'desc not present' );
};

# -- ICB field list produces expected layout ---------------------------
subtest 'ICB layout matches committed offsets' => sub {
    require Brocken::ICB;
    is( Brocken::ICB::SIZE(), 144, 'ICB size=144' );
    my @expected = (
        [ 'HEAP_CURSOR',             0 ],
        [ 'CURRENT_FCB',             8 ],
        [ 'FIBER_HEAD',              16 ],
        [ 'IMMIX_CURSOR',            24 ],
        [ 'IMMIX_LIMIT',             32 ],
        [ 'FREE_BLOCKS',             40 ],
        [ 'FREE16_HEAD',             48 ],
        [ 'SUSPECT_BUFFER_HEAD',     56 ],
        [ 'FUEL',                    64 ],
        [ 'ERR_CODE',                72 ],
        [ 'CURRENT_BLOCK',           80 ],
        [ 'MEMORY_LIMIT',            88 ],
        [ 'MEMORY_USED',             96 ],
        [ 'CAPABILITIES',            104 ],
        [ 'GATE_TABLE',              112 ],
        [ 'HOST_ICB',                120 ],
        [ 'EXCEPTION_HANDLER_STACK', 128 ],
        [ 'THROWN_VALUE',            136 ],
    );
    for my $e (@expected) {
        my ( $name, $offset ) = @$e;
        no strict 'refs';
        my $val = &{"Brocken::ICB::$name"}();
        is( $val, $offset, "ICB $name = $offset" );
    }
    is( Brocken::ICB::ERR_OK(),       0, 'ERR_OK=0' );
    is( Brocken::ICB::ERR_OOM(),      1, 'ERR_OOM=1' );
    is( Brocken::ICB::ERR_NO_FUEL(),  2, 'ERR_NO_FUEL=2' );
    is( Brocken::ICB::ERR_SECURITY(), 3, 'ERR_SECURITY=3' );
    is( Brocken::ICB::ERR_THROW(),    5, 'ERR_THROW=5' );
};

# -- error on missing name/type ----------------------------------------
subtest 'layout_fields dies on missing name' => sub {
    eval { Brocken::Layout::layout_fields( { type => 'i64' } ) };
    like( $@, qr/no name/ );
};
subtest 'layout_fields dies on missing type' => sub {
    eval { Brocken::Layout::layout_fields( { name => 'x' } ) };
    like( $@, qr/no type/ );
};
done_testing;
