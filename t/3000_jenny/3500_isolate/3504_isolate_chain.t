use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
SKIP: {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    skip 'Isolate chain test only on native hosts', 1 unless $host->is_native;
    my $i32 = Brocken::Lindsay::IR::Type::i32();
    my $i64 = Brocken::Lindsay::IR::Type::i64();

    # 1. Isolate spawning another isolate (chain of 2)
    #    Outer isolate creates and joins an inner isolate.
    subtest 'Isolate spawning another isolate' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'inner_fn', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
        my $outer = Brocken::Lindsay::IR::Function->new( name => 'outer_fn', return_type => $i32 );
        my $ob    = Brocken::Lindsay::IR::Builder->new();
        $ob->position_at_end( $outer->append_block('entry') );
        my $iso = $ob->build_isolate_create( $inner, [], '%iso' );
        $ob->build_isolate_join($iso);
        $ob->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 77 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $outer_iso = $mb->build_isolate_create( $outer, [], '%o' );
        $mb->build_isolate_join($outer_iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $outer, $inner ] );
        my $file  = $brocken->tmpdir . '/isolate_chain_2' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = 0;    # $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'isolate spawns isolate exit 99', platform => $host, keep => 1, gdb => $dbg );
    };

    # 2. Isolate chain of depth 3
    #    Main → Outer → Middle → Inner, each joins the next.
    subtest 'Isolate chain depth 3' => sub {
        my $inner = Brocken::Lindsay::IR::Function->new( name => 'inner_fn', return_type => $i32 );
        my $ib    = Brocken::Lindsay::IR::Builder->new();
        $ib->position_at_end( $inner->append_block('entry') );
        $ib->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 42 ) );
        my $middle = Brocken::Lindsay::IR::Function->new( name => 'middle_fn', return_type => $i32 );
        my $mbb    = Brocken::Lindsay::IR::Builder->new();
        $mbb->position_at_end( $middle->append_block('entry') );
        my $mid_iso = $mbb->build_isolate_create( $inner, [], '%mi' );
        $mbb->build_isolate_join($mid_iso);
        $mbb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 55 ) );
        my $outer = Brocken::Lindsay::IR::Function->new( name => 'outer_fn', return_type => $i32 );
        my $ob    = Brocken::Lindsay::IR::Builder->new();
        $ob->position_at_end( $outer->append_block('entry') );
        my $out_iso = $ob->build_isolate_create( $middle, [], '%oi' );
        $ob->build_isolate_join($out_iso);
        $ob->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 77 ) );
        my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i32 );
        my $mb   = Brocken::Lindsay::IR::Builder->new();
        $mb->position_at_end( $main->append_block('entry') );
        my $main_iso = $mb->build_isolate_create( $outer, [], '%m' );
        $mb->build_isolate_join($main_iso);
        $mb->build_ret( Brocken::Lindsay::IR::Constant->new( type => $i32, value => 99 ) );
        my $funcs = $brocken->codegen->emit_functions( [ $main, $outer, $middle, $inner ] );
        my $file  = $brocken->tmpdir . '/isolate_chain_3' . $brocken->ext;
        $brocken->linker->write_executable( $file, $funcs, $host );
        my $dbg = 0;    # $host->is_dragonflybsd || $host->is_netbsd ? 1 : 0;
        run_exec( $file, expected_exit => 99, name => 'isolate chain depth 3 exit 99', platform => $host, keep => 1, gdb => $dbg );
    };
}
done_testing;
