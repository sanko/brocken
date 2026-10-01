use v5.42;
use Test2::V0 '!subtest';
use lib 'lib', '../../../lib', '../../lib', '../lib';
use Test2::Tools::Brocken qw[run_exec cross_available temp_path];
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
use Brocken::Compiler;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Arguments past the end of a register file arrive on the stack.
#
# Each backend has a fixed number of argument registers per class, and nothing
# checked that a call stayed inside them: the caller indexed the register list
# past its end and built a `phys_reg` operand whose name was undefined, which
# the encoder refused with a warning rather than an error, and the callee read
# past its own list the same way.  The first symptom was a program that
# encoded without complaint and then passed the wrong values.
#
# Both halves are numbered the same way on purpose.  An overflowing argument is
# counted from zero -- not from the register index that ran out -- and the two
# register files are sized separately, so an integer that overflows is not
# charged against the floating-point one.  The caller writes it at a raw
# displacement off the stack pointer and the callee reads it from the stack
# pointer as it was on entry, both at 8 * $index.  The offset check below is
# what catches the two drifting apart: the callee once read its first stack
# argument at entry+64 while the caller wrote it at +0, which no encoding check
# notices.
#
# The outgoing area is reserved in the function's frame rather than pushed at
# the call, because the allocator's spill slots are stack displacements it
# computed before the call: moving sp at the call would invalidate every one of
# them, and it would also leave sp unaligned at a public interface.
#
# The structural checks run on the two backends that gained stack arguments
# here; x86-64 reaches the stack by its own already-tested mechanism.  None of
# them execute, so all of it runs on any host.
my @TARGETS = (
    [ 'aarch64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::ARM64' ],
    [ 'riscv64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::RISCV64' ],
);

sub lowered( $triple, $class, $src ) {
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $module   = Brocken::Compiler->new->compile($src);
    my %mf;
    for my $func ( $module->functions->@* ) {
        next unless $func->blocks->@*;
        $mf{ $func->name } = $class->new( platform => $platform )->lower($func);
    }
    return ( $platform, \%mf );
}

# Every memory operand whose displacement is set by the calling convention,
# with the comment of the instruction that uses it.
sub raw_slots($mf) {
    my @slots;
    for my $mbb ( $mf->blocks->@* ) {
        for my $inst ( $mbb->instructions->@* ) {
            for my $op ( $inst->operands->@* ) {
                next unless $op->kind eq 'mem';
                my $addr = $op->value;
                next unless $addr->{raw};
                push @slots, { opcode => $inst->opcode, raw => $addr->{raw}, disp => $addr->{disp} // 0, comment => $inst->comment // '' };
            }
        }
    }
    return @slots;
}

sub calls_named( $mf, $want ) {
    for my $mbb ( $mf->blocks->@* ) {
        for my $inst ( $mbb->instructions->@* ) {
            next unless $inst->opcode eq 'call_func';
            my ($fn) = $inst->operands->@*;
            return 1 if defined $fn && $fn->value eq $want;
        }
    }
    return 0;
}

# A call with more integer arguments than the backend has argument registers.
# The two hidden leading arguments every function carries are counted here too,
# so this overruns by design.
sub overflow_src( $triple ) {
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $hidden   = 2;
    my $room     = scalar $platform->abi->param_registers->@* - $hidden;
    my $n        = $room + 3;
    my @params   = map {"i64 \$p$_"} 0 .. $n - 1;
    my @args     = map { $_ + 1 }   0 .. $n - 1;
    my $sum      = join ' + ', map {"\$p$_"} 0 .. $n - 1;
    my $src      = <<"BROCKEN";
sub over( @{[ join ', ', @params ]} ) -> i64 {
    my i64 \$s = $sum;
    return \$s;
}
return over( @{[ join ', ', @args ]} );
BROCKEN
    return ( $src, $n );
}

for my $target (@TARGETS) {
    my ( $triple, $class ) = @$target;
    my ( $src, $n ) = overflow_src($triple);

    my ( $platform, $mf ) = lowered( $triple, $class, $src );
    my ($callee) = grep {/^over/} keys %$mf;
    my ($caller) = grep { calls_named( $mf->{$_}, $callee ) } keys %$mf;
    ok( $callee && $caller, "$triple: the overflowing call and its callee were both lowered" ) or next;

    my @in  = sort { $a <=> $b } map { $_->{disp} } raw_slots( $mf->{$callee} );
    my @out = sort { $a <=> $b } map { $_->{disp} } raw_slots( $mf->{$caller} );

    ok( @in,  "$triple: the callee reads its $n-argument call from the stack" );
    ok( @out, "$triple: the caller writes its $n-argument call to the stack" );
    is( $in[0],  0,  "$triple: the first incoming stack argument is at entry+0, not past the register file" );
    is( $out[0], 0,  "$triple: the first outgoing stack argument is at sp+0, matching the callee" );
    is( \@in, \@out, "$triple: caller and callee number the stack arguments the same way" );
    is( $in[-1], ( $in[0] + 8 * ( scalar(@in) - 1 ) ), "$triple: the incoming slots are contiguous 8-byte steps" );

    # A mixed overflow is the case that got the numbering wrong: the integer
    # file runs out while the floating-point one still has room, and the
    # overflowing float must not be pushed along by the integer's count.
    my $fp = $platform->abi->fp_param_registers;
    my $mix_n = scalar(@$fp) + 1;
    my $mix   = <<"BROCKEN";
sub mixed( @{[ join ', ', map {"f64 \$f$_"} 0 .. $mix_n - 1 ]}, i64 \$j ) -> i64 {
    my i64 \$s = \$j;
    return \$s;
}
return mixed( @{[ join ', ', map { ( $_ + 1 ) . '.0' } 0 .. $mix_n - 1 ]}, 42 );
BROCKEN
    my ( undef, $mmf ) = lowered( $triple, $class, $mix );
    my ($mcallee) = grep {/^mixed/} keys %$mmf;
    my ($mcaller) = grep { calls_named( $mmf->{$_}, $mcallee ) } keys %$mmf;
    my @min  = sort { $a <=> $b } map { $_->{disp} } raw_slots( $mmf->{$mcallee} );
    my @mout = sort { $a <=> $b } map { $_->{disp} } raw_slots( $mmf->{$mcaller} );
    is( $min[0], 0, "$triple: an integer overflowing does not push the floating-point stack index along" );
    is( \@min, \@mout, "$triple: mixed overflow agrees on both sides" );

    # A 128-bit argument takes a consecutive register pair, so it goes to the
    # stack whole when only one register is left rather than straddling the two.
    # The surface language has no i128 parameter syntax yet, so this builds the
    # function directly.  Two i128 arguments plus one more overflow the pair on
    # every backend here.
    my $regs  = $platform->abi->param_registers;
    my $pairs = int( scalar(@$regs) / 2 );

    # One argument fills each register pair, and the next has nowhere to go
    # but the stack, so the pairs that fit come first.
    my $wide  = wide_func( $pairs + 1 );
    my $wmf   = $class->new( platform => $platform )->lower($wide);
    my @win   = sort { $a <=> $b } map { $_->{disp} } raw_slots($wmf);
    ok( @win, "$triple: the 128-bit argument that ran out of register pairs is read from the stack" );
    is( scalar(@win), 2, "$triple: a 128-bit stack argument takes two contiguous slots, not a split pair" );
    is( $win[0], 0,  "$triple: the first 128-bit stack pair starts at entry+0" );
    is( $win[1], 8,  "$triple: the high half follows the low half by one 8-byte step" );
}

# A function taking one i128 argument more than the register file can hold in
# pairs, returning the last one.  Its lowered form is the only place the
# pair-overflow decision is visible.
sub wide_func($count) {
    my $i128   = Brocken::Lindsay::IR::Type::i128();
    my @params = map { Brocken::Lindsay::IR::Value->new( name => "w$_", type => $i128 ) } 1 .. $count;
    my $func   = Brocken::Lindsay::IR::Function->new( name => 'wide', return_type => $i128, params => \@params );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( $params[-1] );
    return $func;
}

# None of this runs the machine code, and that is deliberate.  Each check
# lowers a function and reads the displacement of every stack operand, which is
# the only way to see that the two halves of the convention agree on a target
# this host cannot execute: the argument registers run out well past what a
# native build here would carry.
#
# The displacements alone are not the whole convention, though, and a check that
# reads them cannot see the two ways the value itself went missing on these
# targets while every offset stayed right.  So the pairs are also executed where
# an emulator is available, and skipped where one is not.
#
# A float return belongs in the first floating-point return register.  Sent to a
# general register instead, the function returned whatever the caller had left
# there, and because that register is also where the first floating-point
# argument arrives, a function returning its second argument returned its first.
#
# A capture of an argument from a register is a parallel move, and a parameter
# that arrived on the stack is read in the middle of it.  The register allocator
# reschedules the captures together, but it only sees the run that leads the
# block, so it used to stop at that read and leave the captures behind it in
# program order -- where one ran after another had already written the register
# it read, and a value arrived as its neighbour's.
exec_pairs();

sub exec_pairs () {
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        my $platform = Brocken::Katsuro::Platform::parse($triple);
        next unless cross_available($platform);

        # Both files full at once is the case the offsets alone never caught:
        # the integer file overflows, so its read lands among the floating-point
        # captures, and the last capture is the one that gets stranded.
        for my $case ( [ 7, 7 ], [ 8, 8 ], [ 10, 10 ] ) {
            my ( $nint, $nfloat ) = @$case;
            my ( @params, @args, @terms, $sum );
            $sum = 0;
            my ( $ni, $nf ) = ( $nint, $nfloat );

            # Interleaved, so the overflow is in the middle of the other file.
            for my $k ( 0 .. $nint + $nfloat - 1 ) {
                if ( $nf > 0 && ( $k % 2 == 1 || $ni == 0 ) ) {
                    my $v = $nf--;
                    push @params, "f64 \$f$v";
                    push @args,   "$v.0";
                    push @terms,  "\$f$v";
                    $sum += $v;
                }
                else {
                    my $v = $ni--;
                    push @params, "i64 \$i$v";
                    push @args,   "$v";
                    push @terms,  "\$i$v";
                    $sum += $v;
                }
            }
            my $src = sprintf "sub g(%s) -> f64 { return %s; } return g(%s);",
                join( ', ', @params ), join( ' + ', @terms ), join( ', ', @args );
            my $name = sprintf '%s: %d integer and %d floating-point arguments arrive intact',
                $triple, $nint, $nfloat;
            run_case( $platform, $class, $src, $sum, $name );

            # A float return read out of a general register came back as the
            # first float the caller passed, which is a wrong answer that no
            # offset check can see.
            my $ret = "sub h(f64 \$a, f64 \$b) -> f64 { return \$b; } return h(1.0, 6.0);";
            run_case( $platform, $class, $ret, 6,
                "$triple: a floating-point return lands in the floating-point return register" );
        }
    }
}

sub run_case ( $platform, $class, $src, $want, $name ) {
    my $brocken = eval { Brocken->new( platform => $platform ) } or return;
    my $binary  = temp_path( 'stack_args_' . $platform->arch . '_' . abs($want) );
    my $built   = eval {
        my $m = Brocken::Compiler->new->compile($src);
        $brocken->linker->write_executable( $binary, $brocken->codegen->emit_functions( $m->functions ), $platform );
        1;
    };
    if ( !$built ) { diag( "$name: did not build: $@" ); return }
    run_exec( $binary, platform => $platform, expected_exit => $want, name => $name );
}

done_testing;
