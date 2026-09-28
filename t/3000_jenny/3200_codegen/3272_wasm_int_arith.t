use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];
use Test2::Tools::Brocken qw(temp_path);

# Integer arithmetic that the Wasm encoder used to get wrong, silently.
#
# The encoder's opcode chain had no `else`, so any opcode it did not recognise
# was dropped without a word. That turned three separate mistakes into wrong
# answers rather than errors:
#
#   * i32 division had no encoder at all, so i32.div disappeared and the
#     right-hand operand was left on the stack as the result;
#   * Wasm has no integer min/max instruction -- only f32.min/f64.min -- yet
#     the lowerer emitted i32_min/i32_max/i64_min/i64_max anyway, so those
#     vanished the same way and the result was the rhs;
#   * div/rem were mapped onto the *unsigned* opcodes, so -42 / 2 returned
#     0x80000005 rather than -21.
#
# On top of that, zext/sext pushed an i32 and then applied i64 ops, which is a
# type mismatch, so every i32-to-i64 extension produced a module that would not
# even validate. Two further slips surfaced while fixing those: the encoder
# labelled 0xAC as i64_extend_i32_u when 0xAC is the *signed* form (0xAD is
# unsigned), so a negative value zero-extended as a sign extension; and the
# integer min/max select has to re-push both operands, because the comparison
# consumes them while select still needs val1 and val2 underneath the
# condition.

my $host     = Brocken::Katsuro::Platform::parse();
my $platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');
my $i32      = Brocken::Lindsay::IR::Type::i32();
my $i64      = Brocken::Lindsay::IR::Type::i64();

my $null = $host->is_windows ? 'NUL' : '/dev/null';

# Take the first line of the lookup only. Splitting on newlines rather than
# trimming everything after the first whitespace matters because the usual
# install path contains a space ("C:\Program Files\Wasmtime\..."), and cutting
# at the first \s would leave a path that does not exist and silently skip
# every case below.
sub find_prog ($name) {
    my $out = $host->is_windows ? `where $name 2>NUL` : `which $name 2>/dev/null`;
    my ($first) = grep { /\S/ } split /\R/, ( defined $out ? $out : '' );
    return $first;
}

my $wasmtime_path = find_prog('wasmtime');
my $node_path     = find_prog('node');

# name, type, builder callback, expected value
my @cases = (
    [ 'i32 div 42/2',       $i32, sub { $_[0]->build_div( K( $i32, 42 ),  K( $i32, 2 ) ) },   21 ],
    [ 'i32 div -42/2',      $i32, sub { $_[0]->build_div( K( $i32, -42 ), K( $i32, 2 ) ) },  -21 ],
    [ 'i32 udiv 42/5',      $i32, sub { $_[0]->build_udiv( K( $i32, 42 ), K( $i32, 5 ) ) },  8 ],
    [ 'i32 rem 43%10',      $i32, sub { $_[0]->build_rem( K( $i32, 43 ), K( $i32, 10 ) ) },  3 ],
    [ 'i32 min 8,42',       $i32, sub { $_[0]->build_min( K( $i32, 8 ),  K( $i32, 42 ) ) },  8 ],
    [ 'i32 max 8,42',       $i32, sub { $_[0]->build_max( K( $i32, 8 ),  K( $i32, 42 ) ) },  42 ],
    [ 'i32 min -8,42',      $i32, sub { $_[0]->build_min( K( $i32, -8 ), K( $i32, 42 ) ) },  -8 ],
    [ 'i32 max -8,42',      $i32, sub { $_[0]->build_max( K( $i32, -8 ), K( $i32, 42 ) ) },  42 ],
    [ 'i64 div 42/2',       $i64, sub { $_[0]->build_div( K( $i64, 42 ),  K( $i64, 2 ) ) },   21 ],
    [ 'i64 div -42/2',      $i64, sub { $_[0]->build_div( K( $i64, -42 ), K( $i64, 2 ) ) },  -21 ],
    [ 'i64 min 8,42',       $i64, sub { $_[0]->build_min( K( $i64, 8 ),  K( $i64, 42 ) ) },  8 ],
    [ 'i64 max 8,42',       $i64, sub { $_[0]->build_max( K( $i64, 8 ),  K( $i64, 42 ) ) },  42 ],
    [ 'zext i32 -5 to i64', $i64, sub { $_[0]->build_zext( K( $i32, -5 ), $i64 ) },         4294967291 ],
    [ 'zext i32 7 to i64',  $i64, sub { $_[0]->build_zext( K( $i32, 7 ),  $i64 ) },         7 ],
    [ 'sext i32 -5 to i64', $i64, sub { $_[0]->build_sext( K( $i32, -5 ), $i64 ) },         -5 ],
    [ 'sext i32 7 to i64',  $i64, sub { $_[0]->build_sext( K( $i32, 7 ),  $i64 ) },         7 ],
);

sub K ( $type, $value ) {
    return Brocken::Lindsay::IR::Constant->new( type => $type, value => $value );
}

subtest 'Wasm integer div/rem/min/max and extension' => sub {
    SKIP: {
        skip 'Neither wasmtime nor node are installed', scalar @cases
            unless ( $wasmtime_path && -x $wasmtime_path ) || ( $node_path && -x $node_path );

        my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $platform );
        my $linker  = Brocken::Jenny::Linker::Wasm->new();

        for my $case (@cases) {
            my ( $name, $type, $build, $want ) = @$case;
            subtest $name => sub {
                my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $type );
                my $builder = Brocken::Lindsay::IR::Builder->new();
                $builder->position_at_end( $func->append_block('entry') );
                $builder->build_ret( $build->($builder) );

                # The encoder must reject an opcode it cannot express rather
                # than dropping it, so a die here is the correct outcome.
                my $res = eval { $codegen->emit_function($func) };
                ok( $res, 'emit_function produced a module' ) or do { diag $@; return };

                my $file = temp_path('wasm_int') . '.wasm';
                eval { $linker->write_executable( $file, $res, $platform ); 1 }
                    or do { diag $@; return };
                ok( -e $file, 'linked a .wasm file' ) or return;

                my $got;
                if ( $wasmtime_path && -x $wasmtime_path ) {
                    my $out = qx["$wasmtime_path" run --invoke main "$file" 2>$null];
                    $out =~ s/\A\s+//;
                    $out =~ s/\s+\z//;
                    $got = $out;
                }
                else {

                    # No wasmtime, so fall back to node. The result is printed
                    # rather than passed out through the exit status: a POSIX
                    # exit status is an 8-bit value, so every case outside
                    # 0..255 came back as its low byte (-21 read as 235), which
                    # failed on the macOS leg where wasmtime is not installed.
                    # The shim runs through the list form, since a qx string with
                    # a redirect goes via cmd.exe on Windows and the embedded
                    # newlines and quotes do not survive it.
                    my $js = sprintf
                        "const fs = require('fs'); const buf = fs.readFileSync('%s');\n"
                      . "WebAssembly.instantiate(buf)\n"
                      . "  .then(res => { process.stdout.write(String(res.instance.exports.main())); })\n"
                      . "  .catch(e => { console.error(e); process.exit(1); });\n",
                        $file;
                    my $out = '';
                    if ( open my $fh, '-|', $node_path, '-e', $js ) {
                        $out = do { local $/ = undef; <$fh> };
                        close $fh;
                    }
                    $got = $out;
                    $got =~ s/\s+//g;
                }
                unlink $file;
                is( $got, $want, "returned $want" );
            };
        }
    }
};

# A missing encoder used to be indistinguishable from a correct one. Feed the
# encoder a MIR opcode no Wasm instruction can express and confirm it refuses
# rather than quietly emitting nothing.
subtest 'Wasm encoder refuses an unknown opcode' => sub {
    SKIP: {
        skip 'ARM64/Wasm codegen unavailable', 1
            unless eval "require Brocken::Jenny::Codegen::Wasm; 1";

        my $mbb = Brocken::Jenny::MIR::MachineBasicBlock->new( name => 'entry' );
        $mbb->add_instruction(
            Brocken::Jenny::MIR::MachineInstruction->new(
                opcode   => 'i32_rotl',
                operands => [],
                comment  => 'deliberately unencodable'
            )
        );
        my $mf = Brocken::Jenny::MIR::MachineFunction->new( name => 'main' );
        $mf->add_block($mbb);

        my $err = do {
            local $@;
            eval {
                Brocken::Jenny::Codegen::Wasm->new( platform => $platform )
                    ->_encode( $mf, [], {}, $i32 );
                1;
            } ? undef : $@;
        };
        ok( defined $err, 'encoding an unknown opcode throws' ) or diag 'it was silently dropped';
        like( $err // '', qr/no encoder for MIR opcode 'i32_rotl'/,
            'the error names the offending opcode' );
    }
};

done_testing;
