use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Lindsay;
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
#
{
    my $module      = Brocken::Lindsay::IR::Module->new( name => 'mem_test' );
    my $param_input = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i32(), name => '%input' );
    my $func = Brocken::Lindsay::IR::Function->new( name => 'copy_val', return_type => Brocken::Lindsay::IR::Type::void(), params => [$param_input] );
    $module->add_function($func);
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    my $ptr = $builder->build_alloca( Brocken::Lindsay::IR::Type::i32(), '%my_ptr' );
    $builder->build_store( $param_input, $ptr );
    my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $ptr, '%loaded_val' );
    $builder->build_ret();
    my $expected_ir = <<~'IR';
; ModuleID = 'mem_test'

define void @copy_val(i32 %input) {
entry:
  %my_ptr = alloca i32
  store i32 %input, ptr %my_ptr
  %loaded_val = load i32, ptr %my_ptr
  ret void
}

IR
    is $module->as_string, $expected_ir, 'Generated Memory IR matches expected LLVM-style output';
}
subtest 'Memory Model: RC and Bump Allocation' => sub {
    my $brocken = Brocken->new();
    my $host    = $brocken->platform;
    my $b       = Brocken::Lindsay::IR::Builder->new();
    my $i64  = Brocken::Lindsay::IR::Type::i64();
    my $ptr  = Brocken::Lindsay::IR::Type::ptr();
    my $void = Brocken::Lindsay::IR::Type::void();

    # -------------------------------------------------------------------
    # 1. Build Brocken::Runtime::incref
    # -------------------------------------------------------------------
    my $p_inc_obj = Brocken::Lindsay::IR::Value->new( type => $ptr, name => 'obj' );
    my $incref_fn = Brocken::Lindsay::IR::Function->new( name => 'Brocken::Runtime::incref', return_type => $void, params => [$p_inc_obj] );
    $b->position_at_end( $incref_fn->append_block('entry') );

    # Load RC (first 8 bytes of Fat Scalar), Add 1, Store RC
    my $rc_val = $b->build_load( $i64, $p_inc_obj, 'rc' );
    my $rc_inc = $b->build_add( $rc_val, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), 'rc_plus_1' );
    $b->build_store( $rc_inc, $p_inc_obj );
    $b->build_ret();

    # -------------------------------------------------------------------
    # 2. Build Brocken::Runtime::decref
    # -------------------------------------------------------------------
    my $p_dec_obj = Brocken::Lindsay::IR::Value->new( type => $ptr, name => 'obj' );
    my $decref_fn = Brocken::Lindsay::IR::Function->new( name => 'Brocken::Runtime::decref', return_type => $void, params => [$p_dec_obj] );
    $b->position_at_end( $decref_fn->append_block('entry') );

    # Load RC, Subtract 1, Store RC. (We will add the 'if RC == 0 free' logic later)
    my $rc_val2 = $b->build_load( $i64, $p_dec_obj, 'rc' );
    my $rc_dec  = $b->build_sub( $rc_val2, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 ), 'rc_minus_1' );
    $b->build_store( $rc_dec, $p_dec_obj );
    $b->build_ret();

    # -------------------------------------------------------------------
    # 3. Build Brocken::Runtime::bump_alloc
    # -------------------------------------------------------------------
    my $p_cursor_ptr = Brocken::Lindsay::IR::Value->new( type => $ptr, name => 'cursor_ptr' );
    my $p_size       = Brocken::Lindsay::IR::Value->new( type => $i64, name => 'size' );
    my $alloc_fn     = Brocken::Lindsay::IR::Function->new( name => 'bump_alloc', return_type => $ptr, params => [ $p_cursor_ptr, $p_size ] );
    $b->position_at_end( $alloc_fn->append_block('entry') );

    # Read the current heap cursor, advance it, save it, and return the old cursor
    my $cursor_val = $b->build_load( $ptr, $p_cursor_ptr, 'cursor' );

    # gep with i8 base type correctly adds `size` bytes to the pointer
    my $next_val = $b->build_gep( Brocken::Lindsay::IR::Type::i8(), $cursor_val, [$p_size], 'next_cursor' );
    $b->build_store( $next_val, $p_cursor_ptr );

    # Initialize the new Fat Scalar's RC to 0
    $b->build_store( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), $cursor_val );
    $b->build_ret($cursor_val);

    # -------------------------------------------------------------------
    # 4. Build main() - The Integration Test
    # -------------------------------------------------------------------
    my $main = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => $i64, params => [] );
    $b->position_at_end( $main->append_block('entry') );

    # Simulate our 32KB Immix block by allocating a smaller block on the local stack
    # (Since we haven't implemented thread-local globals in IR yet)
    my $fake_heap = $b->build_alloca( Brocken::Lindsay::IR::Type::i128(), 'fake_heap' );

    # Allocate a pointer to track our cursor, initialized to the start of the fake heap
    my $cursor_ptr = $b->build_alloca( $ptr, 'cursor_tracker' );
    $b->build_store( $fake_heap, $cursor_ptr );

    # Allocate a Fat Scalar (16 bytes)
    my $fat_scalar = $b->build_call( $alloc_fn, [ $cursor_ptr, Brocken::Lindsay::IR::Constant->new( type => $i64, value => 16 ) ], 'obj' );

    # Test the RC hooks we added! (0 -> 1 -> 2 -> 1)
    $b->build_incref($fat_scalar);
    $b->build_incref($fat_scalar);
    $b->build_decref($fat_scalar);

    # Load the final Reference Count and return it. We expect exactly 1.
    my $final_rc = $b->build_load( $i64, $fat_scalar, 'final_rc' );
    $b->build_ret($final_rc);

    # -------------------------------------------------------------------
    # 5. Compile and Execute
    # -------------------------------------------------------------------
    my @functions = ( $incref_fn, $decref_fn, $alloc_fn, $main );
SKIP: {
        skip 'Native memory model test only runs on native hosts', 1 unless $host->is_native;
        my $codegen = $brocken->codegen;
        my $linker  = $brocken->linker;
        #
        my $funcs       = $codegen->emit_functions( \@functions );
        my $output_file = 'memory_model_test' . $brocken->ext;
        $linker->write_executable( $output_file, $funcs, $host );

        # If this succeeds and returns 1, our allocator, RC system,
        # and cross-function call/spilling logic are mathematically flawless!
        run_exec( $output_file, expected_exit => 1, platform => $host, name => 'Bump alloc and RC correctly returns 1 on ' . $host->friendly );
    }
};
done_testing;
