use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
class Brocken::Katsuro::Lowerer v0.0.1 {
    use Brocken::Lindsay::IR;
    use Brocken::Lindsay::IR::Builder;
    use Brocken::ICB;
    use Carp ();
    field $module       : param = Brocken::Lindsay::IR::Module->new( name => 'main' );
    field $platform     : reader : param = undef;
    field $fuel         : param = $Brocken::default_fuel;
    field $mem_limit    : param = $Brocken::default_mem_limit;
    field $capabilities : param = $Brocken::default_capabilities;
    field $builder = Brocken::Lindsay::IR::Builder->new();
    field $current_func;
    field $current_block;
    field $current_class;                     # class name when inside a method/ADJUST
    field $current_package;                   # namespace from the innermost `package NAME` (see _qualify)
    field $symbols   = {};                    # "name" -> ptr (alloca or GEP result)
    field $functions = {};                    # "name" -> Brocken::Lindsay::IR::Function
    field $classes          : reader = {};    # "ClassName" -> { fields => [...], total_size => N, methods => [...], struct_type => T }
    field $package_versions : reader = {};    # "Package::Name" -> declared version, from `package NAME VERSION`
    field $block_id              = 0;
    field $value_id              = 0;         # monotonic counter making local SSA storage names unique
    field $var_class             = {};        # var_name -> class_name (for ptr vars from constructors)
    field $function_return_class = {};        # func_name -> class_name (for functions returning a class ptr)
    field $param_defaults        = {};        # "name" -> [ {name, default}, ... ] per user parameter, for omitted trailing args
    field $needs_rc              = {};        # var_name -> 1 (RC-tracked variable: an Any box or a class instance)
    field $rc_owner              = {};        # var_name -> owning $_dyn_scope_stack entry (declaring block/loop scope)
    field $class_owned           = {};        # var_name -> class_name (an owned class instance; released through its destructor)
    field $class_escaped         = {};        # var_name -> 1 (used as a value, so its instance must not be reclaimed)
    field $borrowed_params       = {};        # param_name -> 1 (caller-owned Any parameter; the callee must not release it)
    field $weak_var              = {};        # var_name -> 1 (a weak local: it stores without owning a reference)
    field $returns_owned         = {};        # func_name -> 1 (a dynamic return hands the caller an owned +1 reference)
    field $class_returns_owned   = {};        # func_name -> 1 (a class-returning call hands the caller an owned instance)
    field $array_elem_types      = {};        # '@name' -> element IR type (for heap-array GEP scaling)
    field $array_counts          = {};        # '@name' -> compile-time element count, when it is a constant
    field $growable_arrays       = {};        # '@name' -> element-type name for a runtime-sized (growable) local array
    field $array_owned_elem      = {};        # '@name' -> 1 (heap array whose `Any` elements are owned; released by array_release)
    field $hash_var              = {};        # var_name -> 1 (a local %hash; its slot holds a tag-8 table released by hash_release)
    field $hash_value_type       = {};        # var_name -> IR type of the hash's stored values (defaults to dynamic)
    field $rodata : reader       = {};        # label -> bytes for string constants
    field $_rodata_label_counter = 0;
    field $writer_map            = {};        # "Class::name" -> class name (auto-generated writers return their receiver)
    field $_loop_header_blocks   = [];        # stack of header block labels
    field $_loop_check_blocks    = [];        # stack of iteration-check block labels (counter guard)
    field $_loop_exit_blocks     = [];        # stack of exit block labels for break (last)
    field $_loop_body_scopes     = [];        # stack of dynamic-stack scopes opened for each in-progress loop body
    field $_loop_handler_depths  = [];        # stack of $_try_handler_depth at each loop's entry, so `last`/`next` pop what a `try` inside the loop body pushed
    field $_try_handler_depth    = 0;         # number of try-body exception handlers pushed and not yet popped, so `return` can pop them
    field $_dyn_scope_stack      = [];        # stack of scope records for each in-progress block/loop (RC ownership)
    field $fuel_exit_block;                   # set in lower_function, used by call-site fuel checks
    field $_want_override = undef;            # i64 mask forced on a call while lowering a context that consumes a list (e.g. a `for` iterable)

    method unique_block_name($prefix) {
        return $prefix . '_' . $block_id++;
    }

    # Local storage names must be unique across a function: the codegen resolves every operand through its SSA
    # name, so an alloca `%c.addr` and a field GEP `%c.addr` would otherwise alias each other and a later load would
    # read the wrong storage. Every user local goes through here; the fixed `%__heap_base.addr` / `%self.addr` slots
    # and the parameter spill slots keep their conventional names (DWARF derives them).
    method unique_value_name($base) {
        return $base . '.' . ( $value_id++ );
    }

    # Field attribute records -- Parser stores each attribute as { name => 'reader', arg => undef } and
    # { name => 'param', arg => 'amount' } -- so accessor/param naming can consult the custom-name payload.
    method attr_rec( $recs, $name ) {
        for my $r ( $recs->@* ) { return $r if $r->{name} eq $name; }
        return undef;
    }

    method has_attr( $recs, $name ) {
        return defined $self->attr_rec( $recs, $name );
    }

    method attr_arg( $recs, $name ) {
        my $r = $self->attr_rec( $recs, $name );
        return defined $r ? $r->{arg} : undef;
    }

    # Perl strips exactly one leading underscore when deriving a default accessor/param name from a field named
    # `$_foo`, and `$__bar` keeps one underscore:  _foo -> foo, __bar -> _bar.
    method strip_underscore($name) {
        $name =~ s/^_//;
        return $name;
    }
    my %TYPE_MAP = (
        i1     => Brocken::Lindsay::IR::Type::i1(),
        i8     => Brocken::Lindsay::IR::Type::i8(),
        i16    => Brocken::Lindsay::IR::Type::i16(),
        i32    => Brocken::Lindsay::IR::Type::i32(),
        i64    => Brocken::Lindsay::IR::Type::i64(),
        i128   => Brocken::Lindsay::IR::Type::i128(),
        u8     => Brocken::Lindsay::IR::Type::u8(),
        u16    => Brocken::Lindsay::IR::Type::u16(),
        u32    => Brocken::Lindsay::IR::Type::u32(),
        u64    => Brocken::Lindsay::IR::Type::u64(),
        u128   => Brocken::Lindsay::IR::Type::u128(),
        f32    => Brocken::Lindsay::IR::Type::f32(),
        f64    => Brocken::Lindsay::IR::Type::f64(),
        ptr    => Brocken::Lindsay::IR::Type::ptr(),
        void   => Brocken::Lindsay::IR::Type::void(),
        int    => Brocken::Lindsay::IR::Type::i64(),
        bool   => Brocken::Lindsay::IR::Type::i1(),
        Int    => Brocken::Lindsay::IR::Type::i64(),
        Float  => Brocken::Lindsay::IR::Type::f64(),
        Bool   => Brocken::Lindsay::IR::Type::i1(),
        Any    => Brocken::Lindsay::IR::Type::dynamic(),
        String => Brocken::Lindsay::IR::Type::ptr()
    );

    # Native representation types for constants (never dynamic/boxed)
    my %TYPE_NATIVE_MAP = (
        int    => Brocken::Lindsay::IR::Type::i64(),
        bool   => Brocken::Lindsay::IR::Type::i1(),
        Int    => Brocken::Lindsay::IR::Type::i64(),
        Bool   => Brocken::Lindsay::IR::Type::i1(),
        Any    => Brocken::Lindsay::IR::Type::i64(),
        String => Brocken::Lindsay::IR::Type::ptr(),
        i1     => Brocken::Lindsay::IR::Type::i1(),
        i8     => Brocken::Lindsay::IR::Type::i8(),
        i16    => Brocken::Lindsay::IR::Type::i16(),
        i32    => Brocken::Lindsay::IR::Type::i32(),
        i64    => Brocken::Lindsay::IR::Type::i64(),
        i128   => Brocken::Lindsay::IR::Type::i128(),
        u8     => Brocken::Lindsay::IR::Type::u8(),
        u16    => Brocken::Lindsay::IR::Type::u16(),
        u32    => Brocken::Lindsay::IR::Type::u32(),
        u64    => Brocken::Lindsay::IR::Type::u64(),
        u128   => Brocken::Lindsay::IR::Type::u128(),
        f32    => Brocken::Lindsay::IR::Type::f32(),
        f64    => Brocken::Lindsay::IR::Type::f64(),
        ptr    => Brocken::Lindsay::IR::Type::ptr(),
        void   => Brocken::Lindsay::IR::Type::void()
    );

    method _loc($ast) {
        my $f = $ast->file // '';
        my $l = $ast->line // 0;
        my $c = $ast->col  // 0;
        return $f ? "$f line $l, col $c" : "line $l, col $c";
    }

    method type_from_name($name) {
        return $TYPE_MAP{$name} // Carp::croak("Unknown type '$name'");
    }

    # Prefix a bare declaration name with its package. A name that already contains `::` is absolute, so
    # `package P; sub P::x` stays `P::x` rather than becoming `P::P::x`.
    method _qualify( $name, $package ) {
        return $name unless defined $package && length $package;
        return $name if index( $name, '::' ) >= 0;
        return $package . '::' . $name;
    }

    # Resolve a class name as written inside the current package: a declared fully-qualified name first, then the bare
    # spelling (for classes declared at the top level and referenced from another package).
    method _resolve_class_ident($name) {
        return $name if $classes->{$name};
        if ( defined $current_package && length $current_package ) {
            my $qualified = $current_package . '::' . $name;
            return $qualified if $classes->{$qualified};
        }
        return $name;
    }

    method native_type_from_name($name) {
        return $TYPE_NATIVE_MAP{$name} // $self->type_from_name($name);
    }

    # Type size in bytes for field offset calculation. A sub-byte integer (`i1`/`bool`) still occupies one byte of
    # storage, so it rounds up rather than returning a fraction.
    method type_size($ir_type) {
        return 0 if $ir_type->kind eq 'void';
        return 8 if $ir_type->kind eq 'ptr' || $ir_type->kind eq 'dynamic';
        if ( $ir_type->kind eq 'int' || $ir_type->kind eq 'float' ) {
            my $bytes = $ir_type->bits / 8;
            return $bytes < 1 ? 1 : $bytes;
        }
        return 8;
    }

    # Natural alignment of a field. A field is placed at the next multiple of this, so mixed widths leave the gaps
    # the target ABI expects (`i64` after `i8` starts at an 8-byte boundary). The object header is 8 bytes, so every
    # instance starts 8-aligned.
    method type_align($ir_type) {
        return 8 if $ir_type->kind eq 'ptr' || $ir_type->kind eq 'dynamic';
        if ( $ir_type->kind eq 'int' || $ir_type->kind eq 'float' ) {
            my $bytes = $ir_type->bits / 8;
            return $bytes < 1 ? 1 : $bytes;
        }
        return 1;
    }

    method _align_up( $value, $align ) {
        return $value if $align <= 1;
        return ( $value + $align - 1 ) & ~( $align - 1 );
    }

    # Decide whether a dynamic-returning function hands the caller an owned reference (+1) or a borrowed one (+0).
    # Caller-Borrows means a bare `return $param` yields the caller's own box, so no reference changes hands and the
    # caller must incref when it stores the result (F3). Every other dynamic return -- a local, a fresh box, a field
    # load, or a nested call -- yields a reference the callee owns and transfers, so the caller must not incref again
    # (F13). A function is owned if any dynamic return is not a bare, never-reassigned `Any` parameter; a parameter that
    # is assigned has been promoted to an owned slot and no longer qualifies. Owned functions normalize every dynamic
    # return to +1 in `lower_return`, so a single flag describes the whole function even when its returns mix.
    method _classify_return_ownership( $name, $return_type_name, $params_ast, $body, $field_names = {} ) {
        return unless defined $return_type_name && $return_type_name eq 'Any';
        my %any_param = map { $_->{name} => 1 } grep { ( $_->{type} // 'Any' ) eq 'Any' } $params_ast->@*;
        my %assigned;
        my %locals;
        my @returns;
        $self->_scan_function_body( $body, \%assigned, \%locals, \@returns );
        my $owned = 0;
        for my $expr (@returns) {
            if ( defined $expr && $expr->isa('Brocken::Katsuro::AST::Expr::Var') ) {
                my $n = $expr->name;

                # A bare value the callee does not own is handed back unchanged, so the caller owns the box it stores
                # and must incref. Two cases qualify: a local shadow always wins (the exit cleanup will free it, so it
                # is owned), otherwise a field (the object owns the box) or a parameter that is never reassigned (the
                # caller owns the box, Caller-Borrows). An assigned parameter has been promoted to an owned slot.
                next if !$locals{$n} && ( $field_names->{$n} || ( $any_param{$n} && !$assigned{$n} ) );
            }
            $owned = 1;
            last;
        }
        $returns_owned->{$name} = $owned;
    }

    # Collect the local variable names, assignment targets, and return expressions anywhere in a function body.
    # Assignment is a statement, so the walk only descends statement containers; nested blocks, branches, and loops are
    # followed so a declaration or assignment on any path counts.
    method _scan_function_body( $block, $assigned, $locals, $returns, $fresh = undef ) {
        return unless $block;
        for my $stmt ( $block->statements->@* ) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::VarDecl') ) {
                $locals->{ $stmt->name } = 1;
                $fresh->{ $stmt->name } = 1 if $fresh && $self->_is_fresh_construction( $stmt->init );
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ListVarDecl') ) {
                $locals->{ $_->{name} } = 1 for $stmt->targets->@*;
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Assign') ) {
                my $t = $stmt->target;
                $assigned->{ $t->name } = 1 if $t->isa('Brocken::Katsuro::AST::Expr::Var');
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Return') ) {
                push @$returns, $stmt->expr;
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Block') ) {
                $self->_scan_function_body( $stmt, $assigned, $locals, $returns, $fresh );
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::If') ) {
                $self->_scan_function_body( $stmt->then, $assigned, $locals, $returns, $fresh );
                for my $e ( $stmt->elsif->@* ) { $self->_scan_function_body( $e->[1], $assigned, $locals, $returns, $fresh ); }
                $self->_scan_function_body( $stmt->else, $assigned, $locals, $returns, $fresh ) if $stmt->else;
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::While') ) {
                $self->_scan_function_body( $stmt->body, $assigned, $locals, $returns, $fresh );
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::TryCatch') ) {
                $self->_scan_function_body( $stmt->try_body,     $assigned, $locals, $returns, $fresh );
                $self->_scan_function_body( $stmt->catch_body,   $assigned, $locals, $returns, $fresh );
                $self->_scan_function_body( $stmt->finally_body, $assigned, $locals, $returns, $fresh );
            }
        }
    }

    # A call that returns a dynamic (`Any`) value whose callee was classified as owned hands back a reference the
    # callee already owns. The caller consumes it instead of taking a second reference (F13).
    method _owned_call_result($val) {
        return 0 unless ref $val && $val->isa('Brocken::Lindsay::IR::Instruction::Call');
        return 0 unless $val->type && $val->type->kind eq 'dynamic';
        return $returns_owned->{ $val->callee->name } ? 1 : 0;
    }

    # Drop the reference an owned dynamic call result carries when it is used in a non-owning position: discarded, or
    # unboxed on the way into a native/pointer slot. Nowhere retains the box, so leaving it would strand the reference
    # until the arena is torn down. `decref` only returns the 16-byte header to the free list -- it never touches what
    # the payload points at -- so releasing a box whose payload was already copied out is safe; a slot that keeps the
    # box instead consumes the reference through `_owned_call_result` and must not call this.
    method _release_owned_call_temp( $val, $line, $col ) {
        return unless $self->_owned_call_result($val);
        my $hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
        $builder->build_decref( $val, $line, $col, $hb );
    }

    # Whether an expression constructs a fresh instance of a registered class (`Class->new(...)`). A fresh
    # construction is the one class-typed return shape that is unambiguously owned: the constructor writes refcount 1
    # and no other local holds a second reference.
    method _is_fresh_construction($expr) {
        return 0 unless ref $expr && $expr->isa('Brocken::Katsuro::AST::Expr::MethodCall');
        return 0 unless $expr->method eq 'new';
        return 0 unless $expr->obj->isa('Brocken::Katsuro::AST::Expr::Ident');
        return $classes->{ $self->_resolve_class_ident( $expr->obj->name ) } ? 1 : 0;
    }

    # Classify a class-returning function's return ownership. Unlike a dynamic return (where a non-parameter return is
    # always a fresh box the callee owns), a returned instance may be a borrow of `$self`, of a class-typed parameter
    # (Caller-Borrows), or of an instance field. Releasing a borrow would double-free the caller's object, so this
    # classifier is deliberately conservative: a function is owned only when EVERY class-typed return is provably an
    # owned instance -- a fresh `Class->new`, a local that a fresh construction initialized and nothing reassigned, or
    # a call to a function already known owned. Anything else leaves the function borrowed, and the caller keeps the
    # reference it was handed (a leak, never a dangling free).
    method _classify_class_return_ownership( $name, $return_class, $params_ast, $body ) {
        return unless defined $return_class && $classes->{$return_class};
        my ( %assigned, %locals, %fresh, @returns );
        $self->_scan_function_body( $body, \%assigned, \%locals, \@returns, \%fresh );

        # A `return 0` (or `return false`) hands back no instance and a null pointer is safe to release, so such a path
        # neither proves nor disproves ownership and is dropped before the verdict. Only the class-typed returns decide;
        # a function that never hands back an instance stays borrowed.
        my @substantive = grep { !$self->_is_null_return($_) } @returns;
        my $owned = @substantive ? 1 : 0;
        for my $expr (@substantive) {
            unless ( $self->_class_return_is_owned( $expr, \%assigned, \%locals, \%fresh ) ) {
                $owned = 0;
                last;
            }
        }
        $class_returns_owned->{$name} = $owned;
    }

    # Whether a return expression is a null literal (`0` or `false`). Such a path yields no instance, and the caller's
    # scope-exit release tolerates a null instance (the runtime's release path short-circuits on it).
    method _is_null_return($expr) {
        return 0 unless defined $expr && $expr->isa('Brocken::Katsuro::AST::Expr::Const');
        return 1 if $expr->type eq 'Int'  && $expr->value == 0;
        return 1 if $expr->type eq 'Bool' && !$expr->value;
        return 0;
    }

    # One class-typed return is owned only for a proven-fresh instance; every other shape is treated as a borrow.
    method _class_return_is_owned( $expr, $assigned, $locals, $fresh ) {
        return 0 unless defined $expr;
        return 1 if $self->_is_fresh_construction($expr);
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Call') ) {
            return $class_returns_owned->{ $expr->func_name } ? 1 : 0;
        }

        # A bare variable is a borrow by default: `$self`, a class-typed parameter (Caller-Borrows), or an instance
        # field. It is owned only when it names a local that a fresh construction initialized and nothing reassigned.
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            my $n = $expr->name;
            return 0 if $n eq 'self';
            return 0 unless $locals->{$n} && !$assigned->{$n};
            return $fresh->{$n} ? 1 : 0;
        }
        return 0;
    }

    # A call (free sub or method) to a function classified as class-return-owned hands the caller an owned instance of
    # its known return class; anything else returns undef.
    method _owned_class_call($expr) {
        return undef unless ref $expr;
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Call') ) {
            return undef unless $class_returns_owned->{ $expr->func_name };
            return $function_return_class->{ $expr->func_name };
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::MethodCall') ) {
            my $recv = $self->_expr_class( $expr->obj );
            $recv = $current_class
                if !defined $recv && $expr->obj->isa('Brocken::Katsuro::AST::Expr::Var') && $expr->obj->name eq 'self';
            return undef unless defined $recv;
            my $full = $self->_resolve_method( $recv, $expr->method );
            return undef unless $full && $class_returns_owned->{$full};
            return $function_return_class->{$full};
        }
        return undef;
    }

    # Return type inference
    method _infer_return_type($ast) {
        my $body = $ast->body;
        my %var_types;
        for my $p ( $ast->params->@* ) {
            $var_types{ $p->{name} } = $p->{type} // 'Any';
        }
        my @types = $self->_walk_return_types( $body, \%var_types );
        return 'void' unless @types;
        my $acc = shift @types;
        for my $t (@types) { $acc = $self->_lub( $acc, $t ); }
        return $acc;
    }

    method _walk_return_types( $block, $var_types ) {
        my @types;
        for my $stmt ( $block->statements->@* ) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::VarDecl') ) {
                $var_types->{ $stmt->name } = $stmt->type // 'Any';
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ListVarDecl') ) {
                for my $t ( $stmt->targets->@* ) {
                    $var_types->{ $t->{name} } = $t->{type} // 'Any';
                }
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Return') ) {
                if ( defined $stmt->expr ) {
                    push @types, $self->_infer_expr_type( $stmt->expr, $var_types );
                }
                else {
                    push @types, 'void';
                }
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::If') ) {
                my %t = %$var_types;
                push @types, $self->_walk_return_types( $stmt->then, \%t );
                for my $e ( $stmt->elsif->@* ) {
                    my %e = %$var_types;
                    push @types, $self->_walk_return_types( $e->[1], \%e );
                }
                if ( defined $stmt->else ) {
                    my %e = %$var_types;
                    push @types, $self->_walk_return_types( $stmt->else, \%e );
                }
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::While') ) {
                my %t = %$var_types;
                push @types, $self->_walk_return_types( $stmt->body, \%t );
            }
        }
        return @types;
    }

    method _infer_expr_type( $expr, $var_types ) {
        return undef unless defined $expr;
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Const') ) {
            return 'i64'    if $expr->type eq 'Int';
            return 'f64'    if $expr->type eq 'Float';
            return 'String' if $expr->type eq 'String';
            return 'Bool'   if $expr->type eq 'Bool';
            return 'Any';
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            return $var_types->{ $expr->name } // 'Any';
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::List') ) {
            return 'ptr';    # list returns a pointer to heap-allocated list data
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Hash') ) {
            return 'ptr';    # hash returns a pointer to heap-allocated hash data
        }
        return 'Any';
    }

    method _lub( $a, $b ) {
        return $b unless defined $a;
        return $a if $a eq $b;
        return 'Any';
    }

    # Mark every variable used in a value position in `$block` as escaped. A class instance local may only be
    # reclaimed while nothing else can reach it: a receiver (`$obj->m()`, `$obj.f`) borrows the object and leaves the
    # local the sole owner, but a value use (an argument, an assignment RHS, a list/hash element, a return) can hand
    # the pointer onward, and a `ptr` store does not incref, so the local has to keep its reference -- a leak, never a
    # dangling free. The scan is deliberately an over-approximation: anything it cannot pin as a receiver counts as a
    # value use.
    method _scan_escapes($block) {
        return unless defined $block;
        $self->_scan_stmt_escapes($_) for $block->statements->@*;
    }

    method _scan_stmt_escapes($stmt) {
        return unless defined $stmt;
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::VarDecl') ) {
            $self->_scan_value_escapes( $stmt->init );
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ArrayDecl') ) {
            $self->_scan_value_escapes( $stmt->size_expr );
            $self->_scan_value_escapes( $stmt->init );
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Assign') ) {
            $self->_scan_receiver_escapes( $stmt->target );
            $self->_scan_value_escapes( $stmt->expr );
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ListVarDecl') ) {
            $self->_scan_value_escapes( $stmt->expr );
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Return') ) {
            $self->_scan_value_escapes( $stmt->expr );
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Throw') ) {
            $self->_scan_value_escapes( $stmt->expr );
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::If') ) {
            $self->_scan_value_escapes( $stmt->cond );
            $self->_scan_escapes( $stmt->then );
            for my $pair ( $stmt->elsif->@* ) {
                $self->_scan_value_escapes( $pair->[0] );
                $self->_scan_escapes( $pair->[1] );
            }
            $self->_scan_escapes( $stmt->else ) if defined $stmt->else;
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::While') ) {
            $self->_scan_value_escapes( $stmt->cond );
            $self->_scan_escapes( $stmt->body );
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Block') ) {
            $self->_scan_escapes($stmt);
        }
        elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::TryCatch') ) {
            $self->_scan_escapes( $stmt->try_body );
            $self->_scan_escapes( $stmt->catch_body )   if defined $stmt->catch_body;
            $self->_scan_escapes( $stmt->finally_body ) if defined $stmt->finally_body;
        }
        else {
            # A bare expression statement (a call, an intrinsic, a binop): its value is discarded, but any
            # receiver-shaped sub-expression still has to be classified.
            $self->_scan_value_escapes($stmt);
        }
    }

    # The expression's value is consumed as a value (argument, RHS, element, return).
    method _scan_value_escapes($expr) {
        return unless defined $expr && ref $expr;
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            $class_escaped->{ $expr->name } = 1;
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::Paren') ) {
            $self->_scan_value_escapes( $expr->expr );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::UnOp') ) {
            $self->_scan_value_escapes( $expr->expr );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::BinOp') ) {
            $self->_scan_value_escapes( $expr->lhs );
            $self->_scan_value_escapes( $expr->rhs );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::Ternary') ) {
            $self->_scan_value_escapes( $expr->cond );
            $self->_scan_value_escapes( $expr->then );
            $self->_scan_value_escapes( $expr->else );
        }

        # A field read borrows its object; the object pointer itself is not handed onward.
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::FieldAccess') ) {
            $self->_scan_receiver_escapes( $expr->obj );
        }

        # An array/hash index borrows the container and consumes the index.
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::ArrayIndex') ) {
            $self->_scan_receiver_escapes( $expr->array );
            $self->_scan_value_escapes( $expr->index );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::HashIndex') ) {
            $self->_scan_receiver_escapes( $expr->hash );
            $self->_scan_value_escapes( $expr->key );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::Exists') ) {
            $self->_scan_value_escapes( $expr->expr );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::Defined') ) {
            $self->_scan_value_escapes( $expr->expr );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::Delete') ) {
            $self->_scan_value_escapes( $expr->expr );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::ArrayOp') ) {
            $self->_scan_receiver_escapes( $expr->array );
            $self->_scan_value_escapes($_) for $expr->args->@*;
        }

        # A method call borrows its receiver and consumes its arguments.
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::MethodCall') ) {
            $self->_scan_receiver_escapes( $expr->obj );
            $self->_scan_value_escapes($_) for $expr->args->@*;
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::Call') ) {
            $self->_scan_value_escapes($_) for $expr->args->@*;
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::IntrinsicCall') ) {

            # The weak-reference builtins act on a variable's ownership in place: they neither share the pointer nor
            # return it. Classifying the argument as an escaping value would keep a fresh instance out of the owned
            # set, so `weaken` could not release the reference it is meant to drop.
            return if $expr->name =~ /^builtin::(?:weaken|unweaken|is_weak)$/;
            $self->_scan_value_escapes($_) for $expr->args->@*;
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::List') ) {
            $self->_scan_value_escapes($_) for $expr->elements->@*;
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::Assign') ) {
            $self->_scan_receiver_escapes( $expr->target );
            $self->_scan_value_escapes( $expr->expr );
        }
        elsif ( $expr->isa('Brocken::Katsuro::AST::Expr::Hash') ) {
            for my $pair ( $expr->pairs->@* ) {
                $self->_scan_value_escapes( $pair->{key} );
                $self->_scan_value_escapes( $pair->{value} );
            }
        }
    }

    # The expression is used as an object receiver: a bare variable is borrowed, anything more involved is treated as
    # a value use of its sub-expressions.
    method _scan_receiver_escapes($expr) {
        return unless defined $expr && ref $expr;
        return if $expr->isa('Brocken::Katsuro::AST::Expr::Var');
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Paren') ) {
            return $self->_scan_receiver_escapes( $expr->expr );
        }
        $self->_scan_value_escapes($expr);
    }

    # Main entry point
    method lower_program($ast) {
        my @decls;
        my @top_stmts;
        $self->collect_decls( $ast->statements, \@decls, \@top_stmts );
        if (@top_stmts) {
            my $main_body = Brocken::Katsuro::AST::Stmt::Block->new( statements => \@top_stmts );
            my $main_sub
                = Brocken::Katsuro::AST::Stmt::SubDecl->new( name => '_BROCKEN_ENTRY', return_type => 'i64', params => [], body => $main_body, );
            unshift @decls, $main_sub;
        }

        # Pass 1: Register all declarations
        for my $stmt (@decls) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ClassDecl') ) {
                $self->register_class($stmt);
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::SubDecl') ) {
                $self->register_function($stmt);
            }
        }

        # Pass 1.5: Resolve `:isa` and lay out each class's field block over its ancestor chain. Both wait until
        # every class is registered so a parent may be declared after its child.
        $self->resolve_inheritance;
        $self->_layout_class($_) for keys %$classes;

        # Pass 1.55: A dense class id per class, assigned by sorted name so it does not depend on declaration
        # order. The id travels in the object header's auxiliary bits and is what the runtime's cycle collector
        # hands to the generated class scan/restore dispatch (see `generate_gc_dispatch`). Id 0 is reserved for
        # "not a class instance" -- the value a boxed `ptr` carries -- so the shared tag byte never collides.
        {
            my $id = 1;
            for my $name ( sort keys %$classes ) {
                $classes->{$name}{id} = $id++;
            }
        }

        # Pass 1.6: Classify every dynamic-returning function's return ownership before any body is lowered, so a call
        # site knows whether the callee hands back an owned reference (+1) or a borrowed one (+0). Bodies are still AST,
        # so this reads them directly; it must run before Pass 2/3 so forward and cross-class calls see the answer. The
        # same pass classifies class-returning functions, whose returned instance may be an owned fresh construction or
        # a borrow of `$self`, a parameter, or a field (see `_classify_class_return_ownership`).
        for my $stmt (@decls) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::SubDecl') && !$stmt->prototype ) {
                my $name = $self->_qualify( $stmt->name, $stmt->package );
                my $ret  = $stmt->return_type // $self->_infer_return_type($stmt);
                $self->_classify_return_ownership( $name, $ret, $stmt->params, $stmt->body );
                $self->_classify_class_return_ownership( $name, $function_return_class->{$name}, $stmt->params, $stmt->body );
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ClassDecl') ) {
                my $class = $self->_qualify( $stmt->name, $stmt->package );
                my $cd    = $classes->{$class};
                my %fields = map { $_->{name} => 1 } ( $cd && $cd->{fields} ? $cd->{fields}->@* : () );
                for my $m ( $stmt->methods->@* ) {
                    my $ret = $m->return_type // $self->_infer_return_type($m);
                    my $full = $class . '::' . $m->name;
                    $self->_classify_return_ownership( $full, $ret, $m->params, $m->body, \%fields );

                    # Method return classes are resolved as written against the global class map, matching
                    # `register_function_raw` (which registers them later, in Pass 2).
                    $self->_classify_class_return_ownership( $full, ( $classes->{$ret} ? $ret : undef ), $m->params, $m->body );
                }
            }
        }

        # Pass 2: Generate class runtimes ancestors-first so an inherited method is registered before a descendant's
        # body tries to call it (static dispatch resolves against $functions).
        my @class_decls = grep { $_->isa('Brocken::Katsuro::AST::Stmt::ClassDecl') } @decls;
        @class_decls = sort {
            $self->_class_depth( $self->_qualify( $a->name, $a->package ) )
                <=> $self->_class_depth( $self->_qualify( $b->name, $b->package ) )
        } @class_decls;
        for my $stmt (@class_decls) {
            $self->generate_class_runtime($stmt);
        }

        # Pass 2.5: Emit the id -> per-class scan/restore dispatch the runtime's cycle collector calls. The runtime
        # cannot see a class's field layout, so `gc_scan_obj`/`gc_restore_refs` hand a class instance here and this
        # picks the class's own __scan/__restore by the id in the header. A direct-call chain keeps the runtime free
        # of indirect calls; it is emitted before Pass 3 so the runtime's calls resolve against it.
        $self->generate_gc_dispatch;

        # Pass 3: Lower sub and method bodies
        for my $stmt (@decls) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::SubDecl') ) {
                $self->lower_function($stmt);
            }
        }
        return $module;
    }

    # Flatten the program's top-level statements. A `package NAME { ... }` block is a container, not a runtime
    # statement: its declarations join the program's declaration list and its loose statements join the entry, in
    # source order. The parser already stamped the package onto each node, so this only has to descend.
    method collect_decls( $stmts, $decls, $top_stmts ) {
        for my $stmt ( $stmts->@* ) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::PackageDecl') ) {
                $package_versions->{ $stmt->name } = $stmt->version                 if defined $stmt->version;
                $self->collect_decls( $stmt->body->statements, $decls, $top_stmts ) if $stmt->body;
            }
            elsif ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ClassDecl') || $stmt->isa('Brocken::Katsuro::AST::Stmt::SubDecl') ) {
                push @$decls, $stmt;
            }
            else {
                push @$top_stmts, $stmt;
            }
        }
    }

    method generate_class_runtime($ast) {
        my $class_name    = $self->_qualify( $ast->name, $ast->package );
        my $saved_package = $current_package;
        $current_package = $ast->package;
        $current_class   = $class_name;
        my $class_data = $classes->{$class_name};

        # Lower the ADJUST blocks if present, in declaration order.
        if ( $ast->adjusts->@* ) {
            $self->register_method( $class_name, 'ADJUST', 'void', [] );
            $self->lower_adjust( $class_name, $ast->adjusts );
        }

        # Register DESTROY up front (so a method or accessor can call it) but lower its body last (so it can call
        # this class's own methods and accessors, which are generated below).
        my $has_destroy = $ast->destroys->@* ? 1 : 0;
        $self->register_method( $class_name, 'DESTROY', 'void', [] ) if $has_destroy;

        # The reclaim thunk the compiled release sites call: it runs the (chained) DESTROY, tears down the managed
        # fields, and frees the instance. It is separate from DESTROY because DESTROY is an ordinary method a user may
        # call more than once, while the reclaim must run exactly once, when the refcount reaches zero.
        $self->register_method( $class_name, '__destroy', 'void', [] );

        # Lower explicit methods
        for my $m ( $ast->methods->@* ) {
            my $ret_type = $m->return_type;
            if ( !defined $ret_type ) {
                $ret_type = $self->_infer_return_type($m);
            }
            $self->register_method( $class_name, $m->name, $ret_type, $m->params );
            $self->lower_method( $class_name, $m );
        }

        # Auto-generate :reader methods (:accessor is reader + writer). The method name is the custom
        # :reader(name) payload if one was given, otherwise the field name with one leading underscore
        # removed, so `field $_x :reader` generates `x()`. An array/hash field's reader is a `ptr`: the
        # element/hash base for an array, the hash pointer for a hash.
        for my $f ( $ast->fields->@* ) {
            if ( $self->has_attr( $f->attrs, 'reader' ) || $self->has_attr( $f->attrs, 'accessor' ) ) {
                my $mname = $self->attr_arg( $f->attrs, 'reader' ) // $self->attr_arg( $f->attrs, 'accessor' ) // $self->strip_underscore( $f->name );
                my $ret   = $f->kind eq 'scalar' ? $f->type : 'ptr';
                $self->register_method( $class_name, $mname, $ret, [] );
                $self->generate_reader( $class_name, $f, $mname );
            }
        }

        # Auto-generate :writer methods (:accessor is reader + writer). Writers return $self so that
        # calls can be chained: $obj->set_x(1)->set_y(2). As in Perl, the default name is set_ plus the
        # field name with one leading underscore removed (`$_x` -> `set_x`), unless :writer(name) says
        # otherwise. An inline array field has no whole-value writer -- its elements are set in place.
        for my $f ( $ast->fields->@* ) {
            next if $f->kind eq 'array' && $f->inline;
            if ( $self->has_attr( $f->attrs, 'writer' ) || $self->has_attr( $f->attrs, 'accessor' ) ) {
                my $base   = $self->attr_arg( $f->attrs, 'accessor' ) // $self->strip_underscore( $f->name );
                my $mname  = $self->attr_arg( $f->attrs, 'writer' )   // 'set_' . $base;
                my $ptype  = $f->kind eq 'scalar' ? $f->type : 'ptr';
                my @params = ( { type => $ptype, sigil => '$', name => 'value' } );
                $self->register_method( $class_name, $mname, 'ptr', \@params );
                $writer_map->{ $class_name . '::' . $mname } = $class_name;
                $self->generate_writer( $class_name, $f, $mname );
            }
        }

        # Lower DESTROY last: its body may call this class's own methods and accessors, all now registered. The
        # generated body runs its own code then chains to the nearest ancestor's Class::DESTROY (derived-to-root).
        $self->lower_destroy( $class_name, $ast->destroys ) if $has_destroy;
        $self->lower_class_destroy($class_name);
        $self->generate_class_gc($class_name);
        $current_class   = undef;
        $current_package = $saved_package;
    }

    # Register built-in FFI functions
    method _puts_name() {
        return $self->platform && $self->platform->is_windows ? '_puts' : 'puts';
    }

    method _crt_name($name) {
        return $self->platform && $self->platform->is_windows ? '_' . $name : $name;
    }

    method _stringify( $val, $line, $col ) {
        return $val if $val->type->kind eq 'ptr';
        my $type = $val->type;
        my $kind = $type->kind;

        # Spec 4.2 gives a Bool its own rendering: `"1"` or `""`. It is the one integer type whose text is not the
        # integer value, so it is selected from two literals rather than routed through the integer helpers (which
        # would render `false` as either "0" or, with a sign-extending widening, "-1"). All three backends materialise
        # a rodata pointer in a `select` arm, which is what the dynamic path already relies on.
        if ( $kind eq 'int' && $type->bits == 1 ) {
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                return $self->_reflect_rodata( $val->value ? '1' : '' );
            }
            my $t = $self->_reflect_rodata('1');
            my $f = $self->_reflect_rodata('');
            return $builder->build_select( $val, $t, $f, undef, $line, $col );
        }
        if ( $kind eq 'int' ) {
            my $sprintf_arg = $val;
            my $to_str_fn;

            # A narrow signed int is sign-extended so its value survives the widening.
            if ( $type->is_signed ) {
                if ( $type->bits < 64 ) {
                    $sprintf_arg = $builder->build_sext( $val, Brocken::Lindsay::IR::Type::i64(), undef, $line, $col );
                }
                $to_str_fn = $functions->{'Brocken::Runtime::i64_to_str'};
                Carp::croak("Runtime function i64_to_str not found") unless $to_str_fn;
            }
            else {
                if ( $type->bits < 64 ) {
                    $sprintf_arg = $builder->build_zext( $val, Brocken::Lindsay::IR::Type::i64(), undef, $line, $col );
                }
                $to_str_fn = $functions->{'Brocken::Runtime::u64_to_str'};
                Carp::croak("Runtime function u64_to_str not found") unless $to_str_fn;
            }
            my $hb
                = $symbols->{'__heap_base'} ?
                $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col ) :
                undef;
            Carp::croak("_stringify requires __heap_base for int conversion at line $line, col $col") unless $hb;
            return $builder->build_call( $to_str_fn, [ $hb, $sprintf_arg ], undef, $line, $col );
        }
        my $buf         = $builder->build_alloca( Brocken::Lindsay::IR::Type::i8(), undef, 64, $line, $col );
        my $sprintf_arg = $val;
        my $fmt_str;
        if ( $kind eq 'float' ) {
            $fmt_str = "%f\0";
        }
        else {
            Carp::croak("Cannot concatenate value of type '$kind' at line $line, col $col");
        }
        my ( $fmt_label, $fmt_bytes ) = $self->_intern_rodata($fmt_str);
        my $fmt_ref    = Brocken::Lindsay::IR::RodataRef->new( label => $fmt_label, bytes => $fmt_bytes, type => Brocken::Lindsay::IR::Type::ptr(), );
        my $sprintf_fn = Brocken::Lindsay::IR::Function->new(
            name        => $self->_crt_name('sprintf'),
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => [
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),

                # `sprintf` is variadic, but the caller has to know where the conversion argument goes. Declaring the
                # third slot as `f64` is what places the value in the float argument register; without it the operand
                # has no parameter to land in and the buffer keeps its uninitialised contents.
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::f64() ),
            ],
        );
        $builder->build_call( $sprintf_fn, [ $buf, $fmt_ref, $sprintf_arg ], undef, $line, $col );
        return $buf;
    }

    # Stringify an arbitrary value to a String pointer -- the conversion `say`, `print`, and `builtin::stringify` all
    # need. `_stringify` already covers a String (identity), an int, and a float; a boxed `Any` is read through its
    # header tag: tag 3 is a float, tag 4 is a String pointer (the payload is the characters themselves, so stringify
    # is the identity on the unboxed pointer), and anything else renders through the integer payload.
    method _stringify_value( $val, $ast, $line, $col ) {
        return $self->_stringify( $val, $line, $col ) unless $val->type->kind eq 'dynamic';
        my $tag      = $self->_reflect_box_tag( $val, $line, $col );
        my $is_undef = $self->_icmp_eq_i64( $tag, 0, $line, $col );
        my $is_float = $self->_icmp_eq_i64( $tag, 3, $line, $col );
        my $is_str   = $self->_icmp_eq_i64( $tag, 4, $line, $col );
        my $fstr     = $self->_stringify( $builder->build_call( $self->_reflect_runtime('unbox_f64', $ast, $line, $col), [$val], undef, $line, $col ), $line, $col );
        my $istr     = $self->_stringify( $builder->build_call( $self->_reflect_runtime('unbox_i64', $ast, $line, $col), [$val], undef, $line, $col ), $line, $col );
        my $pstr     = $builder->build_call( $self->_reflect_runtime('unbox_ptr', $ast, $line, $col), [$val], undef, $line, $col );
        my $num      = $builder->build_select( $is_float, $fstr, $istr, undef, $line, $col );
        my $str      = $builder->build_select( $is_str, $pstr, $num, undef, $line, $col );

        # undef renders as the empty string (Perl's behaviour), and it is the one box left with tag 0.
        return $builder->build_select( $is_undef, $self->_reflect_rodata(''), $str, undef, $line, $col );
    }

    method register_intrinsics() {
        my $puts_name = $self->_puts_name;
        for my $name (qw(say print)) {
            my $fn = Brocken::Lindsay::IR::Function->new(
                name        => $puts_name,
                return_type => Brocken::Lindsay::IR::Type::void(),
                params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ) ],
            );
            $module->add_function($fn);
            $functions->{$name} = $fn;
        }
    }

    # The element count of an inline array field must be a compile-time constant, because the struct's size and each
    # element's byte offset are computed before any function body is lowered.
    method field_array_count($f) {
        my $sz = $f->size_expr;
        if ( $sz && $sz->isa('Brocken::Katsuro::AST::Expr::Const') && $sz->type eq 'Int' ) {
            return $sz->value;
        }
        Carp::croak( "Inline array field '" . $f->name . "' needs a constant element count (e.g. field [i64; 4] \$" . $f->name . ")" );
    }

    # Pass 1: Register declarations
    method register_class($ast) {
        my $full_name = $self->_qualify( $ast->name, $ast->package );

        # A body-less `class NAME;` is a forward declaration. It never clobbers a definition that already
        # registered (a definition may be written first); it only supplies metadata the earlier one lacked.
        my $existing = $classes->{$full_name};
        if ( $existing && !$ast->fields->@* && !$ast->methods->@* && !$ast->adjusts->@* && !$ast->destroys->@* ) {
            $existing->{version} //= $ast->version;
            push $existing->{attrs}->@*, $ast->attrs->@*;
            return;
        }

        # Only the field kinds and their sizes are decided here. Slot indices and byte offsets depend on the whole
        # ancestor chain, so `_layout_class` assigns them once every class (and its `:isa`) is known.
        my @own_fields;
        for my $f ( $ast->fields->@* ) {
            my $kind   = $f->kind // 'scalar';
            my $inline = $kind eq 'array' && $f->inline ? 1 : 0;

            # The IR type of the storage slot, the element type (arrays), and how many struct slots the field spans.
            # A scalar or pointer slot is one slot; an inline array claims one slot per element so a struct GEP at
            # slot_idx + i lands on element i.
            my ( $ir_type, $elem_ir_type, $span, $size );
            if ( $kind eq 'array' ) {
                $elem_ir_type = $self->type_from_name( $f->elem_type );
                if ($inline) {
                    my $count = $self->field_array_count($f);
                    ( $ir_type, $span, $size ) = ( $elem_ir_type, $count, $count * $self->type_size($elem_ir_type) );
                }
                else {
                    ( $ir_type, $span, $size ) = ( Brocken::Lindsay::IR::Type::ptr(), 1, 8 );
                }
            }
            elsif ( $kind eq 'hash' ) {
                ( $ir_type, $span, $size ) = ( Brocken::Lindsay::IR::Type::ptr(), 1, 8 );
            }
            else {
                $ir_type = $self->type_from_name( $f->type );
                ( $span, $size ) = ( 1, $self->type_size($ir_type) );
            }
            if ( $inline && $self->has_attr( $f->attrs, 'param' ) ) {
                Carp::croak(
                    "Inline array field '" . $f->name . "' cannot be :param; use a pointer array (field " . $f->elem_type . " \@" . $f->name . ")" );
            }
            push @own_fields,
                {
                name         => $f->name,
                type         => $f->type,
                kind         => $kind,
                inline       => $inline,
                ir_type      => $ir_type,
                elem_ir_type => $elem_ir_type,
                span         => $span,
                size         => $size,
                align        => $self->type_align( $inline ? $elem_ir_type : $ir_type ),
                idx          => $#own_fields + 1,
                default      => $f->default,
                default_op   => $f->default_op,
                attrs        => [ $f->attrs->@* ],
                param        => $self->has_attr( $f->attrs, 'param' ) ? 1 : 0,
                param_name   => $self->has_attr( $f->attrs, 'param' ) ?
                    ( $self->attr_arg( $f->attrs, 'param' ) // $self->strip_underscore( $f->name ) ) : undef,
                weak         => $self->has_attr( $f->attrs, 'weak' ) ? 1 : 0,
                };
        }
        $classes->{$full_name} = {
            name       => $full_name,
            own_fields => \@own_fields,
            fields     => \@own_fields,    # replaced with the ancestor chain by _layout_class
            methods    => [],
            package    => $ast->package,
            version    => $ast->version,
            attrs      => [ $ast->attrs->@* ],
            parent     => undef,           # set by resolve_inheritance
        };
    }

    # Resolve each class's `:isa(PARENT)` once every class is registered, so a parent may be declared after its
    # child. A single superclass, named in the same compilation unit.
    method resolve_inheritance() {
        for my $name ( keys %$classes ) {
            my $cd  = $classes->{$name};
            my @isa = grep { $_->{name} eq 'isa' } $cd->{attrs}->@*;
            Carp::croak("Class '$name' has more than one :isa attribute") if @isa > 1;
            next unless @isa;
            my $parent = $isa[0]{arg};
            if ( !$classes->{$parent} && defined $cd->{package} && length $cd->{package} ) {
                my $qualified = $cd->{package} . '::' . $parent;
                $parent = $qualified if $classes->{$qualified};
            }
            Carp::croak("Unknown superclass '$parent' of class '$name'") unless $classes->{$parent};
            Carp::croak("Class '$name' cannot inherit from itself")       if $parent eq $name;
            $cd->{parent} = $parent;
        }

        # A cycle would make _layout_class recurse forever; reject it up front.
        for my $name ( keys %$classes ) {
            my %seen;
            my $cursor = $name;
            while ( defined( $cursor = $classes->{$cursor}{parent} ) ) {
                Carp::croak("Inheritance cycle involving class '$name'") if $seen{$cursor}++;
            }
        }
    }

    # The ancestor chain of a class, root first and the class itself last.
    method _ancestors($name) {
        my @chain;
        my $cursor = $name;
        while ( defined $cursor ) {
            unshift @chain, $cursor;
            $cursor = $classes->{$cursor} ? $classes->{$cursor}{parent} : undef;
        }
        return @chain;
    }

    # Number of ancestors a class has, for ordering class-runtime generation ancestors-first.
    method _class_depth($name) {
        my $depth  = 0;
        my $cursor = $classes->{$name} ? $classes->{$name}{parent} : undef;
        while ( defined $cursor ) {
            $depth++;
            $cursor = $classes->{$cursor} ? $classes->{$cursor}{parent} : undef;
        }
        return $depth;
    }

    # Assign absolute slot indices and byte offsets over the whole chain: the parent's field block, then this class's
    # own fields. An inherited method keeps addressing its own fields at the same offsets because that prefix is
    # identical. Idempotent, and recurses into the parent so layout does not depend on declaration order.
    method _layout_class($name) {
        my $cd = $classes->{$name} or return;
        return if $cd->{struct_type};

        my ( @chain, @field_types, @field_names, @field_offsets );
        my $offset    = 8;
        my $max_align = 8;
        my $slot_base = 0;
        if ( $cd->{parent} ) {
            my $parent = $cd->{parent};
            $self->_layout_class($parent);
            my $pd         = $classes->{$parent};
            @chain         = @{ $pd->{fields} };
            @field_types   = @{ $pd->{struct_type}->field_types };
            @field_names   = @{ $pd->{struct_type}->field_names };
            @field_offsets = @{ $pd->{struct_type}->_field_offsets };
            $offset        = $pd->{total_size};
            $max_align     = $pd->{max_align};
            $slot_base     = scalar @field_types;
        }

        for my $f ( $cd->{own_fields}->@* ) {
            my $align = $f->{align};
            $offset = $self->_align_up( $offset, $align );
            $max_align = $align if $align > $max_align;
            $f->{slot_idx} = $slot_base;
            $f->{offset}   = $offset;
            for my $k ( 0 .. $f->{span} - 1 ) {
                push @field_types,   $f->{inline} ? $f->{elem_ir_type} : $f->{ir_type};
                push @field_names,   $f->{name};
                push @field_offsets, $offset + $k * ( $f->{inline} ? $self->type_size( $f->{elem_ir_type} ) : $f->{size} );
            }
            $slot_base += $f->{span};
            $f->{chain_idx} = scalar @chain;
            push @chain, $f;
            $offset += $f->{size};
        }
        $offset = $self->_align_up( $offset, $max_align );

        $cd->{fields}      = \@chain;
        $cd->{struct_type} = Brocken::Lindsay::IR::Type->new(
            kind           => 'struct',
            struct_name    => $name,
            field_types    => \@field_types,
            field_names    => \@field_names,
            _field_offsets => \@field_offsets,
            bits           => $offset * 8,
            signed         => 0,
        );
        $cd->{total_size} = $offset;
        $cd->{max_align}  = $max_align;
    }

    # The nearest class at or above `$class_name` (walking the ancestor chain) that defines `$method`, as a
    # `Class::method` function name, or undef.
    method _resolve_method( $class_name, $method ) {
        return undef unless defined $class_name;
        my $cursor = $class_name;
        while ( defined $cursor ) {
            my $full = $cursor . '::' . $method;
            return $full if $functions->{$full};
            $cursor = $classes->{$cursor} ? $classes->{$cursor}{parent} : undef;
        }
        return undef;
    }

    method register_function($ast) {
        my $name          = $self->_qualify( $ast->name, $ast->package );
        my $ret_type_name = $ast->return_type;
        if ( !defined $ret_type_name ) {
            $ret_type_name = $self->_infer_return_type($ast);
        }
        my $resolved_ret = $ret_type_name;
        if ( defined $ret_type_name ) {
            my $qualified = $self->_qualify( $ret_type_name, $ast->package );
            $resolved_ret = $qualified if $classes->{$qualified};
        }
        my $ret_class = $classes->{$resolved_ret} ? $resolved_ret : undef;
        $ret_type_name = $classes->{$resolved_ret} ? 'ptr' : $ret_type_name;
        $function_return_class->{$name} = $ret_class;
        my $ret_type = $self->type_from_name($ret_type_name);
        my @params;
        unless ( $name =~ /^Brocken::Runtime::/ ) {
            push @params, Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%__heap_base', );
            unless ( $name eq '_BROCKEN_ENTRY' ) {
                push @params, Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i64(), name => '%__want', );
            }
        }
        for my $p ( $ast->params->@* ) {
            push @params, Brocken::Lindsay::IR::Value->new( type => $self->type_from_name( $p->{type} ), name => '%' . $p->{name}, );
        }
        # Only a callable with at least one default needs its parameter names bound while its arguments are lowered, so
        # that a later default can read an earlier argument. Seeding the list for a default-less callable made the
        # binding loop shadow a caller variable that happened to share a parameter's name (`f($x, $x)` crashed).
        $param_defaults->{$name} = [ map { { name => $_->{name}, default => $_->{default} } } $ast->params->@* ]
            if grep { defined $_->{default} } $ast->params->@*;
        my $fn = Brocken::Lindsay::IR::Function->new( name => $name, return_type => $ret_type, params => \@params, );
        $module->add_function($fn);
        $functions->{$name} = $fn;
    }

    method register_method( $class_name, $method_name, $return_type_name, $params_ast ) {
        my $full_name = $class_name . '::' . $method_name;
        $self->register_function_raw( $full_name, $return_type_name, $params_ast );
    }

    method register_function_raw( $name, $return_type_name, $params_ast ) {
        my $ir_ret_type_name = $classes->{$return_type_name} ? 'ptr' : $return_type_name;
        $function_return_class->{$name} = $classes->{$return_type_name} ? $return_type_name : undef;
        my $ret_type = $self->type_from_name($ir_ret_type_name);
        my @params   = (
            Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%__heap_base', ),
            Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i64(), name => '%__want', ),
            Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%self', ),
        );
        for my $p ( $params_ast->@* ) {
            push @params, Brocken::Lindsay::IR::Value->new( type => $self->type_from_name( $p->{type} ), name => '%' . $p->{name}, );
        }
        $param_defaults->{$name} = [ map { { name => $_->{name}, default => $_->{default} } } $params_ast->@* ]
            if grep { defined $_->{default} } $params_ast->@*;
        my $fn = Brocken::Lindsay::IR::Function->new( name => $name, return_type => $ret_type, params => \@params, );
        $module->add_function($fn);
        $functions->{$name} = $fn;
    }

    # Pass 2: Lower function bodies
    method lower_function($ast) {
        $fuel_exit_block = undef;

        # A prototype (`sub f();`) has no body to lower -- the definition that follows supplies it. An empty *body*
        # (`sub f() {}`) is a real function and must still get a definition, or every call to it fails at link time
        # with an undefined symbol (F16); it falls through and emits the default return below.
        return if $ast->prototype;
        my $name = $self->_qualify( $ast->name, $ast->package );
        $current_package = $ast->package;
        $current_func    = $functions->{$name};
        $symbols         = {};
        $needs_rc        = {};
        $rc_owner        = {};
        $borrowed_params = {};
        $class_owned     = {};
        $class_escaped   = {};
        $weak_var        = {};
        $growable_arrays = {};
        $array_owned_elem = {};
        $hash_var        = {};
        $hash_value_type = {};
        $self->_scan_escapes( $ast->body );
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $has_hidden_heap_base = $current_func->params->@* && $current_func->params->[0]->name eq '%__heap_base';
        my $has_hidden_want = $current_func->params->@* >= 2 && defined $current_func->params->[1] && $current_func->params->[1]->name eq '%__want';
        my $hidden_count    = ( $has_hidden_heap_base ? 1 : 0 ) + ( $has_hidden_want ? 1 : 0 );
        {
            if ($has_hidden_heap_base) {
                my $heap_base_param  = $current_func->params->[0];
                my $heap_base_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::ptr(), '%__heap_base.addr' );
                $builder->build_store( $heap_base_param, $heap_base_alloca );
                $symbols->{'__heap_base'} = $heap_base_alloca;
            }
        }
        {
            my $want_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%__want.addr' );
            if ($has_hidden_want) {
                my $want_param = $current_func->params->[ $has_hidden_heap_base ? 1 : 0 ];
                $builder->build_store( $want_param, $want_alloca );
            }
            else {
                my $default_want = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
                $builder->build_store( $default_want, $want_alloca );
            }
            $symbols->{'__want'} = $want_alloca;
        }
        if ( $current_func->name eq '_BROCKEN_ENTRY' ) {
            my $heap_base = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            my $_init_fn  = $functions->{'Brocken::Runtime::_init'};
            if ($_init_fn) {
                my $heap_size = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::HEAP_SIZE );
                $builder->build_call( $_init_fn, [ $heap_base, $heap_size ], undef );
            }

            # Initialize fuel at [hb+FUEL] to default_fuel
            my $fuel_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $fuel );
            my $hb_fuel    = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            my $fuel_off   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::FUEL );
            my $fuel_addr  = $builder->build_add( $hb_fuel, $fuel_off );
            $builder->build_store( $fuel_const, $fuel_addr );

            # Initialize memory_limit at [hb+MEMORY_LIMIT]
            #
            # A Wasm module declares its linear memory once, so the Immix arena has to stop at the frame region instead
            # of growing into it. Native heaps grow with the mmap and keep the unlimited (0) default, but a Wasm link
            # caps the arena at the heap size it reserved just below the frames.
            my $effective_mem_limit = $mem_limit;
            $effective_mem_limit = Brocken::ICB::HEAP_SIZE if !$effective_mem_limit && $platform && $platform->can('is_wasm') && $platform->is_wasm;
            my $mem_limit_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $effective_mem_limit );
            my $hb_mem          = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            my $mem_off = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::MEMORY_LIMIT );
            my $mem_limit_addr = $builder->build_add( $hb_mem, $mem_off );
            $builder->build_store( $mem_limit_const, $mem_limit_addr );

            # Initialize capabilities at [hb+CAPABILITIES]
            my $caps_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $capabilities );
            my $hb_caps    = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            my $caps_off   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::CAPABILITIES );
            my $caps_addr  = $builder->build_add( $hb_caps, $caps_off );
            $builder->build_store( $caps_const, $caps_addr );
        }
        for my $i ( 0 .. $ast->params->@* - 1 ) {
            my $p      = $current_func->params->[ $i + $hidden_count ];
            my $pname  = $ast->params->[$i]{name};
            my $ptype  = $ast->params->[$i]{type} // 'Any';
            my $alloca = $builder->build_alloca( $p->type, '%' . $pname . '.addr', undef, 0, 0, $pname, $ptype );
            $builder->build_store( $p, $alloca );
            $symbols->{$pname} = $alloca;
            if ( $ptype eq 'Any' ) {
                # Caller-Borrows: an Any argument is not incref'd by the caller, so the callee must not decref it on
                # exit. Track it as borrowed, not owned; a store into the slot (or an escape) takes its own reference.
                $borrowed_params->{$pname} = 1;
            }
        }
        my $body_block = $current_func->append_block( $self->unique_block_name('entry_body') );
        if ($has_hidden_heap_base) {
            if ( $current_func->name ne '_BROCKEN_ENTRY' ) {
                my $hb_fuel    = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
                my $fuel_off   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::FUEL );
                my $fuel_addr  = $builder->build_add( $hb_fuel, $fuel_off );
                my $fuel_val   = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $fuel_addr );
                my $one        = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
                my $fuel_after = $builder->build_sub( $fuel_val, $one );
                $builder->build_store( $fuel_after, $fuel_addr );
                my $zero_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
                my $exhausted  = $builder->build_icmp( 'sle', $fuel_after, $zero_const );
                $fuel_exit_block = $current_func->append_block( $self->unique_block_name('entry_fuel_exit') );
                $builder->build_cond_br( $exhausted, $fuel_exit_block, $body_block );
            }
            else {
                # _BROCKEN_ENTRY: no prologue check, but create exit block for call-site use
                $fuel_exit_block = $current_func->append_block( $self->unique_block_name('entry_fuel_exit') );
                $builder->build_br($body_block);
            }
        }
        else {
            $builder->build_br($body_block);
        }
        $builder->position_at_end($body_block);
        $current_block = $body_block;
        $self->lower_block_body( $ast->body );
        unless ( $current_block && $current_block->terminator ) {
            my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
            for my $name ( sort keys %$needs_rc ) {
                $self->_emit_rc_release( $name, $decref_hb );
            }
            if ( $current_func->return_type->kind eq 'void' ) {
                $builder->build_ret();
            }
            else {
                my $zero = Brocken::Lindsay::IR::Constant->new( type => $current_func->return_type, value => 0 );
                $builder->build_ret($zero);
            }
        }
        if ( defined $fuel_exit_block ) {
            $builder->position_at_end($fuel_exit_block);
            $current_block = $fuel_exit_block;
            my $hb_fuel       = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            my $err_off72     = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 72 );
            my $err_code_addr = $builder->build_add( $hb_fuel, $err_off72 );
            my $cur_err       = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $err_code_addr );
            my $zero_i64      = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
            my $still_ok      = $builder->build_icmp( 'eq', $cur_err, $zero_i64 );
            my $no_fuel_val   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 2 );
            my $final_err     = $builder->build_select( $still_ok, $no_fuel_val, $cur_err );
            $builder->build_store( $final_err, $err_code_addr );

            if ( $current_func->return_type->kind eq 'void' ) {
                $builder->build_ret();
            }
            else {
                my $zero = Brocken::Lindsay::IR::Constant->new( type => $current_func->return_type, value => 0 );
                $builder->build_ret($zero);
            }
        }
    }

    # Block lowering
    method lower_block_body($block_ast) {
        push $_dyn_scope_stack->@*, {};
        $self->lower_block_statements($block_ast);
        pop $_dyn_scope_stack->@*;
    }

    # Lower a block's statements without opening a dynamic-stack scope.  The caller owns the scope (e.g. a loop
    # body, which needs its scope recognizable for last/next cleanup).
    method lower_block_statements($block_ast) {
        for my $stmt ( $block_ast->statements->@* ) {

            # Restore the namespace each statement was parsed in. A synthesized block (the entry body) carries
            # statements from several packages, and a `package NAME { ... }` block's statements were stamped inside
            # it, so the statement is the authority on the current package while it lowers.
            $current_package = $stmt->package if defined $stmt->package;
            $self->lower_statement($stmt);
        }
    }

    # Register an RC-tracked variable, recording the innermost dynamic (block/loop) scope that declares it.  The
    # owning scope lets loop cleanup tell apart a variable the loop body itself owns (still live on the fall-through
    # back edge) from one declared in a nested block that has already closed on that path.
    method _note_rc($name) {
        $needs_rc->{$name} = 1;
        $rc_owner->{$name} = @$_dyn_scope_stack ? $_dyn_scope_stack->[-1] : undef;
    }

    # Register an owned class-instance variable: it is RC-tracked like an `Any`, but its release runs the instance's
    # destructor instead of a plain decref.
    method _note_class( $name, $class ) {
        $class_owned->{$name} = $class;
        $self->_note_rc($name);
    }

    # Drop an RC-tracked variable from scope tracking (after it has been decref'd, or when a path no longer needs it).
    method _forget_rc($name) {
        delete $needs_rc->{$name};
        delete $rc_owner->{$name};
        delete $class_owned->{$name};
    }

    # Release one RC-tracked variable: load its slot and hand the value to the right release path. An owned class
    # instance goes through its destructor; everything else (an `Any` box) is a plain decref.
    method _emit_rc_release( $name, $heap_base ) {
        my $addr = $symbols->{$name} or return;

        # A heap array of owned (`Any`) boxes releases each element before the block: array_release walks the count and
        # decrefs every element, then the array itself. A plain decref would recycle the block and leak the boxes.
        if ( $array_owned_elem->{$name} ) {
            my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $addr );
            my $hb     = $heap_base;
            if ( !defined $hb && $symbols->{'__heap_base'} ) {
                $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            }
            $hb = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 ) unless defined $hb;
            my $release = $functions->{'Brocken::Runtime::array_release'};
            $builder->build_call( $release, [ $hb, $loaded ] ) if $release;
            return;
        }

        # A local hash holds a table rather than a plain box: hash_release drops its stored values and then the
        # table itself, which a plain decref would skip.
        if ( $hash_var->{$name} ) {
            my $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $addr );
            my $hb     = $heap_base;
            if ( !defined $hb && $symbols->{'__heap_base'} ) {
                $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            }
            $hb = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 ) unless defined $hb;
            my $release = $functions->{'Brocken::Runtime::hash_release'};
            $builder->build_call( $release, [ $hb, $loaded ] ) if $release;
            return;
        }
        my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::i64(), $addr );
        my $class = $class_owned->{$name};
        if ( $class && !$class_escaped->{$name} ) {
            my $hb = $heap_base;
            if ( !defined $hb && $symbols->{'__heap_base'} ) {
                $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            }
            $self->_emit_obj_release( $loaded, $class, $hb );
        }
        else {
            $builder->build_decref( $loaded, 0, 0, $heap_base );
        }
    }

    # Drop one reference to an owned class instance and, exactly when that was the last one, run the instance's
    # destructor. The runtime decref is split so the statically-known `Class::__destroy` can be called here rather
    # than dispatched from inside the runtime.
    method _emit_obj_release( $loaded, $class, $heap_base ) {
        my $decref = $functions->{'Brocken::Runtime::decref_obj'};
        my $destroy = $functions->{ $class . '::__destroy' };
        if ( !$decref || !$destroy ) {

            # Without the split runtime (or a generated destructor) fall back to a plain decref: the memory is
            # reclaimed but no user DESTROY runs. This only happens for an internal class with no generated runtime.
            $builder->build_decref( $loaded, 0, 0, $heap_base );
            return;
        }
        my $hbi = defined $heap_base ? $heap_base : Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 );
        my $rc        = $builder->build_call( $decref, [ $loaded, $hbi ] );
        my $zero_i64  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
        my $null_ptr  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 );
        my $rc_zero   = $builder->build_icmp( 'eq', $rc, $zero_i64 );
        my $not_null  = $builder->build_icmp( 'ne', $loaded, $null_ptr );
        my $is_dead   = $builder->build_and( $rc_zero, $not_null );
        my $func      = $current_func;
        my $dtor      = $func->append_block( $self->unique_block_name('obj_destroy') );
        my $done      = $func->append_block( $self->unique_block_name('obj_release_end') );
        $builder->position_at_end($current_block);
        $builder->build_cond_br( $is_dead, $dtor, $done );
        $builder->position_at_end($dtor);
        $current_block = $dtor;
        my $want = $symbols->{'__want'} ? $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $symbols->{'__want'} )
            : Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
        $builder->build_call( $destroy, [ $hbi, $want, $loaded ] );
        $builder->build_br($done);
        $builder->position_at_end($done);
        $current_block = $done;
    }

    # Lower a block with block-scoped RC cleanup.
    # Variables declared as `Any` inside the block are decref'd at block exit, not at function exit.  Early return,
    # last, or next from inside the block bypasses this cleanup; those paths rely on the function-scoped decref loop.
    method lower_block($block_ast) {
        my @saved_keys = sort keys %$needs_rc;
        $self->lower_block_body($block_ast);
        my %saved;
        @saved{@saved_keys} = (1) x @saved_keys;
        my @to_clean;
        for my $name ( sort keys %$needs_rc ) {
            push @to_clean, $name unless exists $saved{$name};
        }
        return unless @to_clean;
        return if $current_block->terminator;
        my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
        for my $name (@to_clean) {
            $self->_emit_rc_release( $name, $decref_hb );
            $self->_forget_rc($name);
        }
    }

    # Statement lowering
    method lower_statement($stmt) {
        return unless defined $stmt;
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::VarDecl') )       { return $self->lower_var_decl($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ArrayDecl') )     { return $self->lower_array_decl($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Assign') )        { return $self->lower_assign($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ListVarDecl') )   { return $self->lower_list_var_decl($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Return') )        { return $self->lower_return($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Throw') )         { return $self->lower_throw($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Exit') )          { return $self->lower_exit($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Warn') )          { return $self->lower_warn($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Die') )           { return $self->lower_die($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::TryCatch') )      { return $self->lower_trycatch($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::If') )            { return $self->lower_if($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::While') )         { return $self->lower_while($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::For') )           { return $self->lower_for($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Break') )         { return $self->lower_break($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Continue') )      { return $self->lower_continue($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Block') )         { return $self->lower_block($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Expr::Call') ) {
            # An expression statement discards its result: an owned `Any` return is a reference nobody keeps.
            my $val = $self->lower_call_expr($stmt);
            $self->_release_owned_call_temp( $val, $stmt->line, $stmt->col );
            return;
        }
        if ( $stmt->isa('Brocken::Katsuro::AST::Expr::IntrinsicCall') ) { $self->lower_intrinsic($stmt); return; }

        # A bare `$x++` statement keeps no result, so an `Any` target steps its slot in place rather than materialising a
        # box that nobody would keep.
        if ( $stmt->isa('Brocken::Katsuro::AST::Expr::IncDec') ) {
            $self->lower_incdec( $stmt, 1 );
            return;
        }

        if ( $stmt->isa('Brocken::Katsuro::AST::Expr::Assign') ) {
            Carp::croak( "Assignment as expression not supported at " . $self->_loc($stmt) );
        }
        if ( $stmt->isa('Brocken::Katsuro::AST::Expr::BinOp') ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::UnOp')        ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Var')         ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Const')       ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Paren')       ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::FieldAccess') ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::ArrayIndex')  ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::HashIndex')   ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Exists')      ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Defined')     ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Delete')      ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::HashKeys')    ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Undef')       ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::UndefOp')     ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::ArrayOp')     ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::MethodCall')  ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::List')        ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Hash')        ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Ternary') ) {
            my $val = $self->lower_expression($stmt);
            # A bare method call as a statement has the same discarded-result shape as a call statement.
            $self->_release_owned_call_temp( $val, $stmt->line, $stmt->col );
            return;
        }
        Carp::croak( "Unknown statement type: " . ref($stmt) . " at " . $self->_loc($stmt) );
    }

    method lower_var_decl($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        return $self->_lower_hash_decl($ast) if $ast->sigil eq '%';
        my $ir_type = $self->type_from_name( $ast->type );
        my $alloca = $builder->build_alloca( $ir_type, $self->unique_value_name( '%' . $ast->name . '.addr' ), undef, $line, $col, $ast->name, $ast->type );
        $symbols->{ $ast->name } = $alloca;
        for my $a ( $ast->attrs->@* ) {
            Carp::croak( "Unknown variable attribute ':" . $a->{name} . "' at " . $self->_loc($ast) ) unless $a->{name} eq 'weak';
        }
        my $is_weak = $self->has_attr( $ast->attrs, 'weak' ) ? 1 : 0;
        $weak_var->{ $ast->name } = 1 if $is_weak;
        if ( $ast->type eq 'Any' && !$is_weak ) {
            $self->_note_rc( $ast->name );
        }
        if ( !defined $ast->init && ( $ir_type->kind eq 'dynamic' || $ir_type->kind eq 'ptr' ) ) {

            # A pointer-shaped slot starts out null, mirroring the Any box. That is what lets `//=`, `||=`, and the `//`
            # operator see an uninitialized `String` (or other ptr) as "undefined" instead of the garbage the fresh
            # stack slot happened to hold.
            my $zero = Brocken::Lindsay::IR::Constant->new( type => $ir_type, value => 0 );
            $builder->build_store( $zero, $alloca, $line, $col );
        }
        if ( defined $ast->init ) {
            my $fresh_class;
            if ( $ast->init->isa('Brocken::Katsuro::AST::Expr::MethodCall') &&
                $ast->init->method eq 'new' &&
                $ast->init->obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
                $var_class->{ $ast->name } = $self->_resolve_class_ident( $ast->init->obj->name );
                $fresh_class = $var_class->{ $ast->name } if $ir_type->kind eq 'ptr';
            }
            elsif ( my $owned_class = $self->_owned_class_call( $ast->init ) ) {

                # A call the callee classified as handing back an owned instance transfers the reference its
                # constructor already wrote, exactly like an inlined `Class->new`: record the class so later
                # field/method access on the local resolves, and let the scope-exit release finalize it.
                $var_class->{ $ast->name } = $owned_class;
                $fresh_class = $owned_class if $ir_type->kind eq 'ptr';
            }
            my $raw_val = $self->lower_expression( $ast->init );
            my $val = $self->maybe_convert_type( $raw_val, $ir_type, $line, $col, 1 );

            # A fresh instance already carries the reference the slot needs -- the constructor wrote a refcount of 1.
            # Track the local for release at scope exit only when nothing can reach it another way (the escape scan
            # above leaves it off the escaped set); otherwise it stays owned, which leaks rather than dangles. A
            # `:weak` local never takes that reference, so it is stored plainly and left untracked.
            if ( $fresh_class && !$class_escaped->{ $ast->name } && !$is_weak ) {
                $self->_note_class( $ast->name, $fresh_class );
                $builder->build_store( $val, $alloca, $line, $col );
            }
            else {

                # An owned dynamic call result already carries the reference the slot needs (F13); take a second one
                # only for values that arrive borrowed (a local, a parameter, a fresh box). A `:weak` slot owns nothing
                # and so never takes a reference.
                if ( $needs_rc->{ $ast->name } && !$self->_owned_call_result($val) ) {
                    $builder->build_incref( $val, $line, $col );
                }
                $builder->build_store( $val, $alloca, $line, $col );
            }

            # An owned call result converted into a non-dynamic slot was unboxed, so the box itself is not stored
            # anywhere; drop its reference. A dynamic slot keeps the box (it consumed the reference above).
            if ( $ir_type->kind ne 'dynamic' ) {
                $self->_release_owned_call_temp( $raw_val, $line, $col );
            }
        }
    }

    # Store a dynamic (`Any`) value into an owned slot, taking a reference to the new value and releasing whatever the
    # slot held before. The displaced value is loaded and decref'd, so the slot must already hold a valid pointer --
    # null or a live box; fresh storage is nulled when it is created. Only dynamic slots are RC-tracked: native and
    # plain-pointer slots must use a plain store. `$heap_base`, when given, is an IR value to use for the decref (the
    # auto-generated accessors have no `__heap_base` symbol, so they pass their own parameter).
    method _emit_owned_store( $val, $addr, $ir_type, $line, $col, $heap_base = undef ) {
        my $old = $builder->build_load( $ir_type, $addr, undef, $line, $col );

        # A dynamic call result already carries an owned reference (F13); the slot consumes it rather than taking a
        # second one. Anything else -- a borrowed argument, an owned local, a fresh box -- needs its own reference.
        $builder->build_incref( $val, $line, $col ) unless $self->_owned_call_result($val);
        $builder->build_store( $val, $addr, $line, $col );
        my $hb = $heap_base;
        if ( !defined $hb && $symbols->{'__heap_base'} ) {
            $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
        }
        $builder->build_decref( $old, $line, $col, $hb );
    }

    # `//=`/`||=` on a dynamic (`Any`) slot is an owned store, but only when the slot is absent: a `select` cannot
    # express "incref the replacement only if it is chosen", so emit a real branch. When the slot is absent (null) the
    # RHS is stored through `_emit_owned_store`, which takes a reference to it and releases the null it displaces;
    # otherwise the slot keeps the box it already owns and no reference changes.
    method _emit_conditional_owned_store( $val, $addr, $ir_type, $line, $col, $op = '//=' ) {
        my $existing    = $builder->build_load( $ir_type, $addr, undef, $line, $col );
        my $is_absent   = $self->_orassign_should_store( $existing, $ir_type, $op, $line, $col );
        my $func        = $current_func;
        my $store_block = $func->append_block( $self->unique_block_name('rc_orassign') );
        my $merge_block = $func->append_block( $self->unique_block_name('rc_orassign_end') );
        $builder->position_at_end($current_block);
        $builder->build_cond_br( $is_absent, $store_block, $merge_block, $line, $col );
        $builder->position_at_end($store_block);
        $current_block = $store_block;
        $self->_emit_owned_store( $val, $addr, $ir_type, $line, $col );
        $builder->build_br( $merge_block, $line, $col );
        $builder->position_at_end($merge_block);
        $current_block = $merge_block;
    }

    # The branch condition shared by the two `//=`/`||=` dynamic-store paths. `//=` stores only into an undefined
    # (null) slot. `||=` stores into a slot that is false, so for a dynamic slot it is Perl truthiness -- a box
    # holding `0`, `0.0`, `""`, or `"0"` is replaced, not just a null box.
    method _orassign_should_store( $existing, $ir_type, $op, $line, $col ) {
        if ( $op eq '||=' && $ir_type->kind eq 'dynamic' ) {
            my $fn = $functions->{'Brocken::Runtime::is_truthy'}
                or Carp::croak("Runtime function is_truthy not found at line $line, col $col");
            my $t    = $builder->build_call( $fn, [$existing], undef, $line, $col );
            my $zero = Brocken::Lindsay::IR::Constant->new( type => $t->type, value => 0 );
            return $builder->build_icmp( 'eq', $t, $zero, undef, $line, $col );
        }
        my $zero = Brocken::Lindsay::IR::Constant->new( type => $ir_type, value => 0 );
        return $builder->build_icmp( 'eq', $existing, $zero, undef, $line, $col );
    }

    # `//=`/`||=` on a borrowed `Any` parameter slot. The slot may end up keeping the caller's borrowed box, so it
    # cannot be released at exit without a matching reference: increment whichever value the test chooses (a no-op
    # balance for the borrowed box, a real reference for a freshly stored one) and store it; the caller promotes the
    # slot to owned afterwards, so the exit cleanup releases exactly the reference taken here.
    method _emit_conditional_borrowed_store( $val, $addr, $ir_type, $line, $col, $op = '//=' ) {
        my $existing  = $builder->build_load( $ir_type, $addr, undef, $line, $col );
        my $is_absent = $self->_orassign_should_store( $existing, $ir_type, $op, $line, $col );
        if ( $self->_owned_call_result($val) ) {

            # The RHS is a call result that already owns a reference, so the two outcomes need different references:
            # storing it consumes that reference, while keeping the slot's borrowed box needs a fresh one. A select
            # cannot express that, so branch.
            my $func        = $current_func;
            my $store_block = $func->append_block( $self->unique_block_name('rc_borrow_store') );
            my $keep_block  = $func->append_block( $self->unique_block_name('rc_borrow_keep') );
            my $merge_block = $func->append_block( $self->unique_block_name('rc_borrow_end') );
            $builder->position_at_end($current_block);
            $builder->build_cond_br( $is_absent, $store_block, $keep_block, $line, $col );
            $builder->position_at_end($store_block);
            $current_block = $store_block;
            $builder->build_store( $val, $addr, $line, $col );
            $builder->build_br( $merge_block, $line, $col );
            $builder->position_at_end($keep_block);
            $current_block = $keep_block;
            $builder->build_incref( $existing, $line, $col );
            $builder->build_br( $merge_block, $line, $col );
            $builder->position_at_end($merge_block);
            $current_block = $merge_block;
            return;
        }
        my $chosen = $builder->build_select( $is_absent, $val, $existing, undef, $line, $col );
        $builder->build_incref( $chosen, $line, $col );
        $builder->build_store( $chosen, $addr, $line, $col );
    }

    method lower_assign($ast) {
        my $target = $ast->target;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        return $self->_lower_hash_store( $target, $ast->expr, $line, $col )
            if $target->isa('Brocken::Katsuro::AST::Expr::HashIndex');
        if ( $target->isa('Brocken::Katsuro::AST::Expr::Var') &&
            $ast->expr->isa('Brocken::Katsuro::AST::Expr::MethodCall') &&
            $ast->expr->method eq 'new' &&
            $ast->expr->obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
            $var_class->{ $target->name } = $self->_resolve_class_ident( $ast->expr->obj->name );
        }
        elsif ( $target->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            my $owned_class = $self->_owned_class_call( $ast->expr );
            $var_class->{ $target->name } = $owned_class if $owned_class;
        }
        my $raw_val = $self->lower_expression( $ast->expr );
        my $val = $raw_val;
        my $addr;
        my $stored_type;
        my $is_field_target = 0;
        my $is_weak_field   = 0;
        if ( $target->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            my $key = $target->sigil eq '@' ? '@' . $target->name : $target->name;
            $addr = $symbols->{$key};
            Carp::croak( "Undefined variable '" . $target->name . "' at " . $self->_loc($target) ) unless $addr;
            if ( $addr->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') && $current_class ) {
                my $cd      = $classes->{$current_class};
                my ($field) = $cd ? grep { $_->{name} eq $target->name } $cd->{own_fields}->@* : ();
                $stored_type    = $field ? $field->{ir_type} : Brocken::Lindsay::IR::Type::i64();
                $is_field_target = 1;    # a bare field name in a method body is a Var bound to its struct GEP
                $is_weak_field   = 1 if $field && $field->{weak};
            }
            else {
                $stored_type = $addr->allocated_type // $val->type;
            }
        }
        elsif ( $target->isa('Brocken::Katsuro::AST::Expr::FieldAccess') ) {
            $addr = $self->lower_field_addr($target);
            my $cls     = $self->resolve_class_name($target);
            my $cd      = $classes->{$cls};
            my ($field) = grep { $_->{name} eq $target->field } $cd->{own_fields}->@*;
            Carp::croak( "Unknown field '" . $target->field . "' in class '" . $cls . "' at " . $self->_loc($target) ) unless $field;
            $stored_type     = $field->{ir_type};
            $is_field_target = 1;
            $is_weak_field   = 1 if $field->{weak};
        }
        elsif ( $target->isa('Brocken::Katsuro::AST::Expr::ArrayIndex') ) {
            $addr        = $self->lower_array_addr($target);
            $stored_type = $addr->base_type;
        }
        else {
            Carp::croak( "Assignment target must be a variable, field access, or array index at " . $self->_loc($target) );
        }
        $val = $self->maybe_convert_type( $val, $stored_type, $line, $col, 1 );
        my $is_rc        = $target->isa('Brocken::Katsuro::AST::Expr::Var') && $needs_rc->{ $target->name };
        my $is_borrowed  = $target->isa('Brocken::Katsuro::AST::Expr::Var') && $borrowed_params->{ $target->name };
        my $is_dyn_field = $is_field_target && $stored_type->kind eq 'dynamic' && !$is_weak_field;

        # An element of a local managed (`Any`) array is itself an owning slot: `array_release` at scope exit drops one
        # reference per element, so a store into one takes a reference and releases what it displaces, exactly like an
        # `Any` local. A field/inline array element stays a plain store (its array has no element-release path).
        my $is_owned_elem = $target->isa('Brocken::Katsuro::AST::Expr::ArrayIndex')
            && $target->array->isa('Brocken::Katsuro::AST::Expr::Var')
            && $target->array->sigil eq '@'
            && $array_owned_elem->{ '@' . $target->array->name };

        # Only an RC-tracked dynamic slot owns its referent: an `Any` local, a dynamic field, a borrowed `Any`
        # parameter, or an owned `Any` array element. A `:weak` field deliberately keeps no reference, so it keeps the
        # branchless form below.
        my $is_dyn_rc = $is_dyn_field
            || ( $stored_type->kind eq 'dynamic' && ( $is_rc || $is_borrowed || $is_owned_elem ) );

        # Reassigning a plain local that owns a class instance takes the same ownership contract as an `Any` slot,
        # but the displaced instance is released through its destructor. Two RHS shapes hand over an owned reference:
        # a fresh `Class->new`, and a call the callee classified as class-return-owned (see
        # `_classify_class_return_ownership`); either already carries the reference the slot consumes. Any other RHS
        # is borrowed and would alias, so an owned local is dropped from ownership instead (it leaks the value it
        # held -- never a dangling free). A field target is excluded: field stores go through the
        # accessor/constructor path, which has its own ownership rules.
        if ( $target->isa('Brocken::Katsuro::AST::Expr::Var') && !$is_field_target && $ast->op eq '=' ) {
            my $rhs_class;
            if ( $stored_type->kind eq 'ptr'
                && $ast->expr->isa('Brocken::Katsuro::AST::Expr::MethodCall')
                && $ast->expr->method eq 'new'
                && $ast->expr->obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
                $rhs_class = $self->_resolve_class_ident( $ast->expr->obj->name );
            }
            else {
                $rhs_class = $self->_owned_class_call( $ast->expr );
            }
            my $tracked = $class_owned->{ $target->name };

            # An escaped local is one the escape scan saw used as a value somewhere else, so it was never tracked and
            # must not become so here: that use may have retained the pointer without taking a reference (a `ptr`
            # store does not incref), and a scope-exit release would then free it out from under the other holder.
            # Store plainly and leak instead.
            if ( $rhs_class && !$class_escaped->{ $target->name } ) {
                my $hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;

                # Only a slot already tracking its referent owns the value it displaces: an untracked slot holds a
                # borrow or null, which must not be released. Release through the old instance's own class.
                my $old = $tracked ? $builder->build_load( $stored_type, $addr, undef, $line, $col ) : undef;
                $self->_note_class( $target->name, $rhs_class );
                $builder->build_store( $val, $addr, $line, $col );
                $self->_emit_obj_release( $old, $tracked, $hb ) if $tracked;
                return;
            }
            if ($tracked) {
                $self->_forget_rc( $target->name );
                $builder->build_store( $val, $addr, $line, $col );
                return;
            }
        }
        if ( $ast->op eq '//=' || $ast->op eq '||=' ) {

            # `//=` and `||=` both keep the value already in the slot when it counts as "present" and store the RHS
            # otherwise. They differ in what "present" means: `//=` wants the slot to be defined (non-null), so it
            # tests a pointer-shaped or boxed value against null; `||=` wants it to be true, so it tests its type
            # against zero (false, 0, 0.0, or null).
            #
            # A native int/float/bool has no undefined value, so `//=` on one has no null test to make and degrades
            # to a plain store -- deliberate, and pinned by t/10000_katsuro/10980_defined_or_assign.t. `||=` still
            # compares a native against zero.
            #
            # A dynamic (`Any`) slot is RC-tracked, so the replacement is only incref'd when it is actually stored;
            # that needs a branch (F2). Pointer and native slots are not RC-tracked: they keep the branchless select
            # (a pointer's null test, a native's zero test).
            my $is_nullable = $stored_type->kind eq 'ptr' || $stored_type->kind eq 'dynamic';
            if ($is_dyn_rc) {
                if ($is_borrowed) {

                    # The slot may keep the caller's borrowed box, so the exit cleanup can only own it if that box's
                    # reference is balanced now; increment whichever value the test chooses and promote the slot.
                    $self->_emit_conditional_borrowed_store( $val, $addr, $stored_type, $line, $col, $ast->op );
                    delete $borrowed_params->{ $target->name };
                    $self->_note_rc( $target->name );
                }
                else {
                    $self->_emit_conditional_owned_store( $val, $addr, $stored_type, $line, $col, $ast->op );
                }
            }
            elsif ( $is_nullable || $ast->op eq '||=' ) {
                my $existing  = $builder->build_load( $stored_type, $addr, undef, $line, $col );
                my $zero      = Brocken::Lindsay::IR::Constant->new( type => $stored_type, value => 0 );
                my $is_absent = $builder->build_icmp( 'eq', $existing, $zero, undef, $line, $col );
                my $new_val   = $builder->build_select( $is_absent, $val, $existing, undef, $line, $col );
                $builder->build_store( $new_val, $addr, $line, $col );
            }
            else {
                $builder->build_store( $val, $addr, $line, $col );
            }
        }
        else {
            if ( $is_rc || $is_dyn_field || $is_owned_elem ) {
                $self->_emit_owned_store( $val, $addr, $stored_type, $line, $col );
            }
            elsif ($is_borrowed) {

                # Storing into a parameter slot that still holds the caller's borrowed reference. Take our own
                # reference to the new value but do NOT release the old one: we never owned it (Caller-Borrows), and
                # releasing it could free the caller's box. From here on the slot is owned, so it is cleaned up at
                # function exit like any other Any local. An owned call result already carries its reference (F13).
                $builder->build_incref( $val, $line, $col ) unless $self->_owned_call_result($val);
                $builder->build_store( $val, $addr, $line, $col );
                delete $borrowed_params->{ $target->name };
                $self->_note_rc( $target->name );
            }
            else {
                $builder->build_store( $val, $addr, $line, $col );
            }
        }

        # An owned call result stored into a non-dynamic slot was converted (unboxed) on the way in, so the box itself
        # is not stored anywhere and its reference would otherwise be stranded. A dynamic slot keeps the box -- an RC
        # slot consumed the reference, a `:weak`/array-element slot holds a borrow -- so those never release here.
        if ( $stored_type->kind ne 'dynamic' ) {
            $self->_release_owned_call_temp( $raw_val, $line, $col );
        }
    }

    # Pop `$count` exception handlers off the ICB stack. `return`/`last`/`next` reach for this so a non-local jump out
    # of a `try` body does not leave the stack pointing at a handler whose jmp_buf belongs to a frame that is about to
    # go away (F4). Each pop is `head = *head` in ICB.exception_handler_stack -- the same sequence `lower_trycatch`
    # emits on its normal and exceptional exits. `__heap_base` is in scope whenever a handler is on the stack, because
    # only `try/catch` increments `$_try_handler_depth` and it requires `__heap_base`.
    method _emit_handler_pops( $count, $line, $col ) {
        return unless $count && $count > 0;
        my $hb_alloca = $symbols->{'__heap_base'} or return;
        my $i64_type  = Brocken::Lindsay::IR::Type::i64();
        for ( 1 .. $count ) {
            my $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $hb_alloca, undef, $line, $col );
            my $eh = $builder->build_add( $hb,
                Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => Brocken::ICB::EXCEPTION_HANDLER_STACK ),
                undef, $line, $col );
            my $head = $builder->build_load( $i64_type, $eh,   undef, $line, $col );
            my $next = $builder->build_load( $i64_type, $head, undef, $line, $col );
            $builder->build_store( $next, $eh, $line, $col );
        }
    }

    method lower_return($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        if ( defined $ast->expr ) {
            my $val      = $self->lower_expression( $ast->expr );
            my $ret_type = $current_func->return_type;
            $val = $self->maybe_convert_type( $val, $ret_type, $line, $col, 1 );
            my @rc_names = sort keys %$needs_rc;

            # Hand the caller an owned reference for a dynamic return. An owned-returning function (+1) increfs the
            # value unless it already carries a reference (a call result, F13); the cleanup below then releases its own
            # locals, so the returned box survives with exactly the caller's reference. The incref must also protect an
            # owned local that the cleanup is about to decref, which is why it runs even when the type test would have
            # said `dynamic` and an earlier rename once left it comparing against `any`.
            #
            # A function whose every dynamic return is a bare borrowed parameter (+0) is left alone: the box belongs to
            # the caller, who passed it in, and the caller increfs when it stores the result (F3).
            if ( $val->type && $val->type->kind eq 'dynamic' && $returns_owned->{ $current_func->name } ) {
                $builder->build_incref( $val, $line, $col ) unless $self->_owned_call_result($val);
            }
            if (@rc_names) {
                my $hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
                for my $name (@rc_names) {
                    $self->_emit_rc_release( $name, $hb );
                }
            }
            $self->_emit_handler_pops( $_try_handler_depth, $line, $col );
            $builder->build_ret( $val, $line, $col );
        }
        else {
            my @rc_names = sort keys %$needs_rc;
            if (@rc_names) {
                my $decref_hb
                    = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
                for my $name (@rc_names) {
                    $self->_emit_rc_release( $name, $decref_hb );
                }
            }
            $self->_emit_handler_pops( $_try_handler_depth, $line, $col );
            $builder->build_ret( undef, $line, $col );
        }
    }

    method lower_if($ast) {
        my $func = $current_func;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $then_block  = $func->append_block( $self->unique_block_name('then') );
        my $merge_block = $func->append_block( $self->unique_block_name('if_end') );
        my $else_block;
        my $has_else = defined $ast->else || $ast->elsif->@* > 0;
        my $cond     = $self->as_condition( $self->lower_expression( $ast->cond ), $line, $col );
        if ($has_else) {
            $else_block = $func->append_block( $self->unique_block_name('else') );
            $builder->position_at_end($current_block);
            $builder->build_cond_br( $cond, $then_block, $else_block, $line, $col );
        }
        else {
            $builder->position_at_end($current_block);
            $builder->build_cond_br( $cond, $then_block, $merge_block, $line, $col );
        }
        $builder->position_at_end($then_block);
        $current_block = $then_block;

        # Branch bodies are block-scoped, so they get the same cleanup a bare block does: an `Any` declared in the
        # branch is released when the branch ends rather than at function exit. Without this a branch inside a loop
        # leaks one box per iteration (F12).
        $self->lower_block( $ast->then );
        unless ( $current_block->terminator ) {
            $builder->build_br( $merge_block, $line, $col );
        }
        if ($has_else) {
            $builder->position_at_end($else_block);
            $current_block = $else_block;
            if ( $ast->elsif->@* > 0 ) {
                my $first_elsif = $ast->elsif->[0];
                $self->lower_elsif_chain( $first_elsif, $merge_block, \@{ $ast->elsif }, 0 );
            }
            elsif ( defined $ast->else ) {
                $self->lower_block( $ast->else );
            }
            unless ( $current_block->terminator ) {
                $builder->build_br( $merge_block, $line, $col );
            }
        }
        $builder->position_at_end($merge_block);
        $current_block = $merge_block;
    }

    method lower_elsif_chain( $pair, $merge_block, $all_pairs, $idx ) {
        my ( $line, $col ) = ( $pair->[0]->line // 0, $pair->[0]->col // 0 );
        my $cond = $self->as_condition( $self->lower_expression( $pair->[0] ), $line, $col );
        my $body = $pair->[1];
        my $func = $current_func;
        my $then = $func->append_block( $self->unique_block_name('elsif_then') );
        my $next;
        my $next_idx = $idx + 1;
        if ( $next_idx < $all_pairs->@* ) {
            $next = $func->append_block( $self->unique_block_name('elsif_n') );
            $builder->position_at_end($current_block);
            $builder->build_cond_br( $cond, $then, $next, $line, $col );
        }
        else {
            $next = $merge_block;
            $builder->position_at_end($current_block);
            $builder->build_cond_br( $cond, $then, $next, $line, $col );
        }
        $builder->position_at_end($then);
        $current_block = $then;
        $self->lower_block($body);
        unless ( $current_block->terminator ) {
            $builder->build_br( $merge_block, $line, $col );
        }
        if ( $next_idx < $all_pairs->@* ) {
            $builder->position_at_end($next);
            $current_block = $next;
            $self->lower_elsif_chain( $all_pairs->[$next_idx], $merge_block, $all_pairs, $next_idx );
        }
    }

    method lower_while($ast) {
        my $func = $current_func;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $header = $func->append_block( $self->unique_block_name('while_header') );
        my $check  = $func->append_block( $self->unique_block_name('while_check') );
        my $body   = $func->append_block( $self->unique_block_name('while_body') );
        my $exit   = $func->append_block( $self->unique_block_name('while_end') );
        push $_loop_header_blocks->@*, $header;
        push $_loop_check_blocks->@*,  $check;
        push $_loop_exit_blocks->@*,   $exit;
        push $_loop_handler_depths->@*, $_try_handler_depth;    # `last`/`next` pop only what a `try` inside this body pushed
        $builder->build_br( $header, $line, $col );
        $builder->position_at_end($header);
        $current_block = $header;
        my $cond = $self->as_condition( $self->lower_expression( $ast->cond ), $line, $col );
        $builder->build_cond_br( $cond, $check, $exit, $line, $col );

        # Check block: decrement fuel at [hb+64]; bail if exhausted.
        # Skip fuel check if function lacks %__heap_base (e.g. runtime functions).
        $builder->position_at_end($check);
        $current_block = $check;
        if ( $symbols->{'__heap_base'} ) {
            my $hb_for_fuel = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
            my $fuel_off    = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::FUEL );
            my $fuel_addr   = $builder->build_add( $hb_for_fuel, $fuel_off, undef, $line, $col );
            my $fuel_val    = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $fuel_addr, undef, $line, $col );
            my $one         = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
            my $fuel_after  = $builder->build_sub( $fuel_val, $one, undef, $line, $col );
            $builder->build_store( $fuel_after, $fuel_addr, $line, $col );
            my $zero      = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
            my $exhausted = $builder->build_icmp( 'sle', $fuel_after, $zero, undef, $line, $col );
            $builder->build_cond_br( $exhausted, $exit, $body, $line, $col );
        }
        else {
            $builder->build_br( $body, $line, $col );
        }
        $builder->position_at_end($body);
        $current_block = $body;
        my $loop_scope = { rc_pre => {%$needs_rc} };
        push $_dyn_scope_stack->@*,  $loop_scope;
        push $_loop_body_scopes->@*, $loop_scope;
        $self->lower_block_statements( $ast->body );
        pop $_loop_body_scopes->@*;
        pop $_dyn_scope_stack->@*;

        # Free RC-tracked values the body created this iteration (arrays and Any) so a loop that re-declares a heap
        # array each pass reuses the freed slab instead of growing the arena.
        $self->_emit_loop_back_edge_rc_cleanup($loop_scope) unless $current_block->terminator;
        unless ( $current_block->terminator ) {
            $builder->build_br( $header, $line, $col );
        }
        pop $_loop_header_blocks->@*;
        pop $_loop_check_blocks->@*;
        pop $_loop_exit_blocks->@*;
        pop $_loop_handler_depths->@*;

        # The loop body's RC vars are scoped to the loop: every iteration path freed them (back edge, break, next).
        # Drop any still tracked for this loop so a later block/function exit does not decref a dead slot again.
        $self->_forget_rc($_) for grep { defined $rc_owner->{$_} && $rc_owner->{$_} == $loop_scope } keys %$needs_rc;
        $builder->position_at_end($exit);
        $current_block = $exit;
    }

    # `for`/`foreach my (TARGETS) (LIST) { ... }`. The list is evaluated once; the loop walks it a stride at a time,
    # where the stride is the number of loop variables, and binds each variable from the matching list slot before
    # running the body. It reuses the block shape of `lower_while` (header -> fuel check -> body -> back edge) so
    # `last`/`next` and the per-iteration RC cleanup behave the same.
    method lower_for($ast) {
        # `for my $i (0 .. N)` is a range, not a list: lower it to an induction loop (spec 4.5) rather than building
        # and walking a tag-7 list.
        if ( $ast->expr && $ast->expr->isa('Brocken::Katsuro::AST::Expr::Range') ) {
            return $self->lower_for_range($ast);
        }
        my $func = $current_func;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $i64_type     = Brocken::Lindsay::IR::Type::i64();
        my $dynamic_type = Brocken::Lindsay::IR::Type::dynamic();
        my @targets      = $ast->targets->@*;
        Carp::croak( "for requires at least one loop variable at " . $self->_loc($ast) ) unless @targets;
        my $stride = scalar @targets;

        # The iterable is a tag-7 list: count at +8, one boxed element per eight-byte slot from +16. A call that
        # produces it must be told want=list, or the callee boxes a single scalar and the loop reads that scalar as if
        # it were a list pointer. The override is set just for the iterable, then the caller's own want is restored.
        my $saved_want   = $_want_override;
        $_want_override  = 2;
        my $list_ptr     = $self->_lower_iterable( $ast->expr, $line, $col );
        $_want_override  = $saved_want;

        # Loop variables get their slots before the loop, so the body reads them across iterations and they are bound,
        # not re-declared, each pass. A slot borrows the box the list holds: it is deliberately *not* RC-tracked, since
        # releasing it here would free a box the list still points at (the same reason `lower_list_var_decl` is the only
        # place a list slot is increfed). The conservative result is that a box reachable only through a loop variable
        # stays alive to the end of the arena rather than risk a dangling free.
        my @slots;
        for my $t (@targets) {
            my $ir_type = $self->type_from_name( $t->{type} );
            my $alloca  = $builder->build_alloca( $ir_type, $self->unique_value_name( '%' . $t->{name} . '.addr' ), undef, $line, $col, $t->{name}, $t->{type} );
            $symbols->{ $t->{name} } = $alloca;
            push @slots, $alloca;
        }

        my $cond = $func->append_block( $self->unique_block_name('for_cond') );
        my $check = $func->append_block( $self->unique_block_name('for_check') );
        my $body  = $func->append_block( $self->unique_block_name('for_body') );
        my $incr  = $func->append_block( $self->unique_block_name('for_incr') );
        my $exit  = $func->append_block( $self->unique_block_name('for_end') );

        # `next` has to run the stride advance before the next test, so the increment block -- not the condition block --
        # is what the loop-control lowering treats as the loop header and jumps to. `last` still targets the exit.
        push $_loop_header_blocks->@*, $incr;
        push $_loop_check_blocks->@*,  $check;
        push $_loop_exit_blocks->@*,   $exit;
        push $_loop_handler_depths->@*, $_try_handler_depth;    # `last`/`next` pop only what a `try` inside this body pushed

        my $k_slot = $builder->build_alloca( $i64_type, $self->unique_value_name('%for.k'), undef, $line, $col );
        my $zero   = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 0 );
        $builder->build_store( $zero, $k_slot, $line, $col );
        $builder->build_br( $cond, $line, $col );

        # Condition: stop when fewer than a stride of elements remain (k + stride > count). The signed `sle` against
        # `count - stride` also skips the loop when the list is shorter than the stride, since the limit goes negative.
        $builder->position_at_end($cond);
        $current_block = $cond;
        my $count_addr = $builder->build_add( $list_ptr, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 8 ), undef, $line, $col );
        my $count      = $builder->build_load( $i64_type, $count_addr, undef, $line, $col );
        my $k          = $builder->build_load( $i64_type, $k_slot, undef, $line, $col );
        my $limit      = $builder->build_sub( $count, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => $stride ), undef, $line, $col );
        my $more       = $builder->build_icmp( 'sle', $k, $limit, undef, $line, $col );
        $builder->build_cond_br( $more, $check, $exit, $line, $col );

        # Fuel check, exactly as `while`: bail to the exit when the decrement drops to zero.
        $builder->position_at_end($check);
        $current_block = $check;
        if ( $symbols->{'__heap_base'} ) {
            my $hb_for_fuel = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
            my $fuel_off    = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => Brocken::ICB::FUEL );
            my $fuel_addr   = $builder->build_add( $hb_for_fuel, $fuel_off, undef, $line, $col );
            my $fuel_val    = $builder->build_load( $i64_type, $fuel_addr, undef, $line, $col );
            my $one         = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 1 );
            my $fuel_after  = $builder->build_sub( $fuel_val, $one, undef, $line, $col );
            $builder->build_store( $fuel_after, $fuel_addr, $line, $col );
            my $exhausted = $builder->build_icmp( 'sle', $fuel_after, $zero, undef, $line, $col );
            $builder->build_cond_br( $exhausted, $exit, $body, $line, $col );
        }
        else {
            $builder->build_br( $body, $line, $col );
        }

        $builder->position_at_end($body);
        $current_block = $body;

        # Bind the stride's worth of slots for this pass. The boxes are read as dynamics, exactly as `lower_list_var_decl`
        # reads them, and converted to the declared target type. `k` is the element index of the stride's first slot, so
        # the row starts at byte `k * 8` and slot `j` sits `j * 8` further in.
        my $k_now   = $builder->build_load( $i64_type, $k_slot, undef, $line, $col );
        my $row_off = $builder->build_mul( $k_now, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 8 ), undef, $line, $col );
        for my $j ( 0 .. $stride - 1 ) {
            my $slot_off  = $builder->build_add( $row_off, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 16 + $j * 8 ), undef, $line, $col );
            my $elem_addr = $builder->build_gep( Brocken::Lindsay::IR::Type::i8(), $list_ptr, [$slot_off], undef, $line, $col );
            my $elem_dyn  = $builder->build_load( $dynamic_type, $elem_addr, undef, $line, $col );
            my $t         = $targets[$j];
            my $ir_type   = $self->type_from_name( $t->{type} );

            # A `String`/class target wants the *payload* pointer, which lives at box + 8. A `dynamic -> ptr` conversion
            # is deliberately left alone by `maybe_convert_type` -- it is the box pointer the `ptr`-taking runtime
            # helpers read the header through -- so the payload is unboxed explicitly here, the same way `stringify`,
            # `trim`, and method dispatch already read a pointer out of a box.
            my $elem_val
                = $t->{type} eq 'Any'     ? $elem_dyn
                : $ir_type->kind eq 'ptr' ? $builder->build_unbox( $elem_dyn, $ir_type, undef, $line, $col )
                :                           $self->maybe_convert_type( $elem_dyn, $ir_type, $line, $col );
            $builder->build_store( $elem_val, $slots[$j], $line, $col );
        }

        my $loop_scope = { rc_pre => {%$needs_rc} };
        push $_dyn_scope_stack->@*,  $loop_scope;
        push $_loop_body_scopes->@*, $loop_scope;
        $self->lower_block_statements( $ast->body );
        pop $_loop_body_scopes->@*;
        pop $_dyn_scope_stack->@*;

        $self->_emit_loop_back_edge_rc_cleanup($loop_scope) unless $current_block->terminator;
        $builder->build_br( $incr, $line, $col ) unless $current_block->terminator;

        # Advance the stride and re-test. `next` jumps straight here.
        $builder->position_at_end($incr);
        $current_block = $incr;
        my $k_cur  = $builder->build_load( $i64_type, $k_slot, undef, $line, $col );
        my $k_next = $builder->build_add( $k_cur, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => $stride ), undef, $line, $col );
        $builder->build_store( $k_next, $k_slot, $line, $col );
        $builder->build_br( $cond, $line, $col );

        pop $_loop_header_blocks->@*;
        pop $_loop_check_blocks->@*;
        pop $_loop_exit_blocks->@*;
        pop $_loop_handler_depths->@*;
        $self->_forget_rc($_) for grep { defined $rc_owner->{$_} && $rc_owner->{$_} == $loop_scope } keys %$needs_rc;
        $builder->position_at_end($exit);
        $current_block = $exit;
    }

    # `for my $i (LO .. HI)` as a zero-allocation induction loop (spec 4.5): `$i = LO; while ($i <= HI) { ...; $i++ }`.
    # Both bounds are evaluated once, and the loop variable is a native integer -- untyped (`Any`) means `i64`, and any
    # other declared type must be an integer, so nothing is boxed or allocated per pass. The range is inclusive at both
    # ends, so the test is `<=` (unsigned types use `ule`). Empty and descending ranges run zero times, because a
    # `[LO, HI]` with `LO > HI` fails the first test; like every other loop the induction is also fuel-guarded.
    method lower_for_range($ast) {
        my $func = $current_func;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $i64_type = Brocken::Lindsay::IR::Type::i64();
        my @targets  = $ast->targets->@*;
        Carp::croak( "a range loop takes exactly one variable at " . $self->_loc($ast) ) unless @targets == 1;
        my $t = $targets[0];

        my $declared = $t->{type};
        my $ir_type  = $declared eq 'Any' ? $i64_type : $self->type_from_name($declared);
        Carp::croak( "a range loop variable must be an integer, not $declared at " . $self->_loc($ast) )
            unless $ir_type->kind eq 'int';

        # Bounds first, so their values are live in the entry block and evaluated only once, then converted to the
        # induction type (a dynamic bound is unboxed to an integer here).
        my $from_val = $self->maybe_convert_type( $self->lower_expression( $ast->expr->from ), $ir_type, $line, $col );
        my $to_val   = $self->maybe_convert_type( $self->lower_expression( $ast->expr->to ),   $ir_type, $line, $col );

        my $slot = $builder->build_alloca( $ir_type, $self->unique_value_name( '%' . $t->{name} . '.addr' ), undef, $line, $col, $t->{name}, $t->{type} );
        $symbols->{ $t->{name} } = $slot;
        $builder->build_store( $from_val, $slot, $line, $col );

        my $cond = $func->append_block( $self->unique_block_name('range_cond') );
        my $check = $func->append_block( $self->unique_block_name('range_check') );
        my $body  = $func->append_block( $self->unique_block_name('range_body') );
        my $incr  = $func->append_block( $self->unique_block_name('range_incr') );
        my $exit  = $func->append_block( $self->unique_block_name('range_end') );

        # As in `lower_for`, `next` runs the increment before re-testing, so the header it jumps to is the increment.
        push $_loop_header_blocks->@*, $incr;
        push $_loop_check_blocks->@*,  $check;
        push $_loop_exit_blocks->@*,   $exit;
        push $_loop_handler_depths->@*, $_try_handler_depth;    # `last`/`next` pop only what a `try` inside this body pushed

        $builder->build_br( $cond, $line, $col );

        $builder->position_at_end($cond);
        $current_block = $cond;
        my $pred  = $ir_type->is_unsigned ? 'ule' : 'sle';
        my $i     = $builder->build_load( $ir_type, $slot, undef, $line, $col );
        my $more  = $builder->build_icmp( $pred, $i, $to_val, undef, $line, $col );
        $builder->build_cond_br( $more, $check, $exit, $line, $col );

        # Fuel check, exactly as `while`/`for`: bail to the exit when the decrement reaches zero.
        $builder->position_at_end($check);
        $current_block = $check;
        if ( $symbols->{'__heap_base'} ) {
            my $zero       = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 0 );
            my $hb         = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
            my $fuel_addr  = $builder->build_add( $hb, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => Brocken::ICB::FUEL ), undef, $line, $col );
            my $fuel       = $builder->build_load( $i64_type, $fuel_addr, undef, $line, $col );
            my $fuel_after = $builder->build_sub( $fuel, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 1 ), undef, $line, $col );
            $builder->build_store( $fuel_after, $fuel_addr, $line, $col );
            my $exhausted = $builder->build_icmp( 'sle', $fuel_after, $zero, undef, $line, $col );
            $builder->build_cond_br( $exhausted, $exit, $body, $line, $col );
        }
        else {
            $builder->build_br( $body, $line, $col );
        }

        $builder->position_at_end($body);
        $current_block = $body;
        my $loop_scope = { rc_pre => {%$needs_rc} };
        push $_dyn_scope_stack->@*,  $loop_scope;
        push $_loop_body_scopes->@*, $loop_scope;
        $self->lower_block_statements( $ast->body );
        pop $_loop_body_scopes->@*;
        pop $_dyn_scope_stack->@*;

        $self->_emit_loop_back_edge_rc_cleanup($loop_scope) unless $current_block->terminator;
        $builder->build_br( $incr, $line, $col ) unless $current_block->terminator;

        $builder->position_at_end($incr);
        $current_block = $incr;
        my $i_cur  = $builder->build_load( $ir_type, $slot, undef, $line, $col );
        my $one    = Brocken::Lindsay::IR::Constant->new( type => $ir_type, value => 1 );
        my $i_next = $builder->build_add( $i_cur, $one, undef, $line, $col );
        $builder->build_store( $i_next, $slot, $line, $col );
        $builder->build_br( $cond, $line, $col );

        pop $_loop_header_blocks->@*;
        pop $_loop_check_blocks->@*;
        pop $_loop_exit_blocks->@*;
        pop $_loop_handler_depths->@*;
        $self->_forget_rc($_) for grep { defined $rc_owner->{$_} && $rc_owner->{$_} == $loop_scope } keys %$needs_rc;
        $builder->position_at_end($exit);
        $current_block = $exit;
    }

    # The iterable of a `for`, as a tag-7 list pointer. An omitted list is the empty list; a bare local array is
    # unrolled into its elements when its length folded to a constant; anything else must already lower to a list
    # pointer (an `Expr::List`, `builtin::indexed`, ...). A boxed iterable is unboxed to its pointer payload.
    method _lower_iterable( $expr, $line, $col ) {
        my $list_ast = Brocken::Katsuro::AST::Expr::List->new(
            file => ( defined $expr ? $expr->file : '' ), line => ( defined $expr ? $expr->line : $line ), col => ( defined $expr ? $expr->col : $col ),
            elements => [],
        );
        return $self->lower_list_expr($list_ast) unless defined $expr;
        if ( $self->_is_local_array($expr) ) {
            my @elements = $self->_array_element_exprs( $expr, $line, $col );
            return $self->lower_list_expr(
                Brocken::Katsuro::AST::Expr::List->new( file => $expr->file, line => $expr->line, col => $expr->col, elements => \@elements ) );
        }
        my $val  = $self->lower_expression($expr);
        my $kind = $val->type->kind;
        return $builder->build_unbox( $val, Brocken::Lindsay::IR::Type::ptr(), undef, $line, $col ) if $kind eq 'dynamic';
        Carp::croak( "for expects a list, but the expression has type $kind at " . $self->_loc($expr) ) unless $kind eq 'ptr';
        return $val;
    }

    # Whether an expression names a local array variable (as opposed to a field array, whose elements this front end
    # does not unroll). A local array's symbol is its alloca or pointer slot; a field array's is a struct GEP.
    method _is_local_array($expr) {
        return 0 unless $expr->isa('Brocken::Katsuro::AST::Expr::Var') && $expr->sigil eq '@';
        my $sym = $symbols->{ '@' . $expr->name };
        return 0 unless $sym;
        return 0 if $sym->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') && $sym->base_type && $sym->base_type->kind eq 'struct';
        return 1;
    }

    # Unroll a compile-time-sized local array into one `@a[i]` expression per element. The index form is what the
    # array lowerer already knows how to address for both a stack array and a heap array.
    method _array_element_exprs( $array_expr, $line, $col ) {
        my $key   = '@' . $array_expr->name;
        my $count = $array_counts->{$key};
        Carp::croak( "Cannot iterate '\@" . $array_expr->name . "' at compile time: its length is not a constant at " . $self->_loc($array_expr) )
            unless defined $count;
        my @elements;
        for my $i ( 0 .. $count - 1 ) {
            my $index = Brocken::Katsuro::AST::Expr::Const->new( file => $array_expr->file, line => $array_expr->line, col => $array_expr->col, value => $i, type => 'Int' );
            push @elements, Brocken::Katsuro::AST::Expr::ArrayIndex->new(
                file => $array_expr->file, line => $array_expr->line, col => $array_expr->col, array => $array_expr, index => $index );
        }
        return @elements;
    }

    # Exception handling: setjmp/longjmp intrinsics
    method _ensure_sjlj_intrinsics() {
        return if $functions->{'setjmp'};
        my $setjmp_fn = Brocken::Lindsay::IR::Function->new(
            name        => 'setjmp',
            return_type => Brocken::Lindsay::IR::Type::i64(),
            params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ) ],
        );
        $module->add_function($setjmp_fn);
        $functions->{'setjmp'} = $setjmp_fn;
        my $longjmp_fn = Brocken::Lindsay::IR::Function->new(
            name        => 'longjmp',
            return_type => Brocken::Lindsay::IR::Type::void(),
            params      => [
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i64() ),
            ],
        );
        $module->add_function($longjmp_fn);
        $functions->{'longjmp'} = $longjmp_fn;
    }

    # try/catch/finally lowering
    # CFG structure:
    #   try_setup -> setjmp call, branch on return value
    #   try_body  -> user code, normal exit pops handler -> finally/merge
    #   landing   -> exception path: load thrown_value, pop handler -> catch/finally
    #   catch     -> catch body -> finally/merge
    #   finally   -> finally body -> merge
    method lower_trycatch($ast) {
        my $func = $current_func;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $hb_alloca = $symbols->{'__heap_base'} or Carp::croak( "try/catch requires __heap_base at " . $self->_loc($ast) );
        my $hb        = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $hb_alloca, undef, $line, $col );
        $self->_ensure_sjlj_intrinsics();
        my $try_body_block   = $func->append_block( $self->unique_block_name('try_body') );
        my $landing_block    = $func->append_block( $self->unique_block_name('landing') );
        my $merge_block      = $func->append_block( $self->unique_block_name('try_merge') );
        my $catch_block      = defined $ast->catch_body   ? $func->append_block( $self->unique_block_name('catch') )   : undef;
        my $finally_block    = defined $ast->finally_body ? $func->append_block( $self->unique_block_name('finally') ) : undef;
        my $normal_exit      = $finally_block // $merge_block;
        my $catch_or_finally = $catch_block   // $finally_block // $merge_block;

        # --- try_setup block ---
        my $setup_block = $func->append_block( $self->unique_block_name('try_setup') );
        $builder->build_br( $setup_block, $line, $col );
        $builder->position_at_end($setup_block);
        $current_block = $setup_block;
        my $bump_alloc_fn = $functions->{'Brocken::Runtime::bump_alloc'} or
            Carp::croak( "Runtime function bump_alloc not found at " . $self->_loc($ast) );

        # Allocate handler node (16 bytes): [next_ptr, jmp_buf_ptr]
        my $handler_size = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 16 );
        my $handler      = $builder->build_call( $bump_alloc_fn, [ $hb, $handler_size ], undef, $line, $col );

        # Allocate jmp_buf (256 bytes, generous for all platforms)
        my $jmp_buf_size = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 256 );
        my $jmp_buf      = $builder->build_call( $bump_alloc_fn, [ $hb, $jmp_buf_size ], undef, $line, $col );

        # Load current handler stack head
        my $eh_stack_addr
            = $builder->build_add( $hb,
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::EXCEPTION_HANDLER_STACK ),
            undef, $line, $col, );
        my $old_head = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $eh_stack_addr, undef, $line, $col );

        # Store old_head at handler+0 (next pointer)
        $builder->build_store( $old_head, $handler, $line, $col );

        # Store jmp_buf at handler+8
        my $jmp_buf_slot
            = $builder->build_add( $handler, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 8 ),
            undef, $line, $col, );
        $builder->build_store( $jmp_buf, $jmp_buf_slot, $line, $col );

        # Push handler onto ICB exception_handler_stack
        $builder->build_store( $handler, $eh_stack_addr, $line, $col );

        # Call setjmp(jmp_buf) -> returns 0 on first call, nonzero after longjmp
        my $setjmp_fn = $functions->{'setjmp'};
        my $sj_ret    = $builder->build_call( $setjmp_fn, [$jmp_buf], undef, $line, $col );

        # Branch: 0 -> try body, nonzero -> landing pad
        my $zero   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
        my $is_exc = $builder->build_icmp( 'ne', $sj_ret, $zero, undef, $line, $col );
        $builder->build_cond_br( $is_exc, $landing_block, $try_body_block, $line, $col );

        # --- try body block ---
        $builder->position_at_end($try_body_block);
        $current_block = $try_body_block;

        # The handler is on the ICB stack for the whole body, so a `return`/`last`/`next` that leaves the body must pop
        # it (F4). The body's normal exit and the landing pad pop it themselves, so the depth is only raised here.
        $_try_handler_depth++;
        $self->lower_block_body( $ast->try_body );
        $_try_handler_depth--;

        # Normal exit: pop handler from ICB
        unless ( $current_block->terminator ) {
            my $cur_head         = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $eh_stack_addr, undef, $line, $col );
            my $cur_handler_next = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $cur_head,      undef, $line, $col );
            $builder->build_store( $cur_handler_next, $eh_stack_addr, $line, $col );
            $builder->build_br( $normal_exit, $line, $col );
        }

        # --- landing pad block (exception path) ---
        $builder->position_at_end($landing_block);
        $current_block = $landing_block;

        # setjmp/longjmp only restores callee-saved registers on the exceptional
        # return; any heap-base copy held in a caller-saved register before the
        # jump is garbage here.  Reload from the alloca slot (frame memory is
        # stable across longjmp because rsp returns to its body value).
        $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $hb_alloca, undef, $line, $col );
        $eh_stack_addr
            = $builder->build_add( $hb,
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::EXCEPTION_HANDLER_STACK ),
            undef, $line, $col, );

        # Load thrown value
        my $thrown_addr
            = $builder->build_add( $hb,
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::THROWN_VALUE ),
            undef, $line, $col, );
        my $thrown_val = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $thrown_addr, undef, $line, $col );

        # Store thrown value to catch_var if present. The parser records the binding with its sigil (`$e`), but the
        # symbol table is keyed by the bare name, so strip it. The alloca gets a unique name and the previous binding
        # is saved (not just deleted), so a nested try/catch that reuses the same variable name does not alias the
        # outer catch's slot or leave the outer binding unbound after the inner block.
        my ( $catch_name, $saved_catch_sym );
        if ( $catch_block && defined $ast->catch_var ) {
            $catch_name = $ast->catch_var;
            $catch_name =~ s/^[\$@%]//;
            my $alloca = $builder->build_alloca(
                Brocken::Lindsay::IR::Type::i64(), $self->unique_value_name('%' . $catch_name . '.addr'), undef, $line,
                $col, $catch_name, 'i64',
            );
            $saved_catch_sym       = $symbols->{$catch_name};
            $symbols->{$catch_name} = $alloca;
            $builder->build_store( $thrown_val, $alloca, $line, $col );
        }

        # Pop handler from ICB (re-load from memory since longjmp clobbered registers)
        my $cur_head2         = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $eh_stack_addr, undef, $line, $col );
        my $cur_handler_next2 = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $cur_head2,     undef, $line, $col );
        $builder->build_store( $cur_handler_next2, $eh_stack_addr, $line, $col );

        # Branch to catch or finally
        $builder->build_br( $catch_or_finally, $line, $col );

        # --- catch body block ---
        if ($catch_block) {
            $builder->position_at_end($catch_block);
            $current_block = $catch_block;
            $self->lower_block_body( $ast->catch_body );

            # Restore (or clear) the catch variable binding, so a nested same-named catch does not clobber an outer
            # one and an outer binding survives the inner block.
            if ( defined $catch_name ) {
                if ( defined $saved_catch_sym ) { $symbols->{$catch_name} = $saved_catch_sym }
                else                            { delete $symbols->{$catch_name} }
            }
            unless ( $current_block->terminator ) {
                $builder->build_br( $finally_block // $merge_block, $line, $col );
            }
        }

        # --- finally body block ---
        if ($finally_block) {
            $builder->position_at_end($finally_block);
            $current_block = $finally_block;
            $self->lower_block_body( $ast->finally_body );
            unless ( $current_block->terminator ) {
                $builder->build_br( $merge_block, $line, $col );
            }
        }

        # --- merge block ---
        $builder->position_at_end($merge_block);
        $current_block = $merge_block;
    }

    # throw lowering
    # Evaluate expr, store in ICB.thrown_value.
    # If handler exists: longjmp to it.
    # If no handler: set err_code = ERR_THROW, continue.
    method lower_throw($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        $self->_ensure_sjlj_intrinsics();
        my $val = $self->lower_expression( $ast->expr );
        $self->_emit_throw_dispatch( $val, $line, $col, 0 );
    }

    # Shared `throw`/`die` codegen. The value is parked in ICB.thrown_value and control leaves through the innermost
    # handler's `longjmp`. With no handler in scope, `throw` keeps its shipped behaviour -- set ERR_THROW and fall
    # through (it only ever unwinds a `try`) -- while `die` ($die_unhandled) writes the message to stderr and exits
    # 255, Perl's status for an uncaught `die`. `$val` is a string pointer when it comes from `die`.
    method _emit_throw_dispatch ( $val, $line, $col, $die_unhandled ) {
        my $hb_alloca = $symbols->{'__heap_base'}
            or Carp::croak( "throw requires __heap_base at line $line, col $col" );
        my $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $hb_alloca, undef, $line, $col );

        # Store thrown value in ICB.thrown_value
        my $thrown_addr = $builder->build_add( $hb,
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::THROWN_VALUE ),
            undef, $line, $col, );
        $builder->build_store( $val, $thrown_addr, $line, $col );

        # Load handler from ICB.exception_handler_stack
        my $eh_stack_addr = $builder->build_add( $hb,
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::EXCEPTION_HANDLER_STACK ),
            undef, $line, $col, );
        my $handler = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $eh_stack_addr, undef, $line, $col );

        # Check if handler exists
        my $zero            = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
        my $has_handler     = $builder->build_icmp( 'ne', $handler, $zero, undef, $line, $col );
        my $do_throw_block  = $current_func->append_block( $self->unique_block_name('do_throw') );
        my $unhandled_block = $current_func->append_block( $self->unique_block_name('unhandled_throw') );
        my $cont_block      = $current_func->append_block( $self->unique_block_name('throw_cont') );
        $builder->build_cond_br( $has_handler, $do_throw_block, $unhandled_block, $line, $col );

        # --- do_throw: longjmp ---
        $builder->position_at_end($do_throw_block);
        $current_block = $do_throw_block;
        my $jmp_buf_slot
            = $builder->build_add( $handler, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 8 ),
            undef, $line, $col, );
        my $jmp_buf_ptr = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $jmp_buf_slot, undef, $line, $col );
        my $longjmp_fn  = $functions->{'longjmp'};
        my $one         = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
        $builder->build_call( $longjmp_fn, [ $jmp_buf_ptr, $one ], undef, $line, $col );

        # longjmp never returns; add unreachable branch for CFG validity
        $builder->build_br( $cont_block, $line, $col );

        # --- unhandled ---
        $builder->position_at_end($unhandled_block);
        $current_block = $unhandled_block;
        if ($die_unhandled) {

            # An uncaught `die` reports the message and ends the process with 255, the status Perl gives it.
            $self->_emit_stderr_write( $val, $line, $col );
            my $exit_fn = $self->_ensure_extern( 'exit', Brocken::Lindsay::IR::Type::void(), [ Brocken::Lindsay::IR::Type::i64() ] );
            my $status  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 255 );
            $builder->build_call( $exit_fn, [$status], undef, $line, $col );
        }
        else {

            # --- unhandled throw: set err_code = ERR_THROW, continue ---
            my $err_addr = $builder->build_add( $hb,
                Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::ERR_CODE ),
                undef, $line, $col, );
            my $err_throw = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::ERR_THROW );
            $builder->build_store( $err_throw, $err_addr, $line, $col );
        }
        $builder->build_br( $cont_block, $line, $col );

        # --- continue block ---
        $builder->position_at_end($cont_block);
        $current_block = $cont_block;
    }

    # `warn(@msgs)` formats its messages and writes them to stderr, followed by a newline. `()` warns Perl's default
    # text. stdout is flushed first so a buffered `say` cannot appear after the diagnostic.
    method lower_warn($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $msg = $self->_build_message( $ast->args, $ast, $line, $col, "Warning: something's wrong" );
        $self->_emit_stderr_write( $msg, $line, $col );
    }

    # `die(@msgs)` formats its messages and raises them as an exception. With a handler in scope it unwinds exactly as
    # `throw` does; with none it writes the message to stderr and exits 255 (Perl's uncaught-die status). `()` dies
    # with the text "Died".
    method lower_die($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        $self->_ensure_sjlj_intrinsics();
        my $msg = $self->_build_message( $ast->args, $ast, $line, $col, 'Died' );
        $self->_emit_throw_dispatch( $msg, $line, $col, 1 );
    }

    # Render a `warn`/`die` message list as one string. Each argument is stringified exactly as `say` would (a dynamic
    # box by header tag), then the pieces are concatenated through the managed `str_concat`. An empty list uses the
    # caller's default text. Brocken has no runtime source location, so Perl's " at FILE line N." suffix is absent.
    method _build_message ( $args, $node, $line, $col, $default ) {
        return $self->_reflect_rodata($default) unless $args->@*;
        my @pieces = map { $self->_stringify_value( $self->lower_expression($_), $node, $line, $col ) } $args->@*;
        my $msg = shift @pieces;
        return $msg unless @pieces;
        my $hb_alloca = $symbols->{'__heap_base'}
            or Carp::croak( "warn/die requires __heap_base at " . $self->_loc($node) );
        my $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $hb_alloca, undef, $line, $col );
        my $concat = $functions->{'Brocken::Runtime::str_concat'}
            or Carp::croak( "Runtime function str_concat not found at " . $self->_loc($node) );
        for my $piece (@pieces) {
            $msg = $builder->build_call( $concat, [ $hb, $msg, $piece ], undef, $line, $col );
        }
        return $msg;
    }

    # Write a NUL-terminated string plus a newline to stderr. libc `write(2, ...)` is used rather than `fputs(stderr,
    # ...)`: stderr is a macro, not an importable symbol, on Windows. stdout is flushed first (`fflush(NULL)`) so a
    # buffered `say` does not appear after the diagnostic; `strlen` supplies the byte count.
    method _emit_stderr_write ( $msg, $line, $col ) {
        my $ptr = Brocken::Lindsay::IR::Type::ptr();
        my $i64 = Brocken::Lindsay::IR::Type::i64();
        my $fflush = $self->_ensure_extern( 'fflush', $i64, [$ptr] );
        my $null   = Brocken::Lindsay::IR::Constant->new( type => $ptr, value => 0 );
        $builder->build_call( $fflush, [$null], undef, $line, $col );
        my $strlen = $self->_ensure_extern( $self->_crt_name('strlen'), $i64, [$ptr] );
        my $len    = $builder->build_call( $strlen, [$msg], undef, $line, $col );
        my $write  = $self->_ensure_extern( $self->_crt_name('write'), $i64, [ $i64, $ptr, $i64 ] );
        my $two    = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 2 );
        $builder->build_call( $write, [ $two, $msg, $len ], undef, $line, $col );
        my $nl  = $self->_reflect_rodata("\n");
        my $one = Brocken::Lindsay::IR::Constant->new( type => $i64, value => 1 );
        $builder->build_call( $write, [ $two, $nl, $one ], undef, $line, $col );
    }

    # Declare (once) an external C function the generated code calls directly -- `exit`, `longjmp`, and the
    # `warn`/`die` helpers. The linker resolves the symbol like any other import; an existing declaration with the
    # same name (e.g. `strlen`, shared with `length`) is reused so the module never declares it twice.
    method _ensure_extern ( $name, $ret, $param_types ) {
        for my $fn ( values %$functions ) {
            next unless ref($fn) eq 'Brocken::Lindsay::IR::Function';
            return $fn if $fn->name eq $name;
        }
        my $fn = Brocken::Lindsay::IR::Function->new(
            name        => $name,
            return_type => $ret,
            params      => [ map { Brocken::Lindsay::IR::Value->new( type => $_ ) } $param_types->@* ],
        );
        $module->add_function($fn);
        $functions->{$name} = $fn;
        return $fn;
    }

    # `exit(CODE)` terminates the process through libc `exit`, which flushes stdio before returning to the OS -- the
    # reason it is a call and not a raw syscall: `say`/`print` write through buffered `puts`, so a raw syscall would
    # drop output written but not yet flushed. The call never returns, so the block is closed with a branch to a
    # continuation block that the code after `exit` unwinds into (as `lower_throw` does for `longjmp`), keeping the
    # CFG well-formed. Native-only for now: a Wasm module has no `exit` import (its runner, WASI, would need
    # `proc_exit`), and the Wasm backend is already excluded from the exit tests.
    method lower_exit($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $code
            = $ast->code
            ? $self->maybe_convert_type( $self->lower_expression( $ast->code ), Brocken::Lindsay::IR::Type::i64(), $line, $col, 0 )
            : Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
        my $exit_fn = $self->_ensure_extern( 'exit', Brocken::Lindsay::IR::Type::void(), [ Brocken::Lindsay::IR::Type::i64() ] );
        $builder->build_call( $exit_fn, [$code], undef, $line, $col );
        my $cont = $current_func->append_block( $self->unique_block_name('exit_cont') );
        $builder->build_br( $cont, $line, $col );
        $builder->position_at_end($cont);
        $current_block = $cont;
    }

    method lower_break($ast) {
        my $exit = $_loop_exit_blocks->[-1] or Carp::croak( "'last' outside loop at " . $self->_loc($ast) );
        my ( $line, $col ) = ( $ast->line, $ast->col );
        # A `try` between this loop's entry and here is left behind by the branch, so pop the handlers it pushed (F4).
        $self->_emit_handler_pops( $_try_handler_depth - ( $_loop_handler_depths->[-1] // 0 ), $line, $col );
        $self->_emit_loop_cleanup();
        $builder->build_br( $exit, $line, $col );
    }

    method lower_continue($ast) {
        my $header = $_loop_header_blocks->[-1] or Carp::croak( "'next' outside loop at " . $self->_loc($ast) );
        my ( $line, $col ) = ( $ast->line, $ast->col );
        # As with `last`, pop any handler a `try` opened inside this loop body before jumping to the header (F4).
        $self->_emit_handler_pops( $_try_handler_depth - ( $_loop_handler_depths->[-1] // 0 ), $line, $col );
        $self->_emit_loop_cleanup();
        $builder->build_br( $header, $line, $col );
    }

    # Decref the RC-tracked values a loop body introduced this iteration and drop them from scope, mirroring
    # lower_block's block-scoped cleanup for the back edge. Values from scopes strictly outside the loop are untouched.
    method _emit_loop_back_edge_rc_cleanup($loop_scope) {
        my @rc_names = sort keys %$needs_rc;
        @rc_names = grep { !$loop_scope->{rc_pre}{$_} } @rc_names;
        return unless @rc_names;
        return if $current_block->terminator;
        my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
        for my $name (@rc_names) {
            $self->_emit_rc_release( $name, $decref_hb );
            $self->_forget_rc($name);
        }
    }

    # Decref RC-tracked variables before leaving a loop body via break/continue.  Only variables the loop body itself
    # introduced are decref'd (objects from outer scopes stay alive for the code that follows the loop).
    method _emit_loop_cleanup() {
        my $loop_scope = $_loop_body_scopes->[-1];
        if ($loop_scope) {
            my @rc_names = sort keys %$needs_rc;
            @rc_names = grep { !$loop_scope->{rc_pre}{$_} } @rc_names;
            if (@rc_names) {
                my $decref_hb
                    = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
                for my $name (@rc_names) {
                    $self->_emit_rc_release( $name, $decref_hb );

                    # A variable the loop body itself owns stays live on the fall-through back edge, so leave it in
                    # %$needs_rc for _emit_loop_back_edge_rc_cleanup.  One declared in a nested block has lexically
                    # closed on that path, so drop it now to avoid a stale or duplicate decref of a dead slot.
                    my $owner = $rc_owner->{$name};
                    $self->_forget_rc($name) unless defined $owner && $owner == $loop_scope;
                }
            }
        }
    }

    # Expression lowering
    method lower_expression($expr) {
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Const') ) {
            return $self->lower_const($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            return $self->lower_var_ref($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::BinOp') ) {
            return $self->lower_binop($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::UnOp') ) {
            return $self->lower_unop($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::IncDec') ) {
            return $self->lower_incdec($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Paren') ) {
            return $self->lower_expression( $expr->expr );
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Call') ) {
            return $self->lower_call_expr($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::IntrinsicCall') ) {
            return $self->lower_intrinsic($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::FieldAccess') ) {
            return $self->lower_field_access($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::ArrayIndex') ) {
            return $self->lower_array_index($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::HashIndex') ) {
            return $self->lower_hash_index($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Exists') ) {
            return $self->lower_exists($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Defined') ) {
            return $self->lower_defined($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Delete') ) {
            return $self->lower_delete($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::HashKeys') ) {
            return $self->lower_hash_keys($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Undef') ) {
            return $self->lower_undef($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::UndefOp') ) {
            return $self->lower_undef_op($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::ArrayOp') ) {
            return $self->lower_array_op($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::MethodCall') ) {
            return $self->lower_method_call($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::ClassConst') ) {
            return $self->lower_class_const($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Want') ) {
            return $self->lower_want($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Ternary') ) {
            return $self->lower_ternary($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::List') ) {
            return $self->lower_list_expr($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::Hash') ) {
            return $self->lower_hash_expr($expr);
        }
        Carp::croak( "Unknown expression type: " . ref($expr) . " at " . $self->_loc($expr) );
    }

    method _intern_rodata($bytes) {
        for my $key ( keys $rodata->%* ) {
            if ( $rodata->{$key} eq $bytes ) {
                return ( $key, $rodata->{$key} );
            }
        }
        my $label = '__str_' . $_rodata_label_counter++;
        $rodata->{$label} = $bytes;
        return ( $label, $bytes );
    }

    method lower_const($ast) {
        if ( $ast->type eq 'String' ) {
            my ( $label, $bytes ) = $self->_intern_rodata( $ast->value . "\0" );
            return Brocken::Lindsay::IR::RodataRef->new( label => $label, bytes => $bytes, type => Brocken::Lindsay::IR::Type::ptr(), );
        }
        return Brocken::Lindsay::IR::Constant->new( type => $self->native_type_from_name( $ast->type ), value => $ast->value, );
    }

    method lower_var_ref($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );

        # Array variables: @arr returns the base pointer directly
        if ( $ast->sigil eq '@' ) {
            my $sym = $symbols->{ '@' . $ast->name } // $symbols->{ $ast->name };
            Carp::croak( "Undefined array variable '\@" . $ast->name . "' at " . $self->_loc($ast) ) unless $sym;

            # A field array bound to a struct GEP: inline storage is its own base, but a pointer array keeps the base
            # in the slot and must be dereferenced. A local `@name` is an alloca and is returned unchanged.
            if ( $sym->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') ) {
                my $fd = $self->field_array_record( $current_class, $ast->name );
                return $sym if !$fd || $fd->{inline};
                return $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $sym, undef, $line, $col );
            }
            return $sym;
        }

        # Hash field: %h yields the heap hash pointer held in the slot.
        if ( $ast->sigil eq '%' ) {
            my $sym = $symbols->{ '%' . $ast->name } // $symbols->{ $ast->name };
            Carp::croak( "Undefined hash variable '%" . $ast->name . "' at " . $self->_loc($ast) ) unless $sym;
            return $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $sym, undef, $line, $col );
        }
        my $sym = $symbols->{ $ast->name };
        Carp::croak( "Undefined variable '" . $ast->name . "' at " . $self->_loc($ast) ) unless $sym;

        # SSA values (e.g. $self parameter) -- return directly
        if ( $sym->isa('Brocken::Lindsay::IR::Value') && !$sym->isa('Brocken::Lindsay::IR::Instruction') ) {
            return $sym;
        }

        # Instruction that represents an address -- load from it. Only an alloca carries an allocated type and a field
        # GEP carries its field's type; anything else bound to the name is already a *value*, which happens when a
        # call binds an earlier parameter to its lowered argument so a later default can reference it (the argument
        # for an `Any` parameter is a Box instruction, not a slot).
        my $loaded_type;
        if ( $sym->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') && $current_class ) {
            my $cd      = $classes->{$current_class};
            my ($field) = $cd ? grep { $_->{name} eq $ast->name } $cd->{own_fields}->@* : ();
            $loaded_type = $field ? $field->{ir_type} : Brocken::Lindsay::IR::Type::i64();
        }
        elsif ( $sym->isa('Brocken::Lindsay::IR::Instruction::Alloca') ) {
            $loaded_type = $sym->allocated_type;
        }
        elsif ( $sym->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') ) {
            $loaded_type = Brocken::Lindsay::IR::Type::ptr();
        }
        else {
            return $sym;
        }
        return $builder->build_load( $loaded_type, $sym, undef, $line, $col );
    }

    # == Hashes ==
    # A local `%h` is a `ptr` slot holding a tag-8 table (or null). Element access is `%h{key}`: the key is lowered to
    # a NUL-terminated string pointer (a string literal stays rodata, another string passes through, a dynamic box is
    # unboxed to its String payload, and an integer is stringified), and the value is always a dynamic box. The table
    # owns its values; hash_release cascades them at scope exit. The keys are borrowed, so a key must outlive the
    # entry -- rodata literals and the fresh managed buffers an integer key makes always do.
    method _lower_hash_decl($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        Carp::croak( "A local \%hash must hold Any values (got '" . $ast->type . "') at " . $self->_loc($ast) )
            unless $ast->type eq 'Any';
        my $ptr_type = Brocken::Lindsay::IR::Type::ptr();
        my $alloca = $builder->build_alloca( $ptr_type, $self->unique_value_name( '%' . $ast->name . '.addr' ), undef, $line, $col, $ast->name, '%' );
        $symbols->{ '%' . $ast->name } = $alloca;
        $symbols->{ $ast->name }       = $alloca;
        $hash_var->{ $ast->name }        = 1;
        $hash_value_type->{ $ast->name } = Brocken::Lindsay::IR::Type::dynamic();
        $self->_note_rc( $ast->name );
        my $hb = $self->_hash_heap_base( $line, $col );
        my $h;
        if ( defined $ast->init ) {
            Carp::croak( "A local \%hash initializer must be a hash literal at " . $self->_loc($ast) )
                unless $ast->init->isa('Brocken::Katsuro::AST::Expr::Hash');
            $h = $self->lower_hash_expr( $ast->init );
        }
        else {
            $h = $builder->build_call( $self->_reflect_runtime( 'hash_new', $ast, $line, $col ), [$hb], undef, $line, $col );
        }
        $builder->build_store( $h, $alloca, $line, $col );
        return;
    }

    method _hash_heap_base($line, $col) {
        return $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col )
            if $symbols->{'__heap_base'};
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 );
    }

    # The key of an element access as a NUL-terminated string pointer.
    method _lower_hash_key( $expr, $line, $col ) {
        my $key  = $self->lower_expression($expr);
        my $kind = $key->type->kind;
        return $key if $kind eq 'ptr';
        return $self->maybe_convert_type( $key, Brocken::Lindsay::IR::Type::ptr(), $line, $col, 1 ) if $kind eq 'dynamic';
        if ( $kind eq 'int' ) {
            return $builder->build_call( $self->_reflect_runtime( 'i64_to_str', $expr, $line, $col ),
                [ $self->_hash_heap_base( $line, $col ), $key ], undef, $line, $col );
        }
        Carp::croak( "A hash key must be a string or integer at line $line, col $col" );
    }

    # Reinterpret a raw pointer-sized IR value as a dynamic (box pointer) without boxing it: storing into a slot and
    # reading it back as `dynamic` is the same bits.
    method _reinterpret_dynamic( $val, $line, $col ) {
        my $slot = $builder->build_alloca( Brocken::Lindsay::IR::Type::ptr(), undef, undef, $line, $col );
        $builder->build_store( $val, $slot, $line, $col );
        return $builder->build_load( Brocken::Lindsay::IR::Type::dynamic(), $slot, undef, $line, $col );
    }

    # `exists %h{key}`: a boolean membership test. It returns i1 directly, so it drops into a condition without the
    # truthiness round-trip a boxed value would need, and it touches no reference counts -- the key is borrowed and
    # nothing is read out of the value slot.
    method lower_exists($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $arg = $ast->expr;
        Carp::croak( "exists expects a hash element like %h{key} at " . $self->_loc($ast) )
            unless $arg->isa('Brocken::Katsuro::AST::Expr::HashIndex');
        my $h   = $self->lower_expression( $arg->hash );
        my $key = $self->_lower_hash_key( $arg->key, $line, $col );
        my $has = $builder->build_call( $self->_reflect_runtime( 'hash_has', $ast, $line, $col ), [ $h, $key ], undef, $line, $col );
        my $zero = Brocken::Lindsay::IR::Constant->new( type => $has->type, value => 0 );
        return $builder->build_icmp( 'ne', $has, $zero, undef, $line, $col );
    }

    # `defined EXPR`: true when the value is not undef. Only a pointer-shaped value can be undefined -- a `String` or
    # class reference, or an `Any` box -- so those test against null. A native int, float, or bool has no undefined
    # value (`defined 0` is true, as in Perl), so it folds to a constant true. This is the null test, not the
    # truthiness test: `defined "0"` is true even though `"0"` is false in a condition.
    method lower_defined($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $val  = $self->lower_expression( $ast->expr );
        my $kind = $val->type->kind;
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => 1 )
            unless $kind eq 'ptr' || $kind eq 'dynamic';
        my $zero = Brocken::Lindsay::IR::Constant->new( type => $val->type, value => 0 );
        return $builder->build_icmp( 'ne', $val, $zero, undef, $line, $col );
    }

    # `delete %h{key}`: remove the entry and hand back the value that was there as a boxed `Any`, or undef (a null box)
    # when the key was absent. `hash_delete` transfers the reference the table held to the caller, so the result is an
    # *owned* dynamic call result: as a discarded statement it is released, and a slot that stores it consumes the
    # reference instead of taking a second one. The callee is a synthetic declaration whose return type is `dynamic`
    # rather than the runtime's `ptr` -- the ABI shape is identical (a box pointer is a pointer-sized value in the
    # integer return register), and it is what marks the call as an owned dynamic return to the reference counting.
    method lower_delete($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $arg = $ast->expr;
        Carp::croak( "delete expects a hash element like %h{key} at " . $self->_loc($ast) )
            unless $arg->isa('Brocken::Katsuro::AST::Expr::HashIndex');
        my $h   = $self->lower_expression( $arg->hash );
        my $key = $self->_lower_hash_key( $arg->key, $line, $col );
        my $hb  = $self->_hash_heap_base( $line, $col );
        my $rt  = $self->_reflect_runtime( 'hash_delete', $ast, $line, $col );
        my $fn  = Brocken::Lindsay::IR::Function->new(
            name        => $rt->name,
            return_type => Brocken::Lindsay::IR::Type::dynamic(),
            params      => $rt->params,
        );
        $returns_owned->{ $fn->name } = 1;
        return $builder->build_call( $fn, [ $hb, $h, $key ], undef, $line, $col );
    }

    # `keys %h` / `values %h` (spec 6.2): a tag-7 list, in insertion order, of the table's keys (as String boxes) or
    # its stored value boxes. The result is a plain list pointer -- the same `ptr` a `for my $k (...)` loop or a list
    # declaration walks -- so there is nothing to box or unbox. The operand must be a local hash variable.
    method lower_hash_keys($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $op  = $ast->op;
        my $arg = $ast->expr;
        Carp::croak( "$op expects a hash variable like %h at " . $self->_loc($ast) )
            unless $arg->isa('Brocken::Katsuro::AST::Expr::Var') && $arg->sigil eq '%';
        my $h  = $self->lower_expression($arg);
        my $hb = $self->_hash_heap_base( $line, $col );
        my $fn = $self->_reflect_runtime( $op eq 'keys' ? 'hash_keys' : 'hash_values', $ast, $line, $col );
        return $builder->build_call( $fn, [ $hb, $h ], undef, $line, $col );
    }

    # `undef` as a value: the null box (Type Tag 0). `defined` sees it as undefined, truthiness as false, and
    # `maybe_convert_type` turns it into a native zero or a null pointer at whatever slot consumes it.
    method lower_undef($ast) {
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::dynamic(), value => 0 );
    }

    # `undef($x)` / `undef $x` / `undef(@a)` / `undef(%h)` (spec 3.3): reset a target to the undefined state. A
    # scalar -- a variable, field, or array element -- is exactly `$x = undef`, so the assignment lowering, and its
    # reference counting, is reused. A whole array or hash is emptied in place: the container keeps its identity and
    # only its contents are dropped.
    method lower_undef_op($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $target = $ast->expr;
        if ( $target->isa('Brocken::Katsuro::AST::Expr::Var') && $target->sigil eq '%' ) {
            return $self->lower_undef_hash( $ast, $target, $line, $col );
        }
        if ( $target->isa('Brocken::Katsuro::AST::Expr::Var') && $target->sigil eq '@' ) {
            return $self->lower_undef_array( $ast, $target, $line, $col );
        }
        my $null = Brocken::Katsuro::AST::Expr::Undef->new( file => $ast->file, line => $line, col => $col );
        my $assign = Brocken::Katsuro::AST::Stmt::Assign->new(
            file => $ast->file, line => $line, col => $col, target => $target, expr => $null, op => '=' );
        $self->lower_assign($assign);
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::dynamic(), value => 0 );
    }

    # `undef %h`: release the table's stored values (`hash_release` cascades them and drops the slot's reference) and
    # install a fresh empty table. The hash keeps its identity; only its contents change.
    method lower_undef_hash( $ast, $target, $line, $col ) {
        my $key  = '%' . $target->name;
        my $slot = $symbols->{$key} // $symbols->{ $target->name };
        Carp::croak( "Unknown hash variable '$key' at " . $self->_loc($ast) ) unless $slot;
        my $hb  = $self->_hash_heap_base( $line, $col );
        my $old = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $slot, undef, $line, $col );
        $builder->build_call( $self->_reflect_runtime( 'hash_release', $ast, $line, $col ), [ $hb, $old ], undef, $line, $col );
        my $new = $builder->build_call( $self->_reflect_runtime( 'hash_new', $ast, $line, $col ), [$hb], undef, $line, $col );
        $builder->build_store( $new, $slot, $line, $col );
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::dynamic(), value => 0 );
    }

    # `undef @a`: empty the array in place. A managed (`Any`) heap array drops one reference per element; a plain
    # element array owns nothing, so only its length falls to zero. A small fixed array lives on the stack and has its
    # elements zeroed directly (a native slot has no undefined state).
    method lower_undef_array( $ast, $target, $line, $col ) {
        my $key = '@' . $target->name;
        my $sym = $symbols->{$key} // $symbols->{ $target->name };
        Carp::croak( "Unknown array variable '$key' at " . $self->_loc($ast) ) unless $sym;
        my $i64 = Brocken::Lindsay::IR::Type::i64();
        my $ptr = Brocken::Lindsay::IR::Type::ptr();
        if ( $needs_rc->{$key} ) {
            my $arr = $builder->build_load( $ptr, $sym, undef, $line, $col );
            if ( $array_owned_elem->{$key} ) {
                my $hb = $self->_hash_heap_base( $line, $col );
                $builder->build_call( $self->_reflect_runtime( 'array_clear', $ast, $line, $col ), [ $hb, $arr ], undef, $line, $col );
            }
            else {
                my $count_addr = $builder->build_gep( Brocken::Lindsay::IR::Type::i8(), $arr,
                    [ Brocken::Lindsay::IR::Constant->new( type => $i64, value => 8 ) ], undef, $line, $col );
                $builder->build_store( Brocken::Lindsay::IR::Constant->new( type => $i64, value => 0 ), $count_addr, $line, $col );
            }
        }
        else {
            my $count = $array_counts->{$key};
            Carp::croak( "undef of a stack array of unknown length at " . $self->_loc($ast) ) unless defined $count;
            my $elem_type = $array_elem_types->{$key} // $i64;
            my $zero = Brocken::Lindsay::IR::Constant->new( type => $elem_type, value => $elem_type->kind eq 'float' ? 0.0 : 0 );
            for my $i ( 0 .. $count - 1 ) {
                my $idx = Brocken::Katsuro::AST::Expr::Const->new( file => $ast->file, line => $line, col => $col, value => $i, type => 'Int' );
                my $addr = $self->lower_array_addr( Brocken::Katsuro::AST::Expr::ArrayIndex->new(
                    file => $ast->file, line => $line, col => $col, array => $target, index => $idx ) );
                $builder->build_store( $zero, $addr, $line, $col );
            }
        }
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::dynamic(), value => 0 );
    }

    # `%h{key}` read: the stored box pointer, reinterpreted as a dynamic value.
    method lower_hash_index($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $h   = $self->lower_expression( $ast->hash );
        my $key = $self->_lower_hash_key( $ast->key, $line, $col );
        my $val = $builder->build_call( $self->_reflect_runtime( 'hash_get', $ast, $line, $col ), [ $h, $key ], undef, $line, $col );
        return $self->_reinterpret_dynamic( $val, $line, $col );
    }

    # `%h{key} = value`: box the value, take an owned reference for the table, store through hash_set, and write the
    # table pointer back into the slot -- a grow may have moved it.
    method _lower_hash_store( $target, $rhs, $line, $col ) {
        my $h   = $self->lower_expression( $target->hash );
        my $key = $self->_lower_hash_key( $target->key, $line, $col );
        my $raw = $self->lower_expression($rhs);
        my $val = $self->maybe_convert_type( $raw, Brocken::Lindsay::IR::Type::dynamic(), $line, $col );
        $builder->build_incref( $val, $line, $col ) unless $self->_owned_call_result($raw);
        my $hb      = $self->_hash_heap_base( $line, $col );
        my $new     = $builder->build_call( $self->_reflect_runtime( 'hash_set', $target, $line, $col ), [ $hb, $h, $key, $val ], undef, $line, $col );
        my $slot    = $symbols->{ '%' . $target->hash->name } // $symbols->{ $target->hash->name };
        Carp::croak( "Unknown hash variable '%" . $target->hash->name . "' at " . $self->_loc($target) ) unless $slot;
        $builder->build_store( $new, $slot, $line, $col );
        return;
    }

    # `push @a, v...`, `pop @a`, `shift @a`, `unshift @a, v...` (spec 6.1). These mutate a *growable* local array --
    # one declared without a compile-time element count (`my [i64] @a;` or `my [i64; $n] @a;`), which is therefore
    # heap-backed with the tag-9 header the runtime helpers need. Growth re-allocates the block, so push/unshift store
    # the fresh base back into the array's slot and answer the new element count; pop/shift mutate the count in place
    # and answer the removed element (0 when the array is empty). Only i64 element arrays are wired up for now.
    method lower_array_op($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $op    = $ast->op;
        my $array = $ast->array;
        Carp::croak( "$op expects a local array variable at " . $self->_loc($ast) )
            unless $array->isa('Brocken::Katsuro::AST::Expr::Var') && $array->sigil eq '@';
        my $key  = '@' . $array->name;
        my $slot = $symbols->{$key};
        Carp::croak( "Unknown array variable '$key' at " . $self->_loc($ast) ) unless $slot;
        my $elem_type = $growable_arrays->{$key};
        Carp::croak( "$op needs a growable array; declare $key without a compile-time element count (e.g. `my [i64] $key;`) at "
                . $self->_loc($ast) )
            unless defined $elem_type;
        Carp::croak( "$op currently supports only i64 element arrays, but $key holds $elem_type at " . $self->_loc($ast) )
            unless $elem_type eq 'i64';

        my $ptr = Brocken::Lindsay::IR::Type::ptr();
        my $i64 = Brocken::Lindsay::IR::Type::i64();
        my $hb  = $self->_hash_heap_base( $line, $col );

        if ( $op eq 'push' || $op eq 'unshift' ) {
            my $grow = $self->_reflect_runtime( $op eq 'push' ? 'array_push_i64' : 'array_unshift_i64', $ast, $line, $col );
            my @vals = map { $self->maybe_convert_type( $self->lower_expression($_), $i64, $line, $col, 1 ) } $ast->args->@*;

            # `unshift @a, 1, 2` yields (1, 2, @a): insert from the last value back so each one lands ahead of the
            # previous, matching Perl's argument order.
            @vals = reverse @vals if $op eq 'unshift';
            my $base = $builder->build_load( $ptr, $slot, undef, $line, $col );
            for my $v (@vals) {
                $base = $builder->build_call( $grow, [ $hb, $base, $v ], undef, $line, $col );

                # The grow returned a fresh block (refcount 1); point the array's slot at it before the next step.
                $builder->build_store( $base, $slot, $line, $col );
            }
            return $builder->build_call( $self->_reflect_runtime( 'array_len', $ast, $line, $col ), [$base], undef, $line, $col );
        }

        my $shrink = $self->_reflect_runtime( $op eq 'pop' ? 'array_pop_i64' : 'array_shift_i64', $ast, $line, $col );
        my $base   = $builder->build_load( $ptr, $slot, undef, $line, $col );
        return $builder->build_call( $shrink, [$base], undef, $line, $col );
    }

    method lower_array_decl($ast) {
        my $ir_type  = $self->type_from_name( $ast->elem_type );

        # An omitted element count (`my [i64] @a;`) is a runtime-sized array with zero elements: it is heap-promoted
        # below and grown with push/unshift. Guarding here keeps `lower_expression` from being handed an undef node.
        my $size_val = defined $ast->size_expr ? $self->lower_expression( $ast->size_expr ) : undef;
        if ( defined $size_val ) {

            # The alloca carries the element count as an i64.  A constant folds to a constant i64 so the backends can
            # still size the frame statically; a runtime value must be an i64 too, or an untyped (`my $n = 4`) size
            # would feed the count as a *box pointer* and the dynamic alloca would carve garbage (audit 5.5).
            $size_val = $self->maybe_convert_type( $size_val, Brocken::Lindsay::IR::Type::i64(), $ast->line, $ast->col );
        }
        my $key        = '@' . $ast->name;
        my $elem_bytes = $ir_type->byte_size;
        $array_elem_types->{$key} = $ir_type;

        # A managed (`Any`) element is a box pointer the array owns: an owning store takes a reference for it and
        # `array_release` drops one per element at scope exit. Only such an array is heap-promoted below regardless of
        # size, because a stack array has no scope-exit release and its elements would leak.
        my $managed = $ir_type->kind eq 'dynamic';
        $array_owned_elem->{$key} = $managed ? 1 : 0;

        # Remember the element count when it folded to a constant, so `builtin::indexed(@a)` (and a `for` over a bare
        # array) can unroll the array at compile time. A runtime count is left undefined and those forms report that
        # they cannot seek into it.
        $array_counts->{$key} = ( defined $size_val && $size_val->isa('Brocken::Lindsay::IR::Constant') ) ? $size_val->value : undef;

        # Heap promotion: dynamic-sized arrays (and static arrays whose element count would exceed 4 KiB of stack) are
        # allocated on the Immix heap via Brocken::Runtime::alloc_array instead of the stack.  The declaration becomes a
        # pointer slot holding the tag-9 array header, RC-tracked like any fat scalar: alloc_array grants refcount 1, so
        # the scope-exit delta (block, loop iteration, function end) frees it back to the segregated free_big list,
        # which next iteration's alloc_array reuses.
        my $static_bytes = defined $size_val && $size_val->isa('Brocken::Lindsay::IR::Constant') ? $size_val->value * $elem_bytes : undef;
        my $promote      = !defined $static_bytes || $static_bytes > 4096 || $managed;
        if ($promote) {
            my $ptr_type  = Brocken::Lindsay::IR::Type::ptr();
            my $slot      = $builder->build_alloca( $ptr_type, $self->unique_value_name( '%' . $key . '.heap' ), undef, $ast->line, $ast->col, $ast->name, $ast->elem_type );
            my $hb_alloca = $symbols->{'__heap_base'} or Carp::croak( "Heap array declaration requires __heap_base at " . $self->_loc($ast) );
            my $hb        = $builder->build_load( $ptr_type, $hb_alloca, undef, $ast->line, $ast->col );
            my $alloc_fn  = $functions->{'Brocken::Runtime::alloc_array'} or
                Carp::croak( "Runtime function alloc_array not found at " . $self->_loc($ast) );
            my $count_val       = $size_val // Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
            my $elem_size_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $elem_bytes );
            my $arr             = $builder->build_call( $alloc_fn, [ $hb, $count_val, $elem_size_const ], undef, $ast->line, $ast->col );
            $builder->build_store( $arr, $slot, $ast->line, $ast->col );

            # A managed array's elements must read as null boxes before the first owning store (which releases the
            # element it displaces). A recycled slab holds stale pointers, so zero the whole body here.
            if ($managed) {
                my $zero_fn = $functions->{'Brocken::Runtime::array_zero'} or
                    Carp::croak( "Runtime function array_zero not found at " . $self->_loc($ast) );
                $builder->build_call( $zero_fn, [ $arr, $count_val, $elem_size_const ], undef, $ast->line, $ast->col );
            }

            $symbols->{$key} = $slot;
            $self->_note_rc($key);

            # A runtime or omitted element count is a *growable* array: it has no compile-time length, so the
            # push/pop/shift/unshift builtins may mutate it (see lower_array_op). A constant count is fixed and rejects
            # them, which keeps the 4 KiB stack/heap threshold from leaking into the language's behaviour.
            $growable_arrays->{$key} = $ast->elem_type if !defined $static_bytes;
            return;
        }

        # A small constant-sized array stays on the stack; every other declaration was heap-promoted above.
        my $alloca = $builder->build_alloca( $ir_type, $self->unique_value_name( '%' . $key . '.addr' ), $size_val, $ast->line, $ast->col, $ast->name, $ast->elem_type );
        $symbols->{$key} = $alloca;
    }

    # The RHS of `my (TYPE $x) = EXPR` must lower to a tag-7 list pointer. A single parenthesized operand parses as an
    # `Expr::Paren`, not a one-element `Expr::List`, so it is read back here as a one-element list; a bare local array
    # inside the parentheses is unrolled, so `my (String $s) = (@a)` takes the first element the way Perl does.
    # Anything else -- an `Expr::List`, or a bare array/scalar that lowers to a list pointer -- is left untouched.
    method _list_rhs_expr( $expr, $line, $col ) {
        return $expr unless defined $expr && $expr->isa('Brocken::Katsuro::AST::Expr::Paren');
        my $inner = $expr->expr;
        my @elements
            = $self->_is_local_array($inner)
            ? $self->_array_element_exprs( $inner, $line, $col )
            : ($inner);
        return Brocken::Katsuro::AST::Expr::List->new(
            file => $inner->file, line => $inner->line, col => $inner->col, elements => \@elements );
    }

    method lower_list_var_decl($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $i64_type     = Brocken::Lindsay::IR::Type::i64();
        my $ptr_type     = Brocken::Lindsay::IR::Type::ptr();
        my $dynamic_type = Brocken::Lindsay::IR::Type::dynamic();
        my @targets      = $ast->targets->@*;
        my $list_ptr     = $self->lower_expression( $self->_list_rhs_expr( $ast->expr, $line, $col ) );
        for my $i ( 0 .. $#targets ) {
            my $t       = $targets[$i];
            my $ir_type = $self->type_from_name( $t->{type} );
            my $alloca  = $builder->build_alloca( $ir_type, $self->unique_value_name( '%' . $t->{name} . '.addr' ), undef, $line, $col, $t->{name}, $t->{type} );
            $symbols->{ $t->{name} } = $alloca;
            if ( $t->{type} eq 'Any' ) {
                $self->_note_rc( $t->{name} );
            }
            my $offset    = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 16 + $i * 8 );
            my $elem_addr = $builder->build_add( $list_ptr, $offset, undef, $line, $col );

            # The slot already holds a box pointer (see `lower_list_expr`), so it is read as a dynamic and not boxed
            # again. Reading it as an i64 and converting to `Any` put a second box around the first, so every unbox
            # downstream read a pointer where it expected a payload.
            my $elem_dyn = $builder->build_load( $dynamic_type, $elem_addr, undef, $line, $col );
            my $elem_val = $t->{type} eq 'Any' ? $elem_dyn : $self->maybe_convert_type( $elem_dyn, $ir_type, $line, $col, 1 );
            if ( $t->{type} eq 'Any' ) {
                $builder->build_incref( $elem_val, $line, $col );
            }
            $builder->build_store( $elem_val, $alloca, $line, $col );
        }
    }

    method lower_array_addr($ast) {
        my $array_expr = $ast->array;
        my $array_base;
        my $elem_type;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        if ( $array_expr->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            my $key = '@' . $array_expr->name;
            my $sym = $symbols->{$key};
            Carp::croak( "Unknown array variable '\@" . $array_expr->name . "' at " . $self->_loc($array_expr) ) unless $sym;

            # A field array's symbol is a struct GEP, which is how it is told apart from a local `@name` (an alloca).
            # Inline storage already sits at that GEP; a pointer array's GEP addresses the slot holding the base, so
            # the base has to be loaded. Neither carries the 24-byte heap header a runtime-sized `my [...] @a` does.
            my $is_field_gep = $sym->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') && $sym->base_type && $sym->base_type->kind eq 'struct';
            my $fd           = $is_field_gep ? $self->field_array_record( $current_class, $array_expr->name ) : undef;
            if ($fd) {
                $array_base = $fd->{inline} ? $sym : $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $sym, undef, $line, $col );
                $elem_type  = $fd->{elem_ir_type};
            }
            else {
                my $slot_type = $sym->allocated_type;
                if ( $needs_rc->{$key} ) {
                    $array_base = $builder->build_load( $slot_type, $sym, undef, $line, $col );

                    # Heap arrays carry a 24-byte header (tag/rc, count, bytes) before the elements; step past it so
                    # the element GEP below lands on element 0 rather than the header.  Stack arrays have no header.
                    my $header_off = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 24 );
                    $array_base = $builder->build_gep( Brocken::Lindsay::IR::Type::i8(), $array_base, [$header_off], undef, $line, $col );
                }
                else {
                    $array_base = $sym;
                }
                $elem_type = $array_elem_types->{$key} // $slot_type;
            }
        }
        elsif ( $array_expr->isa('Brocken::Katsuro::AST::Expr::FieldAccess') ) {
            my $class_name = $self->resolve_class_name($array_expr);
            my $fd         = $self->field_array_record( $class_name, $array_expr->field );
            if ($fd) {

                # `$obj->xs[i]`: take the field's address, then dereference a pointer slot so indexing lands on the
                # elements. An inline array is addressed directly by its GEP.
                my $field_ptr = $self->lower_field_addr($array_expr);
                $array_base = $fd->{inline} ? $field_ptr : $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $field_ptr, undef, $line, $col );
                $elem_type  = $fd->{elem_ir_type};
            }
            else {
                $array_base = $self->lower_expression($array_expr);
                $elem_type  = $array_base->type;
            }
        }
        else {
            $array_base = $self->lower_expression($array_expr);
            $elem_type  = $array_base->type;
        }
        my $index_val = $self->lower_expression( $ast->index );
        return $builder->build_gep( $elem_type, $array_base, [$index_val], '%idx.addr', $line, $col );
    }

    method lower_array_index($ast) {
        my $addr = $self->lower_array_addr($ast);
        return $builder->build_load( $addr->base_type, $addr, undef, $ast->line, $ast->col );
    }

    # `//` is defined-or: the left operand, unless it is undefined -- the null value of a pointer-shaped or boxed type
    # (a `String`, a class reference, or an `Any` box) -- in which case the right operand.
    #
    # Only pointer-shaped values can be undefined in Brocken: a native int, float, or bool is always defined, so `//`
    # on one is simply that operand. The right operand is promoted to the type the result will carry:
    #
    #   * two pointer operands stay a `ptr` (`$s // "default"`);
    #   * anything that meets an `Any` box becomes the box, with native values boxed and a `ptr` payload keeping its
    #     pointer tag (`$earnings // $reserve // 0`);
    #   * a numeric right operand against a pointer left operand also becomes the box, since the two sides have no
    #     common native type.
    method lower_defined_or( $lhs, $rhs, $line, $col ) {
        my $lhs_kind = $lhs->type->kind;
        return $lhs unless $lhs_kind eq 'ptr' || $lhs_kind eq 'dynamic';
        my $result_type = $lhs_kind eq 'ptr' && $rhs->type->kind eq 'ptr' ? Brocken::Lindsay::IR::Type::ptr() : Brocken::Lindsay::IR::Type::dynamic();
        $lhs = $self->maybe_convert_type( $lhs, $result_type, $line, $col );
        $rhs = $self->maybe_convert_type( $rhs, $result_type, $line, $col );
        my $zero     = Brocken::Lindsay::IR::Constant->new( type => $result_type, value => 0 );
        my $is_undef = $builder->build_icmp( 'eq', $lhs, $zero, undef, $line, $col );
        return $builder->build_select( $is_undef, $rhs, $lhs, undef, $line, $col );
    }

    method lower_binop($ast) {
        my $lhs = $self->lower_expression( $ast->lhs );
        my $rhs = $self->lower_expression( $ast->rhs );
        my $op  = $ast->op;
        my ( $line, $col ) = ( $ast->line, $ast->col );

        # `//` (defined-or) is not an integer operator. It is handled before the type unification so that the boxed
        # form can keep its tags (see `lower_defined_or`). Both operands are lowered above so `//` stays parallel with
        # `&&` and `||`, which also evaluate both sides.
        if ( $op eq '//' ) {
            return $self->lower_defined_or( $lhs, $rhs, $line, $col );
        }

        # `.` is not arithmetic either: both operands are stringified, so a dynamic (`Any`) operand must be shown as
        # its string payload. It is handled here, before the numeric unification below, which would otherwise unbox the
        # box to f64 and concatenate `0.000000` for a string-valued box.
        if ( $op eq '.' ) {
            return $self->_lower_concat( $lhs, $rhs, $line, $col, $ast );
        }

        # The string comparisons stringify both operands the same way `.` does, so they take the same early dispatch: a
        # dynamic operand is read as its string payload rather than unboxed to f64 by the numeric unification below.
        if ( $op eq 'eq' || $op eq 'ne' || $op eq 'lt' || $op eq 'gt' || $op eq 'le' || $op eq 'ge' || $op eq 'cmp' ) {
            return $self->_lower_strcmp( $lhs, $rhs, $op, $line, $col, $ast );
        }

        # A float has no bits to shift and no bit pattern to mask, so these operators have no float form. `%` is an
        # integer modulus here for the same reason it is one in Perl.
        #
        # `&&` and `||` are deliberately not in this list. They are a truth test rather than an integer operator, and a
        # float is true when it is not zero; both are handled by comparison below. Truncating instead would make `my f64
        # $a = 0.5; my f64 $b = 1.0; $a && $b` false, because 0.5 truncates to 0.
        my $bool_op      = $op eq '&&' || $op eq '||';
        my $integer_only = !$bool_op && ( $op eq '<<' || $op eq '>>' || $op eq '&' || $op eq '|' || $op eq '^' || $op eq '%' );

        # An untyped variable is a box, and a box's payload may be a float, so an untyped operand is read at whatever
        # width the other operand is rather than always as an i64.
        #
        # Converting both sides to i64 first meant `$x == 1.5` was built as a
        # comparison of two integers: the float-ness of the literal was gone before the comparison existed, so no
        # backend could recover it.
        #
        # When the other operand is itself an integer there is still nothing to go on, because the box might hold a
        # float either way, so arithmetic on an untyped operand is done in f64. That is Perl's scalar rule, under which
        # `1.5 + 1` is 2.5. The alternative -- unboxing to i64 and reading a float payload as its bit pattern -- made
        # `1.5 + 2.5` wrong, and wrong in
        # a way that looked right for a good while: IEEE-754 orders positive floats the same way their bit patterns
        # order as integers, so `$x + $y`, `$x < $y` and `$x == $y` all came out right by accident and only `$x > $y`
        # showed the fault.
        if ( $lhs->type->kind eq 'dynamic' || $rhs->type->kind eq 'dynamic' ) {
            my $target
                = $integer_only             ? Brocken::Lindsay::IR::Type::i64() :
                $bool_op                    ? Brocken::Lindsay::IR::Type::f64() :
                $lhs->type->kind eq 'float' ? $lhs->type :
                $rhs->type->kind eq 'float' ? $rhs->type :
                Brocken::Lindsay::IR::Type::f64();
            $lhs = $self->maybe_convert_type( $lhs, $target );
            $rhs = $self->maybe_convert_type( $rhs, $target );
        }

        # A typed float meeting one of the integer-only operators is truncated toward zero first, which is what Perl
        # does: `12.7 & 10.3` is `12 & 10`, `-3.9 & 7.0` is `-3 & 7` rather than `-4 & 7`, and `1.0 << 2.9` shifts by 2.
        #
        # The conversion belongs here rather than further down because the mixed
        # int/float unification promotes the integer side back up to float, which
        # would leave `my i64 $a = 12; my f64 $b = 10.3; $a | $b` with two
        # doubles again.
        if ($integer_only) {
            my $i64_type = Brocken::Lindsay::IR::Type::i64();
            $lhs = $self->maybe_convert_type( $lhs, $i64_type ) if $lhs->type->kind eq 'float';
            $rhs = $self->maybe_convert_type( $rhs, $i64_type ) if $rhs->type->kind eq 'float';
        }

        # `&&` and `||` take a float the other way round: true when it is not zero, so the operand becomes a `!= 0.0`
        # comparison. Truncation would be wrong in both directions, since 0.5 and -0.5 both truncate to 0.
        #
        # Reading an untyped operand as f64 above is what lets one comparison
        # serve either kind of box: `unbox_f64` widens an integer payload, so `my $x = 5; $x && $y` is `5.0 != 0.0` and
        # true and `my $x = 0; $x && $y` is `0.0 != 0.0` and false, without the tag being read twice.
        if ($bool_op) {
            my $truthy = sub {
                my ($side) = @_;
                my $zero = Brocken::Lindsay::IR::Constant->new( type => $side->type, value => 0.0 );
                return $builder->build_icmp( 'ne', $side, $zero, undef, $line, $col );
            };
            $lhs = $truthy->($lhs) if $lhs->type->kind eq 'float';
            $rhs = $truthy->($rhs) if $rhs->type->kind eq 'float';
        }

        # Unify types for mixed int/float operations: both sides end up the same type kind (both float or both int) so
        # the MIR lowerer can emit the correct opcode (fadd vs add, fcmp vs icmp, etc.).
        #
        # The integer side is promoted up to the float, not the other way round.
        # Converting the float to the integer type truncated it, so `my i64 $a = 1; my f64 $b = 1.5; $a == $b` compared
        # 1 against 1 and answered true, `$a < $b` compared 1 against 1 and answered false, and `my i64 $a = 2; $a * $b`
        # computed 2 * 1. Every one of those was wrong in fully typed code, on every backend, and no backend could
        # recover the fraction once the lowering had thrown it away.
        if ( $lhs->type->kind ne $rhs->type->kind && $lhs->type->kind ne 'dynamic' && $rhs->type->kind ne 'dynamic' ) {
            if ( $lhs->type->kind eq 'int' && $rhs->type->kind eq 'float' ) {
                $lhs = $self->maybe_convert_type( $lhs, $rhs->type );
            }
            else {
                $rhs = $self->maybe_convert_type( $rhs, $lhs->type );
            }
        }

        # Shift operations use LHS type for result width regardless of RHS.
        # Dispatch them before width-promotion to avoid widening LHS.
        return $builder->build_shl( $lhs, $rhs, undef, $line, $col ) if $op eq '<<';
        if ( $op eq '>>' ) {
            return $lhs->type->is_signed ? $builder->build_ashr( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_lshr( $lhs, $rhs, undef, $line, $col );
        }

        # Promote narrower operand to match wider type width so the MIR lowerer sees consistent operand widths (critical
        # for i128/halving).
        if ( $lhs->type->kind eq $rhs->type->kind && $lhs->type->bits != $rhs->type->bits && $lhs->type->kind ne 'dynamic' ) {
            if ( $lhs->type->kind eq 'float' ) {

                # A decimal literal is lexed as f64, so `if ($f32 == 1.5)` hands us an f64 against an f32.  There is no
                # fptrunc/fpext in the IR, so the only sound unification is to re-tag the literal to the width of the
                # other operand; widening the loaded value instead would reinterpret a four-byte pattern as eight.
                if ( $rhs->isa('Brocken::Lindsay::IR::Constant') ) {
                    $rhs = $self->maybe_convert_type( $rhs, $lhs->type );
                }
                elsif ( $lhs->isa('Brocken::Lindsay::IR::Constant') ) {
                    $lhs = $self->maybe_convert_type( $lhs, $rhs->type );
                }
                else {
                    $lhs = $self->maybe_convert_type( $lhs, $rhs->type );
                }
            }
            elsif ( $lhs->type->bits < $rhs->type->bits ) {
                $lhs = $self->maybe_convert_type( $lhs, $rhs->type );
            }
            else {
                $rhs = $self->maybe_convert_type( $rhs, $lhs->type );
            }
        }
        return $builder->build_add( $lhs, $rhs, undef, $line, $col ) if $op eq '+';
        return $builder->build_sub( $lhs, $rhs, undef, $line, $col ) if $op eq '-';
        return $builder->build_mul( $lhs, $rhs, undef, $line, $col ) if $op eq '*';
        if ( $op eq '/' ) {
            $rhs = $self->_emit_div_zero_check( $rhs, $line, $col );
            return $lhs->type->is_signed ? $builder->build_div( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_udiv( $lhs, $rhs, undef, $line, $col );
        }
        if ( $op eq '%' ) {
            $rhs = $self->_emit_div_zero_check( $rhs, $line, $col );
            return $lhs->type->is_signed ? $builder->build_rem( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_urem( $lhs, $rhs, undef, $line, $col );
        }
        return $builder->build_and( $lhs, $rhs, undef, $line, $col ) if $op eq '&';
        return $builder->build_or( $lhs, $rhs, undef, $line, $col )  if $op eq '|';
        return $builder->build_xor( $lhs, $rhs, undef, $line, $col ) if $op eq '^';
        return $builder->build_and( $lhs, $rhs, undef, $line, $col ) if $op eq '&&';
        return $builder->build_or( $lhs, $rhs, undef, $line, $col )  if $op eq '||';

        # Mixed-signedness comparison: types < 64 bits with different signedness produce wrong results because the
        # codegen loads signed operands with movsx (sign-extend) and unsigned with movzx (zero-extend) into 32-bit
        # registers.  When the CMP uses unsigned predicates, the sign-extended value looks like a huge positive number.
        # Fix: widen both operands to a common 32-bit type with appropriate extension so the bit patterns match the
        # simulation semantics.
        if ( $lhs->type->kind eq 'int' &&
            $rhs->type->kind eq 'int'            &&
            $lhs->type->bits == $rhs->type->bits &&
            $lhs->type->bits < 64                &&
            $lhs->type->is_signed != $rhs->type->is_signed ) {
            if ( !$lhs->type->is_signed ) {
                my $wt = Brocken::Lindsay::IR::Type::u32();
                $lhs = $builder->build_zext( $lhs, $wt, undef, $line, $col );
                $rhs = $builder->build_zext( $rhs, $wt, undef, $line, $col );
            }
            else {
                my $wt = Brocken::Lindsay::IR::Type::i32();
                $lhs = $builder->build_sext( $lhs, $wt, undef, $line, $col );
                $rhs = $builder->build_sext( $rhs, $wt, undef, $line, $col );
            }
        }
        return $builder->build_icmp( 'eq', $lhs, $rhs, undef, $line, $col ) if $op eq '==';
        return $builder->build_icmp( 'ne', $lhs, $rhs, undef, $line, $col ) if $op eq '!=';

        # Ordering has no signed/unsigned split for a float, and the backends
        # spell the float predicates plainly: the x86-64 lowerer has them as lt/le/gt/ge -> b/be/a/ae and ARM64 as
        # cset_lt/... . Emitting the integer s/u forms here keyed off is_signed picked a name no float table has, so
        # every ordered float comparison came out false.
        if ( $lhs->type->kind eq 'float' ) {
            return $builder->build_icmp( 'lt', $lhs, $rhs, undef, $line, $col ) if $op eq '<';
            return $builder->build_icmp( 'gt', $lhs, $rhs, undef, $line, $col ) if $op eq '>';
            return $builder->build_icmp( 'le', $lhs, $rhs, undef, $line, $col ) if $op eq '<=';
            return $builder->build_icmp( 'ge', $lhs, $rhs, undef, $line, $col ) if $op eq '>=';
        }
        elsif ( $op eq '<' ) {
            return $builder->build_icmp( $lhs->type->is_signed ? 'slt' : 'ult', $lhs, $rhs, undef, $line, $col );
        }
        elsif ( $op eq '>' ) {
            return $builder->build_icmp( $lhs->type->is_signed ? 'sgt' : 'ugt', $lhs, $rhs, undef, $line, $col );
        }
        elsif ( $op eq '<=' ) {
            return $builder->build_icmp( $lhs->type->is_signed ? 'sle' : 'ule', $lhs, $rhs, undef, $line, $col );
        }
        elsif ( $op eq '>=' ) {
            return $builder->build_icmp( $lhs->type->is_signed ? 'sge' : 'uge', $lhs, $rhs, undef, $line, $col );
        }
        if ( $op eq 'eq' || $op eq 'ne' || $op eq 'lt' || $op eq 'gt' || $op eq 'le' || $op eq 'ge' || $op eq 'cmp' ) {
            return $self->_lower_strcmp( $lhs, $rhs, $op, $line, $col, $ast );
        }
        Carp::croak( "Unknown binary operator '$op' at " . $self->_loc($ast) );
    }

    # The string comparisons. Both operands are stringified through `_stringify_value`, so a dynamic box is rendered
    # from its tag (a String payload, an integer, a float) instead of being unboxed as a number, then compared with
    # libc `strcmp`. Called before the numeric unification in `lower_binop` for the same reason `.` is.
    method _lower_strcmp( $lhs, $rhs, $op, $line, $col, $node ) {
        $lhs = $self->_stringify_value( $lhs, $node, $line, $col );
        $rhs = $self->_stringify_value( $rhs, $node, $line, $col );
        my $strcmp_fn = Brocken::Lindsay::IR::Function->new(
            name        => $self->_crt_name('strcmp'),
            return_type => Brocken::Lindsay::IR::Type::i32(),
            params      => [
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
            ],
        );
        my $cmp_result = $builder->build_call( $strcmp_fn, [ $lhs, $rhs ], undef, $line, $col );
        my $cmp_i64    = $builder->build_sext( $cmp_result, Brocken::Lindsay::IR::Type::i64(), undef, $line, $col );
        my $zero       = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
        if ( $op eq 'cmp' ) {
            my $gt   = $builder->build_icmp( 'sgt', $cmp_i64, $zero, undef, $line, $col );
            my $lt   = $builder->build_icmp( 'slt', $cmp_i64, $zero, undef, $line, $col );
            my $gt64 = $builder->build_zext( $gt, Brocken::Lindsay::IR::Type::i64(), undef, $line, $col );
            my $lt64 = $builder->build_zext( $lt, Brocken::Lindsay::IR::Type::i64(), undef, $line, $col );
            my $neg  = $builder->build_sub( $zero, $lt64, undef, $line, $col );
            return $builder->build_add( $gt64, $neg, undef, $line, $col );
        }
        if ( $op eq 'eq' ) {
            return $builder->build_icmp( 'eq', $cmp_i64, $zero, undef, $line, $col );
        }
        if ( $op eq 'ne' ) {
            return $builder->build_icmp( 'ne', $cmp_i64, $zero, undef, $line, $col );
        }
        if ( $op eq 'lt' ) {
            return $builder->build_icmp( 'slt', $cmp_i64, $zero, undef, $line, $col );
        }
        if ( $op eq 'gt' ) {
            return $builder->build_icmp( 'sgt', $cmp_i64, $zero, undef, $line, $col );
        }
        if ( $op eq 'le' ) {
            return $builder->build_icmp( 'sle', $cmp_i64, $zero, undef, $line, $col );
        }
        if ( $op eq 'ge' ) {
            return $builder->build_icmp( 'sge', $cmp_i64, $zero, undef, $line, $col );
        }
        Carp::croak( "Unknown string comparison '$op' at " . $self->_loc($node) );
    }

    # Concatenate two operands as strings. `_stringify_value` reads a dynamic box's tag at runtime, so a box holding a
    # string shows its payload rather than being unboxed as a number. Two rodata
    # constants fold to one; anything else goes through the managed `str_concat`, which copies both byte strings and
    # NUL-terminates the result (the old strlen+malloc+strcpy+strcat depended on libc, which a Wasm module cannot
    # import). Called before the numeric unification in `lower_binop`, so a dynamic operand is not unboxed to f64.
    method _lower_concat( $lhs, $rhs, $line, $col, $node ) {
        $lhs = $self->_stringify_value( $lhs, $node, $line, $col );
        $rhs = $self->_stringify_value( $rhs, $node, $line, $col );
        if ( $lhs->isa('Brocken::Lindsay::IR::RodataRef') && $rhs->isa('Brocken::Lindsay::IR::RodataRef') ) {
            my $combined = substr( $lhs->bytes, 0, -1 ) . $rhs->bytes;
            my ( $label, $bytes ) = $self->_intern_rodata($combined);
            return Brocken::Lindsay::IR::RodataRef->new( label => $label, bytes => $bytes, type => Brocken::Lindsay::IR::Type::ptr(), );
        }

        my $hb
            = $symbols->{'__heap_base'} ?
            $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col ) :
            undef;
        Carp::croak( "String concat requires __heap_base at " . $self->_loc($node) ) unless $hb;
        my $concat_fn = $functions->{'Brocken::Runtime::str_concat'};
        Carp::croak( "Runtime function str_concat not found at " . $self->_loc($node) ) unless $concat_fn;
        return $builder->build_call( $concat_fn, [ $hb, $lhs, $rhs ], undef, $line, $col );
    }

    method lower_unop($ast) {
        my $operand = $self->lower_expression( $ast->expr );
        my $op      = $ast->op;
        my ( $line, $col ) = ( $ast->line, $ast->col );

        # Logical negation is a truthiness test, so a dynamic operand goes through the runtime helper rather than a
        # blind unbox: `!$box` is true exactly when the box holds `0`, `0.0`, `""`, `"0"`, or undef (a null box).
        if ( $op eq '!' ) {
            if ( $operand->type->kind eq 'dynamic' ) {
                my $fn = $functions->{'Brocken::Runtime::is_truthy'}
                    or Carp::croak("Runtime function is_truthy not found at line $line, col $col");
                my $t    = $builder->build_call( $fn, [$operand], undef, $line, $col );
                my $zero = Brocken::Lindsay::IR::Constant->new( type => $t->type, value => 0 );
                return $builder->build_icmp( 'eq', $t, $zero, undef, $line, $col );
            }
            my $zero = Brocken::Lindsay::IR::Constant->new( type => $operand->type, value => 0 );
            return $builder->build_icmp( 'eq', $operand, $zero, undef, $line, $col );
        }

        # Negation of an untyped (dynamic) operand reads it at f64, not i64. A box may hold a float, and `unbox_i64`
        # truncates a float payload toward zero, so `my $x = -3.5; -$x` came out -3. Reading it as f64 follows the same
        # Perl scalar rule the binary untyped arithmetic uses (`lower_binop`): `unbox_f64` widens an integer payload, so
        # one f64 neg serves either kind of box and preserves the fraction a float box carries. The neg of an f64 is an
        # `fneg`; a constant operand is never dynamic, so the float-literal fold below is untouched.
        if ( $op eq '-' && $operand->type->kind eq 'dynamic' ) {
            $operand = $self->maybe_convert_type( $operand, Brocken::Lindsay::IR::Type::f64() );
        }

        # Unbox remaining dynamic operands to i64 before the remaining unary ops
        if ( $operand->type->kind eq 'dynamic' ) {
            $operand = $self->maybe_convert_type( $operand, Brocken::Lindsay::IR::Type::i64() );
        }

        # Promote i1 before negation: neg(i1) wraps (-1==1 in 1-bit)
        # but i8(-1) sign-extends correctly to wider types.
        if ( $op eq '-' && $operand->type->kind eq 'int' && $operand->type->bits == 1 ) {
            $operand = $self->maybe_convert_type( $operand, Brocken::Lindsay::IR::Type::i8() );
        }

        # Fold negation of a float literal, so `-1.5` is a negative constant rather than an fneg of a positive one.
        # Beyond saving a runtime op,
        # it is load-bearing for f32: the result of an unfolded neg is not a Constant, so there is nothing to re-tag and
        # `my f32 $a = -1.0;` died trying to widen it. Left to floats deliberately -- folding `-5` for an i64 as well is
        # a separate question, since an unsigned neg is defined as wrapping.
        if ( $op eq '-' && $operand->isa('Brocken::Lindsay::IR::Constant') && $operand->type->kind eq 'float' ) {
            return Brocken::Lindsay::IR::Constant->new( type => $operand->type, value => -( $operand->value ) );
        }
        return $builder->build_neg( $operand, undef, $line, $col ) if $op eq '-';
        Carp::croak( "Unknown unary operator '$op' at " . $self->_loc($ast) );
    }

    # `++`/`--` (spec 4.4). The operand must be an lvalue -- a variable, a field access, or an array element. A numeric
    # slot is read, stepped in place, and written back with a plain store; a prefix form yields the post-value, a
    # postfix form the pre-value, and neither result owns a reference.
    #
    # An owned dynamic (`Any`) slot -- an `Any` local, a dynamic field, or an owned `Any` array element -- is stepped by
    # the runtime, which carries the owning-store contract (take a reference to the box it stores, release the one it
    # displaces) and returns an owned reference to the pre- or post-value. That call result is marked owned, so a store
    # consumes the reference and a discard releases it. A borrowed `Any` parameter is promoted to an owned slot first,
    # so the caller's box is never released.
    #
    # A `String` (ptr) slot takes the magical ASCII increment for `++`, or a numeric decrement for `--`; the fresh bytes
    # are stored plainly, since a string carries no reference count. A hash element is not supported yet.
    method lower_incdec( $ast, $discard = 0 ) {
        my $op     = $ast->op;
        my $prefix = $ast->prefix;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $operand = $ast->operand;

        my ( $addr, $stored_type, $is_field_target, $is_weak_field );
        my $target_name = undef;
        if ( $operand->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            $target_name = $operand->name;
            my $key = $operand->sigil eq '@' ? '@' . $operand->name : $operand->name;
            $addr = $symbols->{$key};
            Carp::croak( "Undefined variable '" . $operand->name . "' at " . $self->_loc($operand) ) unless $addr;
            if ( $addr->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') && $current_class ) {
                my $cd      = $classes->{$current_class};
                my ($field) = $cd ? grep { $_->{name} eq $operand->name } $cd->{own_fields}->@* : ();
                $stored_type     = $field ? $field->{ir_type} : Brocken::Lindsay::IR::Type::i64();
                $is_field_target = 1;
                $is_weak_field   = 1 if $field && $field->{weak};
            }
            else {
                $stored_type = $addr->allocated_type;
            }
        }
        elsif ( $operand->isa('Brocken::Katsuro::AST::Expr::FieldAccess') ) {
            $addr = $self->lower_field_addr($operand);
            my $cls = $self->resolve_class_name($operand);
            my $cd  = $classes->{$cls};
            my ($field) = grep { $_->{name} eq $operand->field } $cd->{own_fields}->@*;
            Carp::croak( "Unknown field '" . $operand->field . "' in class '$cls' at " . $self->_loc($operand) ) unless $field;
            $stored_type     = $field->{ir_type};
            $is_field_target = 1;
            $is_weak_field   = 1 if $field->{weak};
        }
        elsif ( $operand->isa('Brocken::Katsuro::AST::Expr::ArrayIndex') ) {
            $addr        = $self->lower_array_addr($operand);
            $stored_type = $addr->base_type;
        }
        elsif ( $operand->isa('Brocken::Katsuro::AST::Expr::HashIndex') ) {
            Carp::croak( "++/-- on a hash element is not supported yet at " . $self->_loc($ast) );
        }
        else {
            Carp::croak( "++/-- target must be a variable, field access, or array index at " . $self->_loc($ast) );
        }

        my $hb = $self->_hash_heap_base( $line, $col );

        my $is_rc        = defined $target_name && $needs_rc->{$target_name};
        my $is_borrowed  = defined $target_name && $borrowed_params->{$target_name};
        my $is_dyn_field = $is_field_target && $stored_type->kind eq 'dynamic' && !$is_weak_field;
        my $is_owned_elem = $operand->isa('Brocken::Katsuro::AST::Expr::ArrayIndex')
            && $operand->array->isa('Brocken::Katsuro::AST::Expr::Var')
            && $operand->array->sigil eq '@'
            && $array_owned_elem->{ '@' . $operand->array->name };
        my $is_dyn_rc = $is_dyn_field || ( $stored_type->kind eq 'dynamic' && ( $is_rc || $is_borrowed || $is_owned_elem ) );

        my $postfix_const
            = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $prefix ? 0 : 1 );

        if ( $stored_type->kind eq 'dynamic' ) {
            if ($is_dyn_rc) {
                if ($is_borrowed) {
                    my $old = $builder->build_load( $stored_type, $addr, undef, $line, $col );
                    $builder->build_incref( $old, $line, $col );
                    delete $borrowed_params->{$target_name};
                    $self->_note_rc($target_name);
                }
                if ($discard) {

                    # Nobody keeps the pre-value, so step the slot in place instead of materialising a box that would be
                    # released on the very next instruction (and briefly buffered as a cycle suspect).
                    my $rt_name = $op eq '++' ? 'inc_slot_discard' : 'dec_slot_discard';
                    $builder->build_call( $self->_reflect_runtime( $rt_name, $ast, $line, $col ), [ $hb, $addr ], undef, $line, $col );
                    return;
                }
                my $rt_name = $op eq '++' ? 'inc_slot' : 'dec_slot';
                return $self->_owned_dynamic_runtime_call( $rt_name, [ $hb, $addr, $postfix_const ], $line, $col );
            }
            Carp::croak( "++/-- on a weak or borrowed dynamic slot is not supported at " . $self->_loc($ast) );
        }

        if ( $stored_type->kind eq 'float' ) {
            my $old = $builder->build_load( $stored_type, $addr, undef, $line, $col );
            my $one = Brocken::Lindsay::IR::Constant->new( type => $stored_type, value => 1.0 );
            my $new = $op eq '++'
                ? $builder->build_add( $old, $one, undef, $line, $col )
                : $builder->build_sub( $old, $one, undef, $line, $col );
            $builder->build_store( $new, $addr, $line, $col );
            return $prefix ? $new : $old;
        }

        if ( $stored_type->kind eq 'int' ) {
            my $old = $builder->build_load( $stored_type, $addr, undef, $line, $col );
            my $one = Brocken::Lindsay::IR::Constant->new( type => $stored_type, value => 1 );
            my $new = $op eq '++'
                ? $builder->build_add( $old, $one, undef, $line, $col )
                : $builder->build_sub( $old, $one, undef, $line, $col );
            $builder->build_store( $new, $addr, $line, $col );
            return $prefix ? $new : $old;
        }

        if ( $stored_type->kind eq 'ptr' ) {
            if ( defined $target_name && $var_class->{$target_name} ) {
                Carp::croak( "++/-- on a class instance is not supported at " . $self->_loc($ast) );
            }
            my $old     = $builder->build_load( $stored_type, $addr, undef, $line, $col );
            my $rt_name = $op eq '++' ? 'str_inc_bytes' : 'str_dec_bytes';
            my $new     = $builder->build_call( $self->_reflect_runtime( $rt_name, $ast, $line, $col ), [ $hb, $old ], undef, $line, $col );
            $builder->build_store( $new, $addr, $line, $col );
            return $prefix ? $new : $old;
        }

        Carp::croak( "++/-- needs a numeric, String, or Any target at " . $self->_loc($ast) );
    }

    # Call a runtime helper that hands back a freshly owned dynamic (`Any`) reference, marking it owned so the store and
    # discard sites release it exactly once (the same wrapper `lower_delete` uses for `hash_delete`).
    method _owned_dynamic_runtime_call( $name, $args, $line, $col ) {
        my $rt = $self->_reflect_runtime( $name, undef, $line, $col );
        my $fn = Brocken::Lindsay::IR::Function->new(
            name        => $rt->name,
            return_type => Brocken::Lindsay::IR::Type::dynamic(),
            params      => $rt->params,
        );
        $returns_owned->{ $fn->name } = 1;
        return $builder->build_call( $fn, $args, undef, $line, $col );
    }

    method _emit_fuel_check( $line, $col ) {
        return unless $symbols->{'__heap_base'};
        return unless defined $fuel_exit_block;

        # Emit fuel decrement + overflow check in a dedicated block, then branch to fuel_exit_block or a fresh ok_block.
        # Keeping the memory ops in a separate block from any subsequent call_func avoids the register-allocator
        # pressure that previously corrupted PE binaries (Bug 9 - the load/add/load/sub/store/cmp sequence placed inline
        # right before a call_func confused the allocator when a physical register overlapped a call argument and the
        # ICB base).
        my $hb_fuel    = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
        my $fuel_off   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::FUEL );
        my $fuel_addr  = $builder->build_add( $hb_fuel, $fuel_off, undef, $line, $col );
        my $fuel_val   = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $fuel_addr, undef, $line, $col );
        my $one        = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
        my $fuel_after = $builder->build_sub( $fuel_val, $one, undef, $line, $col );
        $builder->build_store( $fuel_after, $fuel_addr, $line, $col );
        my $zero      = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
        my $exhausted = $builder->build_icmp( 'sle', $fuel_after, $zero, undef, $line, $col );
        my $ok_block  = $current_func->append_block( $self->unique_block_name('fuel_cont') );
        $builder->build_cond_br( $exhausted, $fuel_exit_block, $ok_block, $line, $col );
        $builder->position_at_end($ok_block);
        $current_block = $ok_block;
    }

    method _emit_cap_check( $required_cap, $line, $col ) {
        return unless $symbols->{'__heap_base'};
        return unless defined $fuel_exit_block;
        my $hb         = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
        my $caps_off   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::CAPABILITIES );
        my $caps_addr  = $builder->build_add( $hb, $caps_off, undef, $line, $col );
        my $caps_val   = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $caps_addr, undef, $line, $col );
        my $cap_mask   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $required_cap );
        my $allowed    = $builder->build_and( $caps_val, $cap_mask, undef, $line, $col );
        my $zero       = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
        my $blocked    = $builder->build_icmp( 'eq', $allowed, $zero, undef, $line, $col );
        my $sec_block  = $current_func->append_block( $self->unique_block_name('cap_violation') );
        my $cont_block = $current_func->append_block( $self->unique_block_name('cap_cont') );
        $builder->build_cond_br( $blocked, $sec_block, $cont_block, $line, $col );
        $builder->position_at_end($sec_block);
        $current_block = $sec_block;
        my $err_off       = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::ERR_CODE );
        my $err_code_addr = $builder->build_add( $hb, $err_off, undef, $line, $col );
        my $err_code_val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::ERR_SECURITY );
        $builder->build_store( $err_code_val, $err_code_addr, $line, $col );
        $builder->build_br( $fuel_exit_block, $line, $col );
        $builder->position_at_end($cont_block);
        $current_block = $cont_block;
    }

    method _emit_div_zero_check( $rhs, $line, $col ) {
        return $rhs unless $symbols->{'__heap_base'};
        return $rhs unless defined $fuel_exit_block;
        my $rhs_type  = $rhs->type;
        my $zero      = Brocken::Lindsay::IR::Constant->new( type => $rhs_type, value => 0 );
        my $is_zero   = $builder->build_icmp( 'eq', $rhs, $zero, undef, $line, $col );
        my $err_block = $current_func->append_block( $self->unique_block_name('div_by_zero') );
        my $ok_block  = $current_func->append_block( $self->unique_block_name('div_ok') );
        $builder->build_cond_br( $is_zero, $err_block, $ok_block, $line, $col );
        $builder->position_at_end($err_block);
        $current_block = $err_block;
        my $hb       = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
        my $err_off  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::ERR_CODE );
        my $err_addr = $builder->build_add( $hb, $err_off, undef, $line, $col );
        my $err_val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::ERR_DIV_ZERO );
        $builder->build_store( $err_val, $err_addr, $line, $col );
        $builder->build_br( $fuel_exit_block, $line, $col );
        $builder->position_at_end($ok_block);
        $current_block = $ok_block;
        return $rhs;
    }

    method lower_call_expr($ast) {
        my $name     = $ast->func_name;
        my $callee   = $functions->{$name};
        my $resolved = $name;
        if ( !$callee && defined $current_package && length $current_package ) {
            my $qualified = $current_package . '::' . $name;
            if ( my $f = $functions->{$qualified} ) { $callee = $f; $resolved = $qualified; }
        }
        my ( $line, $col ) = ( $ast->line, $ast->col );
        unless ($callee) {
            if ( $name eq 'say' || $name eq 'print' ) {
                my $puts_name = $self->_puts_name;
                $callee = Brocken::Lindsay::IR::Function->new(
                    name        => $puts_name,
                    return_type => Brocken::Lindsay::IR::Type::void(),
                    params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ) ],
                );
                $module->add_function($callee);
                $functions->{$name} = $callee;
            }
            elsif ( $name eq 'length' ) {
                $callee = $self->_ensure_extern( $self->_crt_name('strlen'), Brocken::Lindsay::IR::Type::i64(), [ Brocken::Lindsay::IR::Type::ptr() ] );
                $functions->{$name} = $callee;
            }
            else {
                Carp::croak( "Undefined function '$name' at " . $self->_loc($ast) );
            }
        }

        # `say`/`print` hand their argument to `puts(ptr)`, so a non-string value is stringified first: an int or float
        # would otherwise be passed straight through as a pointer and dereferenced (`say(42)` read address 42).
        my $stringify_args = ( $resolved eq 'say' || $resolved eq 'print' );
        my @args;
        my $callee_has_heap_base = $callee->params->@* && defined $callee->params->[0]->name && $callee->params->[0]->name eq '%__heap_base';
        if ($callee_has_heap_base) {
            my $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
            push @args, $hb;
        }
        my $callee_has_want
            = $callee_has_heap_base && $callee->params->@* >= 2 && defined $callee->params->[1]->name && $callee->params->[1]->name eq '%__want';
        if ($callee_has_want) {
            my $want_val = defined $_want_override
                ? Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $_want_override )
                : $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $symbols->{'__want'}, undef, $line, $col );
            push @args, $want_val;
        }
        my $param_idx = ( $callee_has_heap_base ? 1 : 0 ) + ( $callee_has_want ? 1 : 0 );
        my $defaults  = $param_defaults->{$resolved};

        # Arity: an excess argument is a compile error rather than a silently ignored value. `say`/`print` are variadic
        # (they stringify and concatenate every argument), so they are exempt; every other named call is matched
        # one-to-one against the callee's user parameters (the hidden `%__heap_base`/`%__want` are not user arguments
        # and are excluded).
        my $hidden_count = ( $callee_has_heap_base ? 1 : 0 ) + ( $callee_has_want ? 1 : 0 );
        my $user_params  = $callee->params->@* - $hidden_count;
        if ( !$stringify_args && $ast->args->@* > $user_params ) {
            Carp::croak( "Too many arguments to '$name': $user_params expected, got " . $ast->args->@* . " at " . $self->_loc($ast) );
        }

        # A default for one omitted trailing argument may reference an earlier one, so each value that lands in a
        # parameter is bound to that parameter's name while the rest of the call is lowered. The bindings are
        # restored afterwards so they never leak into the caller's scope.
        my @saved;
        for my $arg ( $ast->args->@* ) {
            my $val = $self->lower_expression($arg);
            if ( $stringify_args && $param_idx == 0 ) {
                $val = $self->_stringify_value( $val, $ast, $line, $col );
            }
            elsif ( $param_idx < $callee->params->@* ) {
                $val = $self->maybe_convert_type( $val, $callee->params->[$param_idx]->type );
            }
            push @args, $val;
            if ($defaults) {
                my $di  = $param_idx - ( $callee_has_heap_base ? 1 : 0 ) - ( $callee_has_want ? 1 : 0 );
                my $rec = $di < $defaults->@* ? $defaults->[$di] : undef;
                if ($rec) {
                    push @saved, [ $rec->{name}, $symbols->{ $rec->{name} } ];
                    $symbols->{ $rec->{name} } = $val;
                }
            }
            $param_idx++;
        }

        # `say()`/`print()` with no argument still prints one line: hand `puts` the empty string rather than leaving
        # its argument register unset.
        push @args, $self->_reflect_rodata('') if $stringify_args && !$ast->args->@*;

        # Omitted trailing parameters take their defaults in order. Filling stops at the first parameter without a
        # default: a required parameter cannot be skipped so that a later one can be provided.
        if ($defaults) {
            my $base = ( $callee_has_heap_base ? 1 : 0 ) + ( $callee_has_want ? 1 : 0 );
            while ( $param_idx < $callee->params->@* ) {
                my $di  = $param_idx - $base;
                my $rec = $di < $defaults->@* ? $defaults->[$di] : undef;
                last unless $rec && defined $rec->{default};
                my $val = $self->lower_expression( $rec->{default} );
                $val = $self->maybe_convert_type( $val, $callee->params->[$param_idx]->type );
                push @args,  $val;
                push @saved, [ $rec->{name}, $symbols->{ $rec->{name} } ];
                $symbols->{ $rec->{name} } = $val;
                $param_idx++;
            }
        }

        # ... and a required parameter left unfilled is the other half of the same check: the call site must supply every
        # argument that has no default, rather than leaving the callee to read an uninitialised slot. The arguments are
        # still lowered before this runs, so a bad argument is reported first and an arity error never hides one.
        if ( !$stringify_args && $param_idx < $callee->params->@* ) {
            my $missing = $param_idx - $hidden_count + 1;    # 1-based index of the first unfilled user parameter
            Carp::croak("Missing required argument $missing of '$name' (its parameter has no default) at "
                    . $self->_loc($ast) );
        }
        $symbols->{ $_->[0] } = $_->[1] for @saved;
        $self->_emit_fuel_check( $line, $col );
        return $builder->build_call( $callee, \@args, undef, $line, $col );
    }

    method lower_intrinsic($ast) {
        my $name = $ast->name;
        my @args;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        return $self->lower_builtin( substr( $name, length('builtin::') ), $ast ) if $name =~ /^builtin::/;
        for my $arg ( $ast->args->@* ) {
            push @args, $self->lower_expression($arg);
        }
        # Pointer arithmetic is typed `ptr` regardless of its operands: the result is an address, not the untagged fat
        # scalar the left operand's `dynamic` type would otherwise make it. Without the explicit result type,
        # `my ptr $p = Brocken::ptr_add($any, 0)` reads the sum as a box and pulls out its payload, turning the box
        # pointer into the value it wraps (a `gc_drain` suspect has to stay a pointer).
        return $builder->build_add( $args[0], $args[1], undef, $line, $col, Brocken::Lindsay::IR::Type::ptr() ) if $name eq 'ptr_add';
        return $builder->build_sub( $args[0], $args[1], undef, $line, $col, Brocken::Lindsay::IR::Type::ptr() ) if $name eq 'ptr_sub';
        return $builder->build_icmp( 'sgt', $args[0], $args[1], undef, $line, $col )                   if $name eq 'ptr_cmp_gt';
        return $builder->build_icmp( 'slt', $args[0], $args[1], undef, $line, $col )                   if $name eq 'ptr_cmp_lt';
        return $builder->build_icmp( 'sge', $args[0], $args[1], undef, $line, $col )                   if $name eq 'ptr_cmp_ge';
        return $builder->build_icmp( 'sle', $args[0], $args[1], undef, $line, $col )                   if $name eq 'ptr_cmp_le';
        return $builder->build_icmp( 'eq', $args[0], $args[1], undef, $line, $col )                    if $name eq 'ptr_cmp_eq';
        return $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $args[0], undef, $line, $col ) if $name eq 'load_i64';

        if ( $name eq 'store_i64' ) {
            $builder->build_store( $args[1], $args[0], $line, $col );
            return undef;
        }
        return $builder->build_load( Brocken::Lindsay::IR::Type::i8(), $args[0], undef, $line, $col ) if $name eq 'load_i8';
        if ( $name eq 'store_i8' ) {
            $builder->build_store( $args[1], $args[0], $line, $col );
            return undef;
        }
        return $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $args[0], undef, $line, $col ) if $name eq 'load_i32';
        if ( $name eq 'store_i32' ) {
            $builder->build_store( $args[1], $args[0], $line, $col );
            return undef;
        }

        # A boxed float has to be read as a float. load_i64 on an f64 payload hands back the bit pattern instead of the
        # value, which is what an unbox in an integer context used to see.
        return $builder->build_load( Brocken::Lindsay::IR::Type::f64(), $args[0], undef, $line, $col ) if $name eq 'load_f64';
        if ( $name eq 'store_f64' ) {
            $builder->build_store( $args[1], $args[0], $line, $col );
            return undef;
        }
        return $builder->build_load( Brocken::Lindsay::IR::Type::i16(), $args[0], undef, $line, $col ) if $name eq 'load_u16';
        if ( $name eq 'store_u16' ) {
            $builder->build_store( $args[1], $args[0], $line, $col );
            return undef;
        }
        return $builder->build_add( $args[0], $args[1], undef, $line, $col )  if $name eq 'i64_add';
        return $builder->build_sub( $args[0], $args[1], undef, $line, $col )  if $name eq 'i64_sub';
        return $builder->build_and( $args[0], $args[1], undef, $line, $col )  if $name eq 'band';
        return $builder->build_or( $args[0], $args[1], undef, $line, $col )   if $name eq 'bor';
        return $builder->build_xor( $args[0], $args[1], undef, $line, $col )  if $name eq 'bxor';
        return $builder->build_shl( $args[0], $args[1], undef, $line, $col )  if $name eq 'shl';
        return $builder->build_lshr( $args[0], $args[1], undef, $line, $col ) if $name eq 'shr';

        if ( $name eq 'syscall' ) {
            $self->_emit_cap_check( $Brocken::CAP_FFI // 16, $line, $col );
            return $builder->build_syscall( \@args, undef, $line, $col );
        }
        if ( $name eq 'syscall_by_name' ) {
            my $name_ast = $ast->args->[0];
            Carp::croak( "First argument to syscall_by_name must be a string literal at " . $self->_loc($ast) )
                unless $name_ast->isa('Brocken::Katsuro::AST::Expr::Const') && $name_ast->type eq 'String';
            Carp::croak( "syscall_by_name requires a platform to resolve syscall names at " . $self->_loc($ast) ) unless $platform;
            my $syscall_name = $name_ast->value;
            my $syscall_num  = $platform->syscall($syscall_name);
            Carp::croak( "Unknown syscall name '$syscall_name' at " . $self->_loc($ast) ) unless defined $syscall_num;
            my @syscall_args = ( Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $syscall_num, ) );
            for my $i ( 1 .. $#args ) {
                push @syscall_args, $args[$i];
            }
            $self->_emit_cap_check( $Brocken::CAP_FFI // 16, $line, $col );
            return $builder->build_syscall( \@syscall_args, undef, $line, $col );
        }
        if ( $name eq 'libc' ) {
            my $name_ast = $ast->args->[0];
            Carp::croak( "First argument to libc must be a string literal at " . $self->_loc($ast) )
                unless $name_ast->isa('Brocken::Katsuro::AST::Expr::Const') && $name_ast->type eq 'String';
            my $func_name = $name_ast->value;
            my $extern_fn
                = Brocken::Lindsay::IR::Function->new( name => $func_name, return_type => Brocken::Lindsay::IR::Type::i64(), params => [], );
            my @call_args;
            for my $i ( 1 .. $#args ) {
                push @call_args, $args[$i];
            }
            $self->_emit_cap_check( $Brocken::CAP_FFI // 16, $line, $col );
            return $builder->build_call( $extern_fn, \@call_args, undef, $line, $col );
        }
        if ( $name eq 'heap_base' ) {
            my $hb = $symbols->{'__heap_base'} or Carp::croak( "heap_base intrinsic requires __heap_base symbol at " . $self->_loc($ast) );
            return $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $hb, undef, $line, $col );
        }
        Carp::croak( "Unknown intrinsic '$name' at " . $self->_loc($ast) );
    }

    # == builtin:: namespace ==
    # Mirrors Perl's `builtin` pragma: utility functions present in the interpreter and callable by their
    # fully-qualified `builtin::NAME` name. Pure value builtins lower to a constant or an op; the weak-reference
    # builtins (`weaken`, `unweaken`, `is_weak`) operate on a variable's ownership rather than its value. Brocken has
    # no dynamic value provenance and no taint model, so a few of Perl's builtins are intentionally absent (see
    # docs/spec.md, `builtin::`).
    method lower_builtin( $name, $ast ) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        if ( $name eq 'true' )  { return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => 1 ); }
        if ( $name eq 'false' ) { return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => 0 ); }

        # There is no taint model: a value is never tainted. The argument is still evaluated for side effects.
        if ( $name eq 'is_tainted' ) {
            $self->lower_expression( $ast->args->[0] ) if $ast->args->@*;
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => 0 );
        }

        if ( $name eq 'weaken' || $name eq 'unweaken' || $name eq 'is_weak' ) {
            return $self->lower_weaken_builtin( $name, $ast, $line, $col );
        }
        if ( $name eq 'is_bool' || $name eq 'created_as_string' || $name eq 'created_as_number'
            || $name eq 'stringify' || $name eq 'numify' || $name eq 'reftype' || $name eq 'blessed'
            || $name eq 'refaddr' )
        {
            return $self->lower_reflect_builtin( $name, $ast, $line, $col );
        }
        if ( $name eq 'ceil' || $name eq 'floor' ) {
            return $self->lower_round_builtin( $name, $ast, $line, $col );
        }
        if ( $name eq 'inf' || $name eq 'nan' ) {
            return $self->lower_special_float_builtin( $name, $ast, $line, $col );
        }
        if ( $name eq 'trim' ) {
            return $self->lower_trim_builtin( $ast, $line, $col );
        }
        if ( $name eq 'indexed' ) {
            return $self->lower_indexed_builtin( $ast, $line, $col );
        }
        Carp::croak( "Unknown builtin 'builtin::$name' at " . $self->_loc($ast) );
    }

    # `builtin::weaken`/`unweaken`/`is_weak` take a variable, not a value. Weakness is a static property of the
    # storage (like a `:weak` field or local): a weak slot stores without taking a reference and is skipped by the
    # scope-exit release. `weaken` drops the reference the variable currently holds, so an object it alone owned may
    # be freed and leave the slot dangling -- the documented weak hazard; Brocken has no weak-ref hook that could null
    # it. `unweaken` re-takes a reference. `is_weak` folds to a compile-time boolean.
    method lower_weaken_builtin( $name, $ast, $line, $col ) {
        my $arg = $ast->args->[0];
        Carp::croak( "builtin::$name expects a variable argument at " . $self->_loc($ast) )
            unless $arg && $arg->isa('Brocken::Katsuro::AST::Expr::Var');
        my $vname = $arg->name;
        my $addr  = $symbols->{$vname};
        Carp::croak( "Undefined variable '$vname' for builtin::$name at " . $self->_loc($ast) ) unless $addr;

        if ( $name eq 'is_weak' ) {
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => ( $weak_var->{$vname} ? 1 : 0 ) );
        }

        if ( $name eq 'weaken' ) {
            return undef if $weak_var->{$vname};
            if ( $needs_rc->{$vname} ) {
                my $hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
                $self->_emit_rc_release( $vname, $hb );
                $self->_forget_rc($vname);
            }
            $weak_var->{$vname} = 1;
            return undef;
        }

        # unweaken: re-take a reference to the value the variable currently holds.
        return undef unless $weak_var->{$vname};
        delete $weak_var->{$vname};
        my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::ptr(), $addr, undef, $line, $col );
        $builder->build_incref( $loaded, $line, $col );
        if ( my $class = $var_class->{$vname} ) {
            $self->_note_class( $vname, $class );
        }
        else {
            $self->_note_rc($vname);
        }
        return undef;
    }

    # == builtin:: reflection ==
    # Perl's `builtin` reflection helpers inspect a value's type. Brocken is statically typed, so a value whose IR
    # type is known answers at compile time (a class pointer uses its statically-known class). A value typed `Any`
    # is a runtime box, so the answer is read from the box header: `box_tag` returns the tag every box carries --
    # 1/2 narrow/wide int, 3 float, 4 pointer (String or class instance), 6 i128, 7/9 array, 8 hash. A box carries
    # only the tag, not a class id, so a boxed class instance is indistinguishable from a boxed String or bare
    # pointer. What Brocken cannot recover from a box is the fine-grained Perl provenance: a bool box and a
    # narrow-int box share tag 1, and a String box and a boxed instance share tag 4. Those cases are documented in
    # docs/spec.md.
    method lower_reflect_builtin( $name, $ast, $line, $col ) {
        my $arg = $ast->args->[0];
        Carp::croak( "builtin::$name expects an argument at " . $self->_loc($ast) ) unless $arg;
        my $val  = $self->lower_expression($arg);
        my $kind = $val->type->kind;

        if ( $name eq 'is_bool' ) {
            return $self->_icmp_eq_i64( $self->_reflect_box_tag( $val, $line, $col ), 1, $line, $col )
                if $kind eq 'dynamic';
            my $is_bool = $kind eq 'int' && $val->type->bits == 1 ? 1 : 0;
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => $is_bool );
        }

        if ( $name eq 'created_as_number' ) {
            if ( $kind eq 'dynamic' ) {
                my $tag  = $self->_reflect_box_tag( $val, $line, $col );
                my $low  = $builder->build_or( $self->_icmp_eq_i64( $tag, 1, $line, $col ),
                                               $self->_icmp_eq_i64( $tag, 2, $line, $col ), undef, $line, $col );
                my $high = $builder->build_or( $self->_icmp_eq_i64( $tag, 3, $line, $col ),
                                               $self->_icmp_eq_i64( $tag, 6, $line, $col ), undef, $line, $col );
                return $builder->build_or( $low, $high, undef, $line, $col );
            }
            my $is_num = ( $kind eq 'int' || $kind eq 'float' ) ? 1 : 0;
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => $is_num );
        }

        if ( $name eq 'created_as_string' ) {
            return $self->_icmp_eq_i64( $self->_reflect_box_tag( $val, $line, $col ), 4, $line, $col )
                if $kind eq 'dynamic';
            my $is_str = $kind eq 'ptr' && !defined $self->_reflect_static_class($arg) ? 1 : 0;
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i1(), value => $is_str );
        }

        if ( $name eq 'refaddr' ) {
            return $self->_reflect_ptr_to_i64( $val, $line, $col ) if $kind eq 'dynamic' || $kind eq 'ptr';
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
        }

        if ( $name eq 'reftype' ) {
            my $scalar = $self->_reflect_rodata('SCALAR');
            return $scalar if $kind eq 'int' || $kind eq 'float';
            return $self->_reflect_rodata('ARRAY') if $kind eq 'list';
            return $self->_reflect_rodata('HASH')  if $kind eq 'hash';
            if ( $kind eq 'ptr' ) {
                return defined $self->_reflect_static_class($arg) ? $self->_reflect_rodata('OBJECT') : $scalar;
            }
            if ( $kind eq 'dynamic' ) {
                my $tag    = $self->_reflect_box_tag( $val, $line, $col );
                my $is_arr = $builder->build_or(
                    $self->_icmp_eq_i64( $tag, 7, $line, $col ),
                    $self->_icmp_eq_i64( $tag, 9, $line, $col ), undef, $line, $col
                );
                my $is_hash = $self->_icmp_eq_i64( $tag, 8, $line, $col );
                my $type = $builder->build_select( $is_hash, $self->_reflect_rodata('HASH'), $scalar, undef, $line, $col );
                $type = $builder->build_select( $is_arr,  $self->_reflect_rodata('ARRAY'), $type,   undef, $line, $col );
                return $type;
            }
            return $scalar;
        }

        if ( $name eq 'blessed' ) {
            my $class = $self->_reflect_static_class($arg);
            return $self->_reflect_rodata($class) if defined $class;

            # A box's class id cannot be turned back into a name: the runtime carries no class-name table. An `Any`
            # holding an instance is reported as undef, as a non-object always is.
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 );
        }

        if ( $name eq 'stringify' ) {
            return $self->_stringify_value( $val, $ast, $line, $col );
        }

        if ( $name eq 'numify' ) {
            # A String numifies by parsing its leading number, the way Perl's string-to-number conversion does. The
            # runtime has no such helper, so `numify` calls the C library's `strtod` directly, the way `_stringify`
            # calls `sprintf` for a float.
            my $str_to_f64 = sub ($ptr_val) {
                my $fn = Brocken::Lindsay::IR::Function->new(
                    name        => $self->_crt_name('strtod'),
                    return_type => Brocken::Lindsay::IR::Type::f64(),
                    params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
                                      Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ) ],
                );
                my $null = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 );
                return $builder->build_call( $fn, [ $ptr_val, $null ], undef, $line, $col );
            };
            if ( $kind eq 'dynamic' ) {
                my $tag      = $self->_reflect_box_tag( $val, $line, $col );
                my $is_float = $self->_icmp_eq_i64( $tag, 3, $line, $col );
                my $is_str   = $self->_icmp_eq_i64( $tag, 4, $line, $col );
                my $f        = $builder->build_call( $self->_reflect_runtime('unbox_f64', $ast, $line, $col), [$val], undef, $line, $col );
                my $i        = $builder->build_call( $self->_reflect_runtime('unbox_i64', $ast, $line, $col), [$val], undef, $line, $col );
                my $fi       = $self->maybe_convert_type( $i, Brocken::Lindsay::IR::Type::f64(), $line, $col );
                my $num      = $builder->build_select( $is_float, $f, $fi, undef, $line, $col );
                my $pstr     = $builder->build_call( $self->_reflect_runtime('unbox_ptr', $ast, $line, $col), [$val], undef, $line, $col );

                # Both select arms are evaluated, and `strtod` dereferences its pointer, so a non-string payload (an
                # integer or float box) must not be handed through raw: `strtod(42, NULL)` reads address 42 and traps.
                # A non-string box parses the empty string instead, and the select discards that zero.
                my $empty = $self->_reflect_rodata('');
                my $safe  = $builder->build_select( $is_str, $pstr, $empty, undef, $line, $col );
                my $snum  = $str_to_f64->($safe);
                return $builder->build_select( $is_str, $snum, $num, undef, $line, $col );
            }
            return $val if $kind eq 'float';
            return $self->maybe_convert_type( $val, Brocken::Lindsay::IR::Type::f64(), $line, $col ) if $kind eq 'int';
            return $str_to_f64->($val) if $kind eq 'ptr' && !defined $self->_reflect_static_class($arg);
            Carp::croak( "builtin::numify cannot convert a " . ( $kind eq 'ptr' ? 'class instance' : $kind ) . " to a number at " . $self->_loc($ast) );
        }

        Carp::croak( "Unknown builtin 'builtin::$name' at " . $self->_loc($ast) );
    }

    # == builtin:: rounding ==
    # `ceil`/`floor` answer an `i64` for any numeric argument. An integer argument is already integral, so it passes
    # through. For a float, `fptosi` truncates toward zero, which is exactly right when the value is already
    # integral and off by one in the direction the rounding wants otherwise -- so the truncated value is converted
    # back and compared, and adjusted by one only when it lands on the wrong side. Doing it in the IR rather than
    # calling libm keeps the linker free of a `-lm` dependency (`ceil`/`floor` are not libc symbols) and covers every
    # backend through the same `fptosi`/`sitofp`/`fcmp` it already supports. A value too large for an `i64` is
    # undefined, the same range limit every integer conversion has.
    method lower_round_builtin( $name, $ast, $line, $col ) {
        my $arg = $ast->args->[0];
        Carp::croak( "builtin::$name expects a numeric argument at " . $self->_loc($ast) ) unless $arg;
        my $val  = $self->lower_expression($arg);
        my $kind = $val->type->kind;

        my $round_float = sub ($f) {
            my $trunc   = $builder->build_fptosi( $f, Brocken::Lindsay::IR::Type::i64(), undef, $line, $col );
            my $trunc_f = $builder->build_sitofp( $trunc, Brocken::Lindsay::IR::Type::f64(), undef, $line, $col );
            my $cmp     = $name eq 'ceil'
                ? $builder->build_icmp( 'lt', $trunc_f, $f, undef, $line, $col )
                : $builder->build_icmp( 'gt', $trunc_f, $f, undef, $line, $col );
            my $one = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
            my $adj = $name eq 'ceil'
                ? $builder->build_add( $trunc, $one, undef, $line, $col )
                : $builder->build_sub( $trunc, $one, undef, $line, $col );
            return $builder->build_select( $cmp, $adj, $trunc, undef, $line, $col );
        };

        if ( $kind eq 'int' ) {
            return $self->maybe_convert_type( $val, Brocken::Lindsay::IR::Type::i64(), $line, $col );
        }
        if ( $kind eq 'float' ) {
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                my $v   = $val->value;
                my $int = int($v);
                $int -= 1 if $name eq 'floor' && $int > $v;
                $int += 1 if $name eq 'ceil'  && $int < $v;
                return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $int );
            }
            return $round_float->($val);
        }
        if ( $kind eq 'dynamic' ) {

            # A float box rounds; an int box is returned as-is. `unbox_f64` would widen a large integer to a double
            # and lose bits beyond 2^53, so the tag selects between the rounded float and the untouched integer
            # rather than routing everything through the float path.
            my $tag      = $self->_reflect_box_tag( $val, $line, $col );
            my $is_float = $self->_icmp_eq_i64( $tag, 3, $line, $col );
            my $f        = $builder->build_call( $self->_reflect_runtime( 'unbox_f64', $ast, $line, $col ), [$val], undef, $line, $col );
            my $i        = $builder->build_call( $self->_reflect_runtime( 'unbox_i64', $ast, $line, $col ), [$val], undef, $line, $col );
            return $builder->build_select( $is_float, $round_float->($f), $i, undef, $line, $col );
        }
        Carp::croak( "builtin::$name cannot round a $kind at " . $self->_loc($ast) );
    }

    # == builtin:: inf / nan ==
    # `inf`/`nan` return an `f64`. An optional sign argument picks the sign of the infinity; a non-constant sign is
    # honoured as a runtime comparison (the argument is a sign, exactly as Perl treats it), and `nan` ignores its
    # sign but still evaluates the argument for side effects. The values are the floating-point infinities and a
    # quiet NaN, which the backends pack from the constant's bits (`Inf`/`NaN` survive `pack 'd'`).
    method lower_special_float_builtin( $name, $ast, $line, $col ) {
        state $POS_INF = 9**9**9;
        state $NEG_INF = -( 9**9**9 );
        state $NAN     = ( 9**9**9 ) - ( 9**9**9 );
        my $f64 = sub ($v) {
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::f64(), value => $v );
        };

        my $arg = $ast->args->[0];
        if ( $name eq 'nan' ) {
            $self->lower_expression($arg) if $arg;
            return $f64->($NAN);
        }
        return $f64->($POS_INF) unless $arg;
        my $val = $self->lower_expression($arg);
        return $f64->( $val->value < 0 ? $NEG_INF : $POS_INF )
            if $val->isa('Brocken::Lindsay::IR::Constant');
        $val = $self->maybe_convert_type( $val, Brocken::Lindsay::IR::Type::f64(), $line, $col )
            if $val->type->kind eq 'dynamic';
        my $zero = Brocken::Lindsay::IR::Constant->new( type => $val->type, value => 0 );

        # The ordering predicate is spelled per type: a float uses the plain `lt`, an integer the signed/unsigned
        # `slt`/`ult` the comparison lowering uses. A bare `lt` on an integer operand is a predicate no `set`
        # condition names, so it silently produced a `set` with no suffix.
        my $pred = $val->type->kind eq 'float' ? 'lt' : ( $val->type->is_signed ? 'slt' : 'ult' );
        my $neg  = $builder->build_icmp( $pred, $val, $zero, undef, $line, $col );
        return $builder->build_select( $neg, $f64->($NEG_INF), $f64->($POS_INF), undef, $line, $col );
    }

    # == builtin:: trim ==
    # A fresh string with leading and trailing ASCII whitespace removed. Brocken strings are byte strings, so the
    # Unicode whitespace Perl's `trim` also strips is out of reach (the runtime helper matches ASCII `\s`). A static
    # String is a plain pointer; a boxed string contributes its pointer payload, with a non-string box collapsing to
    # the empty string because both `select` arms are evaluated and the runtime would otherwise read a non-pointer
    # payload as characters.
    method lower_trim_builtin( $ast, $line, $col ) {
        my $arg = $ast->args->[0];
        Carp::croak( "builtin::trim expects an argument at " . $self->_loc($ast) ) unless $arg;
        my $val  = $self->lower_expression($arg);
        my $kind = $val->type->kind;

        my $hb = $symbols->{'__heap_base'}
            ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col )
            : undef;
        Carp::croak( "builtin::trim requires __heap_base at " . $self->_loc($ast) ) unless $hb;
        my $trim_fn = $self->_reflect_runtime( 'str_trim', $ast, $line, $col );

        if ( $kind eq 'ptr' && !defined $self->_reflect_static_class($arg) ) {
            return $builder->build_call( $trim_fn, [ $hb, $val ], undef, $line, $col );
        }
        if ( $kind eq 'dynamic' ) {
            my $tag    = $self->_reflect_box_tag( $val, $line, $col );
            my $is_str = $self->_icmp_eq_i64( $tag, 4, $line, $col );
            my $pstr   = $builder->build_unbox( $val, Brocken::Lindsay::IR::Type::ptr(), undef, $line, $col );
            my $safe   = $builder->build_select( $is_str, $pstr, $self->_reflect_rodata(''), undef, $line, $col );
            return $builder->build_call( $trim_fn, [ $hb, $safe ], undef, $line, $col );
        }
        Carp::croak( "builtin::trim cannot trim a " . ( $kind eq 'ptr' ? 'class instance' : $kind ) . " at " . $self->_loc($ast) );
    }

    # == builtin:: indexed ==
    # `builtin::indexed LIST` returns a flat list of `(index, value)` pairs: 0, e0, 1, e1, ... A `for my ($i, $v)`
    # loop then walks it two slots at a time. `LIST` is the argument list, so `builtin::indexed(10, 20)` is two pairs;
    # a single parenthesized list is flattened, and a single array variable is unrolled into its elements (which needs
    # a compile-time length, since the pair list is built as straight-line stores and cannot grow at runtime).
    method lower_indexed_builtin( $ast, $line, $col ) {
        my @args     = $ast->args->@*;
        my @elements;
        if ( @args == 1 && $self->_is_local_array( $args[0] ) ) {
            @elements = $self->_array_element_exprs( $args[0], $line, $col );
        }
        elsif ( @args == 1 && $args[0]->isa('Brocken::Katsuro::AST::Expr::List') ) {
            @elements = $args[0]->elements->@*;
        }
        else {
            @elements = @args;
        }
        my @flat;
        for my $i ( 0 .. $#elements ) {
            push @flat, Brocken::Katsuro::AST::Expr::Const->new( file => $ast->file, line => $line, col => $col, value => $i, type => 'Int' );
            push @flat, $elements[$i];
        }
        return $self->lower_list_expr(
            Brocken::Katsuro::AST::Expr::List->new( file => $ast->file, line => $line, col => $col, elements => \@flat ) );
    }

    # A `builtin::` reflection helper that inspects a runtime box reads its header tag. `box_tag` is a runtime
    # function because the header layout is the runtime's business, not the front end's.
    method _reflect_box_tag( $val, $line, $col ) {
        return $builder->build_call( $self->_reflect_runtime( 'box_tag', undef, $line, $col ), [$val], undef, $line, $col );
    }

    method _reflect_runtime( $name, $ast = undef, $line = 0, $col = 0 ) {
        my $fn = $functions->{ 'Brocken::Runtime::' . $name };
        Carp::croak( "Runtime function $name not found at line $line, col $col" ) unless $fn;
        return $fn;
    }

    method _icmp_eq_i64( $lhs, $n, $line, $col ) {
        return $builder->build_icmp( 'eq', $lhs,
            Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $n ), undef, $line, $col );
    }

    # The front end has no pointer-to-integer cast. Storing the pointer into a stack slot and reading it back as an
    # i64 is the same bits, which is all `refaddr` needs.
    method _reflect_ptr_to_i64( $val, $line, $col ) {
        my $slot = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), undef, undef, $line, $col );
        $builder->build_store( $val, $slot, $line, $col );
        return $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $slot, undef, $line, $col );
    }

    method _reflect_rodata($str) {
        my ( $label, $bytes ) = $self->_intern_rodata( $str . "\0" );
        return Brocken::Lindsay::IR::RodataRef->new( label => $label, bytes => $bytes, type => Brocken::Lindsay::IR::Type::ptr() );
    }

    # The static class of an argument, or undef. `_expr_class` croaks on an unresolved bareword class, which a
    # reflection helper must treat as "not a class" rather than as a compile error.
    method _reflect_static_class($arg) {
        return undef
            unless $arg->isa('Brocken::Katsuro::AST::Expr::Var')
            || $arg->isa('Brocken::Katsuro::AST::Expr::Call')
            || $arg->isa('Brocken::Katsuro::AST::Expr::MethodCall');
        my $class = eval { $self->_expr_class($arg) };
        return $class;
    }

    # Condition conversion
    # Reduce a value to a 1-bit truth value: Perl truthiness for a boxed value (`is_truthy`, so `"0"`, `""`, `0.0`, and
    # a null box are false), or a `!= 0`/`!= 0.0` comparison for a native int/float/bool. Shared by `&&`/`||` and, in
    # spirit, by `as_condition`.
    method _truthy_i1( $side, $line, $col ) {
        if ( $side->type->kind eq 'dynamic' ) {
            my $fn = $functions->{'Brocken::Runtime::is_truthy'}
                or Carp::croak("Runtime function is_truthy not found at line $line, col $col");
            my $t    = $builder->build_call( $fn, [$side], undef, $line, $col );
            my $zero = Brocken::Lindsay::IR::Constant->new( type => $t->type, value => 0 );
            return $builder->build_icmp( 'ne', $t, $zero, undef, $line, $col );
        }
        my $zero = Brocken::Lindsay::IR::Constant->new(
            type  => $side->type,
            value => $side->type->kind eq 'float' ? 0.0 : 0,
        );
        return $builder->build_icmp( 'ne', $side, $zero, undef, $line, $col );
    }

    method as_condition( $val, $line = 0, $col = 0 ) {

        # A value already of boolean type is used as-is, except a constant: the encoders resolve only registers and
        # memory for a branch or select operand, so a literal condition -- `if (true)`, `if (false)`, or a `defined` on
        # a native scalar, which folds to a constant true -- is materialized as a comparison of itself against zero
        # instead of reaching the encoder as an immediate.
        return $val if $val->type->bits == 1 && !( ref $val && $val->isa('Brocken::Lindsay::IR::Constant') );

        # A dynamic value is tested with the runtime's Perl-truthiness helper rather than a blind unbox: `0`, `0.0`, "",
        # "0", and a null box are false, while "00", "0.0", 0.5, and any reference are true. Unboxing first would also
        # fault on a null box (`if (undef)`), because the payload readers dereference the box pointer.
        return $self->_truthy_i1( $val, $line, $col );
    }

    # Type conversion helper
    method maybe_convert_type( $val, $target_type, $line = 0, $col = 0, $unbox_ptr = 0 ) {

        # `undef` is the null box -- the only dynamic constant the lowerer builds. Converting it to a native type is
        # that type's zero, and to a `ptr`/`String`/class slot it is null; reading the payload out of a null box would
        # dereference address 8. (A real box always arrives as an instruction, never as a dynamic constant.)
        if ( $val->isa('Brocken::Lindsay::IR::Constant') && $val->type->kind eq 'dynamic' && $val->value == 0 ) {
            my $zero = $target_type->kind eq 'float' ? 0.0 : 0;
            return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => $zero );
        }
        return $val if $val->type->kind eq $target_type->kind && $val->type->bits == $target_type->bits;

        # Box: native -> dynamic
        if ( $target_type->kind eq 'dynamic' && $val->type->kind ne 'dynamic' ) {
            if ( $val->type->kind eq 'int' && $val->type->bits < 32 ) {
                my $wt = $val->type->is_signed ? Brocken::Lindsay::IR::Type::i32() : Brocken::Lindsay::IR::Type::u32();
                $val = $val->type->is_signed ? $builder->build_sext( $val, $wt, undef, $line, $col ) :
                    $builder->build_zext( $val, $wt, undef, $line, $col );
            }
            my $hb
                = $symbols->{'__heap_base'} ?
                $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col ) :
                undef;
            return $builder->build_box( $val, undef, $line, $col, $hb );
        }

        # Unbox: dynamic -> native
        if ( $val->type->kind eq 'dynamic' && $target_type->kind ne 'dynamic' ) {

            # Reinterpret: dynamic -> ptr is a no-op by default; a dynamic value IS the box pointer that the
            # `ptr`-taking runtime helpers (`box_tag`, `unbox_i64`, `unbox_f64`) read the header through, so unboxing
            # here would hand them the payload. Where the box's *payload* is wanted instead -- storing an `Any` into a
            # typed `String`/class/`ptr` slot, or returning one from a `String`/`ptr` function -- the caller passes
            # `$unbox_ptr`, which falls through to the blind `build_unbox` below and reads the eight bytes at offset 8.
            return $val if $target_type->kind eq 'ptr' && !$unbox_ptr;

            # A direct unbox is a blind payload load: it reads the eight bytes at offset 8 at whatever width the context
            # asked for, without looking at the tag. So a float payload read into an i64 came back as its bit pattern,
            # and an integer payload read into an f64 came back as a denormal built out of a small integer. The runtime
            # helpers read the tag first and convert, which is what makes the value mean what
            # the box actually holds: unbox_f64 widens an integer payload, unbox_i64 truncates a float payload toward
            # zero.
            #
            # f32 and i128 keep the direct load. There is no fptrunc/fpext in the IR to narrow what unbox_f64 returns,
            # and unbox_i64 would only ever hand back the low eight bytes of an i128 payload. Both were already excluded
            # as unsupported; this does not make them worse.
            my $kind = $target_type->kind;
            my $bits = $target_type->bits;
            if ( $kind eq 'float' && $bits == 64 ) {
                my $fn = $functions->{'Brocken::Runtime::unbox_f64'} or Carp::croak("Runtime function unbox_f64 not found at line $line, col $col");
                return $builder->build_call( $fn, [$val], undef, $line, $col );
            }
            if ( $kind eq 'int' && $bits <= 64 ) {
                my $fn   = $functions->{'Brocken::Runtime::unbox_i64'} or Carp::croak("Runtime function unbox_i64 not found at line $line, col $col");
                my $wide = $builder->build_call( $fn, [$val], undef, $line, $col );
                return $bits == 64 ? $wide : $self->maybe_convert_type( $wide, $target_type, $line, $col );
            }
            return $builder->build_unbox( $val, $target_type, undef, $line, $col );
        }

        # Integer widening: zero-extend for unsigned, sign-extend for signed
        # Integer narrowing: mask to target bit width (AND with mask)
        if ( $val->type->kind eq 'int' && $target_type->kind eq 'int' ) {
            if ( $val->type->bits < $target_type->bits ) {
                if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                    return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => $val->value );
                }
                if ( !( $val->type->is_signed && $val->type->bits > 1 ) ) {
                    return $builder->build_zext( $val, $target_type, undef, $line, $col );
                }

                # Sign-extending into an *unsigned* type is not expressible: the backends size an extension from its
                # source operand and sign-extend all the way out to 32 or 64 bits, with no way to stop at the
                # destination width, so the bits above it survive into whatever consumes them. The promotion picks sext
                # from the *source* signedness, so that is exactly what happened to `my i8 $a = -61; my u16 $b = 65509;
                # $a >= $b`: the narrower signed operand landed in an unsigned comparison still carrying its sign,
                # comparing 0xFFFFFFC3 against 65509 and answering 1.
                # Sign-extend to a signed type of the target width first, then zero-extend that width, which is the
                # value the unsigned type actually holds. A 64-bit destination is already as wide as the register the
                # extension lands in, so its sign is the whole value.
                if ( $target_type->is_signed || $target_type->bits >= 64 ) {
                    return $builder->build_sext( $val, $target_type, undef, $line, $col );
                }
                my $at_width = $builder->build_sext( $val, Brocken::Lindsay::IR::Type::signed_for( $target_type->bits ), undef, $line, $col );
                return $builder->build_zext( $at_width, $target_type, undef, $line, $col );
            }
            if ( $val->type->bits > $target_type->bits ) {
                my $bits = $target_type->bits;
                my $mask;
                if ( $bits >= 64 ) {
                    require Math::BigInt;
                    $mask = ( Math::BigInt->new(1) << $bits ) - 1;
                }
                else {
                    $mask = ( 1 << $bits ) - 1;
                }
                if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                    my $cv = $val->value;
                    if ( ref($cv) && $cv->isa('Math::BigInt') || ref($mask) && $mask->isa('Math::BigInt') ) {
                        require Math::BigInt;
                        my $bn = ref($cv)   && $cv->isa('Math::BigInt')   ? $cv->copy   : Math::BigInt->new($cv);
                        my $bm = ref($mask) && $mask->isa('Math::BigInt') ? $mask->copy : Math::BigInt->new($mask);
                        return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => $bn & $bm );
                    }
                    return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => $cv & $mask );
                }
                my $mask_val = Brocken::Lindsay::IR::Constant->new( type => $val->type, value => $mask );

                # The instruction, not the mask, carries the target type: a narrowed value whose result stayed typed
                # at the source width is classified by that width everywhere downstream -- at a call the ABI saw a
                # u128 argument masked to 64 bits, put it on the stack, and the callee read an uninitialized
                # register instead. The mask keeps the source type so it lowers against the source operands; the
                # backends size the operation from the result.
                return $builder->build_and( $val, $mask_val, undef, $line, $col, $target_type );
            }
        }

        # Integer -> float (sitofp)
        if ( $val->type->kind eq 'int' && $target_type->kind eq 'float' ) {
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => 0.0 + $val->value );
            }
            return $builder->build_sitofp( $val, $target_type, undef, $line, $col );
        }

        # Float -> integer (fptosi). The conversion is masked to the target width for the same reason the int->int case
        # above is: an fptosi typed at a narrow destination still lowers to a full-width convert (a 32-bit cvttsd2si, an
        # fcvtzs to w, a trunc_sat), so without the mask the leftover bits survive into a slot that is only a byte wide,
        # and a bool target kept the whole value instead of one bit.
        #
        # Only a destination narrower than 32 bits needs it. A 32- or 64-bit one is already the width the conversion
        # produces, so masking would be a no-op there -- and the 32-bit mask is not representable, since 0xFFFFFFFF is
        # -1 as a signed i32 and emitting it as an i32 constant is rejected as too large.
        if ( $val->type->kind eq 'float' && $target_type->kind eq 'int' ) {
            my $bits = $target_type->bits;
            my $mask = $bits < 32 ? ( 1 << $bits ) - 1 : undef;
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                my $cv = int( $val->value );
                return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => defined $mask ? $cv & $mask : $cv );
            }
            my $converted = $builder->build_fptosi( $val, $target_type, undef, $line, $col );
            return $converted unless defined $mask;
            my $mask_val = Brocken::Lindsay::IR::Constant->new( type => $target_type, value => $mask );
            return $builder->build_and( $converted, $mask_val, undef, $line, $col );
        }

        # Float width, which is what a decimal literal runs into: it arrives as f64, and `my f32 $t = 1.5;` would
        # otherwise store eight bytes into a four-byte slot. A *literal* is again not a number that needs converting --
        # the constant holds a plain Perl number and each backend packs it at the width its type asks for -- so
        # re-tagging is the whole conversion, and it is also where the rounding to f32 happens.
        if ( $val->type->kind eq 'float' && $target_type->kind eq 'float' ) {
            return $val if $val->type->bits == $target_type->bits;
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => $val->value );
            }
            Carp::croak( "No float-to-float conversion from " .
                    $val->type->bits .
                    " bits to " .
                    $target_type->bits .
                    "; the IR has no fptrunc or fpext, and a float of one width cannot be stored in a slot of the other" );
        }
        $val;
    }

    # Class field helpers
    method resolve_class_name($ast) {
        my $cls = $self->_expr_class( $ast->obj );
        return $cls if defined $cls;
        Carp::croak( "Cannot determine class for field or method access at " . $self->_loc($ast) ) unless $current_class;
        return $current_class;
    }

    # Statically determine the class a receiver expression evaluates to, or undef if it cannot be known.
    method _expr_class($obj) {
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
            my $class = $self->_resolve_class_ident( $obj->name );
            Carp::croak( "Unknown class '" . $obj->name . "' at " . $self->_loc($obj) ) unless $classes->{$class};
            return $class;
        }
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Var') && exists $var_class->{ $obj->name } ) {
            return $var_class->{ $obj->name };
        }
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Call') && exists $function_return_class->{ $obj->func_name } ) {
            return $function_return_class->{ $obj->func_name };
        }
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::MethodCall') ) {
            my $recv = $self->_expr_class( $obj->obj );
            if ( defined $recv ) {

                # Resolve through the ancestor chain: an inherited method is found on the class that declared it.
                my $full = $self->_resolve_method( $recv, $obj->method );
                if ($full) {
                    my $ret_class = $function_return_class->{$full};
                    return $ret_class if $ret_class;

                    # An auto-generated :writer / :accessor method returns its receiver, so a chained call such
                    # as $obj->set_x(1)->set_y(2) keeps the same class. The receiver's static class is kept (not the
                    # declaring class) so chaining an inherited writer with an own writer stays on the receiver.
                    return $recv if $writer_map->{$full};
                }
            }
        }
        return undef;
    }

    # Lower a receiver expression to the object pointer a class method call or field access dereferences. An untyped
    # receiver (`my $p = P->new();`) is a box whose payload is the object pointer, but the callee/field address treats
    # `$self` as the object itself, so the box is unboxed here; a pointer-shaped receiver (`my ptr $p`, `my P $p`,
    # `$self`, a class name) is passed as it stands.
    method _lower_object_ptr( $obj, $line, $col ) {
        my $val = $self->lower_expression($obj);
        if ( $val->type->kind eq 'dynamic' ) {
            $val = $self->maybe_convert_type( $val, Brocken::Lindsay::IR::Type::ptr(), $line, $col, 1 );
        }
        return $val;
    }

    method lower_field_addr($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $obj_ptr     = $self->_lower_object_ptr( $ast->obj, $line, $col );
        my $class_name  = $self->resolve_class_name($ast);
        my $cd          = $classes->{$class_name};
        my $struct_type = $cd->{struct_type};
        my $field_idx;

        # Fields are lexical to the class that declares them, so an outside field access (`$obj->f`) sees only this
        # class's own fields; an inherited field is reached through an inherited accessor.
        for my $fd ( $cd->{own_fields}->@* ) {
            if ( $fd->{name} eq $ast->field ) {
                $field_idx = $fd->{slot_idx};
                last;
            }
        }
        Carp::croak( "Unknown field '" . $ast->field . "' in class '" . $class_name . "' at " . $self->_loc($ast) ) unless defined $field_idx;
        return $builder->build_struct_gep( $struct_type, $obj_ptr, $field_idx, '%' . $ast->field . '.addr', $line, $col );
    }

    method lower_field_access($ast) {
        my $field_ptr  = $self->lower_field_addr($ast);
        my $class_name = $self->resolve_class_name($ast);
        my $cd         = $classes->{$class_name};
        my ($field)    = grep { $_->{name} eq $ast->field } $cd->{own_fields}->@*;

        # A bare array/hash field read yields the element/hash base pointer, as `@arr` does, rather than loading a
        # single scalar out of the storage.
        if ( $field->{kind} eq 'array' ) {
            return $field_ptr if $field->{inline};
            return $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $field_ptr, undef, $ast->line, $ast->col );
        }
        if ( $field->{kind} eq 'hash' ) {
            return $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $field_ptr, undef, $ast->line, $ast->col );
        }
        return $builder->build_load( $field->{ir_type}, $field_ptr, undef, $ast->line, $ast->col );
    }

    method lower_method_call($ast) {
        my $obj_is_class = $ast->obj->isa('Brocken::Katsuro::AST::Expr::Ident');
        my $method       = $ast->method;
        my ( $line, $col ) = ( $ast->line, $ast->col );

        # `$self->SUPER::m(...)` binds to the nearest ancestor strictly above the current class that defines m, which
        # is how a method reaches an overridden parent implementation. Otherwise walk up from the receiver's static
        # class so an inherited method resolves.
        my ( $class_name, $full_name );
        my $super = $method =~ s/^SUPER::// ? 1 : 0;
        if ($super) {
            Carp::croak( 'SUPER:: can only be used inside a class at ' . $self->_loc($ast) ) unless $current_class;
            my $anchor = $classes->{$current_class} ? $classes->{$current_class}{parent} : undef;
            $full_name = $self->_resolve_method( $anchor, $method );
            Carp::croak( "No ancestor of '" . $current_class . "' defines '" . $method . "' at " . $self->_loc($ast) )
                unless $full_name;
        }
        else {
            $class_name = $self->resolve_class_name($ast);

            # `Class->new` is materialised inline below rather than as a named function, so it has nothing to
            # resolve here.
            unless ( $obj_is_class && $method eq 'new' ) {
                $full_name = $self->_resolve_method( $class_name, $method );
                Carp::croak( "Undefined method '" . $method . "' in class '" . $class_name . "' at " . $self->_loc($ast) )
                    unless $full_name;
            }
        }
        my $hb       = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
        my $want_val = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $symbols->{'__want'},      undef, $line, $col );
        if ( $obj_is_class && $method eq 'new' ) {
            my $cd            = $classes->{$class_name};
            my $total_size    = $cd->{total_size};
            my $bump_alloc_fn = $functions->{'Brocken::Runtime::bump_alloc'};
            Carp::croak( "Runtime function bump_alloc not found at " . $self->_loc($ast) ) unless $bump_alloc_fn;
            my $size_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $total_size );
            $self->_emit_fuel_check( $line, $col );
            my $self_ptr     = $builder->build_call( $bump_alloc_fn, [ $hb, $size_const ], undef, $line, $col );

            # The header packs refcount 1, the GC flags, the class-instance tag (4), and the class id in the
            # auxiliary bits. A class with no owned dynamic field against its whole chain is marked Leaf (flag bit
            # 2) so the runtime never buffers it as a cycle suspect. The tag-4 + nonzero-id pair is also what tells
            # `gc_scan_obj` that this is a class instance rather than a boxed `ptr`, whose aux id is 0.
            my $class_id    = $cd->{id} // 0;
            my $has_dynamic = scalar grep { $_->{ir_type} && $_->{ir_type}->kind eq 'dynamic' && !$_->{weak} } $cd->{fields}->@*;
            my $gc_flags    = $has_dynamic ? 0 : 4;
            my $header_val  = 1 | ( $gc_flags << 16 ) | ( 4 << 24 ) | ( $class_id << 32 );
            my $header_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $header_val );
            $builder->build_store( $header_const, $self_ptr, $line, $col );

            # bump_alloc does not zero its memory, so every pointer-shaped array/hash field and every dynamic (`Any`)
            # field is nulled up front. A :param or default below overwrites its slot; one that is left out stays a null
            # pointer rather than a dangling word the object header happened to leave behind. Nulling the dynamic fields
            # is also what makes the owned-store decref (F9) safe: the store always loads the value it displaces, and a
            # fresh slot must read back as null rather than as uninitialised allocator garbage.
            my $null_ptr = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 );
            for my $f ( $cd->{fields}->@* ) {
                next unless $f->{kind} eq 'hash'
                    || ( $f->{kind} eq 'array' && !$f->{inline} )
                    || $f->{ir_type}->kind eq 'dynamic';
                my $slot = $builder->build_struct_gep( $cd->{struct_type}, $self_ptr, $f->{slot_idx}, '%' . $f->{name} . '.null', $line, $col );
                $builder->build_store( $null_ptr, $slot, $line, $col );
            }

            # A field initializer can read the fields assigned before it (`field $y = $x + 1`), so each field's GEP
            # is bound to its name as it is assigned. The bindings are restored at the end so they never leak into
            # the caller's scope (C12). Class context (`$self`, `$current_class`) is established only around the
            # initializers below, so the caller's own expressions are lowered in the caller's class context.
            my @ctor_bindings;
            my %ctor_bound;

            # Constructors take positional values for :param fields in declaration order, followed by an optional
            # Hash of named field overrides: new(1, 2, y => 3).
            my @positional = $ast->args->@*;
            my $hash;
            if ( @positional && $positional[-1]->isa('Brocken::Katsuro::AST::Expr::Hash') ) {
                $hash = pop @positional;
            }
            my %field_idx;
            for my $i ( 0 .. $cd->{fields}->@* - 1 ) {
                $field_idx{ $cd->{fields}[$i]{name} } = $i;
            }
            my @param_fields = grep { $_->{param} } $cd->{fields}->@*;
            Carp::croak( "Too many positional constructor arguments for class '$class_name' at " . $self->_loc($ast) ) if @positional > @param_fields;
            my %seen;
            for my $i ( 0 .. $#positional ) {
                my $fd  = $param_fields[$i];
                my $val = $self->lower_expression( $positional[$i] );
                $val = $self->maybe_convert_type( $val, $fd->{ir_type} );
                my $field_ptr
                    = $builder->build_struct_gep( $cd->{struct_type}, $self_ptr, $fd->{slot_idx}, '%' . $fd->{name} . '.init', $line, $col );
                if ( $fd->{ir_type}->kind eq 'dynamic' && !$fd->{weak} ) {
                    $self->_emit_owned_store( $val, $field_ptr, $fd->{ir_type}, $line, $col );
                }
                else {
                    $builder->build_store( $val, $field_ptr, $line, $col );
                }
                $seen{ $fd->{name} } = 1;
                if ( !$ctor_bound{ $fd->{name} } ) {
                    push @ctor_bindings, [ $fd->{name}, $symbols->{ $fd->{name} } ];
                    $symbols->{ $fd->{name} } = $field_ptr;
                    $ctor_bound{ $fd->{name} } = 1;
                }
            }
            for my $pair ( $hash ? $hash->pairs->@* : () ) {
                my $key_expr = $pair->{key};
                next unless $key_expr->isa('Brocken::Katsuro::AST::Expr::Const') && $key_expr->type eq 'String';
                my $key = $key_expr->value;
                my $fi  = $field_idx{$key};

                # A :param field with a custom (or underscore-stripped) name is addressed by that name:
                # `field $_total :param(total);` is set by `new(total => 42)`.
                if ( !defined $fi ) {
                    for my $f ( $cd->{fields}->@* ) {
                        if ( defined $f->{param_name} && $f->{param_name} eq $key ) { $fi = $f->{chain_idx}; last; }
                    }
                }
                Carp::croak( "Unknown field '$key' in class '$class_name' at " . $self->_loc($ast) ) unless defined $fi;
                my $fd  = $cd->{fields}[$fi];
                my $val = $self->lower_expression( $pair->{value} );
                $val = $self->maybe_convert_type( $val, $fd->{ir_type} );
                my $field_ptr
                    = $builder->build_struct_gep( $cd->{struct_type}, $self_ptr, $fd->{slot_idx}, '%' . $fd->{name} . '.init', $line, $col );
                if ( $fd->{ir_type}->kind eq 'dynamic' && !$fd->{weak} ) {
                    $self->_emit_owned_store( $val, $field_ptr, $fd->{ir_type}, $line, $col );
                }
                else {
                    $builder->build_store( $val, $field_ptr, $line, $col );
                }
                $seen{ $fd->{name} } = 1;

                if ( !$ctor_bound{ $fd->{name} } ) {
                    push @ctor_bindings, [ $fd->{name}, $symbols->{ $fd->{name} } ];
                    $symbols->{ $fd->{name} } = $field_ptr;
                    $ctor_bound{ $fd->{name} } = 1;
                }
            }

            # The field initializers are the only class-context expressions, so establish it now: bind `$self`
            # and set `$current_class` so `__CLASS__` and `$self->method` resolve. All earlier fields are bound.
            my $saved_class = $current_class;
            $current_class = $class_name;
            push @ctor_bindings, [ 'self', $symbols->{self} ];
            my $self_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::ptr(), '%self.addr' );
            $builder->build_store( $self_ptr, $self_alloca, $line, $col );
            $symbols->{self} = $self_alloca;
            $ctor_bound{self} = 1;

            for my $f ( $cd->{fields}->@* ) {
                next unless defined $f->{default};
                my $op     = $f->{default_op} // '=';
                my $is_set = $seen{ $f->{name} };

                # `=` and `//=` apply only to a field the caller left unset; `||=` also rewrites a
                # supplied-but-false value.
                next if $is_set && $op ne '||=';
                my $field_ptr
                    = $builder->build_struct_gep( $cd->{struct_type}, $self_ptr, $f->{slot_idx}, '%' . $f->{name} . '.default', $line, $col );
                if ( $op eq '||=' && $is_set ) {

                    # `||=` applies when the value supplied for the field is false, not merely
                    # absent: keep the caller's value only when it is truthy. A dynamic field is
                    # RC-tracked, so replacing it is a conditional owned store (F2); a native field
                    # has no references to move and keeps the branchless select.
                    my $default_val = $self->lower_expression( $f->{default} );
                    $default_val = $self->maybe_convert_type( $default_val, $f->{ir_type} );
                    if ( $f->{ir_type}->kind eq 'dynamic' && !$f->{weak} ) {
                        $self->_emit_conditional_owned_store( $default_val, $field_ptr, $f->{ir_type}, $line, $col );
                    }
                    else {
                        my $existing = $builder->build_load( $f->{ir_type}, $field_ptr, undef, $line, $col );
                        my $zero     = Brocken::Lindsay::IR::Constant->new( type => $f->{ir_type}, value => 0 );
                        my $is_false = $builder->build_icmp( 'eq', $existing, $zero, undef, $line, $col );
                        my $new_val  = $builder->build_select( $is_false, $default_val, $existing, undef, $line, $col );
                        $builder->build_store( $new_val, $field_ptr, $line, $col );
                    }
                    next;
                }
                my $default_val = $self->lower_expression( $f->{default} );
                $default_val = $self->maybe_convert_type( $default_val, $f->{ir_type} );
                if ( $f->{ir_type}->kind eq 'dynamic' && !$f->{weak} ) {
                    $self->_emit_owned_store( $default_val, $field_ptr, $f->{ir_type}, $line, $col );
                }
                else {
                    $builder->build_store( $default_val, $field_ptr, $line, $col );
                }
                if ( !$ctor_bound{ $f->{name} } ) {
                    push @ctor_bindings, [ $f->{name}, $symbols->{ $f->{name} } ];
                    $symbols->{ $f->{name} } = $field_ptr;
                    $ctor_bound{ $f->{name} } = 1;
                }
            }
            # Run ADJUST root-first so a parent's validation runs before the child's, matching the order the object
            # was initialized in.
            for my $ancestor ( $self->_ancestors($class_name) ) {
                my $adjust_fn = $functions->{ $ancestor . '::ADJUST' };
                next unless $adjust_fn;
                $builder->build_call( $adjust_fn, [ $hb, $want_val, $self_ptr ], undef, $line, $col );
            }
            $current_class = $saved_class;
            $symbols->{ $_->[0] } = $_->[1] for @ctor_bindings;
            return $self_ptr;
        }
        my $callee = $functions->{$full_name};
        Carp::croak( "Undefined method '" . $method . "' in class '" . $class_name . "' at " . $self->_loc($ast) ) unless $callee;
        my $obj_ptr = $obj_is_class ? Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 ) :
            $self->_lower_object_ptr( $ast->obj, $line, $col );
        my @args      = ( $hb, $want_val, $obj_ptr );
        my $param_idx = 3;
        my $defaults  = $param_defaults->{$full_name};

        # Arity, as for plain calls: a method's hidden `%__heap_base`, `%__want`, and `$self` are not user arguments, so
        # the user parameters are everything past the first three.
        my $method_user_params = $callee->params->@* - 3;
        if ( $ast->args->@* > $method_user_params ) {
            Carp::croak( "Too many arguments to '$method': $method_user_params expected, got " . $ast->args->@* . " at "
                    . $self->_loc($ast) );
        }

        # Same omitted-argument handling as plain calls: defaults fill the trailing parameters in order, and a default
        # may reference an earlier one because each landed value is bound to its parameter name until the call is done.
        my @saved;
        for my $arg ( $ast->args->@* ) {
            my $val = $self->lower_expression($arg);
            if ( $param_idx < $callee->params->@* ) {
                $val = $self->maybe_convert_type( $val, $callee->params->[$param_idx]->type );
            }
            push @args, $val;
            if ($defaults) {
                my $rec = $param_idx - 3 < $defaults->@* ? $defaults->[ $param_idx - 3 ] : undef;
                if ($rec) {
                    push @saved, [ $rec->{name}, $symbols->{ $rec->{name} } ];
                    $symbols->{ $rec->{name} } = $val;
                }
            }
            $param_idx++;
        }
        if ($defaults) {
            while ( $param_idx < $callee->params->@* ) {
                my $rec = $param_idx - 3 < $defaults->@* ? $defaults->[ $param_idx - 3 ] : undef;
                last unless $rec && defined $rec->{default};
                my $val = $self->lower_expression( $rec->{default} );
                $val = $self->maybe_convert_type( $val, $callee->params->[$param_idx]->type );
                push @args,  $val;
                push @saved, [ $rec->{name}, $symbols->{ $rec->{name} } ];
                $symbols->{ $rec->{name} } = $val;
                $param_idx++;
            }
        }
        if ( $param_idx < $callee->params->@* ) {
            my $missing = $param_idx - 3 + 1;    # 1-based index of the first unfilled user parameter
            Carp::croak("Missing required argument $missing of '$method' (its parameter has no default) at "
                    . $self->_loc($ast) );
        }
        $symbols->{ $_->[0] } = $_->[1] for @saved;
        $self->_emit_fuel_check( $line, $col );
        return $builder->build_call( $callee, \@args, undef, $line, $col );
    }

    method lower_ternary($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $cond = $self->as_condition( $self->lower_expression( $ast->cond ), $line, $col );
        my $then = $self->lower_expression( $ast->then );
        my $else = $self->lower_expression( $ast->else );
        $then = $self->maybe_convert_type( $then, $else->type ) unless $then->type eq $else->type;
        $else = $self->maybe_convert_type( $else, $then->type ) unless $else->type eq $then->type;
        return $builder->build_select( $cond, $then, $else, undef, $line, $col );
    }

    method lower_want($ast) {
        my $context = $ast->context;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        if ( $context eq 'scalar' || $context eq 'list' || $context eq 'void' ) {
            my $rt_fn_name = 'Brocken::Runtime::want_is_' . $context;
            my $rt_fn      = $functions->{$rt_fn_name};
            Carp::croak( "Runtime function '$rt_fn_name' not found at " . $self->_loc($ast) ) unless $rt_fn;
            my $want_val = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $symbols->{'__want'}, undef, $line, $col );
            return $builder->build_call( $rt_fn, [$want_val], undef, $line, $col );
        }
        my $return_type_name = $current_func->return_type->kind ne 'void' ? $current_func->return_type->as_string() : 'void';
        if ( $context eq $return_type_name ) {
            return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
        }
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0 );
    }

    method lower_list_expr($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $i64_type     = Brocken::Lindsay::IR::Type::i64();
        my $ptr_type     = Brocken::Lindsay::IR::Type::ptr();
        my $dynamic_type = Brocken::Lindsay::IR::Type::dynamic();

        # A list slot is one untagged eight-byte cell, and the reader (`lower_list_var_decl`) has no way to know what it
        # was written as. So a
        # slot cannot hold a float: the bits of 1.5 read back as an integer are 4607182418800017408, not 1.5. Every
        # element is boxed on the way in, which puts the tag next to the payload and lets the reader convert the box
        # into whatever the target declared.
        #
        # This is also the representation the rest of the runtime already assumes. `gc_scan_list` reads each slot and
        # treats it as a pointer when it looks like one, and the reader already increfs an `Any` target on the
        # assumption that the slot holds a box.
        #
        # An element that is already untyped is stored as it stands rather than boxed again, so `my ($a, $b) = ($x, $x)`
        # puts the one box each slot can hold rather than a box around a pointer to a box. That stops the second box,
        # not the second problem: the slot does not take a reference of its own, so a box built in the function that
        # builds the list is released when that function returns. That is separate from the slot representation and is
        # listed under Known Bugs in TODO.md.
        my @elements;
        for my $elem ( $ast->elements->@* ) {
            my $val = $self->lower_expression($elem);
            if ( $val->type->kind eq 'dynamic' ) {
                $builder->build_incref( $val, $line, $col );
                push @elements, $val;
            }
            else {
                my $boxed = $self->maybe_convert_type( $val, $dynamic_type, $line, $col );
                push @elements, $boxed;
            }
        }
        my $count         = scalar @elements;
        my $hb            = $builder->build_load( $ptr_type, $symbols->{'__heap_base'}, undef, $line, $col );
        my $total_size    = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 16 + $count * 8 );
        my $bump_alloc_fn = $functions->{'Brocken::Runtime::bump_alloc'};
        Carp::croak( "Runtime function bump_alloc not found at " . $self->_loc($ast) ) unless $bump_alloc_fn;
        my $list_ptr   = $builder->build_call( $bump_alloc_fn, [ $hb, $total_size ], undef, $line, $col );
        my $header_val = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 7 << 24 );
        $builder->build_store( $header_val, $list_ptr, $line, $col );
        my $count_val  = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => $count );
        my $count_addr = $builder->build_add( $list_ptr, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 8 ), undef, $line, $col );
        $builder->build_store( $count_val, $count_addr, $line, $col );

        for my $i ( 0 .. $#elements ) {
            my $offset    = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 16 + $i * 8 );
            my $elem_addr = $builder->build_add( $list_ptr, $offset, undef, $line, $col );
            $builder->build_store( $elements[$i], $elem_addr, $line, $col );
        }
        return $list_ptr;
    }

    method lower_hash_expr($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $hb        = $self->_hash_heap_base( $line, $col );
        my $hash_new  = $self->_reflect_runtime( 'hash_new', $ast, $line, $col );
        my $hash_set  = $self->_reflect_runtime( 'hash_set', $ast, $line, $col );
        my $hash_ptr  = $builder->build_call( $hash_new, [ $hb ], undef, $line, $col );
        my $dyn_type  = Brocken::Lindsay::IR::Type::dynamic();
        for my $pair ( $ast->pairs->@* ) {
            my $key = $self->_lower_hash_key( $pair->{key}, $line, $col );
            my $raw = $self->lower_expression( $pair->{value} );
            my $val = $self->maybe_convert_type( $raw, $dyn_type, $line, $col );

            # The table takes ownership of one reference to each value. A borrowed box needs a fresh reference; an
            # owned call result already carries one and is consumed. A freshly boxed native has refcount 0, so it
            # needs the reference too.
            $builder->build_incref( $val, $line, $col ) unless $self->_owned_call_result($raw);
            $hash_ptr = $builder->build_call( $hash_set, [ $hb, $hash_ptr, $key, $val ], undef, $line, $col );
        }
        return $hash_ptr;
    }

    # `__CLASS__` evaluates to the current class's name as a string. It used to lower to a `ptr` *constant* whose value
    # was the class name, but a constant's value is numified by the encoder, so the string `Point` became the address 0
    # -- a null pointer rather than a usable class name. Lower it exactly like a string literal instead: a
    # NUL-terminated rodata blob holding the qualified class name, which is the value `perlclass` gives and what
    # `say(__CLASS__)` prints.
    method lower_class_const($ast) {
        Carp::croak( '__CLASS__ used outside of a class at ' . $self->_loc($ast) ) unless $current_class;
        my ( $label, $bytes ) = $self->_intern_rodata( $current_class . "\0" );
        return Brocken::Lindsay::IR::RodataRef->new(
            label => $label,
            bytes => $bytes,
            type  => Brocken::Lindsay::IR::Type::ptr(),
        );
    }

    # Method body lowering with field GEP pre-population
    method lower_method( $class_name, $method_ast ) {
        my $full_name = $class_name . '::' . $method_ast->name;
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $symbols  = {};
        $needs_rc = {};
        $rc_owner = {};
        $borrowed_params = {};
        $class_owned   = {};
        $class_escaped = {};
        $weak_var      = {};
        $array_owned_elem = {};
        $hash_var        = {};
        $hash_value_type = {};
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;

        # %__heap_base is the first param (ptr) at index 0
        {
            my $heap_base_param  = $current_func->params->[0];
            my $heap_base_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::ptr(), '%__heap_base.addr' );
            $builder->build_store( $heap_base_param, $heap_base_alloca );
            $symbols->{'__heap_base'} = $heap_base_alloca;
        }

        # %__want is the second param (i64) at index 1
        {
            my $want_param  = $current_func->params->[1];
            my $want_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%__want.addr' );
            $builder->build_store( $want_param, $want_alloca );
            $symbols->{'__want'} = $want_alloca;
        }

        # $self is the third param (ptr) at index 2
        my $self_val = $current_func->params->[2];
        $symbols->{self} = $self_val;

        # Pre-populate symbol table with field GEPs for direct field name access
        $self->populate_field_geps( $class_name, $self_val );

        # Lower explicit method params (params start at index 3)
        for my $i ( 0 .. $method_ast->params->@* - 1 ) {
            my $p      = $current_func->params->[ $i + 3 ];
            my $pname  = $method_ast->params->[$i]{name};
            my $ptype  = $method_ast->params->[$i]{type} // 'Any';
            my $alloca = $builder->build_alloca( $p->type, '%' . $pname . '.addr', undef, 0, 0, $pname, $ptype );
            $builder->build_store( $p, $alloca );
            $symbols->{$pname} = $alloca;
            if ( $ptype eq 'Any' ) {
                # Caller-Borrows: an Any argument is not incref'd by the caller, so the callee must not decref it on
                # exit. Track it as borrowed, not owned; a store into the slot (or an escape) takes its own reference.
                $borrowed_params->{$pname} = 1;
            }
        }
        $self->_scan_escapes( $method_ast->body );
        $self->lower_block_body( $method_ast->body );
        unless ( $current_block && $current_block->terminator ) {
            my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
            for my $name ( sort keys %$needs_rc ) {
                $self->_emit_rc_release( $name, $decref_hb );
            }
            if ( $current_func->return_type->kind eq 'void' ) {
                $builder->build_ret();
            }
            else {
                my $zero = Brocken::Lindsay::IR::Constant->new( type => $current_func->return_type, value => 0 );
                $builder->build_ret($zero);
            }
        }
    }

    method lower_adjust( $class_name, $adjust_asts ) {
        my $full_name = $class_name . '::ADJUST';
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $symbols  = {};
        $needs_rc = {};
        $rc_owner = {};
        $borrowed_params = {};
        $class_owned   = {};
        $class_escaped = {};
        $weak_var      = {};
        $array_owned_elem = {};
        $hash_var        = {};
        $hash_value_type = {};
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;

        # %__heap_base is the first param (ptr) at index 0
        {
            my $heap_base_param  = $current_func->params->[0];
            my $heap_base_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::ptr(), '%__heap_base.addr' );
            $builder->build_store( $heap_base_param, $heap_base_alloca );
            $symbols->{'__heap_base'} = $heap_base_alloca;
        }

        # %__want is the second param (i64) at index 1
        {
            my $want_param  = $current_func->params->[1];
            my $want_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%__want.addr' );
            $builder->build_store( $want_param, $want_alloca );
            $symbols->{'__want'} = $want_alloca;
        }

        # $self is the third param (ptr) at index 2
        my $self_val = $current_func->params->[2];
        $symbols->{self} = $self_val;
        $self->populate_field_geps( $class_name, $self_val );
        for my $adjust_ast ( $adjust_asts->@* ) {
            $self->_scan_escapes( $adjust_ast->body );
            $self->lower_block_body( $adjust_ast->body );
        }
        unless ( $current_block && $current_block->terminator ) {
            my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
            for my $name ( sort keys %$needs_rc ) {
                $self->_emit_rc_release( $name, $decref_hb );
            }
            $builder->build_ret();
        }
    }

    # Generate Class::DESTROY. The body runs this class's own user DESTROY blocks in declaration order, then chains
    # to the nearest ancestor that defines DESTROY, so teardown runs derived-to-root. A parent runtime is generated
    # before its child, so an ancestor's Class::DESTROY is already registered when this runs. Managed-field teardown
    # joins here once class-typed fields take ownership (TODO F9); until then a field does not own its referent and
    # releasing it here would double-free.
    method lower_destroy( $class_name, $destroy_asts ) {
        my $full_name = $class_name . '::DESTROY';
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $symbols  = {};
        $needs_rc = {};
        $rc_owner = {};
        $borrowed_params = {};
        $class_owned   = {};
        $class_escaped = {};
        $weak_var      = {};
        $array_owned_elem = {};
        $hash_var        = {};
        $hash_value_type = {};
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;

        # %__heap_base is the first param (ptr) at index 0
        {
            my $heap_base_param  = $current_func->params->[0];
            my $heap_base_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::ptr(), '%__heap_base.addr' );
            $builder->build_store( $heap_base_param, $heap_base_alloca );
            $symbols->{'__heap_base'} = $heap_base_alloca;
        }

        # %__want is the second param (i64) at index 1
        {
            my $want_param  = $current_func->params->[1];
            my $want_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%__want.addr' );
            $builder->build_store( $want_param, $want_alloca );
            $symbols->{'__want'} = $want_alloca;
        }

        # $self is the third param (ptr) at index 2
        my $self_val = $current_func->params->[2];
        $symbols->{self} = $self_val;
        $self->populate_field_geps( $class_name, $self_val );
        for my $destroy_ast ( $destroy_asts->@* ) {
            $self->_scan_escapes( $destroy_ast->body );
            $self->lower_block_body( $destroy_ast->body );
        }

        # Chain to the nearest ancestor DESTROY, strictly above this class.
        unless ( $current_block && $current_block->terminator ) {
            my $cd       = $classes->{$class_name};
            my $ancestor = $cd ? $self->_resolve_method( $cd->{parent}, 'DESTROY' ) : undef;
            if ( $ancestor && $functions->{$ancestor} ) {
                my $hb   = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
                my $want = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $symbols->{'__want'} );
                $builder->build_call( $functions->{$ancestor}, [ $hb, $want, $self_val ], undef );
            }
        }

        unless ( $current_block && $current_block->terminator ) {
            my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
            for my $name ( sort keys %$needs_rc ) {
                $self->_emit_rc_release( $name, $decref_hb );
            }
            $builder->build_ret();
        }
    }

    # The reclaim thunk (`Class::__destroy`): run the chained DESTROY, release the managed fields this class owns, and
    # free the instance. A compiled release site calls it exactly when the header refcount reaches zero, so the
    # refcount -- not method dispatch -- is what guarantees it runs once. It is split from DESTROY because DESTROY is
    # an ordinary method a user may call repeatedly, while the reclaim must run exactly once.
    method lower_class_destroy($class_name) {
        my $full_name = $class_name . '::__destroy';
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $symbols  = {};
        $needs_rc = {};
        $rc_owner = {};
        $borrowed_params = {};
        $class_owned   = {};
        $class_escaped = {};
        $weak_var      = {};
        $array_owned_elem = {};
        $hash_var        = {};
        $hash_value_type = {};
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;

        # %__heap_base is the first param (ptr) at index 0
        {
            my $heap_base_param  = $current_func->params->[0];
            my $heap_base_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::ptr(), '%__heap_base.addr' );
            $builder->build_store( $heap_base_param, $heap_base_alloca );
            $symbols->{'__heap_base'} = $heap_base_alloca;
        }

        # %__want is the second param (i64) at index 1
        {
            my $want_param  = $current_func->params->[1];
            my $want_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::i64(), '%__want.addr' );
            $builder->build_store( $want_param, $want_alloca );
            $symbols->{'__want'} = $want_alloca;
        }

        # $self is the third param (ptr) at index 2
        my $self_val = $current_func->params->[2];
        $symbols->{self} = $self_val;

        my $hb   = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
        my $want = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $symbols->{'__want'} );

        # User DESTROY first, before any managed field is released (spec 8.1).
        my $destroy = $self->_resolve_method( $class_name, 'DESTROY' );
        if ( $destroy && $functions->{$destroy} ) {
            $builder->build_call( $functions->{$destroy}, [ $hb, $want, $self_val ], undef );
        }

        # Cascade: each owned dynamic field loses the reference it holds. A pointer-typed field (String, array, hash,
        # or a raw ptr) is not RC-tracked, so it has nothing to release here.
        my $cd = $classes->{$class_name};
        if ($cd) {
            my $struct_type = $cd->{struct_type};
            for my $fd ( $cd->{fields}->@* ) {
                next unless $fd->{ir_type} && $fd->{ir_type}->kind eq 'dynamic' && !$fd->{weak};
                my $fptr = $builder->build_struct_gep( $struct_type, $self_val, $fd->{slot_idx}, '%' . $fd->{name} . '.daddr' );
                my $fval = $builder->build_load( $fd->{ir_type}, $fptr );
                $builder->build_decref( $fval, 0, 0, $hb );
            }
        }

        # Reclaim the instance itself now that its fields are gone.
        my $free = $functions->{'Brocken::Runtime::free_obj'};
        if ($free) {
            $builder->build_call( $free, [ $self_val, $hb ], undef );
        }
        $builder->build_ret();
    }

    # Register a runtime-shaped function: explicit parameters and no hidden __heap_base/__want, so the runtime and
    # the generated id dispatch can call it positionally like any other Brocken::Runtime function.
    method _register_plain_function( $name, $return_type_name, $param_names ) {
        my @params = map { Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%' . $_ ) } @$param_names;
        my $fn = Brocken::Lindsay::IR::Function->new(
            name        => $name,
            return_type => $self->type_from_name($return_type_name),
            params      => \@params,
        );
        $module->add_function($fn);
        $functions->{$name} = $fn;
        return $fn;
    }

    # Generate `Class::__scan` (MarkGray: drop one reference to each owned dynamic field) and `Class::__restore`
    # (Undo: take it back). These mirror the field cascade in `Class::__destroy`, but are entered from the runtime's
    # id dispatch rather than from a compiled release site. A class with no owned dynamic field against its whole
    # ancestor chain still gets both methods; they are empty, and the constructor marks such an instance Leaf so
    # the collector never buffers it.
    method generate_class_gc($class_name) {
        my $cd = $classes->{$class_name};
        return unless $cd;
        my $gc_decref = $functions->{'Brocken::Runtime::gc_decref'};
        my $incref    = $functions->{'Brocken::Runtime::incref'};
        return unless $gc_decref && $incref;

        my $scan    = $self->_register_plain_function( $class_name . '::__scan',    'void', [ 'self', 'hb' ] );
        my $restore = $self->_register_plain_function( $class_name . '::__restore', 'void', ['self'] );
        $self->_lower_gc_method( $class_name, $scan,    $gc_decref, 'scan' );
        $self->_lower_gc_method( $class_name, $restore, $incref,    'restore' );
    }

    # Walk the whole ancestor chain's fields and call `$callee` on each owned dynamic one. `scan` passes the heap
    # base so a field whose count drops to zero is reclaimed; `restore` calls incref, which needs only the box.
    method _lower_gc_method( $class_name, $fn, $callee, $kind ) {
        $current_func  = $fn;
        $symbols       = {};
        $current_block = undef;
        $fn->set_blocks( [] );
        my $entry = $fn->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $self_val = $fn->params->[0];
        my $hb       = $kind eq 'scan' ? $fn->params->[1] : undef;
        my $cd       = $classes->{$class_name};
        for my $fd ( $cd->{fields}->@* ) {
            next unless $fd->{ir_type} && $fd->{ir_type}->kind eq 'dynamic' && !$fd->{weak};
            my $fptr = $builder->build_struct_gep( $cd->{struct_type}, $self_val, $fd->{slot_idx}, '%' . $fd->{name} . '.' . $kind );
            my $fval = $builder->build_load( $fd->{ir_type}, $fptr );
            my @args = $kind eq 'scan' ? ( $fval, $hb ) : ($fval);
            $builder->build_call( $callee, \@args, undef );
        }
        $builder->build_ret();
    }

    # Emit `Brocken::Runtime::gc_scan_class` and `gc_restore_class`: a direct-call switch over the class id in the
    # header, calling each class's `__scan`/`__restore`. They are always emitted, even for a class-less program, so
    # the runtime's `gc_scan_obj`/`gc_restore_refs` always resolve.
    method generate_gc_dispatch() {
        $self->_lower_gc_dispatch( 'Brocken::Runtime::gc_scan_class',    'scan' );
        $self->_lower_gc_dispatch( 'Brocken::Runtime::gc_restore_class', 'restore' );
    }

    method _lower_gc_dispatch( $name, $kind ) {
        my $restore = $kind eq 'restore';
        my $fn      = $self->_register_plain_function( $name, 'void', $restore ? ['obj'] : [ 'obj', 'hb' ] );
        $current_func  = $fn;
        $symbols       = {};
        $current_block = undef;
        $fn->set_blocks( [] );
        my $entry = $fn->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $ret_block = $fn->append_block('ret');

        my @classes = sort { $classes->{$a}{id} <=> $classes->{$b}{id} } grep { $classes->{$_}{id} } keys %$classes;
        if (@classes) {
            my $obj    = $fn->params->[0];
            my $hb     = $restore ? undef : $fn->params->[1];
            my $header = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $obj );
            my $id     = $builder->build_lshr( $header, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 32 ) );
            my $test_block = $entry;
            for my $class_name (@classes) {
                my $cid    = $classes->{$class_name}{id};
                my $target = $functions->{ $class_name . ( $restore ? '::__restore' : '::__scan' ) };
                next unless $target;
                my $match = $fn->append_block( $kind . '_match_' . $cid );
                my $next  = $fn->append_block( $kind . '_next_' . $cid );
                $builder->position_at_end($test_block);
                my $cond = $builder->build_icmp( 'eq', $id, Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $cid ) );
                $builder->build_cond_br( $cond, $match, $next );
                $builder->position_at_end($match);
                my @args = $restore ? ($obj) : ( $obj, $hb );
                $builder->build_call( $target, \@args, undef );
                $builder->build_br($ret_block);
                $test_block = $next;
            }
            $builder->position_at_end($test_block);
            $builder->build_br($ret_block);
        }
        $builder->position_at_end($ret_block);
        $builder->build_ret();
        return;
    }

    # Bind a symbol for each field this class *declares*, so a method body can name it bare. An inherited field is
    # not bound: fields are lexical to the class that declares them (an inherited method sees its own class's fields
    # because it was lowered against that class, whose slot offsets are a prefix of ours).
    method populate_field_geps( $class_name, $self_val ) {
        my $cd = $classes->{$class_name};
        return unless $cd;
        my $struct_type = $cd->{struct_type};
        for my $fd ( $cd->{own_fields}->@* ) {
            my $field_ptr = $builder->build_struct_gep( $struct_type, $self_val, $fd->{slot_idx}, '%' . $fd->{name} . '.addr' );

            # An array field is addressed by its element base. Inline storage already sits at that GEP, while a
            # pointer array's GEP points at the slot holding the base, so `@name` must dereference it. A hash field
            # is an opaque pointer slot and answers to `%name`.
            if ( $fd->{kind} eq 'array' ) {
                $symbols->{ '@' . $fd->{name} } = $field_ptr;
            }
            elsif ( $fd->{kind} eq 'hash' ) {
                $symbols->{ '%' . $fd->{name} } = $field_ptr;
            }
            else {
                $symbols->{ $fd->{name} } = $field_ptr;
            }
        }
    }

    # If `$name` names an array field of `$class_name`, return its record; otherwise undef. The symbol for a field
    # array is always a struct GEP, which is how a field array is told apart from a local `@name` (an alloca).
    method field_array_record( $class_name, $name ) {
        my $cd = $class_name ? $classes->{$class_name} : undef;
        return undef unless $cd;
        my ($fd) = grep { $_->{name} eq $name && $_->{kind} eq 'array' } $cd->{own_fields}->@*;
        return $fd;
    }

    # Auto-generated accessor and constructor lowering
    method generate_reader( $class_name, $field_ast, $mname ) {
        my $full_name = $class_name . '::' . $mname;
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $self_val    = $current_func->params->[2];
        my $cd          = $classes->{$class_name};
        my $struct_type = $cd->{struct_type};
        my ($fd)        = grep { $_->{name} eq $field_ast->name } $cd->{own_fields}->@*;
        my $field_ptr   = $builder->build_struct_gep( $struct_type, $self_val, $fd->{slot_idx}, '%' . $fd->{name} . '.addr' );

        # A scalar field loads its value. An array/hash reader hands back a pointer: the element base for an inline
        # array (the GEP itself), or the pointer held in the slot for a pointer array or a hash.
        my $loaded;
        if ( $fd->{kind} eq 'array' ) {
            $loaded = $fd->{inline} ? $field_ptr : $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $field_ptr );
        }
        elsif ( $fd->{kind} eq 'hash' ) {
            $loaded = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $field_ptr );
        }
        else {
            $loaded = $builder->build_load( $fd->{ir_type}, $field_ptr );
        }
        $builder->build_ret($loaded);
    }

    method generate_writer( $class_name, $field_ast, $mname ) {
        my $full_name = $class_name . '::' . $mname;
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $self_val    = $current_func->params->[2];
        my $value_val   = $current_func->params->[3];
        my $cd          = $classes->{$class_name};
        my $struct_type = $cd->{struct_type};
        my ($fd)        = grep { $_->{name} eq $field_ast->name } $cd->{own_fields}->@*;
        my $field_ptr   = $builder->build_struct_gep( $struct_type, $self_val, $fd->{slot_idx}, '%' . $fd->{name} . '.addr' );
        if ( $fd->{ir_type}->kind eq 'dynamic' && !$fd->{weak} ) {

            # The writer takes the caller's value (borrowed) and must own a reference of its own in the field. The
            # accessor has no `__heap_base` symbol, so hand it its own hidden parameter for the decref. A `:weak`
            # field stores the pointer without taking ownership, so it uses the plain store below.
            $self->_emit_owned_store( $value_val, $field_ptr, $fd->{ir_type}, 0, 0, $current_func->params->[0] );
        }
        else {
            $builder->build_store( $value_val, $field_ptr );
        }
        $builder->build_ret($self_val);
    }
};
#
1;
