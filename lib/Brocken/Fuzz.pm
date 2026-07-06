use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Time::HiRes qw[time];

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

    method fuzz( $count = 100 ) {
        my @results;
        for my $i ( 1 .. $count ) {
            my $program = $self->generate_program( 20, 5 );
            my $result  = $self->test_program($program);
            push @results, $result;
            if ( $result->{status} ne 'pass' ) {
                my $host = $result->{host} // '(unknown)';
                my $msg  = sprintf "Fuzz #%d FAILED (seed=%d, host=%s): %s\n  Source:\n%s\n", $i, $seed, $host, $result->{reason}, $result->{source};
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
                my $host = $result->{host} // '(unknown)';
                my $msg  = sprintf "Fuzz #%d FAILED (seed=%d, host=%s): %s\n  Source:\n%s\n", $i, $seed, $host, $result->{reason}, $result->{source};
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
        warn sprintf "Fuzzing complete: %d iterations (%d pass, %d fail) in %.1fs (%.1f iters/sec)\n", $i, $n_pass, $n_fail, $elapsed, $i / $elapsed;
        return [];
    }

    method log_progress( $i, $count, $result ) {
        return;
    }

    # Generate a random Brocken program returning i64
    method generate_program( $max_ops = 15, $max_vars = 5 ) {
        my $vars = {};
        my @stmts;
        my $n_vars = $self->_rand_int($max_vars) + 1;

        # Declare variables with random initial values
        my @var_names;
        for my $vi ( 1 .. $n_vars ) {
            my $name = 'v' . $vi;
            my $init = $self->_rand_i64_val();
            push @var_names, $name;
            $vars->{$name} = $init;
            push @stmts, "my i64 \$$name = $init;";
        }

        # Generate random operations
        my $n_ops = $self->_rand_int($max_ops) + 1;
        for my $oi ( 1 .. $n_ops ) {
            my $stmt = $self->_random_stmt( $vars, \@var_names, $oi == $n_ops );
            push @stmts, $stmt->{code} if $stmt->{code};
        }
        my $result_var = $var_names[ $self->_rand_int($#var_names) ];
        push @stmts, "return \$$result_var;";
        my $source   = join "\n", @stmts;
        my $expected = $vars->{$result_var} & 0xFF;
        return { source => $source, expected => $expected, vars => $vars };
    }

    # Generate a single random statement
    method _random_stmt( $vars, $var_names, $is_last ) {
        my $type = $self->_rand_int(4);
        if ( $type == 0 && scalar( $var_names->@* ) >= 2 ) {
            return $self->_gen_binop_assign( $vars, $var_names );
        }
        elsif ( $type == 1 ) {
            return $self->_gen_unop_assign( $vars, $var_names );
        }
        elsif ( $type == 2 && scalar( $var_names->@* ) >= 2 && !$is_last ) {
            return $self->_gen_if_else( $vars, $var_names );
        }
        else {
            return $self->_gen_binop_assign( $vars, $var_names );
        }
    }

    method _gen_binop_assign( $vars, $var_names ) {
        my $dst = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $lhs = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $rhs = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $lv  = $vars->{$lhs};
        my $rv  = $vars->{$rhs};
        my $op;
        for my $try ( 0 .. 9 ) {
            $op = $self->_rand_binop();
            last unless defined $rv && $rv == 0 && ( $op eq '/' || $op eq '%' );
        }
        $op = '+' if defined $rv && $rv == 0 && ( $op eq '/' || $op eq '%' );
        return { code => "\$$dst = \$$lhs $op \$$rhs;" } unless defined $lv && defined $rv;
        my $result = $self->_eval_i64( $op, $lv, $rv );
        $vars->{$dst} = $result if defined $result;
        return { code => "\$$dst = \$$lhs $op \$$rhs;" };
    }

    method _gen_unop_assign( $vars, $var_names ) {
        my $dst = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $src = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $sv  = $vars->{$src};
        return { code => "\$$dst = -\$$src;" } unless defined $sv;
        $vars->{$dst} = -$sv;
        return { code => "\$$dst = -\$$src;" };
    }

    method _gen_if_else( $vars, $var_names ) {
        my $lhs     = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $rhs     = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $cmp     = $self->_rand_cmpop();
        my $lv      = $vars->{$lhs} // 0;
        my $rv      = $vars->{$rhs} // 0;
        my $cond    = $self->_eval_cmp( $cmp, $lv, $rv );
        my $var     = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $then_l  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $then_r  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $else_l  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $else_r  = $var_names->[ $self->_rand_int( $#{$var_names} ) ];
        my $then_rv = $vars->{$then_r} // 0;
        my $then_op;

        for my $try ( 0 .. 9 ) {
            $then_op = $self->_rand_binop();
            last unless $then_rv == 0 && ( $then_op eq '/' || $then_op eq '%' );
        }
        $then_op = '+' if $then_rv == 0 && ( $then_op eq '/' || $then_op eq '%' );
        my $else_rv = $vars->{$else_r} // 0;
        my $else_op;
        for my $try ( 0 .. 9 ) {
            $else_op = $self->_rand_binop();
            last unless $else_rv == 0 && ( $else_op eq '/' || $else_op eq '%' );
        }
        $else_op = '+' if $else_rv == 0 && ( $else_op eq '/' || $else_op eq '%' );
        my $then_v = $self->_eval_i64( $then_op, $vars->{$then_l} // 0, $then_rv );
        my $else_v = $self->_eval_i64( $else_op, $vars->{$else_l} // 0, $else_rv );
        $vars->{$var} = $cond ? $then_v : $else_v;
        return {
            code => join "\n",
            "if (\$$lhs $cmp \$$rhs) {", "    \$$var = \$$then_l $then_op \$$then_r;", "} else {", "    \$$var = \$$else_l $else_op \$$else_r;", "}"
        };
    }

    method _rand_binop() {
        my @ops = qw[+ - * / % & | ^];
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

    method _eval_cmp( $cmp, $l, $r ) {
        if ( $cmp eq '==' ) { return $l == $r }
        if ( $cmp eq '!=' ) { return $l != $r }
        if ( $cmp eq '<' )  { return $l < $r }
        if ( $cmp eq '>' )  { return $l > $r }
        if ( $cmp eq '<=' ) { return $l <= $r }
        if ( $cmp eq '>=' ) { return $l >= $r }
        return 0;
    }

    method _rand_i64_val() {
        return int( rand(200) ) - 100;
    }

    method _rand_int($max) {
        return int( rand( $max + 1 ) );
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
        my $result = { source => $program->{source}, status => 'pass', expected => $program->{expected}, host => $self->host_str };
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
