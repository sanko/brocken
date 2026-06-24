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
my $func     = Brocken::Lindsay::IR::Function->new( name => 'math', return_type => Brocken::Lindsay::IR::Type::i32() );
my $builder  = Brocken::Lindsay::IR::Builder->new();
$builder->position_at_end( $func->append_block('entry') );
my $v1 = $builder->build_add(
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 10 ),
    '%v1'
);
my $v2 = $builder->build_sub( $v1, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 8 ), '%v2' );
$builder->build_ret($v2);
my $codegen = $brocken->codegen;
my $bytes   = $codegen->emit_function($func);
ok( length($bytes) > 0, 'Generated math bytes for ' . $platform->friendly );
my $linker = $brocken->linker;
SKIP: {
    skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
    my $output_file = 'math_test' . $brocken->ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -x $output_file || $platform->is_windows, 'Math binary exists' );
    my $cmd = $platform->is_windows ? $output_file : "./$output_file";
    system {$cmd} $cmd;
    my $exit_code = $? >> 8;
    is( $exit_code, 42, 'Math binary returned 42 on ' . $platform->friendly );
    unlink $output_file;
}
done_testing;
