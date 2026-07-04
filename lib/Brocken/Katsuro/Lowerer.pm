use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
use Carp ();

class Brocken::Katsuro::Lowerer {
    field $module : param = Brocken::Lindsay::IR::Module->new( name => 'main' );
    field $platform : reader : param = undef;
    field $builder = Brocken::Lindsay::IR::Builder->new();
    field $current_func;
    field $current_block;
    field $current_class;                 # class name when inside a method/ADJUST
    field $symbols               = {};    # "name" -> ptr (alloca or GEP result)
    field $functions             = {};    # "name" -> Brocken::Lindsay::IR::Function
    field $classes : reader      = {};    # "ClassName" -> { fields => [...], total_size => N, methods => [...], adjust => undef }
    field $block_id              = 0;
    field $var_class             = {};    # var_name -> class_name (for ptr vars from constructors)
    field $function_return_class = {};    # func_name -> class_name (for functions returning a class ptr)
    field $rodata : reader       = {};    # label -> bytes for string constants
    field $_rodata_label_counter = 0;

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

    # === Main entry point ===
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

    method generate_class_runtime($ast) {
        my $class_name = $ast->name;
        $current_class = $class_name;
        my $class_data = $classes->{$class_name};

        # Lower the ADJUST block if present
        if ( defined $ast->adjust ) {
            $self->register_method( $class_name, 'ADJUST', 'void', [] );
            $self->lower_adjust( $class_name, $ast->adjust );
        }

        # Lower explicit methods
        for my $m ( $ast->methods->@* ) {
            $self->register_method( $class_name, $m->name, $m->return_type, $m->params );
            $self->lower_method( $class_name, $m );
        }

        # Auto-generate :reader methods
        for my $f ( $ast->fields->@* ) {
            if ( grep { $_ eq 'reader' } $f->attrs->@* ) {
                my $mname = $f->name;
                $self->register_method( $class_name, $mname, $f->type, [] );
                $self->generate_reader( $class_name, $f );
            }
        }

        # Auto-generate :writer methods
        for my $f ( $ast->fields->@* ) {
            if ( grep { $_ eq 'writer' } $f->attrs->@* ) {
                my $mname  = 'set_' . $f->name;
                my @params = ( { type => $f->type, sigil => '$', name => 'value' } );
                $self->register_method( $class_name, $mname, 'void', \@params );
                $self->generate_writer( $class_name, $f );
            }
        }

        # Auto-generate constructor from :param fields
        {
            my @param_fields = grep {
                my $ff = $_;
                grep { $_ eq 'param' } $ff->attrs->@*
            } $ast->fields->@*;
            my $ctor_name = $class_name . '::new';
            my $ret_type  = 'void';
            my @params;
            for my $pf (@param_fields) {
                push @params, { type => $pf->type, sigil => '$', name => $pf->name };
            }
            $self->register_function_raw( $ctor_name, $ret_type, \@params );
            $self->generate_constructor( $class_name, $ast->fields, \@param_fields, $ast->adjust );
        }
        $current_class = undef;
    }

    # === Register built-in FFI functions ===
    method _puts_name() {
        return $self->platform && $self->platform->is_windows ? '_puts' : 'puts';
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

    # === Pass 1: Register declarations ===
    method register_class($ast) {
        my @fields;
        my $offset = 0;
        my @field_types;
        my @field_names;
        my @field_offsets;
        for my $f ( $ast->fields->@* ) {
            my $ir_type = $self->type_from_name( $f->type );
            push @field_types,   $ir_type;
            push @field_names,   $f->name;
            push @field_offsets, $offset;
            push @fields, { name => $f->name, type => $f->type, ir_type => $ir_type, offset => $offset, size => $self->type_size($ir_type), };
            $offset += $self->type_size($ir_type);
        }
        my $struct_type = Brocken::Lindsay::IR::Type->new(
            kind           => 'struct',
            struct_name    => $ast->name,
            field_types    => \@field_types,
            field_names    => \@field_names,
            _field_offsets => \@field_offsets,
            bits           => $offset * 8,
            signed         => 0,
        );
        $classes->{ $ast->name } = { fields => \@fields, total_size => $offset, methods => [], adjust => undef, struct_type => $struct_type, };
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
            push @params, Brocken::Lindsay::IR::Value->new( type => $self->type_from_name( $p->{type} ), name => '%' . $p->{name}, );
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
            push @params, Brocken::Lindsay::IR::Value->new( type => $self->type_from_name( $p->{type} ), name => '%' . $p->{name}, );
        }
        my $fn = Brocken::Lindsay::IR::Function->new( name => $name, return_type => $ret_type, params => \@params, );
        $module->add_function($fn);
        $functions->{$name} = $fn;
    }

    # === Pass 2: Lower function bodies ===
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
            my $ptype  = $ast->params->[$i]{type} // 'Any';
            my $alloca = $builder->build_alloca( $p->type, '%' . $pname . '.addr', undef, 0, 0, $pname, $ptype );
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

    # === Block lowering ===
    method lower_block_body($block_ast) {
        for my $stmt ( $block_ast->statements->@* ) {
            $self->lower_statement($stmt);
        }
    }

    # === Statement lowering ===
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
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $alloca = $builder->build_alloca( $ir_type, '%' . $ast->name . '.addr', undef, $line, $col, $ast->name, $ast->type );
        $symbols->{ $ast->name } = $alloca;
        if ( defined $ast->init ) {
            if ( $ast->init->isa('Brocken::Katsuro::AST::Expr::MethodCall') &&
                $ast->init->method eq 'new' &&
                $ast->init->obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
                $var_class->{ $ast->name } = $ast->init->obj->name;
            }
            my $val = $self->lower_expression( $ast->init );
            $val = $self->maybe_convert_type( $val, $ir_type );
            $builder->build_store( $val, $alloca, $line, $col );
        }
    }

    method lower_assign($ast) {
        my $target = $ast->target;
        my ( $line, $col ) = ( $ast->line, $ast->col );
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
            my $existing = $builder->build_load( $stored_type, $addr, undef, $line, $col );
            my $zero     = Brocken::Lindsay::IR::Constant->new( type => $stored_type, value => 0 );
            my $is_undef = $builder->build_icmp( 'eq', $existing, $zero, undef, $line, $col );
            my $new_val  = $builder->build_select( $is_undef, $val, $existing, undef, $line, $col );
            $builder->build_store( $new_val, $addr, $line, $col );
        }
        else {
            $builder->build_store( $val, $addr, $line, $col );
        }
    }

    method lower_return($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        if ( defined $ast->expr ) {
            my $val      = $self->lower_expression( $ast->expr );
            my $ret_type = $current_func->return_type;
            $val = $self->maybe_convert_type( $val, $ret_type );
            $builder->build_ret( $val, $line, $col );
        }
        else {
            $builder->build_ret( undef, $line, $col );
        }
    }

    method lower_if($ast) {
        my $parent_block = $current_block;
        my $func         = $current_func;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $then_block  = $func->append_block( $self->unique_block_name('then') );
        my $merge_block = $func->append_block( $self->unique_block_name('if_end') );
        my $else_block;
        my $has_else = defined $ast->else || $ast->elsif->@* > 0;
        my $cond     = $self->as_condition( $self->lower_expression( $ast->cond ), $line, $col );

        if ($has_else) {
            $else_block = $func->append_block( $self->unique_block_name('else') );
            $builder->position_at_end($parent_block);
            $builder->build_cond_br( $cond, $then_block, $else_block, $line, $col );
        }
        else {
            $builder->position_at_end($parent_block);
            $builder->build_cond_br( $cond, $then_block, $merge_block, $line, $col );
        }
        $builder->position_at_end($then_block);
        $current_block = $then_block;
        $self->lower_block_body( $ast->then );
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
                $self->lower_block_body( $ast->else );
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
        $self->lower_block_body($body);
        unless ( $current_block->terminator ) {
            $builder->build_br( $merge_block, $line, $col );
        }
        if ( $next->name ne 'if_end' ) {
            $builder->position_at_end($next);
            $current_block = $next;
            $self->lower_elsif_chain( $all_pairs->[$next_idx], $merge_block, $all_pairs, $next_idx );
        }
    }

    method lower_while($ast) {
        my $func = $current_func;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $header = $func->append_block( $self->unique_block_name('while_header') );
        my $body   = $func->append_block( $self->unique_block_name('while_body') );
        my $exit   = $func->append_block( $self->unique_block_name('while_end') );
        $builder->position_at_end($current_block);
        $builder->build_br( $header, $line, $col );
        $builder->position_at_end($header);
        $current_block = $header;
        my $cond = $self->as_condition( $self->lower_expression( $ast->cond ), $line, $col );
        $builder->build_cond_br( $cond, $body, $exit, $line, $col );
        $builder->position_at_end($body);
        $current_block = $body;
        $self->lower_block_body( $ast->body );

        unless ( $current_block->terminator ) {
            $builder->build_br( $header, $line, $col );
        }
        $builder->position_at_end($exit);
        $current_block = $exit;
    }

    # === Expression lowering ===
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
        if ( $ast->type eq 'String' ) {
            my $label = '__str_' . $_rodata_label_counter++;
            $rodata->{$label} = $ast->value . "\0";
            return Brocken::Lindsay::IR::RodataRef->new( label => $label, bytes => $ast->value . "\0", type => Brocken::Lindsay::IR::Type::ptr(), );
        }
        return Brocken::Lindsay::IR::Constant->new( type => $self->native_type_from_name( $ast->type ), value => $ast->value, );
    }

    method lower_var_ref($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );

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
        return $builder->build_load( $loaded_type, $sym, undef, $line, $col );
    }

    method lower_array_decl($ast) {
        my $ir_type  = $self->type_from_name( $ast->elem_type );
        my $size_val = $self->lower_expression( $ast->size_expr );
        my $key      = '@' . $ast->name;
        my $alloca   = $builder->build_alloca( $ir_type, '%' . $key . '.addr', $size_val, $ast->line, $ast->col, $ast->name, $ast->elem_type );
        $symbols->{$key} = $alloca;
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
            $array_base = $sym;
            $elem_type  = $sym->allocated_type;
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

    method lower_binop($ast) {
        my $lhs = $self->lower_expression( $ast->lhs );
        my $rhs = $self->lower_expression( $ast->rhs );
        my $op  = $ast->op;
        my ( $line, $col ) = ( $ast->line, $ast->col );

        # Unbox dynamic operands to i64 for arithmetic/comparison
        my $native = Brocken::Lindsay::IR::Type::i64();
        if ( $lhs->type->kind eq 'dynamic' || $rhs->type->kind eq 'dynamic' ) {
            $lhs = $self->maybe_convert_type( $lhs, $native );
            $rhs = $self->maybe_convert_type( $rhs, $native );
        }
        return $builder->build_add( $lhs, $rhs, undef, $line, $col ) if $op eq '+';
        return $builder->build_sub( $lhs, $rhs, undef, $line, $col ) if $op eq '-';
        return $builder->build_mul( $lhs, $rhs, undef, $line, $col ) if $op eq '*';
        if ( $op eq '/' ) {
            return $lhs->type->is_signed ? $builder->build_div( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_udiv( $lhs, $rhs, undef, $line, $col );
        }
        if ( $op eq '%' ) {
            return $lhs->type->is_signed ? $builder->build_rem( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_urem( $lhs, $rhs, undef, $line, $col );
        }
        return $builder->build_shl( $lhs, $rhs, undef, $line, $col ) if $op eq '<<';
        if ( $op eq '>>' ) {
            return $lhs->type->is_signed ? $builder->build_ashr( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_lshr( $lhs, $rhs, undef, $line, $col );
        }
        return $builder->build_and( $lhs, $rhs, undef, $line, $col )        if $op eq '&&';
        return $builder->build_or( $lhs, $rhs, undef, $line, $col )         if $op eq '||';
        return $builder->build_icmp( 'eq', $lhs, $rhs, undef, $line, $col ) if $op eq '==';
        return $builder->build_icmp( 'ne', $lhs, $rhs, undef, $line, $col ) if $op eq '!=';
        if ( $op eq '<' ) {
            return $builder->build_icmp( $lhs->type->is_signed ? 'slt' : 'ult', $lhs, $rhs, undef, $line, $col );
        }
        if ( $op eq '>' ) {
            return $builder->build_icmp( $lhs->type->is_signed ? 'sgt' : 'ugt', $lhs, $rhs, undef, $line, $col );
        }
        if ( $op eq '<=' ) {
            return $builder->build_icmp( $lhs->type->is_signed ? 'sle' : 'ule', $lhs, $rhs, undef, $line, $col );
        }
        if ( $op eq '>=' ) {
            return $builder->build_icmp( $lhs->type->is_signed ? 'sge' : 'uge', $lhs, $rhs, undef, $line, $col );
        }
        Carp::croak( "Unknown binary operator '$op' at " . $self->_loc($ast) );
    }

    method lower_unop($ast) {
        my $operand = $self->lower_expression( $ast->expr );
        my $op      = $ast->op;
        my ( $line, $col ) = ( $ast->line, $ast->col );

        # Unbox dynamic operands to i64 before unary ops
        if ( $operand->type->kind eq 'dynamic' ) {
            $operand = $self->maybe_convert_type( $operand, Brocken::Lindsay::IR::Type::i64() );
        }
        return $builder->build_neg( $operand, undef, $line, $col ) if $op eq '-';
        if ( $op eq '!' ) {
            my $zero = Brocken::Lindsay::IR::Constant->new( type => $operand->type, value => 0 );
            return $builder->build_icmp( 'eq', $operand, $zero, undef, $line, $col );
        }
        Carp::croak( "Unknown unary operator '$op' at " . $self->_loc($ast) );
    }

    method lower_call_expr($ast) {
        my $name   = $ast->func_name;
        my $callee = $functions->{$name};
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
        return $builder->build_call( $callee, \@args, $ret_is_void ? undef : '%' . $name . '_res', $line, $col );
    }

    method lower_intrinsic($ast) {
        my $name = $ast->name;
        my @args;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        for my $arg ( $ast->args->@* ) {
            push @args, $self->lower_expression($arg);
        }
        return $builder->build_add( $args[0], $args[1], undef, $line, $col )                           if $name eq 'ptr_add';
        return $builder->build_sub( $args[0], $args[1], undef, $line, $col )                           if $name eq 'ptr_sub';
        return $builder->build_icmp( 'sgt', $args[0], $args[1], undef, $line, $col )                   if $name eq 'ptr_cmp_gt';
        return $builder->build_icmp( 'slt', $args[0], $args[1], undef, $line, $col )                   if $name eq 'ptr_cmp_lt';
        return $builder->build_icmp( 'eq', $args[0], $args[1], undef, $line, $col )                    if $name eq 'ptr_cmp_eq';
        return $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $args[0], undef, $line, $col ) if $name eq 'load_i64';
        if ( $name eq 'store_i64' ) {
            $builder->build_store( $args[1], $args[0], $line, $col );
            return undef;
        }
        return $builder->build_load( Brocken::Lindsay::IR::Type::i32(), $args[0], undef, $line, $col ) if $name eq 'load_i32';
        if ( $name eq 'store_i32' ) {
            $builder->build_store( $args[1], $args[0], $line, $col );
            return undef;
        }
        return $builder->build_and( $args[0], $args[1], undef, $line, $col )  if $name eq 'band';
        return $builder->build_or( $args[0], $args[1], undef, $line, $col )   if $name eq 'bor';
        return $builder->build_xor( $args[0], $args[1], undef, $line, $col )  if $name eq 'bxor';
        return $builder->build_shl( $args[0], $args[1], undef, $line, $col )  if $name eq 'shl';
        return $builder->build_lshr( $args[0], $args[1], undef, $line, $col ) if $name eq 'shr';
        return $builder->build_syscall( \@args, undef, $line, $col )          if $name eq 'syscall';
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
            return $builder->build_call( $extern_fn, \@call_args, undef, $line, $col );
        }
        Carp::croak( "Unknown intrinsic '$name' at " . $self->_loc($ast) );
    }

    # === Condition conversion ===
    method as_condition( $val, $line = 0, $col = 0 ) {
        return $val if $val->type->bits == 1;

        # Unbox dynamic to i64 before comparing against zero
        if ( $val->type->kind eq 'dynamic' ) {
            $val = $self->maybe_convert_type( $val, Brocken::Lindsay::IR::Type::i64(), $line, $col );
        }
        my $zero = Brocken::Lindsay::IR::Constant->new( type => $val->type, value => 0 );
        return $builder->build_icmp( 'ne', $val, $zero, undef, $line, $col );
    }

    # === Type conversion helper ===
    method maybe_convert_type( $val, $target_type, $line = 0, $col = 0 ) {
        return $val if $val->type->kind eq $target_type->kind && $val->type->bits == $target_type->bits;

        # Box: native -> dynamic
        if ( $target_type->kind eq 'dynamic' && $val->type->kind ne 'dynamic' ) {
            return $builder->build_box( $val, undef, $line, $col );
        }

        # Unbox: dynamic -> native
        if ( $val->type->kind eq 'dynamic' && $target_type->kind ne 'dynamic' ) {
            return $builder->build_unbox( $val, $target_type, undef, $line, $col );
        }

        # Integer widening: zero-extend for unsigned, sign-extend for signed
        if ( $val->type->kind eq 'int' && $target_type->kind eq 'int' ) {
            if ( $val->type->bits < $target_type->bits ) {
                return $val->type->is_signed ? $builder->build_sext( $val, $target_type, undef, $line, $col ) :
                    $builder->build_zext( $val, $target_type, undef, $line, $col );
            }
        }
        $val;
    }

    # === Class field helpers ===
    method resolve_class_name($ast) {
        my $obj = $ast->obj;
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
            Carp::croak( "Unknown class '" . $obj->name . "' at " . $self->_loc($obj) ) unless $classes->{ $obj->name };
            return $obj->name;
        }
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Var') && exists $var_class->{ $obj->name } ) {
            return $var_class->{ $obj->name };
        }
        if ( $obj->isa('Brocken::Katsuro::AST::Expr::Call') && exists $function_return_class->{ $obj->func_name } ) {
            return $function_return_class->{ $obj->func_name };
        }
        Carp::croak( "Cannot determine class for field or method access at " . $self->_loc($ast) ) unless $current_class;
        return $current_class;
    }

    method lower_field_addr($ast) {
        my $obj_ptr     = $self->lower_expression( $ast->obj );
        my $class_name  = $self->resolve_class_name($ast);
        my $cd          = $classes->{$class_name};
        my $struct_type = $cd->{struct_type};
        my $field_idx;
        my ( $line, $col ) = ( $ast->line, $ast->col );
        for my $i ( 0 .. $cd->{fields}->@* - 1 ) {
            if ( $cd->{fields}[$i]{name} eq $ast->field ) {
                $field_idx = $i;
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
        my ($field)    = grep { $_->{name} eq $ast->field } $cd->{fields}->@*;
        return $builder->build_load( $field->{ir_type}, $field_ptr, undef, $ast->line, $ast->col );
    }

    method lower_method_call($ast) {
        my $class_name   = $self->resolve_class_name($ast);
        my $obj_is_class = $ast->obj->isa('Brocken::Katsuro::AST::Expr::Ident');
        my $full_name    = $class_name . '::' . $ast->method;
        my $callee       = $functions->{$full_name};
        my ( $line, $col ) = ( $ast->line, $ast->col );
        Carp::croak( "Undefined method '" . $ast->method . "' in class '" . $class_name . "' at " . $self->_loc($ast) ) unless $callee;
        if ( $obj_is_class && $ast->method eq 'new' ) {
            my $cd         = $classes->{$class_name};
            my $total_size = $cd->{total_size};
            my $self_ptr;
            if ( exists $symbols->{'__heap_base'} ) {
                my $bump_alloc_fn = $functions->{'Brocken::Runtime::bump_alloc'};
                Carp::croak( "Runtime function bump_alloc not found at " . $self->_loc($ast) ) unless $bump_alloc_fn;
                my $heap_base  = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
                my $size_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $total_size );
                $self_ptr = $builder->build_call( $bump_alloc_fn, [ $heap_base, $size_const ], '%obj', $line, $col );
            }
            else {
                my $struct_type = Brocken::Lindsay::IR::Type->new( kind => 'int', bits => $total_size * 8 );
                $self_ptr = $builder->build_alloca( $struct_type, '%obj', undef, $line, $col );
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
            $builder->build_call( $callee, \@args, undef, $line, $col );
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
        return $builder->build_call( $callee, \@args, $ret_is_void ? undef : '%' . $ast->method . '_res', $line, $col );
    }

    method lower_class_const($ast) {
        Carp::croak( "__CLASS__ used outside of a class at " . $self->_loc($ast) ) unless $current_class;
        return Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => $current_class, );
    }

    # === Method body lowering with field GEP pre-population ===
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
            my $ptype  = $method_ast->params->[$i]{type} // 'Any';
            my $alloca = $builder->build_alloca( $p->type, '%' . $pname . '.addr', undef, 0, 0, $pname, $ptype );
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
        my $struct_type = $cd->{struct_type};
        for my $i ( 0 .. $cd->{fields}->@* - 1 ) {
            my $fd        = $cd->{fields}[$i];
            my $field_ptr = $builder->build_struct_gep( $struct_type, $self_val, $i, '%' . $fd->{name} . '.addr' );
            $symbols->{ $fd->{name} } = $field_ptr;
        }
    }

    # === Auto-generated accessor and constructor lowering ===
    method generate_reader( $class_name, $field_ast ) {
        my $full_name = $class_name . '::' . $field_ast->name;
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $current_func->set_blocks( [] );
        my $entry = $current_func->append_block('entry');
        $builder->position_at_end($entry);
        $current_block = $entry;
        my $self_val    = $current_func->params->[0];
        my $cd          = $classes->{$class_name};
        my $struct_type = $cd->{struct_type};
        my $field_idx;

        for my $i ( 0 .. $cd->{fields}->@* - 1 ) {
            if ( $cd->{fields}[$i]{name} eq $field_ast->name ) {
                $field_idx = $i;
                last;
            }
        }
        my ($fd)      = grep { $_->{name} eq $field_ast->name } $cd->{fields}->@*;
        my $field_ptr = $builder->build_struct_gep( $struct_type, $self_val, $field_idx, '%' . $fd->{name} . '.addr' );
        my $loaded    = $builder->build_load( $fd->{ir_type}, $field_ptr );
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
        my $self_val    = $current_func->params->[0];
        my $value_val   = $current_func->params->[1];
        my $cd          = $classes->{$class_name};
        my $struct_type = $cd->{struct_type};
        my $field_idx;

        for my $i ( 0 .. $cd->{fields}->@* - 1 ) {
            if ( $cd->{fields}[$i]{name} eq $field_ast->name ) {
                $field_idx = $i;
                last;
            }
        }
        my ($fd) = grep { $_->{name} eq $field_ast->name } $cd->{fields}->@*;
        my $field_ptr = $builder->build_struct_gep( $struct_type, $self_val, $field_idx, '%' . $fd->{name} . '.addr' );
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
        my $cd          = $classes->{$class_name};
        my $struct_type = $cd->{struct_type};
        my $self_ptr    = $current_func->params->[0];

        # Initialize fields: defaults first, then params override
        my $param_idx = 0;
        for my $i ( 0 .. $all_fields->@* - 1 ) {
            my $f         = $all_fields->[$i];
            my ($fd)      = grep { $_->{name} eq $f->name } $cd->{fields}->@*;
            my $field_ptr = $builder->build_struct_gep( $struct_type, $self_ptr, $i, '%' . $f->name . '.init' );
            my $is_param  = grep { $_ eq 'param' } $f->attrs->@*;
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

=head1 NAME

Brocken::Katsuro::Lowerer - AST-to-IR lowering pass

=head1 DESCRIPTION

Walks the Katsuro AST produced by the parser and emits Lindsay IR instructions. Handles variable declarations (with
debug name/type tagging), function definitions, control flow (if/while/return), operator lowering, class registration
(building B<class_info> struct metadata), and runtime integration.

=head1 FIELDS

=over

=item C<$classes :reader>

Hashref of class definitions populated during lowering. Each key is a class name; each value is a hashref with
C<fields> (array of C<< { name, type } >>). Attached to the IR Module via C<set_class_info> after lowering completes.

=item C<$functions :reader>

Hashref of lowered IR functions keyed by name. Used internally for call resolution.

=back

=head1 METHODS

=head2 lower_program( $ast )

Accepts a L<Brocken::Katsuro::AST::Program> and returns a L<Brocken::Lindsay::IR::Module> containing all lowered
functions, global variables, and class metadata.

=cut

1;
