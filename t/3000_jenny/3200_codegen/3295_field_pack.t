use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
use Test2::Tools::Brocken qw(temp_path);
no warnings qw[experimental::class experimental::builtin portable];
use feature               qw[class];

my $host          = Brocken::Katsuro::Platform::parse();
my $wasmtime_path = $host->is_windows ? `where wasmtime 2>NUL` : `which wasmtime 2>/dev/null`;
chomp $wasmtime_path if $wasmtime_path;
my $wasm_platform = Brocken::Katsuro::Platform::parse('wasm32-unknown-wasi');

# `:pack` and `:pack(N)` on a field, the C `__attribute__((packed))` and
# `__attribute__((aligned(N)))` pair.
#
#     field i32 $a :pack;     alignment 1 -- packed against its neighbour
#     field i32 $b :pack(2);  alignment exactly 2
#     field i32 $c :pack(16); alignment exactly 16, above its natural 4
#
# The value replaces the natural alignment rather than combining with it. That
# has to be a replacement and not a maximum, because C's `aligned(N)` lowers a
# field's alignment as readily as it raises one: an i32 with `:pack(2)` only
# needs a 2-byte boundary, and taking the maximum would silently ignore it. It
# also means a bare `:pack` has to mean `:pack(1)` and not "no alignment", or
# the two spellings would disagree.
#
# A packed struct can be smaller than the 8-byte allocation granularity, and its
# size need not be a multiple of 4. The class size and the allocation size are
# rounded separately for that reason: a 3-byte struct is a legal layout and must
# not be rounded back up to 4 just because the next field would rather it were.

# The layout half reads offsets back out of each generated accessor's field GEP,
# so it asserts the number the backend will use rather than recomputing it.
sub offsets_for {
    my ($src) = @_;
    my $module = Brocken::Compiler->new->compile($src);
    my %out;
    for my $f ( $module->functions->@* ) {
        next unless $f->name =~ /^P::(\w+)$/;
        my $m = $1;
        for my $b ( $f->blocks->@* ) {
            for my $i ( $b->instructions->@* ) {
                next unless $i->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr');
                my $disp = $i->operands->[1];
                next unless $disp->isa('Brocken::Lindsay::IR::Constant');
                $out{$m} = $disp->value;
            }
        }
    }
    return \%out;
}

for my $case (
    # A bare `:pack` pulls the field to the next byte but leaves its neighbours'
    # alignment alone. `c` is an i32, so C still puts it on a 4-byte boundary and
    # it lands at 8 rather than 5 -- packing one field is not `__attribute__
    # ((packed))` on the whole struct.
    [ 'packed i8 between two i32' => 'class P { field i32 $a :reader; field i8 $b :pack :reader; field i32 $c :reader; }', { a => 0, b => 4, c => 8 } ],
    [ 'packed i8 after an i32'    => 'class P { field i8 $a :reader; field i32 $b :reader; field i8 $c :pack :reader; }',    { a => 0, b => 4, c => 8 } ],
    [ 'every field packed'        => 'class P { field i8 $a :pack :reader; field i16 $b :pack :reader; field i32 $c :pack :reader; }', { a => 0, b => 1, c => 3 } ],

    # A specific alignment, including one below the natural one.
    [ 'i32 with pack(2) at offset 0' => 'class P { field i32 $a :reader; field i32 $b :pack(2) :reader; }', { a => 0, b => 4 } ],
    [ 'i32 with pack(2) after an i8'  => 'class P { field i8 $a :reader; field i32 $b :pack(2) :reader; }', { a => 0, b => 2 } ],
    [ 'i32 with pack(4) after an i8'  => 'class P { field i8 $a :reader; field i32 $b :pack(4) :reader; }', { a => 0, b => 4 } ],

    # Over-aligning, the other direction.
    [ 'i8 over-aligned to 16' => 'class P { field i32 $a :reader; field i8 $b :pack(16) :reader; field i32 $c :reader; }', { a => 0, b => 16, c => 20 } ],
    [ 'i8 over-aligned to 8'  => 'class P { field i8 $a :pack(8) :reader; }', { a => 0 } ],

    # `:pack(1)` and a bare `:pack` have to agree, or the two spellings drift.
    [ 'pack(1) matches a bare pack' => 'class P { field i32 $a :reader; field i8 $b :pack(1) :reader; field i32 $c :reader; }', { a => 0, b => 4, c => 8 } ],

    # Other attributes are unaffected, and `pack` never shows up as one.
    [ 'pack alongside reader and writer' => 'class P { field i8 $a :pack :reader :writer; field i8 $b :reader; }', { a => 0, b => 1 } ],
) {
    my ( $name, $decl, $want ) = @$case;
    my $got = offsets_for($decl);
    my @bad;
    for my $m ( sort keys %$want ) {
        push @bad, "$m: want $want->{$m}, got " . ( defined $got->{$m} ? $got->{$m} : 'undef' )
            if !defined $got->{$m} || $got->{$m} != $want->{$m};
    }
    is( scalar @bad, 0, "pack layout: $name" ) or diag join( '; ', @bad );
}

# `pack` is a layout modifier, not a flag. If it landed in the attribute list
# the accessor and parameter passes grep by name, then `:pack` would be read as
# a request for a reader named `pack`, and `:pack(N)` would have nowhere to put
# its argument. Both spellings are checked to have left `attrs` alone and to
# have carried their value out of band.
{
    my $ast    = Brocken::Compiler->new->parse_only('class P { field i8 $a :pack :param :reader; field i8 $b :pack(4) :param; }');
    my ($decl) = grep { $_->isa('Brocken::Katsuro::AST::Stmt::ClassDecl') } $ast->statements->@*;
    my ($fa)   = $decl->fields->@*;
    my $fb     = $decl->fields->[1];

    is( $fa->align, 1, 'a bare :pack records an alignment of 1' );
    is( $fb->align, 4, 'a :pack(4) records an alignment of 4' );
    is( $fa->attrs->@*, 2, 'a bare :pack leaves its two real attributes in place' );
    is( $fb->attrs->@*, 1, 'a :pack(4) leaves its one real attribute in place' );
    is( scalar( grep { $_ eq 'pack' } $fa->attrs->@* ), 0, "':pack' is not in the attribute list" );
    is( scalar( grep { $_ eq 'pack' } $fb->attrs->@* ), 0, "':pack(4)' is not in the attribute list" );
}

# An alignment has to be a power of two, because the layout rounds offsets up to
# a multiple of it. Rejected where it was written, so the diagnostic can point at
# the token.
for my $bad ( 0, 3, 5, 12, 100 ) {
    my $ok = eval { Brocken::Compiler->new->compile("class P { field i8 \$a :pack($bad) :reader; }"); 1 };
    ok( !$ok, "':pack($bad)' is rejected" );
    like( $@ // '', qr/power of two/, "':pack($bad)' says why" ) unless $ok;
}

# --- Behaviour ----------------------------------------------------------------
#
# A layout is only correct if the generated code agrees with it at run time, and
# a packed struct is the case where the two are most likely to drift: the fields
# are within a byte or two of each other, so an access one byte too wide lands
# straight on a neighbour that is now genuinely adjacent.
#
# Each program returns 42 when every field still reads back and 1 otherwise,
# because a native exit code is a single byte and cannot carry -300.

my @cases = (
    {
        name => 'a packed i8 write leaves the packed i32 around it alone',
        src  => <<'BROCKEN',
class P {
    field i32 $a :pack :param :reader :writer;
    field i8 $b :pack :param :reader :writer;
    field i16 $c :pack :param :reader :writer;
}
my ptr $p = P->new(100000, 7, 300);
$p->set_b(9);
if ($p->a() == 100000) {
    if ($p->b() == 9) {
        if ($p->c() == 300) { return 42; }
    }
}
return 1;
BROCKEN
    },
    {
        name => 'a packed i16 write leaves the packed i8 after it alone',
        src  => <<'BROCKEN',
class P {
    field i8 $b :pack :param :reader :writer;
    field i16 $c :pack :param :reader :writer;
}
my ptr $p = P->new(7, 300);
$p->set_c(400);
if ($p->b() == 7) {
    if ($p->c() == 400) { return 42; }
}
return 1;
BROCKEN
    },
    {
        name => 'a fully packed struct smaller than 8 bytes still works',
        src  => <<'BROCKEN',
class P {
    field i8 $a :pack :param :reader :writer;
    field i8 $b :pack :param :reader :writer;
    field i8 $c :pack :param :reader :writer;
}
my ptr $p = P->new(1, 2, 3);
$p->set_b(9);
if ($p->a() == 1) {
    if ($p->b() == 9) {
        if ($p->c() == 3) { return 42; }
    }
}
return 1;
BROCKEN
    },
    {
        name => 'a fully packed struct does not overrun the next object',
        src  => <<'BROCKEN',
class A {
    field i8 $a :pack :param :reader :writer;
    field i8 $b :pack :param :reader :writer;
    field i8 $c :pack :param :reader :writer;
}
class B { field i16 $w :param :reader; }
my ptr $a = A->new(1, 2, 3);
my ptr $b = B->new(258);
$a->set_b(9);
if ($b->w() == 258) { return 42; }
return 1;
BROCKEN
    },
    {
        name => 'an over-aligned field is still read and written whole',
        src  => <<'BROCKEN',
class P {
    field i32 $a :pack(16) :param :reader :writer;
    field i8 $b :param :reader :writer;
}
my ptr $p = P->new(400000, 3);
$p->set_a(500000);
if ($p->a() == 500000) {
    if ($p->b() == 3) { return 42; }
}
return 1;
BROCKEN
    },
    {
        name => 'a negative value in a packed field stays sign-extended',
        src  => <<'BROCKEN',
class P {
    field i8 $a :pack :param :reader;
    field i16 $b :pack :param :reader;
}
my ptr $p = P->new(-7, -300);
if ($p->a() == -7) {
    if ($p->b() == -300) { return 42; }
}
return 1;
BROCKEN
    },
    {
        name => 'packed fields are reachable from a method body through accessors',
        src  => <<'BROCKEN',
class P {
    field i8 $a :pack :param :reader :writer;
    field i8 $b :pack :param :reader :writer;
    method sum() -> i8 { return $self->a() + $self->b(); }
}
my ptr $p = P->new(3, 4);
$p->set_a(10);
if ($p->sum() == 14) { return 42; }
return 1;
BROCKEN
    },
);

sub run_wasm {
    my ( $src, $name ) = @_;
    my $module  = Brocken::Compiler->new->compile($src);
    my $codegen = Brocken::Jenny::Codegen::Wasm->new( platform => $wasm_platform );
    my $out     = temp_path($name) . '.wasm';
    Brocken::Jenny::Linker::Wasm->new->write_executable( $out, $codegen->emit_functions( $module->functions ), $wasm_platform );
    my $r = qx["$wasmtime_path" run --invoke _BROCKEN_ENTRY "$out" 1024 2>&1];
    $r =~ s/^warning: using .*$//mg;
    $r =~ s/^\s+|\s+$//g;
    unlink $out;
    return $r;
}

for my $case (@cases) {
    SKIP: {
        skip 'wasmtime not available', 1 unless $wasmtime_path && -f $wasmtime_path;
        is( run_wasm( $case->{src}, 'pack_wasm' ), 42, "wasm: $case->{name}" );
    }
}

{
    my $brocken = Brocken->new;
    SKIP: {
        skip 'Not native', scalar @cases unless $brocken->platform->is_native;

        for my $case (@cases) {
            my $module = Brocken::Compiler->new->compile( $case->{src} );
            my $funcs  = $brocken->codegen->emit_functions( $module->functions );
            my $file   = $brocken->tmpdir . '/pack' . $brocken->ext;
            $brocken->linker->write_executable( $file, $funcs, $brocken->platform );
            system $file;
            is( $? >> 8, 42, "native: $case->{name}" );
        }
    }
}

done_testing;
