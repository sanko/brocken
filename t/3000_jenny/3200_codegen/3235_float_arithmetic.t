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
my $fptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::f32(), '%fptr' );
$builder->build_store( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 10.5 ), $fptr );
my $fv   = $builder->build_load( Brocken::Lindsay::IR::Type::f32(), $fptr, '%fv' );
my $fres = $builder->build_add( $fv, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f32(), value => 20.5 ), '%fres' );
$builder->build_store( $fres, $fptr );
my $ret = $builder->build_add(
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 40 ),
    Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i32(), value => 2 ),
    '%ret'
);
$builder->build_ret($ret);
my $codegen = $brocken->codegen;
my $bytes   = $codegen->emit_function($func);
ok( length($bytes) > 0, 'Generated float math bytes for ' . $platform->friendly );
my $linker = $brocken->linker;
SKIP: {
    skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
    my $output_file = 'float_test' . $brocken->ext;
    $linker->write_executable( $output_file, $bytes, $platform );
    ok( -e $output_file, 'Float math binary exists' );
    my $cmd = $platform->is_windows ? $output_file : "./$output_file";
    my $ret = system {$cmd} $cmd;
SKIP: {
        skip "system() failed to spawn ($!)", 1 if $ret == -1;
        my $exit_code = $? >> 8;
        is( $exit_code, 42, 'Float math binary returned 42 on ' . $platform->friendly );
    }
    unlink $output_file;
}
done_testing;
