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

        # Generate a random Brocken program with typed variables.
        # May include sub declarations and inter-procedural calls (Phase F2).
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
                my $init_val = $self->_rand_typed_val( $bits, $signed );
                $vars->{$name} = $init_val;
                my $keyword = $self->_type_keyword( $bits, $signed );
                my $fmt     = $self->_fmt_val( $init_val, $bits, $signed );
                push @stmts, "my $keyword \$$name = $fmt;";
            }

            # Optionally generate sub definitions (0-3)
            my @subs_meta;
            my $n_subs = $self->_rand_int(3);
            my %used_sub_names;
            for my $si ( 1 .. $n_subs ) {
                my $sub = $self->_gen_sub_decl( \%used_sub_names );
                next unless $sub && $sub->{code};
                push @subs_meta, $sub;
            }

            # Generate random operations (now with call support)
            my $n_ops = $self->_rand_int($max_ops) + 1;
            for my $oi ( 1 .. $n_ops ) {
                my $stmt = $self->_random_stmt( $vars, $var_types, \@var_names, $oi == $n_ops, \@subs_meta );
                push @stmts, $stmt->{code} if $stmt->{code};
            }
            my $result_var = $var_names[ $self->_rand_int($#var_names) ];
            if ( $var_types->{$result_var}{signed} eq 'f' ) {
                push @stmts, "my i64 \$__r0 = \$$result_var;";
                push @stmts, "return \$__r0;";
            }
            else {
                push @stmts, "return \$$result_var;";
            }

            # Compute whether we need 'brocken_native_types' for 128-bit types.
            # Check both top-level vars and sub body/param types.
            my $uses_big = scalar( grep { $var_types->{$_}{bits} >= 128 } keys $var_types->%* );
            if ( !$uses_big ) {
                for my $sub (@subs_meta) {
                    for my $p ( $sub->{params}->@* ) {
                        if ( $p->{bits} >= 128 ) { $uses_big = 1; last }
                    }
                    last if $uses_big;
                    for my $v ( values $sub->{body_var_types}->%* ) {
                        if ( $v->{bits} >= 128 ) { $uses_big = 1; last }
                    }
                    last if $uses_big;
                }
            }
            my $header   = $uses_big ? q{use feature 'brocken_native_types';} . "\n" : '';
            my $sub_code = join "\n\n", map { $_->{code} } @subs_meta;
            my $source   = $header . ( $sub_code ? "$sub_code\n\n" : '' ) . join "\n", @stmts;
            my $expected = $vars->{$result_var} & 0xFF;
            return { source => $source, expected => $expected, vars => $vars, subs => \@subs_meta };
        }

        # Generate a single random statement (optionally including function calls
        # when $subs_meta is non-empty).
        method _random_stmt( $vars, $var_types, $var_names, $is_last, $subs_meta = [] ) {
            my $n_vars     = scalar( $var_names->@* );
            my @i1_vars    = grep { $var_types->{$_}{bits} == 1 } $var_names->@*;
            my @f64_vars   = grep { $var_types->{$_}{signed} eq 'f' } $var_names->@*;
            my $n_f64_vars = scalar(@f64_vars);
            my $n_int_vars = $n_vars - $n_f64_vars;
            my $n_subs     = scalar( $subs_meta->@* );
            my $type       = $self->_rand_int( $n_subs >= 1 ? 13 : 12 );
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
            elsif ( $type == 6 && $n_f64_vars >= 2 ) {
                return $self->_gen_fbinop_assign( $vars, $var_types, $var_names );
            }
            elsif ( $type == 7 && $n_f64_vars >= 1 && $n_int_vars >= 1 ) {
                return $self->_gen_f2i_assign( $vars, $var_types, $var_names );
            }
            elsif ( $type == 8 && $n_f64_vars >= 1 && $n_int_vars >= 1 ) {
                return $self->_gen_mixed_binop_assign( $vars, $var_types, $var_names );
            }
            elsif ( $type == 9 && $n_vars >= 2 && !$is_last ) {
                return $self->_gen_while( $vars, $var_types, $var_names );
            }
            elsif ( $type == 10 && $n_vars >= 2 && !$is_last ) {
                return $self->_gen_nested_if( $vars, $var_types, $var_names );
            }
            elsif ( $type == 11 && $n_vars >= 2 && !$is_last ) {
                return $self->_gen_multi_cmp( $vars, $var_types, $var_names );
            }
            elsif ( $type == 12 && $n_subs >= 1 ) {
                return $self->_gen_call_assign( $vars, $var_types, $var_names, $subs_meta );
            }
            else {
                return $self->_gen_binop_assign( $vars, $var_types, $var_names );
            }
        }

        method _gen_binop_assign( $vars, $var_types, $var_names ) {
            my @int_names = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @int_names < 2;
            my $dst      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $lhs      = $int_names[ $self->_rand_int($#int_names) ];
            my $rhs      = $int_names[ $self->_rand_int($#int_names) ];
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
            my @int_names = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @int_names < 1;
            my $dst = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $src = $int_names[ $self->_rand_int($#int_names) ];
            my $sv  = $vars->{$src};
            return { code => "\$$dst = -\$$src;" } unless defined $sv;
            my $t = $var_types->{$dst};
            $vars->{$dst} = $self->_clamp_to_type( -$sv, $t->{bits}, $t->{signed} );
            return { code => "\$$dst = -\$$src;" };
        }

        method _gen_if_else( $vars, $var_types, $var_names ) {
            my @int_names = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @int_names < 2;
            my $lhs      = $int_names[ $self->_rand_int($#int_names) ];
            my $rhs      = $int_names[ $self->_rand_int($#int_names) ];
            my $cmp      = $self->_rand_cmpop();
            my $lv       = $vars->{$lhs} // 0;
            my $rv       = $vars->{$rhs} // 0;
            my $cond     = $self->_eval_cmp_typed( $cmp, $lv, $rv, $var_types->{$lhs}, $var_types->{$rhs} );
            my $var      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $var_bits = $var_types->{$var}{bits} // 64;
            my $then_l   = $int_names[ $self->_rand_int($#int_names) ];
            my $then_r   = $int_names[ $self->_rand_int($#int_names) ];
            my $else_l   = $int_names[ $self->_rand_int($#int_names) ];
            my $else_r   = $int_names[ $self->_rand_int($#int_names) ];
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
            my @int_names = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @int_names < 2;
            my $dst  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $lhs  = $int_names[ $self->_rand_int($#int_names) ];
            my $rhs  = $int_names[ $self->_rand_int($#int_names) ];
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

        # Generate a while loop with tracked expected values.
        # The condition compares two different int vars; the body contains
        # 1-3 simple assignments.  Simulation detects non-terminating
        # loops (max 1000 iterations) and skips generation.
        method _gen_while( $vars, $var_types, $var_names ) {
            my @int_names = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @int_names < 2;

            # Pick two DIFFERENT variables for the condition (same-var
            # comparison like $v >= $v is always true / non-terminating).
            my $cond_lhs = $int_names[ $self->_rand_int($#int_names) ];
            my $cond_rhs = $cond_lhs;
            for my $try ( 0 .. 9 ) {
                $cond_rhs = $int_names[ $self->_rand_int($#int_names) ];
                last if $cond_rhs ne $cond_lhs;
            }
            return { code => undef } if $cond_rhs eq $cond_lhs;
            my $cmp = $self->_rand_cmpop();

            # Generate 1-3 body statements
            my $n_body = $self->_rand_int(3) + 1;
            my @body_items;
            for my $bi ( 1 .. $n_body ) {
                my $item = $self->_gen_body_assign( $vars, $var_types, $var_names );
                push @body_items, $item if $item->{code};
            }
            return { code => undef } if @body_items == 0;

            # Snapshot $vars so we can roll back if we skip the loop.
            my @saved_vars_keys = keys %$vars;
            my %saved_vars;
            @saved_vars{@saved_vars_keys} = @$vars{@saved_vars_keys};

            # Simulate the loop to update expected variable values.
            # If we hit max_iter without the condition becoming false,
            # this is probably a non-terminating loop -- skip it.
            # A wall-clock timeout prevents pathological BigInt iterations
            # from hanging the simulation (e.g. on slow CI hardware).
            my $max_iter    = 1000;
            my $n_sim       = 0;
            my $sim_start   = time;
            my $sim_timeout = 2;
            for my $iter ( 1 .. $max_iter ) {
                last if time - $sim_start > $sim_timeout;
                my $lv = $vars->{$cond_lhs} // 0;
                my $rv = $vars->{$cond_rhs} // 0;
                last unless $self->_eval_cmp_typed( $cmp, $lv, $rv, $var_types->{$cond_lhs}, $var_types->{$cond_rhs} );
                $n_sim = $iter;
                for my $item (@body_items) {
                    $item->{apply}->();
                }
            }

            # If simulation ended with the condition still true (whether
            # by max_iter or wall-clock timeout), skip (non-terminating).
            my $lv_end = $vars->{$cond_lhs} // 0;
            my $rv_end = $vars->{$cond_rhs} // 0;
            if ( $n_sim > 0 && $self->_eval_cmp_typed( $cmp, $lv_end, $rv_end, $var_types->{$cond_lhs}, $var_types->{$cond_rhs} ) ) {
                @$vars{@saved_vars_keys} = @saved_vars{@saved_vars_keys};
                return { code => undef };
            }
            my $body_code = join "\n", map { "    " . $_->{code} } @body_items;
            return { code => "while (\$$cond_lhs $cmp \$$cond_rhs) {\n$body_code\n}" };
        }

        # Generate a single replayable body statement for use inside while/nested
        # blocks.  Returns { code => '...', apply => sub { ... } } where apply()
        # updates $vars to match the Brocken compiler's effect.
        method _gen_body_assign( $vars, $var_types, $var_names ) {
            my @int_names = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @int_names < 1;
            my $kind = $self->_rand_int(2);
            if ( $kind == 0 && @int_names >= 2 ) {

                # Binop: $dst = $lhs op $rhs
                my $dst      = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
                my $lhs      = $int_names[ $self->_rand_int($#int_names) ];
                my $rhs      = $int_names[ $self->_rand_int($#int_names) ];
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
                $op = '+' if defined $rv && $rv == 0 && ( $op eq '/' || $op eq '%' );
                $op = '+' if ( $op eq '<<' || $op eq '>>' ) && defined $rv && ( $rv < 0 || $rv >= $dst_bits );
                my $code  = "\$$dst = \$$lhs $op \$$rhs;";
                my $apply = sub {
                    my $lv2 = $vars->{$lhs};
                    my $rv2 = $vars->{$rhs};
                    return unless defined $lv2 && defined $rv2;
                    my $result = $self->_eval_i64_typed( $op, $lv2, $rv2, $var_types->{$lhs}, $var_types->{$rhs} );
                    if ( defined $result ) {
                        my $t = $var_types->{$dst};
                        $vars->{$dst} = $self->_clamp_to_type( $result, $t->{bits}, $t->{signed} );
                    }
                };
                return { code => $code, apply => $apply };
            }
            else {
                # Unop: $dst = -$src
                my $dst   = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
                my $src   = $int_names[ $self->_rand_int($#int_names) ];
                my $code  = "\$$dst = -\$$src;";
                my $apply = sub {
                    my $sv = $vars->{$src};
                    return unless defined $sv;
                    my $t = $var_types->{$dst};
                    $vars->{$dst} = $self->_clamp_to_type( -$sv, $t->{bits}, $t->{signed} );
                };
                return { code => $code, apply => $apply };
            }
        }

        # Generate an if/else whose branches contain 1-2 body statements
        # instead of a single assignment.  Uses _gen_body_assign for
        # simulation and replay, same as _gen_while.
        method _gen_nested_if( $vars, $var_types, $var_names ) {
            my @int_names = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @int_names < 2;
            my $cond_lhs = $int_names[ $self->_rand_int($#int_names) ];
            my $cond_rhs = $int_names[ $self->_rand_int($#int_names) ];
            my $cmp      = $self->_rand_cmpop();
            my $lv       = $vars->{$cond_lhs} // 0;
            my $rv       = $vars->{$cond_rhs} // 0;
            my $cond     = $self->_eval_cmp_typed( $cmp, $lv, $rv, $var_types->{$cond_lhs}, $var_types->{$cond_rhs} );
            my $n_then   = $self->_rand_int(2) + 1;
            my @then_items;

            for ( 1 .. $n_then ) {
                my $item = $self->_gen_body_assign( $vars, $var_types, $var_names );
                push @then_items, $item if $item->{code};
            }
            return { code => undef } if @then_items == 0;
            my @else_items;
            my $has_else = $self->_rand_int(1);
            if ($has_else) {
                my $n_else = $self->_rand_int(2) + 1;
                for ( 1 .. $n_else ) {
                    my $item = $self->_gen_body_assign( $vars, $var_types, $var_names );
                    push @else_items, $item if $item->{code};
                }
            }
            if ($cond) {
                for my $item (@then_items) { $item->{apply}->() }
            }
            elsif ($has_else) {
                for my $item (@else_items) { $item->{apply}->() }
            }
            my $then_code = join "\n", map { "    " . $_->{code} } @then_items;
            if ( $has_else && @else_items > 0 ) {
                my $else_code = join "\n", map { "    " . $_->{code} } @else_items;
                return { code => "if (\$$cond_lhs $cmp \$$cond_rhs) {\n$then_code\n} else {\n$else_code\n}" };
            }
            return { code => "if (\$$cond_lhs $cmp \$$cond_rhs) {\n$then_code\n}" };
        }

        # Generate a chained comparison condition:
        #   if ($v < $w && $x > $y) { $dst = 1; } else { $dst = 0; }
        # Uses && or || to combine two comparisons.
        method _gen_multi_cmp( $vars, $var_types, $var_names ) {
            my @int_names = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @int_names < 2;
            my $lhs1  = $int_names[ $self->_rand_int($#int_names) ];
            my $rhs1  = $int_names[ $self->_rand_int($#int_names) ];
            my $cmp1  = $self->_rand_cmpop();
            my $lhs2  = $int_names[ $self->_rand_int($#int_names) ];
            my $rhs2  = $int_names[ $self->_rand_int($#int_names) ];
            my $cmp2  = $self->_rand_cmpop();
            my $logic = $self->_rand_int(1) ? '&&' : '||';
            my $c1    = $self->_eval_cmp_typed( $cmp1, $vars->{$lhs1} // 0, $vars->{$rhs1} // 0, $var_types->{$lhs1}, $var_types->{$rhs1} );
            my $c2    = $self->_eval_cmp_typed( $cmp2, $vars->{$lhs2} // 0, $vars->{$rhs2} // 0, $var_types->{$lhs2}, $var_types->{$rhs2} );
            my $cond  = $logic eq '&&' ? ( $c1 && $c2 ) : ( $c1 || $c2 );
            my $dst   = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $t     = $var_types->{$dst};
            $vars->{$dst} = $self->_clamp_to_type( $cond ? 1 : 0, $t->{bits}, $t->{signed} );
            return { code =>
                    join( "\n", "if (\$$lhs1 $cmp1 \$$rhs1 $logic \$$lhs2 $cmp2 \$$rhs2) {", "    \$$dst = 1;", "} else {", "    \$$dst = 0;", "}" ),
            };
        }

        # Float binary ops (+, -, *, / only; no shift/bitwise for float)
        method _rand_fbinop() {
            my @ops = qw[+ - * /];
            return $ops[ $self->_rand_int($#ops) ];
        }

        method _rand_binop() {
            my @ops = qw[+ - * / % & | ^ << >>];
            return $ops[ $self->_rand_int($#ops) ];
        }

        method _rand_cmpop() {
            my @ops = qw[== != < > <= >=];
            return $ops[ $self->_rand_int($#ops) ];
        }

        # Evaluate a float binop using Perl's native float arithmetic.
        # Division by zero yields 0 (matches Brocken's defined behavior).
        method _eval_f64_binop( $op, $l, $r ) {
            if ( $op eq '+' ) { return $l + $r }
            if ( $op eq '-' ) { return $l - $r }
            if ( $op eq '*' ) { return $l * $r }
            if ( $op eq '/' ) { return $r != 0 ? $l / $r : 0 }
            return undef;
        }

        # Generate a float-to-int assignment (fptosi via maybe_convert_type).
        # Source is f64, destination is any int type.
        method _gen_f2i_assign( $vars, $var_types, $var_names ) {
            my @f64_vars = grep { $var_types->{$_}{signed} eq 'f' } $var_names->@*;
            my @int_vars = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @f64_vars < 1 || @int_vars < 1;
            my $src = $f64_vars[ $self->_rand_int($#f64_vars) ];
            my $dst = $int_vars[ $self->_rand_int($#int_vars) ];
            my $sv  = $vars->{$src};
            if ( defined $sv ) {
                my $t = $var_types->{$dst};
                $vars->{$dst} = $self->_clamp_to_type( int($sv), $t->{bits}, $t->{signed} );
            }
            return { code => "\$$dst = \$$src;" };
        }

        # Generate a mixed int/float binop assignment.
        # One operand is int, the other is f64.  The LHS determines the result
        # type; the Brocken compiler converts RHS to match via maybe_convert_type
        # (sitofp for int->float, fptosi for float->int).
        method _gen_mixed_binop_assign( $vars, $var_types, $var_names ) {
            my @f64_vars = grep { $var_types->{$_}{signed} eq 'f' } $var_names->@*;
            my @int_vars = grep { $var_types->{$_}{signed} ne 'f' } $var_names->@*;
            return { code => undef } if @f64_vars < 1 || @int_vars < 1;
            my $flip = $self->_rand_int(1);
            my $lhs  = $flip ? $int_vars[ $self->_rand_int($#int_vars) ] : $f64_vars[ $self->_rand_int($#f64_vars) ];
            my $rhs  = $flip ? $f64_vars[ $self->_rand_int($#f64_vars) ] : $int_vars[ $self->_rand_int($#int_vars) ];
            my $dst  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $lv   = $vars->{$lhs};
            my $rv   = $vars->{$rhs};
            my $op   = $self->_rand_fbinop();

            if ( defined $lv && defined $rv ) {
                if ( $op eq '/' && $rv == 0 ) { $op = '+' }
                my $result;
                if ($flip) {

                    # LHS is int, RHS is float: fptosi RHS, then int op
                    my $t   = $var_types->{$lhs};
                    my $irv = int($rv);
                    $result = $self->_eval_i64_typed( $op, $lv, $irv, $t, $t );
                }
                else {
                    # LHS is float, RHS is int: sitofp RHS, then float op
                    $result = $self->_eval_f64_binop( $op, $lv, $rv );
                }
                if ( defined $result ) {
                    my $t = $var_types->{$dst};
                    $vars->{$dst} = $self->_clamp_to_type( $result, $t->{bits}, $t->{signed} );
                }
            }
            return { code => "\$$dst = \$$lhs $op \$$rhs;" };
        }

        # Generate a float binop assignment between two f64 vars.
        # Dst is also f64; all three operands must be f64-typed.
        method _gen_fbinop_assign( $vars, $var_types, $var_names ) {
            my @f64_vars = grep { $var_types->{$_}{signed} eq 'f' } $var_names->@*;
            return { code => undef } if @f64_vars < 2;
            my $dst = $f64_vars[ $self->_rand_int($#f64_vars) ];
            my $lhs = $f64_vars[ $self->_rand_int($#f64_vars) ];
            my $rhs = $f64_vars[ $self->_rand_int($#f64_vars) ];
            my $lv  = $vars->{$lhs};
            my $rv  = $vars->{$rhs};
            my $op  = $self->_rand_fbinop();

            if ( defined $lv && defined $rv ) {
                if ( $op eq '/' && $rv == 0 ) { $op = '+' }
                my $result = $self->_eval_f64_binop( $op, $lv, $rv );
                if ( defined $result ) {
                    $vars->{$dst} = $self->_clamp_to_type( $result, 64, 'f' );
                }
            }
            return { code => "\$$dst = \$$lhs $op \$$rhs;" };
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

        # Evaluate a binary operation on 128-bit values using Math::BigInt.
        # Matches Brocken's i128 semantics (truncate-toward-zero division).
        method _eval_i128_binop( $op, $lv, $rv ) {
            require Math::BigInt;
            return undef if ( $op eq '/' || $op eq '%' ) && ( ref($rv) ? $rv->is_zero : $rv == 0 );
            my $l = ref($lv) && $lv->isa('Math::BigInt') ? $lv : Math::BigInt->new($lv);
            my $r = ref($rv) && $rv->isa('Math::BigInt') ? $rv : Math::BigInt->new($rv);
            if ( $op eq '+' ) { return $l + $r }
            if ( $op eq '-' ) { return $l - $r }
            if ( $op eq '*' ) { return $l * $r }
            if ( $op eq '/' ) {
                my ( $q, $rem ) = $l->copy->bdiv($r);
                return $q + 1 if $q < 0 && !$rem->is_zero;
                return $q;
            }
            if ( $op eq '%' )  { return $l->copy->bmod($r) }
            if ( $op eq '&' )  { return $l & $r }
            if ( $op eq '|' )  { return $l | $r }
            if ( $op eq '^' )  { return $l ^ $r }
            if ( $op eq '<<' ) { return $l << $r }
            if ( $op eq '>>' ) { return $l >> $r }
            return undef;
        }

        # Reinterpret an unsigned i128 value as signed two's complement.
        method _reinterpret_i128_to_signed($val) {
            require Math::BigInt;
            my $n    = ref($val) && $val->isa('Math::BigInt') ? $val->copy : Math::BigInt->new($val);
            my $sign = Math::BigInt->new(1) << 127;
            if ( $n >= $sign ) {
                $n = $n - ( Math::BigInt->new(1) << 128 );
            }
            return $n;
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
        # Delegates to i128 methods when operand width >= 128.
        method _eval_i64_typed( $op, $lv, $rv, $lt, $rt ) {
            my $bits = $lt->{bits} // 64;
            return $self->_eval_i128_typed( $op, $lv, $rv, $lt, $rt ) if $bits >= 128;
            my $lsig = $lt->{signed} // 1;
            my $rsig = $rt->{signed} // 1;

            # When LHS is signed and RHS is unsigned, the RHS bit pattern
            # is used directly in the signed operation.  Only when RHS is
            # same width or wider -- narrower types are zero-extended
            # (unsigned widen) by the compiler before division.
            if ( $lsig && !$rsig && ( $op eq '/' || $op eq '%' ) && $rt->{bits} >= $bits ) {
                my $signed_rv = $self->_reinterpret_to_signed( $rv, $rt->{bits} // 64 );
                return $self->_eval_i64( $op, $lv, $signed_rv );
            }

            # When LHS is unsigned and RHS is signed negative:
            # - If RHS is wider, the compiler promotes LHS to RHS type
            #   (signed) and performs a signed operation.
            # - Otherwise, the unsigned op treats negative RHS as a
            #   huge positive (>= 2^63), so div yields 0, rem yields LHS.
            if ( !$lsig && $rsig && $rv < 0 && ( $op eq '/' || $op eq '%' ) ) {
                if ( ( $rt->{bits} // 64 ) > $bits ) {
                    return $self->_eval_i64( $op, $lv, $rv );
                }
                return 0   if $op eq '/';
                return $lv if $op eq '%';
            }
            return $self->_eval_i64( $op, $lv, $rv );
        }

        # Evaluate binary operation for 128-bit types using Math::BigInt.
        # Handles signed/unsigned reinterpretation matching Brocken's codegen.
        method _eval_i128_typed( $op, $lv, $rv, $lt, $rt ) {
            my $lsig = $lt->{signed} // 1;
            my $rsig = $rt->{signed} // 1;
            if ( $lsig && !$rsig && ( $op eq '/' || $op eq '%' ) ) {
                my $signed_rv = $self->_reinterpret_i128_to_signed($rv);
                return $self->_eval_i128_binop( $op, $lv, $signed_rv );
            }
            if ( !$lsig && $rsig && ( $op eq '/' || $op eq '%' ) && $rv < 0 ) {
                return 0   if $op eq '/';
                return $lv if $op eq '%';
            }
            return $self->_eval_i128_binop( $op, $lv, $rv );
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
        # to >= 2^63 in unsigned interpretation.
        # Comparison width is the LHS type width (x86_64 uses 32-bit for types
        # with bits < 64, 64-bit otherwise).
        # When LHS is signed and RHS is unsigned with high bit set, the unsigned
        # RHS bit pattern is interpreted as signed negative (matching x86 codegen).
        method _eval_cmp_typed( $cmp, $lv, $rv, $lt, $rt ) {
            my $lsig  = $lt->{signed} // 1;
            my $rsig  = $rt->{signed} // 1;
            my $lbits = $lt->{bits}   // 64;
            return $self->_eval_cmp_i128( $cmp, $lv, $rv, $lt, $rt ) if $lbits >= 128;

            # LHS signed, RHS unsigned: reinterpret RHS as signed of its width.
            # Only when RHS is same width or wider -- narrower types are
            # zero-extended (unsigned widen) by the compiler before comparison.
            if ( $lsig && !$rsig && $rt->{bits} >= $lbits ) {
                my $signed_rv = $self->_reinterpret_to_signed( $rv, $rt->{bits} // 64 );
                return $self->_eval_cmp( $cmp, $lv, $signed_rv );
            }

            # LHS unsigned, RHS signed negative:
            # - If RHS is wider, the compiler promotes LHS to RHS type
            #   (signed) and does a signed comparison.
            # - Otherwise, the compiler promotes RHS to LHS type (unsigned)
            #   and does an unsigned comparison at LHS width.
            if ( !$lsig && $rsig && $rv < 0 && $lbits < 128 ) {
                if ( ( $rt->{bits} // 64 ) > $lbits ) {
                    return $self->_eval_cmp( $cmp, $lv, $rv );
                }
                my $mask = $lbits >= 64 ? ~0 : ( 1 << $lbits ) - 1;
                return $self->_eval_cmp( $cmp, $lv & $mask, $rv & $mask );
            }
            return $self->_eval_cmp( $cmp, $lv, $rv );
        }

        # Evaluate comparison for 128-bit types using Math::BigInt.
        method _eval_cmp_i128( $cmp, $lv, $rv, $lt, $rt ) {
            my $lsig = $lt->{signed} // 1;
            my $rsig = $rt->{signed} // 1;
            require Math::BigInt;
            my $l = ref($lv) && $lv->isa('Math::BigInt') ? $lv : Math::BigInt->new($lv);
            my $r = ref($rv) && $rv->isa('Math::BigInt') ? $rv : Math::BigInt->new($rv);
            if ( $lsig && !$rsig ) {
                $r = $self->_reinterpret_i128_to_signed($r);
                return $self->_eval_cmp( $cmp, $l, $r );
            }
            if ( !$lsig && $rsig && $r < 0 ) {
                return $self->_eval_cmp( $cmp, $l, $r );
            }
            return $self->_eval_cmp( $cmp, $l, $r );
        }

        method _rand_i64_val() {
            return int( rand(200) ) - 100;
        }

        method _rand_int($max) {
            return int( rand( $max + 1 ) );
        }

        # Return a random type as (bits, signed) tuple.
        # 'f' in signed field means f64.  Weighted toward wider int types.
        method _rand_type() {
            my @types = (
                [ 1,   1 ],      # i1  (bool)
                [ 8,   1 ],      # i8
                [ 8,   0 ],      # u8
                [ 16,  1 ],      # i16
                [ 16,  0 ],      # u16
                [ 32,  1 ],      # i32
                [ 32,  0 ],      # u32
                [ 64,  1 ],      # i64
                [ 64,  0 ],      # u64
                [ 64,  'f' ],    # f64
                [ 128, 1 ],      # i128
                [ 128, 0 ],      # u128
            );
            my @weights = ( 1, 2, 1, 2, 1, 3, 2, 4, 2, 2, 1, 1 );
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
            return 'f64'  if $signed eq 'f';
            return $signed ? "i$bits" : "u$bits";
        }

        # Format a typed value for embedding in Brocken source code.
        method _fmt_val( $val, $bits, $signed ) {
            return 'true'        if $bits == 1 && $val;
            return 'false'       if $bits == 1 && !$val;
            return "$val" . '.0' if $signed eq 'f';
            return "$val";
        }

        # Clamp a Perl value to the range of a given type.
        # For all integer types, the alloca is byte-granular and Store truncates
        # to the alloca byte width, so i1/i8 clamp to a single byte (0xFF),
        # i16 to 0xFFFF, etc.  This matches Brocken's maybe_convert_type behavior
        # which does NOT narrow int-to-int (full lower bytes are retained).
        # Signed types additionally apply two's-complement wrapping.
        # f64 values force float conversion (0.0 + $val) to match sitofp semantics
        # when int results are stored to f64 destinations by _gen_binop_assign etc.
        method _clamp_to_type( $val, $bits, $signed ) {
            return $val ? 1 : 0                        if $bits == 1;
            return 0.0 + $val                          if $signed eq 'f';
            return $self->_clamp_i128( $val, $signed ) if $bits >= 128;
            return $val                                if $bits >= 64 && $signed;
            if ( $bits >= 64 && !$signed ) {
                return $val & ~0;
            }
            use integer;
            my $mask    = ( 1 << $bits ) - 1;
            my $clamped = $val & $mask;
            if ( $signed && ( $clamped & ( 1 << ( $bits - 1 ) ) ) ) {
                $clamped -= ( 1 << $bits );
            }
            return $clamped;
        }

        # Clamp a value to signed/unsigned 128-bit range using Math::BigInt.
        # Defensively adds max to negative values before AND so that older
        # BigInt versions (pre-2.x) that don't two's-complement & on negatives
        # still produce the correct unsigned representation.
        method _clamp_i128( $val, $signed ) {
            require Math::BigInt;
            my $n    = ref($val) && $val->isa('Math::BigInt') ? $val->copy : Math::BigInt->new($val);
            my $max  = ( Math::BigInt->new(1) << 128 );
            my $mask = $max - 1;
            if ( $n < 0 ) { $n = $n + $max }
            $n = $n & $mask;
            if ( $signed && $n >= ( Math::BigInt->new(1) << 127 ) ) {
                $n = $n - $max;
            }
            return $n;
        }

        # Generate a random value appropriate for the given type.
        method _rand_typed_val( $bits, $signed ) {
            return int( rand(2) )                                                   if $bits == 1;
            return $self->_rand_f64_val()                                           if $signed eq 'f';
            return $self->_clamp_to_type( $self->_rand_i128_val(), $bits, $signed ) if $bits >= 128;
            if ( $bits >= 64 && !$signed ) {
                return int( rand( 2**31 - 1 ) ) + int( rand( 2**31 - 1 ) );
            }
            return $self->_clamp_to_type( $self->_rand_i64_val(), $bits, $signed );
        }

        # Generate a random i128 value (small range for initial testing).
        # Returns a Math::BigInt object.
        method _rand_i128_val() {
            require Math::BigInt;
            return Math::BigInt->new( int( rand(200) ) - 100 );
        }

        # Generate a random f64-compatible value (non-negative integer stored as
        # Perl float; avoids negative-literal parse concerns in declarations).
        method _rand_f64_val() {
            return int( rand(100) );
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

        # Run a compiled executable, optionally with args and output capture.
        # Returns { exit_code, stdout, stderr, error }.
        # When capture is not requested, uses the no-shell system($file, @$argv)
        # path for reliable exit-code propagation on all platforms.
        method _exec_program( $file, %opts ) {
            my $timeout        = $opts{timeout}        // 10;
            my $argv           = $opts{args}           // [];
            my $capture_stdout = $opts{capture_stdout} // 0;
            my $capture_stderr = $opts{capture_stderr} // 0;
            my $exit_code;
            my $stdout;
            my $stderr;
            my $error;

            if ( $capture_stdout || $capture_stderr ) {
                my $out_file;
                my $err_file;
                $out_file = $self->tmpdir . '/fuzz_stdout_' . $$ . '.tmp' if $capture_stdout;
                $err_file = $self->tmpdir . '/fuzz_stderr_' . $$ . '.tmp' if $capture_stderr;
                my $qfile = $file;
                $qfile = qq{"$qfile"} if $qfile =~ /\s/;
                my $cmd = $qfile;
                $cmd .= ' ' . join ' ', map { /\s/ ? qq{"$_"} : $_ } @$argv if @$argv;
                $cmd .= ' > ' . qq{"$out_file"}  if defined $out_file;
                $cmd .= ' 2> ' . qq{"$err_file"} if defined $err_file;
                eval {
                    local $SIG{ALRM} = sub { die "fuzz_timeout\n" };
                    alarm($timeout);
                    system $cmd;
                    alarm(0);
                };
                $error = $@;
                if ( defined $out_file && -e $out_file ) {
                    open my $fh, '<', $out_file or die "Cannot read $out_file: $!";
                    local $/;
                    $stdout = <$fh> // '';
                    close $fh;
                    unlink $out_file;
                }
                if ( defined $err_file && -e $err_file ) {
                    open my $fh, '<', $err_file or die "Cannot read $err_file: $!";
                    local $/;
                    $stderr = <$fh> // '';
                    close $fh;
                    unlink $err_file;
                }
            }
            else {
                eval {
                    local $SIG{ALRM} = sub { die "fuzz_timeout\n" };
                    alarm($timeout);
                    system( $file, @$argv );
                    alarm(0);
                };
                $error = $@;
            }
            unless ($error) {
                $exit_code = $? >> 8;
                $exit_code = undef if $? == -1;
            }
            return { exit_code => $exit_code, stdout => $stdout, stderr => $stderr, error => $error };
        }

        # Compile and run a generated program, return test result.
        # The program hash may include:
        #   source          - Brocken source code (required)
        #   expected        - expected integer return value (required)
        #   args            - arrayref of command-line arguments (optional)
        #   capture_stdout  - boolean, capture stdout into result (optional)
        #   capture_stderr  - boolean, capture stderr into result (optional)
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
            my $exec_result = $self->_exec_program(
                $file,
                args           => $program->{args}           // [],
                capture_stdout => $program->{capture_stdout} // 0,
                capture_stderr => $program->{capture_stderr} // 0,
                timeout        => 10,
            );
            if ( $exec_result->{error} ) {
                unlink $file if $file;
                my $reason = $exec_result->{error} =~ /fuzz_timeout/ ? "Exec: timeout" : "Exec: $exec_result->{error}";
                return { %$result, status => 'exec_fail', reason => $reason };
            }
            unless ( defined $exec_result->{exit_code} ) {
                unlink $file if $file;
                return { %$result, status => 'exec_fail', reason => 'System could not spawn process' };
            }
            unlink $file if $file;
            if ( $program->{capture_stdout} ) { $result->{stdout} = $exec_result->{stdout} }
            if ( $program->{capture_stderr} ) { $result->{stderr} = $exec_result->{stderr} }
            my $exit_code       = $exec_result->{exit_code};
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

        # -- Phase F2: Multi-function program support --
        # Generate a random sub declaration with typed params, local vars,
        # body statements, and a return statement.
        # Returns a metadata hashref suitable for _gen_call_assign / _simulate_call,
        # or undef if generation failed (e.g. no valid body statements).
        method _gen_sub_decl($used_names) {
            my @POOL  = qw[helper adder getval compute transform fold double triple];
            my @avail = grep { !$used_names->{$_} } @POOL;
            return undef if @avail == 0;
            my $name = $avail[ $self->_rand_int($#avail) ];
            $used_names->{$name} = 1;
            my $n_params = $self->_rand_int(3);    # 0-2 params
            my @params;
            my @param_names;

            for my $pi ( 1 .. $n_params ) {
                my ( $bits, $signed ) = $self->_gen_sub_body_type();
                my $pname = 'p' . $pi;
                push @params, { name => $pname, bits => $bits, signed => $signed };
                push @param_names, $pname;
            }
            my ( $ret_bits, $ret_signed ) = $self->_gen_sub_body_type();
            my $ret_keyword = $self->_type_keyword( $ret_bits, $ret_signed );

            # Body scope: params + local vars
            my $body_vars      = {};
            my $body_var_types = {};
            for my $p (@params) {
                $body_var_types->{ $p->{name} } = { bits => $p->{bits}, signed => $p->{signed} };
            }
            my $n_locals = $self->_rand_int(3) + 1;    # 1-3 locals, always at least 1
            my @local_names;
            my @local_decls;
            for my $li ( 1 .. $n_locals ) {
                my $lname = 'l' . $li;
                push @local_names, $lname;
                my ( $bits, $signed ) = $self->_gen_sub_body_type();
                $body_var_types->{$lname} = { bits => $bits, signed => $signed };
                my $init_val = $self->_rand_typed_val( $bits, $signed );
                $body_vars->{$lname} = $init_val;
                my $keyword = $self->_type_keyword( $bits, $signed );
                my $fmt     = $self->_fmt_val( $init_val, $bits, $signed );
                push @local_decls, "my $keyword \$$lname = $fmt;";
            }
            my @all_body_var_names = ( @param_names, @local_names );
            my $n_body             = $self->_rand_int(4) + 1;          # 1-4 body statements
            my @body_items;
            for my $bi ( 1 .. $n_body ) {
                my $item = $self->_gen_body_assign( $body_vars, $body_var_types, \@all_body_var_names );
                push @body_items, $item if $item->{code};
            }
            return undef if @body_items == 0;
            my $ret_var    = $all_body_var_names[ $self->_rand_int($#all_body_var_names) ];
            my $param_code = join ', ',     map { $self->_type_keyword( $_->{bits}, $_->{signed} ) . ' $' . $_->{name} } @params;
            my $body_code  = join "\n    ", @local_decls, map { $_->{code} } @body_items;
            my $code       = "sub $name($param_code) -> $ret_keyword {\n    $body_code\n    return \$$ret_var;\n}";
            return {
                name           => $name,
                params         => \@params,
                param_names    => \@param_names,
                return_type    => { bits => $ret_bits, signed => $ret_signed },
                return_var     => $ret_var,
                body_items     => \@body_items,
                body_vars      => $body_vars,
                body_var_types => $body_var_types,
                code           => $code,
            };
        }

        # Generate a function-call assignment: $dst = funcname($arg1, ...).
        # Picks a random previously-defined sub, matches args to param types
        # (preferring compatible existing vars, falling back to literals),
        # and simulates the call for expected-value tracking.
        method _gen_call_assign( $vars, $var_types, $var_names, $subs_meta ) {
            return { code => undef } if scalar( $subs_meta->@* ) < 1;
            my $dst = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
            my $sub = $subs_meta->[ $self->_rand_int( $#{$subs_meta} ) ];
            my @args;
            my @arg_codes;
            for my $p ( $sub->{params}->@* ) {
                my @compat = grep { $var_types->{$_}{bits} == $p->{bits} && $var_types->{$_}{signed} eq $p->{signed} } $var_names->@*;
                if (@compat) {
                    my $arg = $compat[ $self->_rand_int($#compat) ];
                    push @args,      $vars->{$arg};
                    push @arg_codes, '$' . $arg;
                }
                else {
                    my $val = $self->_rand_typed_val( $p->{bits}, $p->{signed} );
                    push @args,      $val;
                    push @arg_codes, $self->_fmt_val( $val, $p->{bits}, $p->{signed} );
                }
            }
            my $result;
            eval { $result = $self->_simulate_call( $sub, \@args ); };
            if ( defined $result && !$@ ) {
                my $t = $var_types->{$dst};
                $vars->{$dst} = $self->_clamp_to_type( $result, $t->{bits}, $t->{signed} );
            }
            my $code = "\$$dst = " . $sub->{name} . '(' . join( ', ', @arg_codes ) . ');';
            return { code => $code };
        }

        # Simulate a call to a sub defined by _gen_sub_decl.
        # Snapshots the sub's body_vars, binds params to arg values, applies all
        # body_items, reads the return variable, then restores the snapshot.
        # The snapshot/restore pattern keeps the sub's body_vars pristine for
        # subsequent calls in the same top-level program.
        method _simulate_call( $sub_meta, $args_av ) {
            my $body_vars = $sub_meta->{body_vars};
            my %snapshot  = %$body_vars;
            for my $i ( 0 .. $#{ $sub_meta->{params} } ) {
                my $p = $sub_meta->{params}[$i];
                $body_vars->{ $p->{name} } = $self->_clamp_to_type( $args_av->[$i], $p->{bits}, $p->{signed} );
            }
            for my $item ( $sub_meta->{body_items}->@* ) {
                $item->{apply}->();
            }
            my $result = $body_vars->{ $sub_meta->{return_var} };
            @{$body_vars}{ keys %snapshot } = values %snapshot;
            return $result;
        }

        # Return a random integer type (no float) suitable for sub body variables.
        # This keeps sub body operations simple (int-only binop/unop from
        # _gen_body_assign).
        method _gen_sub_body_type() {
            my @types   = ( [ 1, 1 ], [ 8, 1 ], [ 8, 0 ], [ 16, 1 ], [ 16, 0 ], [ 32, 1 ], [ 32, 0 ], [ 64, 1 ], [ 64, 0 ], [ 128, 1 ], [ 128, 0 ], );
            my @weights = ( 1, 2, 1, 2, 1, 3, 2, 4, 2, 1, 1 );
            my $total   = 0;
            $total += $_ for @weights;
            my $r = $self->_rand_int( $total - 1 );
            for my $i ( 0 .. $#types ) {
                $r -= $weights[$i];
                return $types[$i]->@* if $r < 0;
            }
            return ( 64, 1 );
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
