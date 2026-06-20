use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $host = Brocken::Katsuro::Platform::parse();

sub build_alloc_func {
    my $cursor_ptr = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%cursor_ptr' );
    my $limit_ptr  = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%limit_ptr' );
    my $size       = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i64(), name => '%size' );
    my $func       = Brocken::Lindsay::IR::Function->new(
        name        => 'alloc',
        return_type => Brocken::Lindsay::IR::Type::ptr(),
        params      => [ $cursor_ptr, $limit_ptr, $size ]
    );
    my $b  = Brocken::Lindsay::IR::Builder->new();
    my $e  = $func->append_block('entry');
    my $ok = $func->append_block('ok');
    my $fl = $func->append_block('fail');
    $b->position_at_end($e);
    my $cursor = $b->build_load( Brocken::Lindsay::IR::Type::ptr(), $cursor_ptr, '%cursor' );
    my $limit  = $b->build_load( Brocken::Lindsay::IR::Type::ptr(), $limit_ptr,  '%limit' );
    my $next   = $b->build_gep( Brocken::Lindsay::IR::Type::i8(), $cursor, [$size], '%next' );
    my $cmp    = $b->build_icmp( 'ugt', $next, $limit, '%cmp' );
    $b->build_cond_br( $cmp, $fl, $ok );
    $b->position_at_end($ok);
    $b->build_store( $next, $cursor_ptr );
    $b->build_ret($cursor);
    $b->position_at_end($fl);
    $b->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 ) );
    return $func;
}

sub build_box_int_func {
    my $mem = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%mem' );
    my $val = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i64(), name => '%val' );
    my $func = Brocken::Lindsay::IR::Function->new(
        name        => 'box_int',
        return_type => Brocken::Lindsay::IR::Type::ptr(),
        params      => [ $mem, $val ]
    );
    my $b = Brocken::Lindsay::IR::Builder->new();
    $b->position_at_end( $func->append_block('entry') );
    my $packed = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0x0000000000040000 );
    $b->build_store( $packed, $mem );
    my $payload_ptr = $b->build_gep( Brocken::Lindsay::IR::Type::i8(), $mem, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 8 ) ], '%payload_ptr' );
    $b->build_store( $val, $payload_ptr );
    $b->build_ret($mem);
    return $func;
}

sub build_incref_func {
    my $obj = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%obj' );
    my $func = Brocken::Lindsay::IR::Function->new(
        name        => 'incref',
        return_type => Brocken::Lindsay::IR::Type::void(),
        params      => [$obj]
    );
    my $b = Brocken::Lindsay::IR::Builder->new();
    $b->position_at_end( $func->append_block('entry') );
    my $rc = $b->build_load( Brocken::Lindsay::IR::Type::i64(), $obj, '%rc' );
    my $one = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
    my $rc_new = $b->build_add( $rc, $one, '%rc_new' );
    $b->build_store( $rc_new, $obj );
    $b->build_ret();
    return $func;
}

sub build_decref_func {
    my $obj = Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%obj' );
    my $func = Brocken::Lindsay::IR::Function->new(
        name        => 'decref',
        return_type => Brocken::Lindsay::IR::Type::void(),
        params      => [$obj]
    );
    my $b    = Brocken::Lindsay::IR::Builder->new();
    my $e    = $func->append_block('entry');
    my $fr   = $func->append_block('free');
    my $done = $func->append_block('done');
    $b->position_at_end($e);
    my $rc     = $b->build_load( Brocken::Lindsay::IR::Type::i64(), $obj, '%rc' );
    my $one    = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
    my $rc_new = $b->build_sub( $rc, $one, '%rc_new' );
    $b->build_store( $rc_new, $obj );
    my $zero    = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
    my $is_zero = $b->build_icmp( 'eq', $rc_new, $zero, '%is_zero' );
    $b->build_cond_br( $is_zero, $fr, $done );
    $b->position_at_end($fr);
    $b->build_ret();
    $b->position_at_end($done);
    $b->build_ret();
    return $func;
}

subtest 'Jenny::Codegen Memory System' => sub {
    my $alloc  = build_alloc_func();
    my $box    = build_box_int_func();
    my $inc    = build_incref_func();
    my $dec    = build_decref_func();

    my $main   = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i64(), params => [] );
    my $b      = Brocken::Lindsay::IR::Builder->new();
    $b->position_at_end( $main->append_block('entry') );

    my $heap       = $b->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%heap' );
    my $heap_end   = $b->build_gep( Brocken::Lindsay::IR::Type::i8(), $heap, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 128 ) ], '%heap_end' );
    my $cursor_slot = $b->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%cursor_slot' );
    $b->build_store( $heap, $cursor_slot );
    my $limit_slot = $b->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%limit_slot' );
    $b->build_store( $heap_end, $limit_slot );

    my $chunk = $b->build_call( $alloc, [ $cursor_slot, $limit_slot, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 16 ) ], '%chunk' );
    my $boxed = $b->build_call( $box, [ $chunk, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 42 ) ], '%boxed' );

    $b->build_call( $inc, [$boxed], undef );
    $b->build_call( $dec, [$boxed], undef );

    my $payload_ptr = $b->build_gep( Brocken::Lindsay::IR::Type::i8(), $boxed, [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 8 ) ], '%payload_ptr' );
    my $result = $b->build_load( Brocken::Lindsay::IR::Type::i64(), $payload_ptr, '%result' );
    $b->build_ret($result);

    my ($codegen, $linker);
    if ( $host->is_arm64 && $host->is_macos ) {
        $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::MachO->new();
    }
    elsif ( $host->is_arm64 && $host->is_windows ) {
        $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::PE->new();
    }
    elsif ( $host->is_arm64 ) {
        $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
    }
    elsif ( $host->is_riscv64 ) {
        $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
    }
    elsif ( $host->is_x64 && $host->is_macos ) {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::MachO->new();
    }
    elsif ( $host->is_x64 && $host->is_windows ) {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::PE->new();
    }
    else {
        $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $host );
        $linker  = Brocken::Jenny::Linker::ELF64->new();
    }
    my $funcs = $codegen->emit_functions( [ $main, $alloc, $box, $inc, $dec ] );
    is( ref $funcs,        'ARRAY',  'emit_functions returned array ref' );
    is( scalar $funcs->@*, 5,        'emit_functions returned 5 entries' );

    SKIP: {
        skip 'Execution test only on native hosts', 2 unless $host->is_native;
        my $output_file = 'memory_test' . $host->bin_ext;
        $linker->write_executable( $output_file, $funcs, $host );
        ok( -e $output_file, 'Memory system binary exists' );
        run_exec( $output_file, expected_exit => 42, platform => $host,
            name => 'box_int(42) -> incref -> decref -> unbox = 42 on ' . $host->friendly );
    }
};
done_testing;
