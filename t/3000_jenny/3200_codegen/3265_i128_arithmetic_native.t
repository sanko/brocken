use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../../../lib', '../../../lib', '../../lib';
use Test2::Tools::Brocken qw[run_exec];
use Brocken;
use Brocken::Lindsay;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];
my $brocken  = Brocken->new();
my $platform = $brocken->platform;

# Test 1: constant i128 return (42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ) );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 constant bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_const_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 constant file exists' );
        run_exec( $output_file, expected_exit => 42, platform => $platform, name => 'Native i128 constant returned 42 on ' . $platform->friendly );
    }
}

# Test 2: i128 add (40 + 2 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 40 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 add bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_add_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 add file exists' );
        run_exec( $output_file, expected_exit => 42, platform => $platform, name => 'Native i128 add (40+2) returned 42 on ' . $platform->friendly );
    }
}

# Test 3: i128 shl (21 << 1 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_shl(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 shl bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_shl_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 shl file exists' );
        run_exec( $output_file, expected_exit => 42, platform => $platform, name => 'Native i128 shl (21<<1) returned 42 on ' . $platform->friendly );
    }
}

# Test 3b: i128 mul (21 * 2 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_mul(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 mul bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_mul_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 mul file exists' );
        run_exec( $output_file, expected_exit => 42, platform => $platform, name => 'Native i128 mul (21*2) returned 42 on ' . $platform->friendly );
    }
}

# Test 4: i128 lshr (84 >> 1 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_lshr(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 84 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 lshr bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_lshr_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 lshr file exists' );
        run_exec(
            $output_file,
            expected_exit => 42,
            platform      => $platform,
            name          => 'Native i128 lshr (84>>1) returned 42 on ' . $platform->friendly
        );
    }
}

# Test 5: i128 ashr (84 >> 1 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_ashr(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 84 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(),  value => 1 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 ashr bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_ashr_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 ashr file exists' );
        run_exec(
            $output_file,
            expected_exit => 42,
            platform      => $platform,
            name          => 'Native i128 ashr (84>>1) returned 42 on ' . $platform->friendly
        );
    }
}

# Test 6: i128 div (42 / 2 = 21)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_div(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 2 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 div bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_div_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 div file exists' );
        run_exec( $output_file, expected_exit => 21, platform => $platform, name => 'Native i128 div (42/2) returned 21 on ' . $platform->friendly );
    }
}

# Test 7: i128 rem (21 % 10 = 1)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_rem(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 21 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 10 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 rem bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_rem_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 rem file exists' );
        run_exec( $output_file, expected_exit => 1, platform => $platform, name => 'Native i128 rem (21%10) returned 1 on ' . $platform->friendly );
    }
}

# Test 8: i128 add with carry chain (-1 + 43 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -1 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 43 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 carry add bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_carry_add_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 carry add file exists' );
        run_exec(
            $output_file,
            expected_exit => 42,
            platform      => $platform,
            name          => 'Native i128 carry add (-1+43) returned 42 on ' . $platform->friendly
        );
    }
}

# Test 9: i128 sub with borrow (5 - 3 = 2)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_sub(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 3 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 sub (5-3) bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_sub_5_3_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 sub (5-3) file exists' );
        run_exec( $output_file, expected_exit => 2, platform => $platform, name => 'Native i128 sub (5-3) returned 2 on ' . $platform->friendly );
    }
}

# Test 9b: i128 sub with borrow (0 - 1 = -1)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_sub(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 1 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 borrow sub bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_borrow_sub_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 borrow sub file exists' );
        my $cmd = $platform->is_windows ? '.\\' . $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit_code = $? >> 8;
        is( $exit_code, 255, 'Native i128 borrow sub (0-1) returned 255 on ' . $platform->friendly );
    }
}

# Test 10: i128 mul (7 * 6 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_mul(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 7 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 6 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 edge mul bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_edge_mul_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 edge mul file exists' );
        run_exec(
            $output_file,
            expected_exit => 42,
            platform      => $platform,
            name          => 'Native i128 edge mul (7*6) returned 42 on ' . $platform->friendly
        );
    }
}

# Test 11: i128 div (100 / 3 = 33)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_div(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 100 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 3 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 edge div bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_edge_div_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 edge div file exists' );
        run_exec(
            $output_file,
            expected_exit => 33,
            platform      => $platform,
            name          => 'Native i128 edge div (100/3) returned 33 on ' . $platform->friendly
        );
    }
}

# Test 12: i128 rem (100 % 7 = 2)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_rem(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 100 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 7 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 edge rem bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_edge_rem_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 edge rem file exists' );
        run_exec(
            $output_file,
            expected_exit => 2,
            platform      => $platform,
            name          => 'Native i128 edge rem (100%7) returned 2 on ' . $platform->friendly
        );
    }
}

# Test 13: i128 sub with negative rhs (5 - (-1) = 6)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_sub(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value =>  5 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -1 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 sub negative rhs bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_sub_neg_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 sub negative rhs file exists' );
        run_exec(
            $output_file,
            expected_exit => 6,
            platform      => $platform,
            name          => 'Native i128 sub (5 - (-1)) returned 6 on ' . $platform->friendly
        );
    }
}

# Test 14: i128 add with carry through hi ((-1) + 2 = 1)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_add(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -1 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value =>  2 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 add carry hi bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_add_carry_hi_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 add carry hi file exists' );
        run_exec(
            $output_file,
            expected_exit => 1,
            platform      => $platform,
            name          => 'Native i128 add ((-1) + 2) returned 1 on ' . $platform->friendly
        );
    }
}

# Test 15: i128 and ((-1) & 42 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_and(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -1 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 and bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_and_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 and file exists' );
        run_exec(
            $output_file,
            expected_exit => 42,
            platform      => $platform,
            name          => 'Native i128 and (-1 & 42) returned 42 on ' . $platform->friendly
        );
    }
}

# Test 16: i128 or (0 | 42 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_or(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 or bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_or_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 or file exists' );
        run_exec( $output_file, expected_exit => 42, platform => $platform, name => 'Native i128 or (0 | 42) returned 42 on ' . $platform->friendly );
    }
}

# Test 17: i128 xor (42 xor 0 = 42)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_xor(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 0 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 xor bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_xor_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 xor file exists' );
        run_exec(
            $output_file,
            expected_exit => 42,
            platform      => $platform,
            name          => 'Native i128 xor (42 xor 0) returned 42 on ' . $platform->friendly
        );
    }
}

# Test 18: signed i128 div (-42 / 2 = -21)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_div(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value =>  2 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 signed div bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_sdiv1_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 signed div (-42/2) file exists' );
        my $cmd = $platform->is_windows ? '.\\' . $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit = $? >> 8;
        is( $exit, 235, 'Native i128 signed div (-42/2) returned 235 (-21) on ' . $platform->friendly );
    }
}

# Test 19: signed i128 div (42 / -2 = -21)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_div(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => 42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -2 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 signed div 2 bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_sdiv2_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 signed div (42/-2) file exists' );
        my $cmd = $platform->is_windows ? '.\\' . $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit = $? >> 8;
        is( $exit, 235, 'Native i128 signed div (42/-2) returned 235 (-21) on ' . $platform->friendly );
    }
}

# Test 20: signed i128 div (-42 / -2 = 21)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_div(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -2 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 signed div neg both bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_sdiv3_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 signed div (-42/-2) file exists' );
        run_exec(
            $output_file,
            expected_exit => 21,
            platform      => $platform,
            name          => 'Native i128 signed div (-42/-2) returned 21 on ' . $platform->friendly
        );
    }
}

# Test 21: signed i128 rem (-42 % 5 = -2, exit 254)
{
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'main', return_type => Brocken::Lindsay::IR::Type::i128() );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret(
        $builder->build_rem(
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value => -42 ),
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i128(), value =>  5 ),
            '%r'
        )
    );
    my $codegen = $brocken->codegen;
    my $bytes = $codegen->emit_function($func);
    ok( length($bytes) > 0, 'Generated native i128 signed rem bytes for ' . $platform->friendly );
    my $linker = $brocken->linker;
SKIP: {
        skip 'Execution test only supported on native hosts', 2 unless $platform->is_native;
        my $output_file = 'i128_srem1_native' . $brocken->ext;
        $linker->write_executable( $output_file, $bytes, $platform );
        ok( -e $output_file, 'Native i128 signed rem (-42%5) file exists' );
        my $cmd = $platform->is_windows ? '.\\' . $output_file : "./$output_file";
        system {$cmd} $cmd;
        my $exit = $? >> 8;
        is( $exit, 254, 'Native i128 signed rem (-42%5) returned 254 (-2) on ' . $platform->friendly );
    }
}
done_testing;
