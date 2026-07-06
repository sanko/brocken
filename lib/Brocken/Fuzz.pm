package Brocken::Fuzz {
    use v5.42;
    use feature qw[class];
    no warnings qw[experimental::class];
    use Time::HiRes qw[time];

    # Utility subroutines callable as Brocken::Fuzz::encode_case_id(...)
    # without instantiating a Fuzz object.
    sub encode_case_id ( $seed, $case_num, $max_ops, $max_vars ) {
        return unpack 'H*', pack 'V V C C', $seed, $case_num, $max_ops, $max_vars;
    }

    sub decode_case_id ($id) {
        return unpack 'V V C C', pack 'H*', $id;
    }

    class Brocken::Fuzz {
        field $seed         : param = undef;
        field $bail_on_fail : param = 0;
        field $brocken      : reader;
        field $codegen      : reader;
        field $linker       : reader;
        field $host         : reader;
        field $host_str     : reader;
        field $tmpdir       : reader;
        field $ext          : reader;
        ADJUST {
            $seed //= int( rand(2147483647) );
            srand($seed);
            require Brocken;
            require Brocken::Compiler;
            my $b = Brocken->new();
            $brocken  = $b;
            $codegen  = $b->codegen;
            $linker   = $b->linker;
            $host     = $b->platform;
            $host_str = ref( $b->platform ) ? $b->platform->friendly : $b->platform;
            $tmpdir   = $b->tmpdir;
            $ext      = $b->ext;
        }
        method seed() { return $seed }

        # Encode a (seed, case_num, max_ops, max_vars) tuple into a compact
        # reversible hex string for use as a single-argument case identifier.
        method fuzz( $count = 100, $max_ops = 20, $max_vars = 5 ) {
            srand( $self->seed );
            my @results;
            for my $i ( 1 .. $count ) {
                my $program = $self->generate_program( $max_ops, $max_vars );
                my $result  = $self->test_program($program);
                my $case_id = encode_case_id( $seed, $i, $max_ops, $max_vars );
                $result->{case_num} = $i;
                $result->{max_ops}  = $max_ops;
                $result->{max_vars} = $max_vars;
                $result->{case_id}  = $case_id;
                push @results, $result;

                if ( $result->{status} ne 'pass' ) {
                    my $host = $result->{host} // '(unknown)';
                    my $msg  = sprintf "Fuzz #%d FAILED (id=%s, seed=%d, case=%d, max_ops=%d, max_vars=%d, host=%s): %s\n  Source:\n%s\n", $i,
                        $case_id, $seed, $i, $max_ops, $max_vars, $host, $result->{reason}, $result->{source};
                    if ($bail_on_fail) {
                        die $msg;
                    }
                    warn $msg;
                }
                $self->log_progress( $i, $count, $result );
            }
            return \@results;
        }

        method fuzz_until_time( $time_limit_sec = 300, $max_ops = 20, $max_vars = 5 ) {
            srand( $self->seed );
            my $start    = time;
            my $i        = 0;
            my $n_pass   = 0;
            my $n_fail   = 0;
            my $progress = 0;
            while (1) {
                $i++;
                my $program = $self->generate_program( $max_ops, $max_vars );
                my $result  = $self->test_program($program);
                if ( $result->{status} eq 'pass' ) {
                    $n_pass++;
                }
                else {
                    $n_fail++;
                    my $host    = $result->{host} // '(unknown)';
                    my $case_id = encode_case_id( $seed, $i, $max_ops, $max_vars );
                    my $msg     = sprintf "Fuzz #%d FAILED (id=%s, seed=%d, case=%d, max_ops=%d, max_vars=%d, host=%s): %s\n  Source:\n%s\n", $i,
                        $case_id, $seed, $i, $max_ops, $max_vars, $host, $result->{reason}, $result->{source};
                    if ($bail_on_fail) {
                        warn sprintf "Stopped after %d iterations (%d pass, 1 fail) in %.0fs\n", $i, $n_pass, time - $start;
                        die $msg;
                    }
                    warn $msg;
                }
                my $elapsed      = time - $start;
                my $new_progress = int( $elapsed / 30 );
                if ( $new_progress > $progress ) {
                    $progress = $new_progress;
                    warn sprintf "Progress: %d iterations (%d pass, %d fail) in %.0fs\n", $i, $n_pass, $n_fail, $elapsed;
                }
                last if $elapsed >= $time_limit_sec;
            }
            my $elapsed = time - $start;
            warn sprintf "Fuzzing complete: %d iterations (%d pass, %d fail) in %.1fs (%.1f iters/sec)\n", $i, $n_pass, $n_fail, $elapsed,
                $i / $elapsed;
            return [];
        }

        # Run a single specific fuzz case by index.  Reseeds srand to guarantee
        # deterministic output regardless of other objects or intervening calls
        # to rand().  Any (seed, case_num, max_ops, max_vars) tuple always
        # produces the same program, in any process or session.
        method run_case( $case_num, $max_ops = 20, $max_vars = 5 ) {
            srand( $self->seed );
            my $program;
            for my $i ( 1 .. $case_num ) {
                $program = $self->generate_program( $max_ops, $max_vars );
            }
            my $result = $self->test_program($program);
            $result->{case_num} = $case_num;
            $result->{max_ops}  = $max_ops;
            $result->{max_vars} = $max_vars;
            $result->{case_id}  = encode_case_id( $self->seed, $case_num, $max_ops, $max_vars );
            return $result;
        }

        method log_progress( $i, $count, $result ) {
            return;
        }

        # Generate a random Brocken program with typed variables
        method generate_program( $max_ops = 15, $max_vars = 5 ) {
            my $vars      = {};
            my $var_types = {};
            my @stmts;
            my $n_vars = $self->_rand_int($max_vars) + 1;

            # Declare variables with random types and initial values
            my @var_names;
            for my $vi ( 1 .. $n_vars ) {
                my $name = 'v' . $vi;
                push @var_names, $name;
                my ( $bits, $signed ) = $self->_rand_type();
                $var_types->{$name} = { bits => $bits, signed => $signed };
                my $init = $self->_rand_typed_val( $bits, $signed );
                $vars->{$name} = $init;
                my $keyword = $self->_type_keyword( $bits, $signed );
                push @stmts, "my $keyword \$$name = $init;";
            }

            # Generate random operations
            my $n_ops = $self->_rand_int($max_ops) + 1;
            for my $oi ( 1 .. $n_ops ) {
                my $stmt = $self->_random_stmt( $vars, $var_types, \@var_names, $oi == $n_ops );
                push @stmts, $stmt->{code} if $stmt->{code};
            }
            my $result_var = $var_names[ $self->_rand_int($#var_names) ];
            push @stmts, "return \$$result_var;";
            my $source   = join "\n", @stmts;
            my $expected = $vars->{$result_var} & 0xFF;
            return { source => $source, expected => $expected, vars => $vars };
        }

        # Generate a single random statement
        method _random_stmt( $vars, $var_types, $var_names, $is_last ) {
            my $n_vars  = scalar( $var_names->@* );
            my @i1_vars = grep { $var_types->{$_}{bits} == 1 } $var_names->@*;
            my $type    = $self->_rand_int(6);
            if ( $type == 0 ) {
                return $self->_gen_binop_assign( $vars, $var_types, $var_names );
            }
            elsif ( $type == 1 ) {
                return $self->_gen_unop_assign( $vars, $var_types, $var_names );
            }
            elsif ( $type == 2 && $n_vars >= 2 ) {
                return $self->_gen_cmp_assign( $vars, $var_types, $var_names );
            }
            elsif ( $type == 3 && $n_vars >= 2 && !$is_last ) {
                return $self->_gen_if_else( $vars, $var_types, $var_names );
            }
            elsif ( $type == 4 && scalar(@i1_vars) >= 2 ) {
                return $self->_gen_bool_binop( $vars, $var_types, $var_names );
            }
            elsif ( $type == 5 && scalar(@i1_vars) >= 1 ) {
                return $self->_gen_bool_unop( $vars, $var_types, $var_names );
            }
            else {
                return $self->_gen_binop_assign( $vars, $var_types, $var_names );
            }
        }

        method _gen_binop_assign( $vars, $var_types, $var_names ) {
            my $dst      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $lhs      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $rhs      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $lv       = $vars->{$lhs};
            my $rv       = $vars->{$rhs};
            my $dst_bits = $var_types->{$dst}{bits} // 64;
            my $op;
            for my $try ( 0 .. 9 ) {
                $op = $self->_rand_binop();
                last
                    unless defined $rv &&
                    ( ( $rv == 0 && ( $op eq '/' || $op eq '%' ) ) || ( ( $op eq '<<' || $op eq '>>' ) && ( $rv < 0 || $rv >= $dst_bits ) ) );
            }
            if ( defined $rv ) {
                $op = '+' if $rv == 0 && ( $op eq '/' || $op eq '%' );
                $op = '+' if ( $op eq '<<' || $op eq '>>' ) && ( $rv < 0 || $rv >= $dst_bits );
            }
            return { code => "\$$dst = \$$lhs $op \$$rhs;" } unless defined $lv && defined $rv;
            my $result = $self->_eval_i64_typed( $op, $lv, $rv, $var_types->{$lhs}, $var_types->{$rhs} );
            if ( defined $result ) {
                my $t = $var_types->{$dst};
                $vars->{$dst} = $self->_clamp_to_type( $result, $t->{bits}, $t->{signed} );
            }
            return { code => "\$$dst = \$$lhs $op \$$rhs;" };
        }

        method _gen_unop_assign( $vars, $var_types, $var_names ) {
            my $dst = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $src = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $sv  = $vars->{$src};
            return { code => "\$$dst = -\$$src;" } unless defined $sv;
            my $t = $var_types->{$dst};
            $vars->{$dst} = $self->_clamp_to_type( -$sv, $t->{bits}, $t->{signed} );
            return { code => "\$$dst = -\$$src;" };
        }

        method _gen_if_else( $vars, $var_types, $var_names ) {
            my $lhs      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $rhs      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $cmp      = $self->_rand_cmpop();
            my $lv       = $vars->{$lhs} // 0;
            my $rv       = $vars->{$rhs} // 0;
            my $cond     = $self->_eval_cmp_typed( $cmp, $lv, $rv, $var_types->{$lhs}, $var_types->{$rhs} );
            my $var      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $var_bits = $var_types->{$var}{bits} // 64;
            my $then_l   = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $then_r   = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $else_l   = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $else_r   = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $then_rv  = $vars->{$then_r} // 0;
            my $then_op;

            for my $try ( 0 .. 9 ) {
                $then_op = $self->_rand_binop();
                last
                    unless $then_rv == 0 && ( $then_op eq '/' || $then_op eq '%' ) ||
                    ( ( $then_op eq '<<' || $then_op eq '>>' ) && ( $then_rv < 0 || $then_rv >= $var_bits ) );
            }
            $then_op = '+' if $then_rv == 0 && ( $then_op eq '/' || $then_op eq '%' );
            $then_op = '+' if ( $then_op eq '<<' || $then_op eq '>>' ) && ( $then_rv < 0 || $then_rv >= $var_bits );
            my $else_rv = $vars->{$else_r} // 0;
            my $else_op;
            for my $try ( 0 .. 9 ) {
                $else_op = $self->_rand_binop();
                last
                    unless $else_rv == 0 && ( $else_op eq '/' || $else_op eq '%' ) ||
                    ( ( $else_op eq '<<' || $else_op eq '>>' ) && ( $else_rv < 0 || $else_rv >= $var_bits ) );
            }
            $else_op = '+' if $else_rv == 0 && ( $else_op eq '/' || $else_op eq '%' );
            $else_op = '+' if ( $else_op eq '<<' || $else_op eq '>>' ) && ( $else_rv < 0 || $else_rv >= $var_bits );
            my $then_v = $self->_eval_i64_typed( $then_op, $vars->{$then_l} // 0, $then_rv, $var_types->{$then_l}, $var_types->{$then_r} );
            my $else_v = $self->_eval_i64_typed( $else_op, $vars->{$else_l} // 0, $else_rv, $var_types->{$else_l}, $var_types->{$else_r} );
            my $t      = $var_types->{$var};
            $vars->{$var} = $self->_clamp_to_type( $cond ? $then_v : $else_v, $t->{bits}, $t->{signed} );
            return {
                code => join "\n",
                "if (\$$lhs $cmp \$$rhs) {", "    \$$var = \$$then_l $then_op \$$then_r;", "} else {", "    \$$var = \$$else_l $else_op \$$else_r;",
                "}"
            };
        }

        # Compare two variables and assign the boolean (1/0) result to a destination.
        method _gen_cmp_assign( $vars, $var_types, $var_names ) {
            my $dst  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $lhs  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $rhs  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $cmp  = $self->_rand_cmpop();
            my $lv   = $vars->{$lhs} // 0;
            my $rv   = $vars->{$rhs} // 0;
            my $cond = $self->_eval_cmp_typed( $cmp, $lv, $rv, $var_types->{$lhs}, $var_types->{$rhs} );
            my $t    = $var_types->{$dst};
            $vars->{$dst} = $self->_clamp_to_type( $cond ? 1 : 0, $t->{bits}, $t->{signed} );
            return { code => join( "\n", "if (\$$lhs $cmp \$$rhs) {", "    \$$dst = 1;", "} else {", "    \$$dst = 0;", "}" ), };
        }

        # Generate a boolean binary operation (and/or/xor) on i1-typed variables.
        method _gen_bool_binop( $vars, $var_types, $var_names ) {
            my @i1_vars = grep { $var_types->{$_}{bits} == 1 } $var_names->@*;
            my $dst     = $i1_vars[ $self->_rand_int($#i1_vars) ];
            my $lhs     = $i1_vars[ $self->_rand_int($#i1_vars) ];
            my $rhs     = $i1_vars[ $self->_rand_int($#i1_vars) ];
            my @bops    = qw[and or xor];
            my $bop     = $bops[ $self->_rand_int($#bops) ];
            my $lv      = $vars->{$lhs} ? 1 : 0;
            my $rv      = $vars->{$rhs} ? 1 : 0;
            my ( $sim_val, $code );

            if ( $bop eq 'and' ) {
                $sim_val = $lv && $rv;
                $code    = join( "\n", "if (\$$lhs) {", "    \$$dst = \$$rhs;", "} else {", "    \$$dst = 0;", "}" );
            }
            elsif ( $bop eq 'or' ) {
                $sim_val = $lv || $rv;
                $code    = join( "\n", "if (\$$lhs) {", "    \$$dst = 1;", "} else {", "    \$$dst = \$$rhs;", "}" );
            }
            else {    # xor
                $sim_val = $lv ^ $rv;
                $code    = "\$$dst = \$$lhs ^ \$$rhs;";
            }
            $vars->{$dst} = $self->_clamp_to_type( $sim_val, 1, 1 );
            return { code => $code };
        }

        # Generate a boolean unary operation (not) on i1-typed variables.
        method _gen_bool_unop( $vars, $var_types, $var_names ) {
            my @i1_vars = grep { $var_types->{$_}{bits} == 1 } $var_names->@*;
            my $dst     = $i1_vars[ $self->_rand_int($#i1_vars) ];
            my $src     = $i1_vars[ $self->_rand_int($#i1_vars) ];
            my $sv      = $vars->{$src} ? 1 : 0;
            $vars->{$dst} = $self->_clamp_to_type( $sv ? 0 : 1, 1, 1 );
            return { code => join( "\n", "if (\$$src) {", "    \$$dst = 0;", "} else {", "    \$$dst = 1;", "}" ), };
        }

        method _rand_binop() {
            my @ops = qw[+ - * / % & | ^ << >>];
            return $ops[ $self->_rand_int($#ops) ];
        }

        method _rand_cmpop() {
            my @ops = qw[== != < > <= >=];
            return $ops[ $self->_rand_int($#ops) ];
        }

        method _eval_i64( $op, $l, $r ) {
            return undef if $op eq '/' && $r == 0;
            return undef if $op eq '%' && $r == 0;
            use integer;
            if ( $op eq '+' )  { return $l + $r }
            if ( $op eq '-' )  { return $l - $r }
            if ( $op eq '*' )  { return $l * $r }
            if ( $op eq '/' )  { return int( $l / $r ) }
            if ( $op eq '%' )  { return $l % $r }
            if ( $op eq '&' )  { return $l & $r }
            if ( $op eq '|' )  { return $l | $r }
            if ( $op eq '^' )  { return $l ^ $r }
            if ( $op eq '<<' ) { return $l << $r }
            if ( $op eq '>>' ) { return $l >> $r }
            return undef;
        }

        # Reinterpret an unsigned value as signed of the given bit width.
        # This matches Brocken's codegen behavior: an unsigned value with the
        # high bit set, when loaded at its native width and used in a signed
        # operation (sdiv/idiv/setCC with signed condition), has its bit pattern
        # interpreted as a negative signed value.
        method _reinterpret_to_signed( $val, $bits ) {
            return $val if $bits >= 64;
            my $sign_bit = 1 << ( $bits - 1 );
            my $mask     = ( 1 << $bits ) - 1;
            my $wrapped  = $val & $mask;
            return $wrapped & $sign_bit ? $wrapped - ( 1 << $bits ) : $wrapped;
        }

        # Evaluate binary operation matching Brocken's semantics:
        # signed/unsigned choice from LHS type only; no common-type promotion.
        method _eval_i64_typed( $op, $lv, $rv, $lt, $rt ) {
            my $lsig = $lt->{signed} // 1;
            my $rsig = $rt->{signed} // 1;

            # When LHS is signed and RHS is unsigned, the RHS bit pattern
            # is used directly in the signed operation.  If the RHS's high
            # bit is set, reinterpret it as a signed negative value.
            if ( $lsig && !$rsig && ( $op eq '/' || $op eq '%' ) ) {
                my $signed_rv = $self->_reinterpret_to_signed( $rv, $rt->{bits} // 64 );
                return $self->_eval_i64( $op, $lv, $signed_rv );
            }

            # When LHS is unsigned and RHS is signed negative: unsigned op
            # treats the negative RHS as a huge positive (>= 2^63), so div
            # yields 0 and rem yields the LHS.
            if ( !$lsig && $rsig && $rv < 0 && ( $op eq '/' || $op eq '%' ) ) {
                return 0   if $op eq '/';
                return $lv if $op eq '%';
            }
            return $self->_eval_i64( $op, $lv, $rv );
        }

        method _eval_cmp( $cmp, $l, $r ) {
            if ( $cmp eq '==' ) { return $l == $r }
            if ( $cmp eq '!=' ) { return $l != $r }
            if ( $cmp eq '<' )  { return $l < $r }
            if ( $cmp eq '>' )  { return $l > $r }
            if ( $cmp eq '<=' ) { return $l <= $r }
            if ( $cmp eq '>=' ) { return $l >= $r }
            return 0;
        }

        # Evaluate comparison matching Brocken's semantics:
        # signed/unsigned choice from LHS type only; no common-type promotion.
        # When LHS is unsigned and RHS is signed negative, the RHS sign-extends
        # to >= 2^63 in unsigned interpretation, so comparisons with unsigned LHS
        # (< 2^63) have fixed outcomes.
        # When LHS is signed and RHS is unsigned with high bit set, the unsigned
        # RHS bit pattern is interpreted as signed negative (matching x86 codegen).
        method _eval_cmp_typed( $cmp, $lv, $rv, $lt, $rt ) {
            my $lsig = $lt->{signed} // 1;
            my $rsig = $rt->{signed} // 1;

            # LHS signed, RHS unsigned: reinterpret RHS as signed of its width
            if ( $lsig && !$rsig ) {
                my $signed_rv = $self->_reinterpret_to_signed( $rv, $rt->{bits} // 64 );
                return $self->_eval_cmp( $cmp, $lv, $signed_rv );
            }

            # LHS unsigned, RHS signed negative: unsigned comparison treats
            # negative RHS as >= 2^63, giving fixed outcomes for small LHS
            if ( !$lsig && $rsig && $rv < 0 ) {
                if ( $cmp eq '<' || $cmp eq '<=' ) { return 1 }
                if ( $cmp eq '>' || $cmp eq '>=' ) { return 0 }
                if ( $cmp eq '==' )                { return 0 }
                if ( $cmp eq '!=' )                { return 1 }
            }
            return $self->_eval_cmp( $cmp, $lv, $rv );
        }

        method _rand_i64_val() {
            return int( rand(200) ) - 100;
        }

        method _rand_int($max) {
            return int( rand( $max + 1 ) );
        }

        # Return a random integer type as (bits, signed) tuple.
        # Weighted toward wider types so clamping doesn't dominate early.
        # Unsigned types have lower weight than their signed counterparts.
        method _rand_type() {
            my @types = (
                [ 1,  1 ],    # i1  (bool)
                [ 8,  1 ],    # i8
                [ 8,  0 ],    # u8
                [ 16, 1 ],    # i16
                [ 16, 0 ],    # u16
                [ 32, 1 ],    # i32
                [ 32, 0 ],    # u32
                [ 64, 1 ],    # i64
                [ 64, 0 ],    # u64
            );
            my @weights = ( 1, 2, 1, 2, 1, 3, 2, 4, 2 );
            my $total   = 0;
            $total += $_ for @weights;
            my $r = $self->_rand_int( $total - 1 );
            for my $i ( 0 .. $#types ) {
                $r -= $weights[$i];
                return $types[$i]->@* if $r < 0;
            }
            return ( 64, 1 );
        }

        # Return the Brocken source-level type keyword for a (bits, signed) pair.
        method _type_keyword( $bits, $signed ) {
            return 'bool' if $bits == 1;
            return $signed ? "i$bits" : "u$bits";
        }

        # Clamp a Perl integer value to the range of a given integer type.
        # i1 returns 0 or 1.  Signed types use two's-complement wrapping.
        method _clamp_to_type( $val, $bits, $signed ) {
            return $val ? 1 : 0 if $bits == 1;
            return $val         if $bits >= 64 && $signed;
            if ( $bits >= 64 && !$signed ) {
                return $val < 0 ? 0 : $val;
            }
            use integer;
            my $mask    = ( 1 << $bits ) - 1;
            my $clamped = $val & $mask;
            if ( $signed && ( $clamped & ( 1 << ( $bits - 1 ) ) ) ) {
                $clamped -= ( 1 << $bits );
            }
            return $clamped;
        }

        # Generate a random value appropriate for the given type.
        method _rand_typed_val( $bits, $signed ) {
            return int( rand(2) ) if $bits == 1;
            if ( $bits >= 64 && !$signed ) {
                return int( rand( 2**31 - 1 ) ) + int( rand( 2**31 - 1 ) );
            }
            return $self->_clamp_to_type( $self->_rand_i64_val(), $bits, $signed );
        }

        # Break reference cycles in an IR Module to allow Perl GC to free it.
        method _release_module($module) {
            return unless $module;
            for my $func ( $module->functions->@* ) {
                for my $block ( $func->blocks->@* ) {
                    my $insts = $block->instructions;
                    @$insts = ();
                }
                $func->set_blocks( [] );
            }
        }

        # Break reference cycles in codegen output.
        method _release_funcs($funcs) {
            return unless $funcs && ref($funcs) eq 'ARRAY';
            for my $fd ( $funcs->@* ) {
                $fd->{fixups}     = undef if exists $fd->{fixups};
                $fd->{alloca_map} = undef if exists $fd->{alloca_map};
                $fd->{source_map} = undef if exists $fd->{source_map};
            }
        }

        # Compile and run a generated program, return test result
        method test_program($program) {
            my $result
                = { source => $program->{source}, status => 'pass', expected => $program->{expected}, host => $self->host_str, seed => $self->seed };
            my $module;
            eval {
                my $compiler = Brocken::Compiler->new();
                $module = $compiler->compile( $program->{source} );
            };
            if ( my $err = $@ ) {
                return { %$result, status => 'compile_fail', reason => "Compile: $err" };
            }
            my $funcs;
            eval { $funcs = $self->codegen->emit_functions( $module->functions ); };
            $self->_release_module($module);
            undef $module;
            if ( my $err = $@ ) {
                return { %$result, status => 'codegen_fail', reason => "Codegen: $err" };
            }
            my $file;
            eval {
                $file = $self->tmpdir . '/fuzz_output' . $self->ext;
                $self->linker->write_executable( $file, $funcs, $self->host );
            };
            $self->_release_funcs($funcs);
            undef $funcs;
            if ( my $err = $@ ) {
                unlink $file if $file;
                return { %$result, status => 'link_fail', reason => "Link: $err" };
            }
            my $exit_code;
            eval {
                system $file;
                $exit_code = $? >> 8;
                $exit_code = undef if $? == -1;
            };
            if ( my $err = $@ ) {
                unlink $file if $file;
                return { %$result, status => 'exec_fail', reason => "Exec: $err" };
            }
            unless ( defined $exit_code ) {
                unlink $file if $file;
                return { %$result, status => 'exec_fail', reason => 'System could not spawn process' };
            }
            unlink $file if $file;
            my $masked_expected = $program->{expected} & 0xFF;
            if ( $exit_code != $masked_expected ) {
                return {
                    %$result,
                    status => 'fail',
                    reason => "Expected " . $program->{expected} . " (masked $masked_expected), got $exit_code",
                    got    => $exit_code,
                };
            }
            return $result;
        }
    }

    # Run a fuzz case by its compact hex case_id.
    # Equivalent to decode_case_id($id) -> new(seed=N)->run_case(...).
    sub run_case_id ($case_id) {
        my ( $seed, $case_num, $max_ops, $max_vars ) = decode_case_id($case_id);
        my $fuzz = Brocken::Fuzz->new( seed => $seed );
        return $fuzz->run_case( $case_num, $max_ops, $max_vars );
    }
    1;
}
