use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $brocken  = Brocken->new();
my $platform = $brocken->platform;
my $func     = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i32() );
my $builder  = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func->append_block('entry') );
my $neg  = $builder->build_neg( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ), '%neg' );
my $c1   = $builder->build_icmp( 'eq', $neg, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c1' );
my $abs  = $builder->build_abs( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -42.0 ), '%abs' );
my $c2   = $builder->build_icmp( 'eq', $abs, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c2' );
my $sqrt = $builder->build_sqrt( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 1764.0 ), '%sqrt' );
my $c3  = $builder->build_icmp( 'eq', $sqrt, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c3' );
my $min = $builder->build_min(
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 99.0 ),
    '%min'
);
my $c4  = $builder->build_icmp( 'eq', $min, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c4' );
my $max = $builder->build_max(
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => -1.0 ),
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ),
    '%max'
);
my $c5  = $builder->build_icmp( 'eq', $max, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 42.0 ), '%c5' );
my $all = $builder->build_and( $c1, $c2, '%a' );
$all = $builder->build_and( $all, $c3, '%b' );
$all = $builder->build_and( $all, $c4, '%c' );
$all = $builder->build_and( $all, $c5, '%d' );
my $t_block = $func->append_block('if.then');
my $f_block = $func->append_block('if.else');
$builder->build_cond_br( $all, $t_block, $f_block );
$builder->position_at_end($t_block);
$builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 42 ) );
$builder->position_at_end($f_block);
$builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 0 ) );
my $codegen = $brocken->codegen;
my $bytes   = $codegen->emit_function($func);
ok( length($bytes) > 0, 'Generated float unary/minmax bytes for ' . $platform->friendly );
my $linker = $brocken->linker;
SKIP: {
    skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
    my $output_file = $brocken->tmpdir . '/fum_test' . $brocken->ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -e $output_file, 'Float unary/minmax binary exists' );
    my $ret = system $output_file;
SKIP: {
        skip "system() failed to spawn ($!)", 1 if $ret == -1;
        my $exit_code = $? >> 8;
        is( $exit_code, 42, 'Float unary/minmax returned 42 on ' . $platform->friendly );
    }
    unlink $output_file;
}
done_testing;
