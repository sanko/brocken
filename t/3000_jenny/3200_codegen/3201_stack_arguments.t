use v5.42;
use Test2::V0 '!subtest';
use blib;
use Test2::Tools::Brocken qw[run_exec cross_available temp_path];
use Brocken;
use Brocken::Katsuro;
use Brocken::Lindsay;
use Brocken::Jenny;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

# Arguments past the end of a register file arrive on the stack.
#
# Each backend has a fixed number of argument registers per class, and nothing
# checked that a call stayed inside them: the caller indexed the register list past its end and built a `phys_reg`
# operand whose name was undefined, which the encoder refused with a warning rather than an error, and the callee read
# past its own list the same way.  The first symptom was a program that encoded without complaint and then passed the
# wrong values.
#
# Both halves are numbered the same way on purpose.  An overflowing argument is counted from zero -- not from the
# register index that ran out -- and the two register files are sized separately, so an integer that overflows is not
# charged against the floating-point one.  The caller writes it at a raw displacement off the stack pointer and the
# callee reads it from the stack pointer as it was on entry, both at 8 * $index.  The offset check below is
# what catches the two drifting apart: the callee once read its first stack argument at entry+64 while the caller wrote
# it at +0, which no encoding check notices.
#
# The outgoing area is reserved in the function's frame rather than pushed at the call, because the allocator's spill
# slots are stack displacements it
# computed before the call: moving sp at the call would invalidate every one of them, and it would also leave sp
# unaligned at a public interface.
#
# The structural checks run on every backend, including x86-64, which reaches
# the stack by the same two raw operands at different fixed offsets: the caller writes below its own frame pointer, the
# callee reads above the return address and any shadow space.  None of the structural checks execute, so all of it runs
# on any host.
#
# The trailing pair is the first incoming and outgoing stack displacement, which the convention places at different
# places on different targets.  AArch64 and RISC-V number both halves from zero, so the caller and the callee agree
# outright; x86-64 starts the outgoing area past the Win64 shadow space and reads the incoming area past the return
# address, which puts the two a fixed distance apart that the checks below have to account for rather than compare for
# equality.
my @TARGETS = (
    [ 'aarch64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::ARM64',   0,  0 ],
    [ 'riscv64-unknown-linux-gnu', 'Brocken::Jenny::Lowerer::RISCV64', 0,  0 ],
    [ 'x86_64-unknown-linux-gnu',  'Brocken::Jenny::Lowerer::X86_64',  0,  16 ],
    [ 'x86_64-pc-windows-msvc',    'Brocken::Jenny::Lowerer::X86_64',  32, 48 ],
);

sub lowered( $triple, $class, $src ) {
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $module   = Brocken->new->compile($src);
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
# The two hidden leading arguments every function carries are counted here too, so this overruns by design.
sub overflow_src($triple) {
    my $platform = Brocken::Katsuro::Platform::parse($triple);
    my $hidden   = 2;
    my $room     = scalar $platform->abi->param_registers->@* - $hidden;
    my $n        = $room + 3;
    my @params   = map {"i64 \$p$_"} 0 .. $n - 1;
    my @args     = map { $_ + 1 } 0 .. $n - 1;
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
    my ( $triple, $class, $out_base, $in_base ) = @$target;
    my ( $src,      $n )  = overflow_src($triple);
    my ( $platform, $mf ) = lowered( $triple, $class, $src );
    my ($callee) = grep {/^over/} keys %$mf;
    my ($caller) = grep { calls_named( $mf->{$_}, $callee ) } keys %$mf;
    ok( $callee && $caller, "$triple: the overflowing call and its callee were both lowered" ) or next;
    my @in  = sort { $a <=> $b } map { $_->{disp} } raw_slots( $mf->{$callee} );
    my @out = sort { $a <=> $b } map { $_->{disp} } raw_slots( $mf->{$caller} );
    ok( @in,  "$triple: the callee reads its $n-argument call from the stack" );
    ok( @out, "$triple: the caller writes its $n-argument call to the stack" );
    is( $in[0],  $in_base,                                       "$triple: the first incoming stack argument sits where the convention puts it" );
    is( $out[0], $out_base,                                      "$triple: the first outgoing stack argument sits where the convention puts it" );
    is( \@in,    [ map { $_ + ( $in_base - $out_base ) } @out ], "$triple: caller and callee number the stack arguments the same way" );
    is( $in[-1], ( $in[0] + 8 * ( scalar(@in) - 1 ) ),           "$triple: the incoming slots are contiguous 8-byte steps" );

    # A mixed overflow is the case that got the numbering wrong: the integer file runs out while the floating-point one
    # still has room, and the overflowing float must not be pushed along by the integer's count.
    my $fp    = $platform->abi->fp_param_registers;
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
    my @min       = sort { $a <=> $b } map { $_->{disp} } raw_slots( $mmf->{$mcallee} );
    my @mout      = sort { $a <=> $b } map { $_->{disp} } raw_slots( $mmf->{$mcaller} );
    is( $min[0], $in_base, "$triple: an integer overflowing does not push the floating-point stack index along" );
    is( \@min,   [ map { $_ + ( $in_base - $out_base ) } @mout ], "$triple: mixed overflow agrees on both sides" );

    # A 128-bit argument takes a consecutive register pair, so it goes to the stack whole when only one register is left
    # rather than straddling the two.
    # The surface language has no i128 parameter syntax yet, so this builds the function directly.  Two i128 arguments
    # plus one more overflow the pair on every backend here.
    my $regs  = $platform->abi->param_registers;
    my $pairs = int( scalar(@$regs) / 2 );

    # One argument fills each register pair, and the next has nowhere to go
    # but the stack, so the pairs that fit come first.
    my $wide = wide_func( $pairs + 1 );
    my $wmf  = $class->new( platform => $platform )->lower($wide);
    my @win  = sort { $a <=> $b } map { $_->{disp} } raw_slots($wmf);
    ok( @win, "$triple: the 128-bit argument that ran out of register pairs is read from the stack" );
    is( scalar(@win), 2,            "$triple: a 128-bit stack argument takes two contiguous slots, not a split pair" );
    is( $win[0],      $in_base,     "$triple: the first 128-bit stack pair starts where the convention starts it" );
    is( $win[1],      $in_base + 8, "$triple: the high half follows the low half by one 8-byte step" );
}

# A function taking one i128 argument more than the register file can hold in pairs, returning the last one.  Its
# lowered form is the only place the pair-overflow decision is visible.
sub wide_func($count) {
    my $i128    = Brocken::Lindsay::IR::Type::i128();
    my @params  = map { Brocken::Lindsay::IR::Value->new( name => "w$_", type => $i128 ) } 1 .. $count;
    my $func    = Brocken::Lindsay::IR::Function->new( name => 'wide', return_type => $i128, params => \@params );
    my $builder = Brocken::Lindsay::IR::Builder->new();
    $builder->position_at_end( $func->append_block('entry') );
    $builder->build_ret( $params[-1] );
    return $func;
}

# None of this runs the machine code, and that is deliberate.  Each check lowers a function and reads the displacement
# of every stack operand, which is the only way to see that the two halves of the convention agree on a target
# this host cannot execute: the argument registers run out well past what a native build here would carry.
#
# The displacements alone are not the whole convention, though, and a check that reads them cannot see the two ways the
# value itself went missing on these targets while every offset stayed right.  So the pairs are also executed where an
# emulator is available, and skipped where one is not.
#
# A float return belongs in the first floating-point return register.  Sent to a general register instead, the function
# returned whatever the caller had left there, and because that register is also where the first floating-point argument
# arrives, a function returning its second argument returned its first.
#
# A capture of an argument from a register is a parallel move, and a parameter that arrived on the stack is read in the
# middle of it.  The register allocator reschedules the captures together, but it only sees the run that leads the
# block, so it used to stop at that read and leave the captures behind it in program order -- where one ran after
# another had already written the register it read, and a value arrived as its neighbour's.
exec_pairs();

# The offsets above agree with each other and still say nothing about whether the caller has room to write them, which
# is the part that was missing on
# x86-64: the outgoing arguments were addressed off a captured copy of the stack pointer rather than the stack pointer
# itself, so nothing counted their size and the area the allocator had already handed out for spills and callee saves
# began at the bottom of the frame, right underneath them.  A call that overflowed the register file therefore wrote
# over its own saved registers, and the argument count where that first showed was well past what the convention can
# carry, so every check above was satisfied and the program still crashed.
#
# The reservation is what the fix is: the outgoing area is sized up front and taken out of the frame before anything
# else, so the two sets of displacements are disjoint by construction rather than by luck.  That is only visible after
# allocation, since the spill displacements are the allocator's to choose.
x86_outgoing_area();

sub x86_outgoing_area () {
    for my $target ( grep { $_->[0] =~ /x86_64/ } @TARGETS ) {
        my ( $triple, $class, $out_base, $in_base ) = @$target;
        my $brocken  = Brocken->new( platform => Brocken::Katsuro::Platform::parse($triple) );
        my $platform = $brocken->platform;
        my $codegen  = $brocken->codegen;

        # Three past the register file, so the outgoing area has to grow past
        # the Win64 shadow space it is otherwise floored at.
        my ( $src, $n ) = overflow_src($triple);
        my $module = Brocken->new->compile($src);
        for my $func ( $module->functions->@* ) {
            next unless $func->blocks->@*;
            my $fname = $func->name;
            my $mf    = $class->new( platform => $platform )->lower($func);
            next unless calls_named( $mf, 'over' );
            my $alloc = Brocken::Jenny::RegAlloc::LinearScan->new;
            my $int   = $alloc->allocate( $mf, $platform, 0 );
            $alloc->insert_spill_code( $mf, $int->{spill_slots}, $int->{spill_temp}, $platform->stack_reg, 0, $int->{spill_addr_temp} );
            my $fp = $alloc->allocate( $mf, $platform, 1 );
            $alloc->insert_spill_code( $mf, $fp->{spill_slots}, $fp->{spill_temp}, $platform->stack_reg, 1, $fp->{spill_addr_temp} );
            my $caller_base = $codegen->_caller_save_base( $int->{spill_slots}, $fp->{spill_slots} );
            $alloc->insert_caller_save_code( $mf, [ $platform->registers('caller')->@* ],    $platform->stack_reg, 0, $caller_base );
            $alloc->insert_caller_save_code( $mf, [ $platform->fp_registers('caller')->@* ], $platform->stack_reg, 1, $caller_base );

            # The alloca area is a plain sum of what the function asked for, and it sits between the outgoing area and
            # the spills, so it has to be added back to get from the allocator's displacement to the one the instruction
            # ends up encoding.
            my $alloca = 0;
            my ( @out, @reserved );
            for my $mbb ( $mf->blocks->@* ) {
                for my $inst ( $mbb->instructions->@* ) {
                    if ( $inst->opcode eq 'alloca' ) {
                        my ( undef, $size ) = $inst->operands->@*;
                        $alloca += $size->value;
                        $alloca = ( $alloca + 15 ) & ~15;
                    }
                    for my $op ( $inst->operands->@* ) {
                        next unless $op->kind eq 'mem';
                        my $addr = $op->value;
                        next unless defined $addr->{base} && !ref $addr->{base} && $addr->{base} eq $platform->stack_reg;
                        my $disp = $addr->{disp} // 0;

                        # A raw displacement is the convention's and is encoded where it is written down.  Everything
                        # else is the allocator's and is shifted past the outgoing area, and that shift is what has to
                        # clear the top of it.
                        if    ( $addr->{raw} && $addr->{raw} ne 'entry' ) { push @out,      $disp }
                        elsif ( !$addr->{raw} )                           { push @reserved, $disp }
                    }
                }
            }
            @out      = sort { $a <=> $b } @out;
            @reserved = sort { $a <=> $b } @reserved;

            # The area the backend takes out for the outgoing arguments.  A backend that never had this had nowhere to
            # count them, which is the whole of the bug, so a missing reservation is a failure here rather than a reason
            # to skip.
            my $sizer = $codegen->can('_compute_call_arg_frame') ? '_compute_call_arg_frame'                     : undef;
            my $area  = $sizer                                   ? $codegen->$sizer( $mf, $platform->stack_reg ) : -1;
            ok( @out, "$triple: the $n-argument call in $fname writes $n-2 arguments to the stack" );
            is( $out[0], $out_base, "$triple: $fname writes the first overflowing argument where the convention puts it" );
            ok( $area >= ( $out[-1] + 8 ), "$triple: $fname reserves room for its whole outgoing area" );

            # The lowest spill and callee-save slot, once shifted into the frame by the alloca and outgoing areas, has
            # to sit above the topmost outgoing argument.  A frame that reserved nothing leaves both at zero, and the
            # call writes its arguments straight over them.
            my $lowest = scalar(@reserved) ? $reserved[0] + $alloca + $area : $area;
            ok( $lowest > $out[-1], "$triple: the outgoing area in $fname does not overlap the spill and callee-save area" );
        }
    }
}

sub exec_pairs () {
    for my $target (@TARGETS) {
        my ( $triple, $class ) = @$target;
        my $platform = Brocken::Katsuro::Platform::parse($triple);
        next unless cross_available($platform);

        # Both files full at once is the case the offsets alone never caught: the integer file overflows, so its read
        # lands among the floating-point captures, and the last capture is the one that gets stranded.
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
            my $src  = sprintf "sub g(%s) -> f64 { return %s; } return g(%s);", join( ', ', @params ), join( ' + ', @terms ), join( ', ', @args );
            my $name = sprintf '%s: %d integer and %d floating-point arguments arrive intact', $triple, $nint, $nfloat;
            run_case( $platform, $class, $src, $sum, $name );

            # A float return read out of a general register came back as the first float the caller passed, which is a
            # wrong answer that no offset check can see.
            my $ret = "sub h(f64 \$a, f64 \$b) -> f64 { return \$b; } return h(1.0, 6.0);";
            run_case( $platform, $class, $ret, 6, "$triple: a floating-point return lands in the floating-point return register" );
        }
    }
}

sub run_case ( $platform, $class, $src, $want, $name ) {
    my $brocken = eval { Brocken->new( platform => $platform ) } or return;
    my $binary  = temp_path( 'stack_args_' . $platform->arch . '_' . abs($want) );
    my $built   = eval {
        my $m = Brocken->new->compile($src);
        $brocken->linker->write_executable( $binary, $brocken->codegen->emit_functions( $m->functions ), $platform );
        1;
    };
    if ( !$built ) { diag("$name: did not build: $@"); return }
    run_exec( $binary, platform => $platform, expected_exit => $want, name => $name );
}
done_testing;
