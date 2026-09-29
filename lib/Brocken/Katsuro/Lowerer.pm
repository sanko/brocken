use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
use Carp ();

class Brocken::Katsuro::Lowerer {
    field $module : param = Brocken::Lindsay::IR::Module->new( name => 'main' );
    field $builder = Brocken::Lindsay::IR::Builder->new();
    field $current_func;
    field $current_block;
    field $current_class;                 # class name when inside a method/ADJUST
    field $symbols               = {};    # "name" -> ptr (alloca or GEP result)
    field $functions             = {};    # "name" -> Brocken::Lindsay::IR::Function
    field $classes               = {};    # "ClassName" -> {fields=>[...], total_size=>N, methods=>[...], adjust=>undef}
    field $block_id              = 0;
    field $var_class             = {};    # var_name -> class_name (for ptr vars from constructors)
    field $function_return_class = {};    # func_name -> class_name (for functions returning a class ptr)
    field $param_class           = {};    # func_name -> { param_name -> class_name } (for class-typed params)

    method unique_block_name($prefix) {
        return $prefix . '_' . $block_id++;
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
        Bool   => Brocken::Lindsay::IR::Type::i1(),
        Any    => Brocken::Lindsay::IR::Type::dynamic(),
        String => Brocken::Lindsay::IR::Type::ptr(),
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
        void   => Brocken::Lindsay::IR::Type::void(),
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

    method native_type_from_name($name) {
        return $TYPE_NATIVE_MAP{$name} // $self->type_from_name($name);
    }

    # Type size in bytes for field offset calculation
    method type_size($ir_type) {
        return 0                  if $ir_type->kind eq 'void';
        return 8                  if $ir_type->kind eq 'ptr' || $ir_type->kind eq 'dynamic';
        return $ir_type->bits / 8 if $ir_type->kind eq 'int' || $ir_type->kind eq 'float';
        return 8;
    }

    # Field alignment in bytes, C-style. Scalar fields sit at a multiple of
    # their own size, so a `struct { int8_t a; int16_t b; }` puts b at 2
    # rather than 1 and lines up with what a C compiler produces, which is
    # what makes a Brocken class usable behind a C declaration.
    #
    # Capped at 8 so an i128 aligns like the pointer-sized box it is really
    # stored in.
    #
    # The override is `:pack(N)`, and it replaces the natural alignment
    # outright rather than combining with it, so it can pull a field in
    # (`field i16 $b :pack` lands it at the next byte) or push one out
    # (`field i8 $a :pack(16)`). Taking a minimum or a maximum instead would
    # make one of those a no-op.
    method type_align( $ir_type, $override = undef ) {
        return $override if $override;
        my $size = $self->type_size($ir_type);
        return 1 if !$size;
        return $size > 8 ? 8 : $size;
    }

    method align_up( $offset, $align ) {
        return $offset if $align <= 1;
        my $rem = $offset % $align;
        return $rem ? $offset + ( $align - $rem ) : $offset;
    }

    # Main entry point
    method lower_program($ast) {
        my @all_stmts = $ast->statements->@*;
        my @decls;
        my @top_stmts;
        for my $stmt (@all_stmts) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ClassDecl') || $stmt->isa('Brocken::Katsuro::AST::Stmt::SubDecl') ) {
                push @decls, $stmt;
            }
            else {
                push @top_stmts, $stmt;
            }
        }
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

        # Pass 2: Generate class runtimes first so auto-generated methods
        # (constructor, reader, writer) register in $functions before
        # any function body tries to call them.
        for my $stmt (@decls) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ClassDecl') ) {
                $self->generate_class_runtime($stmt);
            }
        }

        # Pass 3: Lower sub and method bodies
        for my $stmt (@decls) {
            if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::SubDecl') ) {
                $self->lower_function($stmt);
            }
        }
        return $module;
    }

    # Register every method a class can have before lowering any of them.
    #
    # A method body may call any method on its class, including the readers,
    # writers and constructor that are generated here rather than declared in
    # the source, and lower_method resolves a callee by looking it up in
    # $functions. A method whose callee is not yet registered cannot see it, so
    # registering the whole class first and lowering second lets a body reach
    # every method of its own class regardless of the order bodies are lowered
    # in.
    method generate_class_runtime($ast) {
        my $class_name = $ast->name;
        $current_class = $class_name;
        my $has_adjust = defined $ast->adjust;

        # A generated accessor must not displace a method the source declared
        # under the same name. The declared method is the one a caller means,
        # and letting a later registration overwrite $functions would leave
        # two functions of one name in the module and silently retarget calls.
        my %declared = map { $_->name => 1 } $ast->methods->@*;
        $declared{'ADJUST'} = 1 if $has_adjust;
        my @readers = grep {
            grep { $_ eq 'reader' }
                $_->attrs->@*
        } grep { !$declared{ $_->name } } $ast->fields->@*;
        my @writers = grep {
            grep { $_ eq 'writer' }
                $_->attrs->@*
        } grep { !$declared{ 'set_' . $_->name } } $ast->fields->@*;
        my @param_fields = grep {
            grep { $_ eq 'param' }
                $_->attrs->@*
        } $ast->fields->@*;

        # Pass 1: register signatures for everything on the class.
        if ($has_adjust) {
            $self->register_method( $class_name, 'ADJUST', 'void', [] );
        }
        for my $m ( $ast->methods->@* ) {
            $self->register_method( $class_name, $m->name, $m->return_type, $m->params );
        }
        for my $f (@readers) {
            $self->register_method( $class_name, $f->name, $f->type, [] );
        }
        for my $f (@writers) {
            my @params = ( { type => $f->type, sigil => '$', name => 'value' } );
            $self->register_method( $class_name, 'set_' . $f->name, 'void', \@params );
        }
        {
            my @params = map { { type => $_->type, sigil => '$', name => $_->name } } @param_fields;
            $self->register_function_raw( $class_name . '::new', 'void', \@params );
        }

        # Pass 2: lower bodies, now that every callee has a signature.
        $self->lower_adjust( $class_name, $ast->adjust ) if $has_adjust;
        for my $m ( $ast->methods->@* ) {
            $self->lower_method( $class_name, $m );
        }
        for my $f (@readers) {
            $self->generate_reader( $class_name, $f );
        }
        for my $f (@writers) {
            $self->generate_writer( $class_name, $f );
        }
        $self->generate_constructor( $class_name, $ast->fields, \@param_fields, $ast->adjust );
        $current_class = undef;
    }

    # Register built-in FFI functions
    method register_intrinsics() {
        for my $name (qw(say print)) {
            my $fn = Brocken::Lindsay::IR::Function->new(
                name        => $name,
                return_type => Brocken::Lindsay::IR::Type::void(),
                params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ) ],
            );
            $module->add_function($fn);
            $functions->{$name} = $fn;
        }
    }

    # Pass 1: Register declarations
    #
    # C layout. Each field goes at the next multiple of its own alignment, and
    # the struct is rounded up to its own alignment -- the max over its
    # fields -- which is what `sizeof` returns in C.
    #
    # Rounding the total up is what makes `sizeof` agree with C, and it keeps
    # the value a power of two for scalar-only classes. It is still not the
    # number the allocator is asked for: a later `:pack` can produce a size
    # that is not a multiple of 8, and the allocation size below rounds
    # separately rather than forcing the layout to stay aligned.
    method register_class($ast) {
        my @fields;
        my $offset    = 0;
        my $max_align = 1;
        for my $f ( $ast->fields->@* ) {
            my $ir_type = $self->type_from_name( $f->type );
            my $size    = $self->type_size($ir_type);

            # undef unless the field asked for a specific alignment with
            # `:pack` / `:pack(N)`, in which case N replaces the natural
            # alignment outright -- lower for a bare `:pack`, or higher for an
            # over-aligning `:pack(16)`, which is what C's
            # __attribute__((aligned(N))) does.
            my $align = $self->type_align( $ir_type, $f->align );
            $max_align = $align if $align > $max_align;
            $offset    = $self->align_up( $offset, $align );

            # `default_ast` is kept as the unlowered expression because the
            # constructor cannot apply it: its signature carries one parameter
            # per `:param` field and so has no way to know which ones the caller
            # actually passed. The call site fills the gaps instead, which means
            # it needs the expression itself, not a lowered value that would
            # belong to whatever function was being compiled at the time.
            push @fields, { name => $f->name, type => $f->type, ir_type => $ir_type, offset => $offset, size => $size, default_ast => $f->default, };
            $offset += $size;
        }
        $offset = $self->align_up( $offset, $max_align );
        $classes->{ $ast->name } = { fields => \@fields, total_size => $offset, align => $max_align, methods => [], adjust => undef, };
    }

    # A parameter whose declared type names a class is a pointer, and the class
    # is remembered so that a field or method access on the parameter resolves.
    # This is the parameter counterpart of the class return type above: the two
    # together are the whole of "a class travels with a pointer", and without
    # them `sub g(ptr $q) { $q->x() }` had no way to know what $q points at.
    method param_type_for( $func_name, $p ) {
        if ( $classes->{ $p->{type} } ) {
            $param_class->{$func_name}->{ $p->{name} } = $p->{type};
            return Brocken::Lindsay::IR::Type::ptr();
        }
        return $self->type_from_name( $p->{type} );
    }

    method register_function($ast) {
        my $ret_type_name = $classes->{ $ast->return_type } ? 'ptr' : $ast->return_type;
        $function_return_class->{ $ast->name } = $classes->{ $ast->return_type } ? $ast->return_type : undef;
        my $ret_type = $self->type_from_name($ret_type_name);
        my @params;
        if ( $ast->name eq '_BROCKEN_ENTRY' ) {
            push @params, Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%__heap_base', );
        }
        for my $p ( $ast->params->@* ) {
            push @params, Brocken::Lindsay::IR::Value->new( type => $self->param_type_for( $ast->name, $p ), name => '%' . $p->{name}, );
        }
        my $fn = Brocken::Lindsay::IR::Function->new( name => $ast->name, return_type => $ret_type, params => \@params, );
        $module->add_function($fn);
        $functions->{ $ast->name } = $fn;
    }

    method register_method( $class_name, $method_name, $return_type_name, $params_ast ) {
        my $full_name = $class_name . '::' . $method_name;
        $self->register_function_raw( $full_name, $return_type_name, $params_ast );
    }

    method register_function_raw( $name, $return_type_name, $params_ast ) {
        my $ir_ret_type_name = $classes->{$return_type_name} ? 'ptr' : $return_type_name;
        $function_return_class->{$name} = $classes->{$return_type_name} ? $return_type_name : undef;
        my $ret_type = $self->type_from_name($ir_ret_type_name);
        my @params   = ( Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%self', ), );
        for my $p ( $params_ast->@* ) {
            push @params, Brocken::Lindsay::IR::Value->new( type => $self->param_type_for( $name, $p ), name => '%' . $p->{name}, );
        }
        my $fn = Brocken::Lindsay::IR::Function->new( name => $name, return_type => $ret_type, params => \@params, );
        $module->add_function($fn);
        $functions->{$name} = $fn;
    }

    # Pass 2: Lower function bodies
    method lower_function($ast) {
        return if $ast->body->statements->@* == 0;
        $current_func = $functions->{ $ast->name };
        $symbols      = {};
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        if ( $current_func->name eq '_BROCKEN_ENTRY' ) {
            my $heap_base_param  = $current_func->params->[0];
            my $heap_base_alloca = $builder->build_alloca( Brocken::Lindsay::IR::Type::ptr(), '%__heap_base.addr' );
            $builder->build_store( $heap_base_param, $heap_base_alloca );
            $symbols->{'__heap_base'} = $heap_base_alloca;
            my $_init_fn = $functions->{'Brocken::Runtime::_init'};
            if ($_init_fn) {
                my $heap_base = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $heap_base_alloca );
                my $heap_size = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0x100000 );
                $builder->build_call( $_init_fn, [ $heap_base, $heap_size ], undef );
            }
        }
        for my $i ( 0 .. $ast->params->@* - 1 ) {
            my $p      = $current_func->params->[$i];
            my $pname  = $ast->params->[$i]{name};
            my $alloca = $builder->build_alloca( $p->type, '%' . $pname . '.addr' );
            $builder->build_store( $p, $alloca );
            $symbols->{$pname} = $alloca;
        }
        $self->lower_block_body( $ast->body );
        unless ( $current_block && $current_block->terminator ) {
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
        for my $stmt ( $block_ast->statements->@* ) {
            $self->lower_statement($stmt);
        }
    }

    # Statement lowering
    method lower_statement($stmt) {
        return unless defined $stmt;
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::VarDecl') )       { return $self->lower_var_decl($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ArrayDecl') )     { return $self->lower_array_decl($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Assign') )        { return $self->lower_assign($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Return') )        { return $self->lower_return($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::If') )            { return $self->lower_if($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::While') )         { return $self->lower_while($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Block') )         { return $self->lower_block_body($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Expr::Call') )          { $self->lower_call_expr($stmt); return; }
        if ( $stmt->isa('Brocken::Katsuro::AST::Expr::IntrinsicCall') ) { $self->lower_intrinsic($stmt); return; }

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
            $stmt->isa('Brocken::Katsuro::AST::Expr::MethodCall') ) {
            $self->lower_expression($stmt);
            return;
        }
        Carp::croak( "Unknown statement type: " . ref($stmt) . " at " . $self->_loc($stmt) );
    }

    method lower_var_decl($ast) {
        my $ir_type = $self->type_from_name( $ast->type );
        my $alloca  = $builder->build_alloca( $ir_type, '%' . $ast->name . '.addr' );
        $symbols->{ $ast->name } = $alloca;
        if ( defined $ast->init ) {
            if ( $ast->init->isa('Brocken::Katsuro::AST::Expr::MethodCall') &&
                $ast->init->method eq 'new' &&
                $ast->init->obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
                $var_class->{ $ast->name } = $ast->init->obj->name;
            }
            my $val = $self->lower_expression( $ast->init );
            $val = $self->maybe_convert_type( $val, $ir_type );
            $builder->build_store( $val, $alloca );
        }
    }

    method lower_assign($ast) {
        my $target = $ast->target;
        if ( $target->isa('Brocken::Katsuro::AST::Expr::Var') &&
            $ast->expr->isa('Brocken::Katsuro::AST::Expr::MethodCall') &&
            $ast->expr->method eq 'new' &&
            $ast->expr->obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
            $var_class->{ $target->name } = $ast->expr->obj->name;
        }
        my $val = $self->lower_expression( $ast->expr );
        my $addr;
        my $stored_type;
        if ( $target->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            $addr = $symbols->{ $target->name };
            Carp::croak( "Undefined variable '" . $target->name . "' at " . $self->_loc($target) ) unless $addr;
            if ( $addr->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') && $current_class ) {
                my $cd      = $classes->{$current_class};
                my ($field) = $cd ? grep { $_->{name} eq $target->name } $cd->{fields}->@* : ();
                $stored_type = $field ? $field->{ir_type} : Brocken::Lindsay::IR::Type::i64();
            }
            else {
                $stored_type = $addr->allocated_type // $val->type;
            }
        }
        elsif ( $target->isa('Brocken::Katsuro::AST::Expr::FieldAccess') ) {
            $addr = $self->lower_field_addr($target);
            my $cls     = $self->resolve_class_name($target);
            my $cd      = $classes->{$cls};
            my ($field) = grep { $_->{name} eq $target->field } $cd->{fields}->@*;
            Carp::croak( "Unknown field '" . $target->field . "' in class '" . $cls . "' at " . $self->_loc($target) ) unless $field;
            $stored_type = $field->{ir_type};
        }
        elsif ( $target->isa('Brocken::Katsuro::AST::Expr::ArrayIndex') ) {
            $addr        = $self->lower_array_addr($target);
            $stored_type = $addr->base_type;
        }
        else {
            Carp::croak( "Assignment target must be a variable, field access, or array index at " . $self->_loc($target) );
        }
        $val = $self->maybe_convert_type( $val, $stored_type );
        if ( $ast->op eq '//=' ) {
            my $existing = $builder->build_load( $stored_type, $addr );
            my $zero     = Brocken::Lindsay::IR::Constant->new( type => $stored_type, value => 0 );
            my $is_undef = $builder->build_icmp( 'eq', $existing, $zero );
            my $new_val  = $builder->build_select( $is_undef, $val, $existing );
            $builder->build_store( $new_val, $addr );
        }
        else {
            $builder->build_store( $val, $addr );
        }
    }

    method lower_return($ast) {
        if ( defined $ast->expr ) {
            my $val      = $self->lower_expression( $ast->expr );
            my $ret_type = $current_func->return_type;
            $val = $self->maybe_convert_type( $val, $ret_type );
            $builder->build_ret($val);
        }
        else {
            $builder->build_ret();
        }
    }

    method lower_if($ast) {
        my $parent_block = $current_block;
        my $func         = $current_func;
        my $then_block   = $func->append_block( $self->unique_block_name('then') );
        my $merge_block  = $func->append_block( $self->unique_block_name('if_end') );
        my $else_block;
        my $has_else = defined $ast->else || $ast->elsif->@* > 0;
        my $cond     = $self->as_condition( $self->lower_expression( $ast->cond ) );
        if ($has_else) {
            $else_block = $func->append_block( $self->unique_block_name('else') );
            $builder->position_at_end($parent_block);
            $builder->build_cond_br( $cond, $then_block, $else_block );
        }
        else {
            $builder->position_at_end($parent_block);
            $builder->build_cond_br( $cond, $then_block, $merge_block );
        }
        $builder->position_at_end($then_block);
        $current_block = $then_block;
        $self->lower_block_body( $ast->then );
        unless ( $current_block->terminator ) {
            $builder->build_br($merge_block);
        }
        if ($has_else) {
            $builder->position_at_end($else_block);
            $current_block = $else_block;
            if ( $ast->elsif->@* > 0 ) {
                my $first_elsif = $ast->elsif->[0];
                $self->lower_elsif_chain( $first_elsif, $merge_block, \@{ $ast->elsif }, 0 );
            }
            elsif ( defined $ast->else ) {
                $self->lower_block_body( $ast->else );
            }
            unless ( $current_block->terminator ) {
                $builder->build_br($merge_block);
            }
        }
        $builder->position_at_end($merge_block);
        $current_block = $merge_block;
    }

    method lower_elsif_chain( $pair, $merge_block, $all_pairs, $idx ) {
        my $cond = $self->as_condition( $self->lower_expression( $pair->[0] ) );
        my $body = $pair->[1];
        my $func = $current_func;
        my $then = $func->append_block( $self->unique_block_name('elsif_then') );
        my $next;
        my $next_idx = $idx + 1;
        if ( $next_idx < $all_pairs->@* ) {
            $next = $func->append_block( $self->unique_block_name('elsif_n') );
            $builder->position_at_end($current_block);
            $builder->build_cond_br( $cond, $then, $next );
        }
        else {
            $next = $merge_block;
            $builder->position_at_end($current_block);
            $builder->build_cond_br( $cond, $then, $next );
        }
        $builder->position_at_end($then);
        $current_block = $then;
        $self->lower_block_body($body);
        unless ( $current_block->terminator ) {
            $builder->build_br($merge_block);
        }
        if ( $next->name ne 'if_end' ) {
            $builder->position_at_end($next);
            $current_block = $next;
            $self->lower_elsif_chain( $all_pairs->[$next_idx], $merge_block, $all_pairs, $next_idx );
        }
    }

    method lower_while($ast) {
        my $func   = $current_func;
        my $header = $func->append_block( $self->unique_block_name('while_header') );
        my $body   = $func->append_block( $self->unique_block_name('while_body') );
        my $exit   = $func->append_block( $self->unique_block_name('while_end') );
        $builder->position_at_end($current_block);
        $builder->build_br($header);
        $builder->position_at_end($header);
        $current_block = $header;
        my $cond = $self->as_condition( $self->lower_expression( $ast->cond ) );
        $builder->build_cond_br( $cond, $body, $exit );
        $builder->position_at_end($body);
        $current_block = $body;
        $self->lower_block_body( $ast->body );

        unless ( $current_block->terminator ) {
            $builder->build_br($header);
        }
        $builder->position_at_end($exit);
        $current_block = $exit;
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
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::MethodCall') ) {
            return $self->lower_method_call($expr);
        }
        if ( $expr->isa('Brocken::Katsuro::AST::Expr::ClassConst') ) {
            return $self->lower_class_const($expr);
        }
        Carp::croak( "Unknown expression type: " . ref($expr) . " at " . $self->_loc($expr) );
    }

    method lower_const($ast) {
        return Brocken::Lindsay::IR::Constant->new( type => $self->native_type_from_name( $ast->type ), value => $ast->value, );
    }

    method lower_var_ref($ast) {

        # Array variables: @arr returns the base pointer directly
        if ( $ast->sigil eq '@' ) {
            my $sym = $symbols->{ '@' . $ast->name } // $symbols->{ $ast->name };
            Carp::croak( "Undefined array variable '\@" . $ast->name . "' at " . $self->_loc($ast) ) unless $sym;
            return $sym;
        }
        my $sym = $symbols->{ $ast->name };
        Carp::croak( "Undefined variable '" . $ast->name . "' at " . $self->_loc($ast) ) unless $sym;

        # SSA values (e.g. $self parameter) -- return directly
        if ( $sym->isa('Brocken::Lindsay::IR::Value') && !$sym->isa('Brocken::Lindsay::IR::Instruction') ) {
            return $sym;
        }

        # Instruction that represents an address -- load from it
        my $loaded_type;
        if ( $sym->isa('Brocken::Lindsay::IR::Instruction::GetElementPtr') && $current_class ) {
            my $cd      = $classes->{$current_class};
            my ($field) = $cd ? grep { $_->{name} eq $ast->name } $cd->{fields}->@* : ();
            $loaded_type = $field ? $field->{ir_type} : Brocken::Lindsay::IR::Type::i64();
        }
        else {
            $loaded_type = $sym->allocated_type // Brocken::Lindsay::IR::Type::i64();
        }
        return $builder->build_load( $loaded_type, $sym );
    }

    method lower_array_decl($ast) {
        my $ir_type  = $self->type_from_name( $ast->elem_type );
        my $size_val = $self->lower_expression( $ast->size_expr );
        my $key      = '@' . $ast->name;
        my $alloca   = $builder->build_alloca( $ir_type, '%' . $key . '.addr', $size_val );
        $symbols->{$key} = $alloca;
    }

    method lower_array_addr($ast) {
        my $array_expr = $ast->array;
        my $array_base;
        my $elem_type;
        if ( $array_expr->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            my $key = '@' . $array_expr->name;
            my $sym = $symbols->{$key};
            Carp::croak( "Unknown array variable '\@" . $array_expr->name . "' at " . $self->_loc($array_expr) ) unless $sym;
            $array_base = $sym;
            $elem_type  = $sym->allocated_type;
        }
        else {
            $array_base = $self->lower_expression($array_expr);
            $elem_type  = $array_base->type;
        }
        my $index_val = $self->lower_expression( $ast->index );
        return $builder->build_gep( $elem_type, $array_base, [$index_val], '%idx.addr' );
    }

    method lower_array_index($ast) {
        my $addr = $self->lower_array_addr($ast);
        return $builder->build_load( $addr->base_type, $addr );
    }

    method lower_binop($ast) {
        my $lhs = $self->lower_expression( $ast->lhs );
        my $rhs = $self->lower_expression( $ast->rhs );
        my $op  = $ast->op;

        # Unbox dynamic operands to i64 for arithmetic/comparison
        my $native = Brocken::Lindsay::IR::Type::i64();
        if ( $lhs->type->kind eq 'dynamic' || $rhs->type->kind eq 'dynamic' ) {
            $lhs = $self->maybe_convert_type( $lhs, $native );
            $rhs = $self->maybe_convert_type( $rhs, $native );
        }

        # Two native integers have to meet at a common width before the
        # instruction. `$g == -1` where `$g` is an i32 local and the literal is
        # an i64 left the operands as i32 and i64, and the backend compared them
        # as if both were the width it picked from the left operand, so the guard
        # was silently false. A literal does not carry the local's type, so
        # promote the narrower operand instead. The narrower side is always the
        # one converted, which is also the only direction that works: widening
        # emits a sext/zext, while asking for a narrow target on a wide value is
        # a no-op and would leave the mismatch in place.
        if ( $lhs->type->kind eq 'int' && $rhs->type->kind eq 'int' && $lhs->type->bits != $rhs->type->bits ) {
            if ( $lhs->type->bits < $rhs->type->bits ) {
                $lhs = $self->maybe_convert_type( $lhs, $rhs->type );
            }
            else {
                $rhs = $self->maybe_convert_type( $rhs, $lhs->type );
            }
        }

        # An integer literal on one side of a float operation is the same
        # under-the-hood-the-same-number case as an initializer, and the same
        # reasoning applies: re-tag the literal rather than convert it. Without
        # this the operands reach the backend as float:64 and int:64 and the
        # wider operand decides the width, so `$t + 1` compared and added an
        # i64 against an f64. Re-tagging the literal to the float type puts both
        # sides in the same domain before the instruction.
        # Two floats of different widths, which a decimal literal brings in:
        # `my f32 $a = 1.5;` stores an f32 and `if ($a == 1.5)` compares it
        # against the f64 the literal defaults to. The int case above covers
        # ints; this is its float counterpart, and without it the comparison
        # reached Wasm as an f32 against an f64 and the validator rejected the
        # module. There is no fpext or fptrunc in the IR, so this only works
        # for a literal -- but that is the case that exists, since without a
        # decimal literal there was no way to write a float constant at all.
        if ( $lhs->type->kind eq 'float' && $rhs->type->kind eq 'float' && $lhs->type->bits != $rhs->type->bits ) {
            my $is_const = sub { $_[0]->isa('Brocken::Lindsay::IR::Constant') };
            Carp::croak( "Cannot compare a " .
                    $lhs->type->bits .
                    "-bit float against a " .
                    $rhs->type->bits .
                    "-bit one; the IR has no float width conversion, so at least one of them has to be a literal" )
                unless $is_const->($lhs) || $is_const->($rhs);

            # The literal takes the width of the value it is compared against.
            # That direction is the only one available -- the other side is a
            # loaded value, and there is no instruction to widen or narrow it --
            # and it is the rule an integer literal already follows below.
            ( $lhs, $rhs )
                = $is_const->($lhs) ? ( Brocken::Lindsay::IR::Constant->new( type => $rhs->type, value => $lhs->value ), $rhs ) :
                ( $lhs, Brocken::Lindsay::IR::Constant->new( type => $lhs->type, value => $rhs->value ) );
        }
        if ( $lhs->type->kind eq 'float' xor $rhs->type->kind eq 'float' ) {
            my $float_side = $lhs->type->kind eq 'float' ? $lhs : $rhs;
            my $int_side   = $lhs->type->kind eq 'float' ? $rhs : $lhs;
            if ( $int_side->isa('Brocken::Lindsay::IR::Constant') && $int_side->type->kind eq 'int' ) {
                $int_side = Brocken::Lindsay::IR::Constant->new( type => $float_side->type, value => $int_side->value );
            }
            else {
                # A computed int is not the same number under another tag, so
                # this is a real conversion rather than a relabelling, and it
                # has to go through the same path as an initializer: `sitofp`
                # and then the float operation. It used to be refused outright,
                # which read as a hole in the compiler because the initializer
                # right next to it accepted the identical value -- `my f64 $t =
                # -$i;` converts and `w() == -3` did not. Negating in float
                # instead would mean an xor against a sign mask, so converting
                # the already-negated integer is both the cheap answer and the
                # one that agrees with the initializer.
                $int_side = $self->maybe_convert_type( $int_side, $float_side->type );
            }
            ( $lhs, $rhs ) = $lhs->type->kind eq 'float' ? ( $lhs, $int_side ) : ( $int_side, $rhs );
        }
        return $builder->build_add( $lhs, $rhs ) if $op eq '+';
        return $builder->build_sub( $lhs, $rhs ) if $op eq '-';
        return $builder->build_mul( $lhs, $rhs ) if $op eq '*';
        if ( $op eq '/' ) {
            return $lhs->type->is_signed ? $builder->build_div( $lhs, $rhs ) : $builder->build_udiv( $lhs, $rhs );
        }
        if ( $op eq '%' ) {
            return $lhs->type->is_signed ? $builder->build_rem( $lhs, $rhs ) : $builder->build_urem( $lhs, $rhs );
        }
        return $builder->build_and( $lhs, $rhs )        if $op eq '&&';
        return $builder->build_or( $lhs, $rhs )         if $op eq '||';
        return $builder->build_icmp( 'eq', $lhs, $rhs ) if $op eq '==';
        return $builder->build_icmp( 'ne', $lhs, $rhs ) if $op eq '!=';

        # The ordering predicates come in two sets and the operand kind picks
        # between them, not the signedness. A float has no signedness, so
        # asking for it here produced an integer predicate -- `slt` -- against a
        # backend whose float table is keyed `lt`, and the lookup missed and
        # emitted 'set' . undef. Floats compare ordered, so there is one set
        # each for < > <= >=; the sign matters only for integers.
        my $is_float = $lhs->type->kind eq 'float';
        my %order    = $is_float ? ( '<' => 'lt', '>' => 'gt', '<=' => 'le', '>=' => 'ge' ) : (
            '<'  => ( $lhs->type->is_signed ? 'slt' : 'ult' ),
            '>'  => ( $lhs->type->is_signed ? 'sgt' : 'ugt' ),
            '<=' => ( $lhs->type->is_signed ? 'sle' : 'ule' ),
            '>=' => ( $lhs->type->is_signed ? 'sge' : 'uge' ),
        );
        if ( my $pred = $order{$op} ) {
            return $builder->build_icmp( $pred, $lhs, $rhs );
        }
        Carp::croak( "Unknown binary operator '$op' at " . $self->_loc($ast) );
    }

    method lower_unop($ast) {
        my $operand = $self->lower_expression( $ast->expr );
        my $op      = $ast->op;

        # Unbox dynamic operands to i64 before unary ops
        if ( $operand->type->kind eq 'dynamic' ) {
            $operand = $self->maybe_convert_type( $operand, Brocken::Lindsay::IR::Type::i64() );
        }
        return $builder->build_neg($operand) if $op eq '-';
        if ( $op eq '!' ) {
            my $zero = Brocken::Lindsay::IR::Constant->new( type => $operand->type, value => 0 );
            return $builder->build_icmp( 'eq', $operand, $zero );
        }
        Carp::croak( "Unknown unary operator '$op' at " . $self->_loc($ast) );
    }

    method lower_call_expr($ast) {
        my $name   = $ast->func_name;
        my $callee = $functions->{$name};
        unless ($callee) {
            if ( $name eq 'say' || $name eq 'print' ) {
                $callee = Brocken::Lindsay::IR::Function->new(
                    name        => $name,
                    return_type => Brocken::Lindsay::IR::Type::void(),
                    params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ) ],
                );
                $module->add_function($callee);
                $functions->{$name} = $callee;
            }
            else {
                Carp::croak( "Undefined function '$name' at " . $self->_loc($ast) );
            }
        }
        my @args;
        my $param_idx = 0;
        for my $arg ( $ast->args->@* ) {
            my $val = $self->lower_expression($arg);
            if ( $param_idx < $callee->params->@* ) {
                $val = $self->maybe_convert_type( $val, $callee->params->[$param_idx]->type );
            }
            push @args, $val;
            $param_idx++;
        }
        my $ret_is_void = $callee->return_type->kind eq 'void';
        return $builder->build_call( $callee, \@args, $ret_is_void ? undef : $builder->_unique_name( '%' . $name . '_res' ) );
    }

    method lower_intrinsic($ast) {
        my $name = $ast->name;
        my @args;
        for my $arg ( $ast->args->@* ) {
            push @args, $self->lower_expression($arg);
        }
        return $builder->build_add( $args[0], $args[1] )                           if $name eq 'ptr_add';
        return $builder->build_sub( $args[0], $args[1] )                           if $name eq 'ptr_sub';
        return $builder->build_icmp( 'sgt', $args[0], $args[1] )                   if $name eq 'ptr_cmp_gt';
        return $builder->build_icmp( 'slt', $args[0], $args[1] )                   if $name eq 'ptr_cmp_lt';
        return $builder->build_icmp( 'eq', $args[0], $args[1] )                    if $name eq 'ptr_cmp_eq';
        return $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $args[0] ) if $name eq 'load_i64';

        # Each store has to build only for its own intrinsic. A bare
        # `build_store` here ran for *every* intrinsic, so `load_i32` and
        # anything added after it emitted a store with undefined operands ahead
        # of the real instruction. `store_i64` happened to work only because the
        # unconditional store it built was the correct one.
        if ( $name eq 'store_i64' ) {
            $builder->build_store( $args[1], $args[0] );
            return undef;
        }
        return $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $args[0] ) if $name eq 'load_i32';
        if ( $name eq 'store_i32' ) {
            $builder->build_store( $args[1], $args[0] );
            return undef;
        }

        # Linear-memory control. A wasm32 module can ask the host for more pages,
        # which is what lets the runtime back the heap it was promised instead of
        # trapping at the statically declared size. `memory_grow` yields the
        # previous size in pages or -1 on refusal, so a target with a fixed
        # host-provided region lowers it to a constant -1 and the runtime reports
        # out-of-memory rather than writing past the region.
        return $builder->build_memory_grow( $args[0] ) if $name eq 'memory_grow';
        return $builder->build_memory_size()           if $name eq 'memory_size';
        Carp::croak( "Unknown intrinsic '$name' at " . $self->_loc($ast) );
    }

    # Condition conversion
    method as_condition($val) {
        return $val if $val->type->bits == 1;

        # Unbox dynamic to i64 before comparing against zero
        if ( $val->type->kind eq 'dynamic' ) {
            $val = $self->maybe_convert_type( $val, Brocken::Lindsay::IR::Type::i64() );
        }
        my $zero = Brocken::Lindsay::IR::Constant->new( type => $val->type, value => 0 );
        return $builder->build_icmp( 'ne', $val, $zero );
    }

    # Type conversion helper
    method maybe_convert_type( $val, $target_type ) {
        return $val if $val->type->kind eq $target_type->kind && $val->type->bits == $target_type->bits;

        # Box: native -> dynamic
        if ( $target_type->kind eq 'dynamic' && $val->type->kind ne 'dynamic' ) {
            return $builder->build_box($val);
        }

        # Unbox: dynamic -> native
        if ( $val->type->kind eq 'dynamic' && $target_type->kind ne 'dynamic' ) {
            return $builder->build_unbox( $val, $target_type );
        }

        # Integer width changes: widen with zero/sign extension, narrow with a
        # truncation. A literal carries no type of its own, so `my i32 $g = -1`
        # reaches here as an i64 -1 against an i32 slot; without the narrowing it
        # was stored as eight bytes through a four-byte slot, which native
        # tolerated and the Wasm validator rejected ("expected i32, found i64").
        if ( $val->type->kind eq 'int' && $target_type->kind eq 'int' ) {
            if ( $val->type->bits < $target_type->bits ) {
                return $val->type->is_signed ? $builder->build_sext( $val, $target_type ) : $builder->build_zext( $val, $target_type );
            }
            if ( $val->type->bits > $target_type->bits ) {
                return $builder->build_trunc( $val, $target_type );
            }
            return $val;
        }

        # Integer -> pointer. A backend declares a pointer as a machine address
        # of its own width, so a `return 0` in a function declared `-> ptr` has
        # to arrive as a pointer. Leaving the literal typed as i64 made the
        # return value an i64 while the Wasm type section declared the function
        # as returning i32, and the module failed to validate.
        if ( $val->type->kind eq 'int' && $target_type->kind eq 'ptr' ) {
            return $builder->build_ptrcast( $val, $target_type );
        }

        # Pointer -> integer, the mirror image: `-> i64` returning a pointer.
        if ( $val->type->kind eq 'ptr' && $target_type->kind eq 'int' ) {
            return $builder->build_ptrcast( $val, $target_type );
        }

        # Integer -> float. A literal reaching a float slot is not a number that
        # needs converting, it is the same number under a different tag, so
        # re-tagging *is* the conversion. This has to happen: the backends pack
        # a float-typed constant with pack('d'/'f'), but fell back to packing the
        # raw integer for an int-typed one, so `my f64 $t = 3` stored eight
        # zero-extended bytes and the reload read them back as a denormal.
        if ( $val->type->kind eq 'int' && $target_type->kind eq 'float' ) {

            # A *literal* is not a number that needs converting, it is the same
            # number under a different tag, so re-tagging *is* the conversion.
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => $val->value );
            }

            # A *computed* int does need converting, and every target has one
            # instruction for it: CVTSI2SD, SCVTF, FCVT.S.L and
            # f64.convert_i64_s. Storing integer bits through a float slot is
            # wrong for everything past 2**52, so refusing it was the safe
            # answer, but it also meant an int could not be assigned to a float
            # at all.
            my $bits = $val->type->bits;
            Carp::croak(
                "No integer-to-float conversion for a " . $bits . "-bit integer; " . "none of the targets has an instruction wider than 64 bits" )
                if $bits > 64;

            # x86-64 has no unsigned convert at all, and values at or above
            # 2**63 need several instructions to come out right rather than one.
            Carp::croak( "No unsigned 64-bit integer-to-float conversion; " . "x86-64 has no unsigned form of the instruction" )
                if $bits == 64 && !$val->type->is_signed;

            # Widening to 64 bits first is also what makes the unsigned cases
            # work: there is only a signed convert instruction, but a u8, u16 or
            # u32 zero-extended into an i64 is a positive i64 and converts
            # correctly, while sign-extending a negative one would not.
            my $wide = $val;
            if ( $bits < 64 ) {
                $wide = $val->type->is_signed ? $builder->build_sext( $val, Brocken::Lindsay::IR::Type::i64() ) :
                    $builder->build_zext( $val, Brocken::Lindsay::IR::Type::i64() );
            }
            return $builder->build_sitofp( $wide, $target_type );
        }

        # Float -> integer, the mirror of the case above and unlike it: the two
        # hold different bits, so nothing here is a relabelling. Reaching this
        # point at all meant the float was stored verbatim into an integer slot
        # and read back as its IEEE pattern -- `my f64 $t = 3; my i64 $i = $t`
        # left $i holding 0x4008000000000000, whose low byte is 0, so a program
        # that only looked at the answer saw a plausible zero rather than an
        # obviously wrong number.
        if ( $val->type->kind eq 'float' && $target_type->kind eq 'int' ) {

            # A literal is folded here rather than left for the instruction. A
            # float constant holds a plain Perl number, and the integer it names
            # is that number truncated toward zero, which is what every backend
            # instruction does anyway.
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => int( $val->value ) );
            }
            return $builder->build_fptosi( $val, $target_type );
        }

        # Float width, which is what a decimal literal runs into: it arrives as
        # f64, and `my f32 $t = 1.5;` would otherwise store eight bytes into a
        # four-byte slot. A *literal* is again not a number that needs
        # converting -- the constant holds a plain Perl number and each backend
        # packs it at the width its type asks for -- so re-tagging is the whole
        # conversion, and it is also where the rounding to f32 happens.
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
        my $obj = $ast->obj;
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
            Carp::croak( "Unknown class '" . $obj->name . "' at " . $self->_loc($obj) ) unless $classes->{ $obj->name };
            return $obj->name;
        }
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            return $var_class->{ $obj->name } if exists $var_class->{ $obj->name };

            # A parameter declared with its class, `sub g(Point $q)`. Keyed by
            # the function currently being lowered, which is why a local of the
            # same name in another function cannot leak a class into this one.
            if ($current_func) {
                my $by_param = $param_class->{ $current_func->name }->{ $obj->name };
                return $by_param if $by_param;
            }
        }
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Call') && exists $function_return_class->{ $obj->func_name } ) {
            return $function_return_class->{ $obj->func_name };
        }
        if ($current_class) {
            return $current_class;
        }

        # Nothing above knew the class. The overwhelmingly common cause is a
        # bare `ptr` parameter, which carries no class at all, so say that
        # rather than leaving the reader to guess why inference failed.
        my $hint = '';
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Var') ) {
            $hint = " -- declare the parameter with its class, e.g. sub g(ClassName \$" . $obj->name . "), if one is in scope here";
        }
        Carp::croak( "Cannot determine class for field or method access at " . $self->_loc($ast) . $hint );
    }

    method lower_field_addr($ast) {
        my $obj_ptr    = $self->lower_expression( $ast->obj );
        my $class_name = $self->resolve_class_name($ast);
        my $cd         = $classes->{$class_name};
        my ($field)    = grep { $_->{name} eq $ast->field } $cd->{fields}->@*;
        Carp::croak( "Unknown field '" . $ast->field . "' in class '" . $class_name . "' at " . $self->_loc($ast) ) unless $field;
        return $builder->build_gep(
            Brocken::Lindsay::IR::Type::i8(),
            $obj_ptr,
            [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $field->{offset} ) ],
            '%' . $ast->field . '.addr'
        );
    }

    method lower_field_access($ast) {
        my $field_ptr  = $self->lower_field_addr($ast);
        my $class_name = $self->resolve_class_name($ast);
        my $cd         = $classes->{$class_name};
        my ($field)    = grep { $_->{name} eq $ast->field } $cd->{fields}->@*;
        return $builder->build_load( $field->{ir_type}, $field_ptr );
    }

    method lower_method_call($ast) {
        my $class_name   = $self->resolve_class_name($ast);
        my $obj_is_class = $ast->obj->isa('Brocken::Katsuro::AST::Expr::Ident');
        my $full_name    = $class_name . '::' . $ast->method;
        my $callee       = $functions->{$full_name};
        Carp::croak( "Undefined method '" . $ast->method . "' in class '" . $class_name . "' at " . $self->_loc($ast) ) unless $callee;
        if ( $obj_is_class && $ast->method eq 'new' ) {
            my $cd         = $classes->{$class_name};
            my $total_size = $cd->{total_size};

            # The allocation size is the struct rounded up to the allocator's
            # 8-byte granularity, kept separate from the logical layout size.
            # The alloca below has no byte-count form, so it takes an integer
            # type -- and deriving `bits` from a byte count invented widths no
            # backend has, a 24-bit type for a 3-byte struct. Rounding here
            # means the two can never drift apart again, and it matches what
            # the heap path already asks `bump_alloc` for.
            my $alloc_size = $self->align_up( $total_size, 8 ) || 8;
            my $self_ptr;
            if ( exists $symbols->{'__heap_base'} ) {
                my $bump_alloc_fn = $functions->{'Brocken::Runtime::bump_alloc'};
                Carp::croak( "Runtime function bump_alloc not found at " . $self->_loc($ast) ) unless $bump_alloc_fn;
                my $heap_base  = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
                my $size_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $alloc_size );
                my $alloc      = $builder->build_call( $bump_alloc_fn, [ $heap_base, $size_const ], undef );

                # `bump_alloc` reports exhaustion by returning 0. Passing that
                # straight to the constructor made it store through a null
                # pointer, which on wasm is a wild write rather than the
                # allocation failure it actually is, so the result is checked
                # before anything writes to it.
                my $check_alloc_fn = $functions->{'Brocken::Runtime::check_alloc'};
                Carp::croak( "Runtime function check_alloc not found at " . $self->_loc($ast) ) unless $check_alloc_fn;
                $self_ptr = $builder->build_call( $check_alloc_fn, [$alloc], '%obj' );
            }
            else {
                my $alloc_type = Brocken::Lindsay::IR::Type->new( kind => 'int', bits => $alloc_size * 8 );
                $self_ptr = $builder->build_alloca( $alloc_type, '%obj' );
            }
            my @args       = ($self_ptr);
            my $ctor_p_idx = 1;
            for my $arg ( $ast->args->@* ) {
                my $val = $self->lower_expression($arg);
                if ( $ctor_p_idx < $callee->params->@* ) {
                    $val = $self->maybe_convert_type( $val, $callee->params->[$ctor_p_idx]->type );
                }
                push @args, $val;
                $ctor_p_idx++;
            }

            # A `:param` field the caller left out still occupies a slot in the
            # constructor's signature, and the constructor stores that slot
            # whatever it finds there. So a missing argument used to arrive as
            # an uninitialized register -- and on wasm as an uninitialized
            # local, where the validator rejects the read outright ("expected
            # i32 but nothing on stack") rather than producing a wrong answer.
            #
            # Supply the field's default for the gap, and a zero when it has
            # none. Doing it here rather than in the constructor is forced: the
            # signature is fixed at one parameter per `:param` field, so the
            # constructor has no way to tell "passed zero" from "not passed".
            if ( $ctor_p_idx < $callee->params->@* ) {
                my $cd = $classes->{$class_name};
                for my $i ( $ctor_p_idx .. $callee->params->@* - 1 ) {
                    my $param_type = $callee->params->[$i]->type;

                    # Parameter values are named with their sigil (`%b`), so the
                    # sigil has to come off before matching a field by name.
                    my $param_name = $callee->params->[$i]->name // '';
                    $param_name =~ s/^%//;
                    my ($fd) = grep { $_->{name} eq $param_name } $cd->{fields}->@*;
                    my $val;
                    if ( $fd && defined $fd->{default_ast} ) {
                        $val = $self->lower_expression( $fd->{default_ast} );
                    }
                    else {
                        $val = Brocken::Lindsay::IR::Constant->new( type => $param_type, value => 0 );
                    }
                    push @args, $self->maybe_convert_type( $val, $param_type );
                }
            }
            $builder->build_call( $callee, \@args, undef );
            return $self_ptr;
        }
        my $obj_ptr = $obj_is_class ? Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 ) :
            $self->lower_expression( $ast->obj );
        my @args      = ($obj_ptr);
        my $param_idx = 1;
        for my $arg ( $ast->args->@* ) {
            my $val = $self->lower_expression($arg);
            if ( $param_idx < $callee->params->@* ) {
                $val = $self->maybe_convert_type( $val, $callee->params->[$param_idx]->type );
            }
            push @args, $val;
            $param_idx++;
        }
        my $ret_is_void = $callee->return_type->kind eq 'void';
        return $builder->build_call( $callee, \@args, $ret_is_void ? undef : $builder->_unique_name( '%' . $ast->method . '_res' ) );
    }

    method lower_class_const($ast) {
        Carp::croak( "__CLASS__ used outside of a class at " . $self->_loc($ast) ) unless $current_class;
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => $current_class, );
    }

    # Method body lowering with field GEP pre-population
    method lower_method( $class_name, $method_ast ) {
        my $full_name = $class_name . '::' . $method_ast->name;
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $symbols = {};
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;

        # $self is the first param (ptr) at index 0
        my $self_val = $current_func->params->[0];
        $symbols->{self} = $self_val;

        # Pre-populate symbol table with field GEPs for direct field name access
        $self->populate_field_geps( $class_name, $self_val );

        # Lower explicit method params (params start at index 1)
        for my $i ( 0 .. $method_ast->params->@* - 1 ) {
            my $p      = $current_func->params->[ $i + 1 ];
            my $pname  = $method_ast->params->[$i]{name};
            my $alloca = $builder->build_alloca( $p->type, '%' . $pname . '.addr' );
            $builder->build_store( $p, $alloca );
            $symbols->{$pname} = $alloca;
        }
        $self->lower_block_body( $method_ast->body );
        unless ( $current_block && $current_block->terminator ) {
            if ( $current_func->return_type->kind eq 'void' ) {
                $builder->build_ret();
            }
            else {
                my $zero = Brocken::Lindsay::IR::Constant->new( type => $current_func->return_type, value => 0 );
                $builder->build_ret($zero);
            }
        }
    }

    method lower_adjust( $class_name, $adjust_ast ) {
        my $full_name = $class_name . '::ADJUST';
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $symbols = {};
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;

        # $self is the first param (ptr) at index 0
        my $self_val = $current_func->params->[0];
        $symbols->{self} = $self_val;
        $self->populate_field_geps( $class_name, $self_val );
        $self->lower_block_body( $adjust_ast->body );
        unless ( $current_block && $current_block->terminator ) {
            $builder->build_ret();
        }
    }

    method populate_field_geps( $class_name, $self_val ) {
        my $cd = $classes->{$class_name};
        return unless $cd;
        for my $fd ( $cd->{fields}->@* ) {
            my $field_ptr = $builder->build_gep(
                Brocken::Lindsay::IR::Type::i8(),
                $self_val,
                [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $fd->{offset} ) ],
                '%' . $fd->{name} . '.addr'
            );
            $symbols->{ $fd->{name} } = $field_ptr;
        }
    }

    # Auto-generated accessor and constructor lowering
    method generate_reader( $class_name, $field_ast ) {
        my $full_name = $class_name . '::' . $field_ast->name;
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $self_val  = $current_func->params->[0];
        my $cd        = $classes->{$class_name};
        my ($fd)      = grep { $_->{name} eq $field_ast->name } $cd->{fields}->@*;
        my $field_ptr = $builder->build_gep(
            Brocken::Lindsay::IR::Type::i8(),
            $self_val,
            [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $fd->{offset} ) ],
            '%' . $fd->{name} . '.addr'
        );
        my $loaded = $builder->build_load( $fd->{ir_type}, $field_ptr );
        $builder->build_ret($loaded);
    }

    method generate_writer( $class_name, $field_ast ) {
        my $full_name = $class_name . '::set_' . $field_ast->name;
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $self_val  = $current_func->params->[0];
        my $value_val = $current_func->params->[1];
        my $cd        = $classes->{$class_name};
        my ($fd)      = grep { $_->{name} eq $field_ast->name } $cd->{fields}->@*;
        my $field_ptr = $builder->build_gep(
            Brocken::Lindsay::IR::Type::i8(),
            $self_val,
            [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $fd->{offset} ) ],
            '%' . $fd->{name} . '.addr'
        );
        $builder->build_store( $value_val, $field_ptr );
        $builder->build_ret();
    }

    method generate_constructor( $class_name, $all_fields, $param_fields, $adjust_ast ) {
        my $ctor_name = $class_name . '::new';
        $current_func = $functions->{$ctor_name};
        return unless $current_func;
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $cd       = $classes->{$class_name};
        my $self_ptr = $current_func->params->[0];

        # A `:param` field is stored from its parameter, and a field that is not
        # a parameter is stored from its default if it has one.
        #
        # A `:param` field that also has a default is stored from the parameter
        # like any other, because the call site has already substituted the
        # default for a `:param` the caller left out. It cannot be applied here
        # instead: this signature carries one parameter per `:param` field, so
        # there is no way to tell an omitted argument from one that was passed
        # as zero.
        my $param_idx = 0;
        for my $f ( $all_fields->@* ) {
            my ($fd) = grep { $_->{name} eq $f->name } $cd->{fields}->@*;
            my $field_ptr = $builder->build_gep(
                Brocken::Lindsay::IR::Type::i8(),
                $self_ptr,
                [ Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $fd->{offset} ) ],
                '%' . $f->name . '.init'
            );
            my $is_param = grep { $_ eq 'param' } $f->attrs->@*;
            if ($is_param) {
                my $param_val = $current_func->params->[ $param_idx + 1 ];
                my $converted = $self->maybe_convert_type( $param_val, $fd->{ir_type} );
                $builder->build_store( $converted, $field_ptr );
                $param_idx++;
            }
            elsif ( defined $f->default ) {
                my $default_val = $self->lower_expression( $f->default );
                $default_val = $self->maybe_convert_type( $default_val, $fd->{ir_type} );
                $builder->build_store( $default_val, $field_ptr );
            }
        }

        # Call ADJUST if present
        if ( defined $adjust_ast ) {
            my $adjust_fn = $functions->{ $class_name . '::ADJUST' };
            if ($adjust_fn) {
                $builder->build_call( $adjust_fn, [$self_ptr], undef );
            }
        }
        $builder->build_ret();
    }
}
1;
