use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Lindsay::IR;
use Brocken::Lindsay::IR::Builder;
use Brocken::ICB;
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
    field $needs_rc              = {};    # var_name -> 1 (Any-typed variable needing refcounting)
    field $rodata : reader       = {};    # label -> bytes for string constants
    field $_rodata_label_counter = 0;
    field $_loop_header_blocks   = [];    # stack of header block labels
    field $_loop_check_blocks    = [];    # stack of iteration-check block labels (counter guard)
    field $_loop_exit_blocks     = [];    # stack of exit block labels for break (last)
    field $fuel_exit_block;               # set in lower_function, used by call-site fuel checks

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
        Float  => Brocken::Lindsay::IR::Type::f64(),
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

    # === Return type inference ===
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
            my $ret_type = $m->return_type;
            if ( !defined $ret_type ) {
                $ret_type = $self->_infer_return_type($m);
            }
            $self->register_method( $class_name, $m->name, $ret_type, $m->params );
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
        $current_class = undef;
    }

    # === Register built-in FFI functions ===
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
        if ( $kind eq 'int' ) {
            my $sprintf_arg = $val;
            my $to_str_fn;
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
                Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
            ],
        );
        $builder->build_call( $sprintf_fn, [ $buf, $fmt_ref, $sprintf_arg ], undef, $line, $col );
        return $buf;
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
            push @fields,
                {
                name       => $f->name,
                type       => $f->type,
                ir_type    => $ir_type,
                offset     => $offset,
                size       => $self->type_size($ir_type),
                idx        => $#fields + 1,
                default    => $f->default,
                default_op => $f->default_op,
                };
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
        my $ret_type_name = $ast->return_type;
        if ( !defined $ret_type_name ) {
            $ret_type_name = $self->_infer_return_type($ast);
        }
        my $ret_class = $classes->{$ret_type_name} ? $ret_type_name : undef;
        $ret_type_name = $classes->{$ret_type_name} ? 'ptr' : $ret_type_name;
        $function_return_class->{ $ast->name } = $ret_class;
        my $ret_type = $self->type_from_name($ret_type_name);
        my @params;
        unless ( $ast->name =~ /^Brocken::Runtime::/ ) {
            push @params, Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%__heap_base', );
            unless ( $ast->name eq '_BROCKEN_ENTRY' ) {
                push @params, Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i64(), name => '%__want', );
            }
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
        my @params   = (
            Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%__heap_base', ),
            Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i64(), name => '%__want', ),
            Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr(), name => '%self', ),
        );
        for my $p ( $params_ast->@* ) {
            push @params, Brocken::Lindsay::IR::Value->new( type => $self->type_from_name( $p->{type} ), name => '%' . $p->{name}, );
        }
        my $fn = Brocken::Lindsay::IR::Function->new( name => $name, return_type => $ret_type, params => \@params, );
        $module->add_function($fn);
        $functions->{$name} = $fn;
    }

    # === Pass 2: Lower function bodies ===
    method lower_function($ast) {
        $fuel_exit_block = undef;
        return if $ast->body->statements->@* == 0;
        $current_func = $functions->{ $ast->name };
        $symbols      = {};
        $needs_rc     = {};
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
                my $heap_size = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 0x100000 );
                $builder->build_call( $_init_fn, [ $heap_base, $heap_size ], undef );
            }

            # Initialize fuel at [hb+FUEL] to default_fuel
            my $default_fuel = $Brocken::default_fuel // 1000000;
            my $fuel_const   = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $default_fuel );
            my $hb_fuel      = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            my $fuel_off     = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::FUEL );
            my $fuel_addr    = $builder->build_add( $hb_fuel, $fuel_off );
            $builder->build_store( $fuel_const, $fuel_addr );

            # Initialize memory_limit at [hb+MEMORY_LIMIT]
            my $mem_limit_val   = $Brocken::default_mem_limit // 0;
            my $mem_limit_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $mem_limit_val );
            my $hb_mem          = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} );
            my $mem_off = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => Brocken::ICB::MEMORY_LIMIT );
            my $mem_limit_addr = $builder->build_add( $hb_mem, $mem_off );
            $builder->build_store( $mem_limit_const, $mem_limit_addr );

            # Initialize capabilities at [hb+CAPABILITIES]
            my $caps_val   = $Brocken::default_capabilities // ~0;
            my $caps_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $caps_val );
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
                $needs_rc->{$pname} = 1;
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
                my $addr   = $symbols->{$name} or next;
                my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::i64(), $addr );
                $builder->build_decref( $loaded, 0, 0, $decref_hb );
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
            my $err_code_val  = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 2 );
            $builder->build_store( $err_code_val, $err_code_addr );
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

    # Lower a block with block-scoped RC cleanup.
    # Variables declared as `Any` inside the block are decref'd at block exit,
    # not at function exit.  Early return, last, or next from inside the block
    # bypasses this cleanup; those paths rely on the function-scoped decref loop.
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
            my $addr   = $symbols->{$name} or next;
            my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::i64(), $addr );
            $builder->build_decref( $loaded, 0, 0, $decref_hb );
            delete $needs_rc->{$name};
        }
    }

    # === Statement lowering ===
    method lower_statement($stmt) {
        return unless defined $stmt;
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::VarDecl') )       { return $self->lower_var_decl($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ArrayDecl') )     { return $self->lower_array_decl($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Assign') )        { return $self->lower_assign($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::ListVarDecl') )   { return $self->lower_list_var_decl($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Return') )        { return $self->lower_return($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::If') )            { return $self->lower_if($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::While') )         { return $self->lower_while($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Break') )         { return $self->lower_break($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Continue') )      { return $self->lower_continue($stmt); }
        if ( $stmt->isa('Brocken::Katsuro::AST::Stmt::Block') )         { return $self->lower_block($stmt); }
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
            $stmt->isa('Brocken::Katsuro::AST::Expr::MethodCall')  ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::List')        ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Hash')        ||
            $stmt->isa('Brocken::Katsuro::AST::Expr::Ternary') ) {
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
        if ( $ast->type eq 'Any' ) {
            $needs_rc->{ $ast->name } = 1;
        }
        if ( !defined $ast->init && $ast->type eq 'Any' ) {
            my $zero = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 );
            $builder->build_store( $zero, $alloca, $line, $col );
        }
        if ( defined $ast->init ) {
            if ( $ast->init->isa('Brocken::Katsuro::AST::Expr::MethodCall') &&
                $ast->init->method eq 'new' &&
                $ast->init->obj->isa('Brocken::Katsuro::AST::Expr::Ident') ) {
                $var_class->{ $ast->name } = $ast->init->obj->name;
            }
            my $val = $self->lower_expression( $ast->init );
            $val = $self->maybe_convert_type( $val, $ir_type );
            if ( $needs_rc->{ $ast->name } ) {
                $builder->build_incref( $val, $line, $col );
            }
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
            my $is_rc = $target->isa('Brocken::Katsuro::AST::Expr::Var') && $needs_rc->{ $target->name };
            if ($is_rc) {
                my $old = $builder->build_load( $stored_type, $addr, undef, $line, $col );
                $builder->build_incref( $val, $line, $col );
                $builder->build_store( $val, $addr, $line, $col );
                my $decref_hb
                    = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
                $builder->build_decref( $old, $line, $col, $decref_hb );
            }
            else {
                $builder->build_store( $val, $addr, $line, $col );
            }
        }
    }

    method lower_return($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        if ( defined $ast->expr ) {
            my $val      = $self->lower_expression( $ast->expr );
            my $ret_type = $current_func->return_type;
            $val = $self->maybe_convert_type( $val, $ret_type );
            my @rc_names = sort keys %$needs_rc;
            if (@rc_names) {

                # Incref the return value so it survives the decref of all RC locals below.
                # If $val refers to the same object as one of the locals, this bump keeps RC >= 1
                # across the cleanup, preventing a premature free + dangling pointer.
                # Only applies when $val is an Any type (heap-allocated with RC).
                if ( $val->type && $val->type->kind eq 'any' ) {
                    $builder->build_incref( $val, $line, $col );
                }
                my $hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
                for my $name (@rc_names) {
                    my $addr   = $symbols->{$name} or next;
                    my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::i64(), $addr );
                    $builder->build_decref( $loaded, 0, 0, $hb );
                }
            }
            $builder->build_ret( $val, $line, $col );
        }
        else {
            my @rc_names = sort keys %$needs_rc;
            if (@rc_names) {
                my $decref_hb
                    = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
                for my $name (@rc_names) {
                    my $addr   = $symbols->{$name} or next;
                    my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::i64(), $addr );
                    $builder->build_decref( $loaded, 0, 0, $decref_hb );
                }
            }
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
        $self->lower_block_body( $ast->body );
        unless ( $current_block->terminator ) {
            $builder->build_br( $header, $line, $col );
        }
        pop $_loop_header_blocks->@*;
        pop $_loop_check_blocks->@*;
        pop $_loop_exit_blocks->@*;
        $builder->position_at_end($exit);
        $current_block = $exit;
    }

    method lower_break($ast) {
        my $exit = $_loop_exit_blocks->[-1] or Carp::croak( "'last' outside loop at " . $self->_loc($ast) );
        my ( $line, $col ) = ( $ast->line, $ast->col );
        $self->_emit_loop_cleanup();
        $builder->build_br( $exit, $line, $col );
    }

    method lower_continue($ast) {
        my $header = $_loop_header_blocks->[-1] or Carp::croak( "'next' outside loop at " . $self->_loc($ast) );
        my ( $line, $col ) = ( $ast->line, $ast->col );
        $self->_emit_loop_cleanup();
        $builder->build_br( $header, $line, $col );
    }

    # Decref RC-tracked variables before leaving the current block via break/continue.
    method _emit_loop_cleanup() {
        my @rc_names = sort keys %$needs_rc;
        return unless @rc_names;
        my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
        for my $name (@rc_names) {
            my $addr   = $symbols->{$name} or next;
            my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::i64(), $addr );
            $builder->build_decref( $loaded, 0, 0, $decref_hb );
        }
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

    method lower_list_var_decl($ast) {
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $i64_type = Brocken::Lindsay::IR::Type::i64();
        my $ptr_type = Brocken::Lindsay::IR::Type::ptr();
        my @targets  = $ast->targets->@*;
        my $list_ptr = $self->lower_expression( $ast->expr );
        for my $i ( 0 .. $#targets ) {
            my $t       = $targets[$i];
            my $ir_type = $self->type_from_name( $t->{type} );
            my $alloca  = $builder->build_alloca( $ir_type, '%' . $t->{name} . '.addr', undef, $line, $col, $t->{name}, $t->{type} );
            $symbols->{ $t->{name} } = $alloca;
            if ( $t->{type} eq 'Any' ) {
                $needs_rc->{ $t->{name} } = 1;
            }
            my $offset    = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 16 + $i * 8 );
            my $elem_addr = $builder->build_add( $list_ptr, $offset, undef, $line, $col );
            my $elem_raw  = $builder->build_load( $i64_type, $elem_addr, undef, $line, $col );
            my $elem_val  = $self->maybe_convert_type( $elem_raw, $ir_type );
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

        # Unify types for mixed int/float operations: convert RHS to match LHS
        # type.  This ensures the MIR lowerer sees two operands of the same
        # type kind (both float or both int) and can emit the correct opcode
        # (fadd vs add, fcmp vs icmp, etc.).
        if ( $lhs->type->kind ne $rhs->type->kind && $lhs->type->kind ne 'dynamic' && $rhs->type->kind ne 'dynamic' ) {
            $rhs = $self->maybe_convert_type( $rhs, $lhs->type );
        }

        # Shift operations use LHS type for result width regardless of RHS.
        # Dispatch them before width-promotion to avoid widening LHS.
        return $builder->build_shl( $lhs, $rhs, undef, $line, $col ) if $op eq '<<';
        if ( $op eq '>>' ) {
            return $lhs->type->is_signed ? $builder->build_ashr( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_lshr( $lhs, $rhs, undef, $line, $col );
        }

        # Promote narrower operand to match wider type width so the MIR
        # lowerer sees consistent operand widths (critical for i128/halving).
        if ( $lhs->type->kind eq $rhs->type->kind && $lhs->type->bits != $rhs->type->bits && $lhs->type->kind ne 'dynamic' ) {
            if ( $lhs->type->bits < $rhs->type->bits ) {
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
            return $lhs->type->is_signed ? $builder->build_div( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_udiv( $lhs, $rhs, undef, $line, $col );
        }
        if ( $op eq '%' ) {
            return $lhs->type->is_signed ? $builder->build_rem( $lhs, $rhs, undef, $line, $col ) :
                $builder->build_urem( $lhs, $rhs, undef, $line, $col );
        }
        return $builder->build_and( $lhs, $rhs, undef, $line, $col ) if $op eq '&';
        return $builder->build_or( $lhs, $rhs, undef, $line, $col )  if $op eq '|';
        return $builder->build_xor( $lhs, $rhs, undef, $line, $col ) if $op eq '^';
        return $builder->build_and( $lhs, $rhs, undef, $line, $col ) if $op eq '&&';
        return $builder->build_or( $lhs, $rhs, undef, $line, $col )  if $op eq '||';

        # Mixed-signedness comparison: types < 64 bits with different signedness
        # produce wrong results because the codegen loads signed operands with
        # movsx (sign-extend) and unsigned with movzx (zero-extend) into 32-bit
        # registers.  When the CMP uses unsigned predicates, the sign-extended
        # value looks like a huge positive number.  Fix: widen both operands to
        # a common 32-bit type with appropriate extension so the bit patterns
        # match the simulation semantics.
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
        if ( $op eq '.' ) {
            $lhs = $self->_stringify( $lhs, $line, $col );
            $rhs = $self->_stringify( $rhs, $line, $col );
            if ( $lhs->isa('Brocken::Lindsay::IR::RodataRef') && $rhs->isa('Brocken::Lindsay::IR::RodataRef') ) {
                my $combined = substr( $lhs->bytes, 0, -1 ) . $rhs->bytes;
                my ( $label, $bytes ) = $self->_intern_rodata($combined);
                return Brocken::Lindsay::IR::RodataRef->new( label => $label, bytes => $bytes, type => Brocken::Lindsay::IR::Type::ptr(), );
            }
            my $strlen_fn = Brocken::Lindsay::IR::Function->new(
                name        => $self->_crt_name('strlen'),
                return_type => Brocken::Lindsay::IR::Type::i64(),
                params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ) ],
            );
            my $len_l      = $builder->build_call( $strlen_fn, [$lhs], undef, $line, $col );
            my $len_r      = $builder->build_call( $strlen_fn, [$rhs], undef, $line, $col );
            my $total      = $builder->build_add( $len_l, $len_r, undef, $line, $col );
            my $one        = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => 1 );
            my $alloc_size = $builder->build_add( $total, $one, undef, $line, $col );
            my $malloc_fn  = Brocken::Lindsay::IR::Function->new(
                name        => $self->_crt_name('malloc'),
                return_type => Brocken::Lindsay::IR::Type::ptr(),
                params      => [ Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::i64() ) ],
            );
            my $buf       = $builder->build_call( $malloc_fn, [$alloc_size], undef, $line, $col );
            my $strcpy_fn = Brocken::Lindsay::IR::Function->new(
                name        => $self->_crt_name('strcpy'),
                return_type => Brocken::Lindsay::IR::Type::ptr(),
                params      => [
                    Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
                    Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
                ],
            );
            $builder->build_call( $strcpy_fn, [ $buf, $lhs ], undef, $line, $col );
            my $strcat_fn = Brocken::Lindsay::IR::Function->new(
                name        => $self->_crt_name('strcat'),
                return_type => Brocken::Lindsay::IR::Type::ptr(),
                params      => [
                    Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
                    Brocken::Lindsay::IR::Value->new( type => Brocken::Lindsay::IR::Type::ptr() ),
                ],
            );
            $builder->build_call( $strcat_fn, [ $buf, $rhs ], undef, $line, $col );
            return $buf;
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

        # Promote i1 before negation: neg(i1) wraps (-1==1 in 1-bit)
        # but i8(-1) sign-extends correctly to wider types.
        if ( $op eq '-' && $operand->type->kind eq 'int' && $operand->type->bits == 1 ) {
            $operand = $self->maybe_convert_type( $operand, Brocken::Lindsay::IR::Type::i8() );
        }
        return $builder->build_neg( $operand, undef, $line, $col ) if $op eq '-';
        if ( $op eq '!' ) {
            my $zero = Brocken::Lindsay::IR::Constant->new( type => $operand->type, value => 0 );
            return $builder->build_icmp( 'eq', $operand, $zero, undef, $line, $col );
        }
        Carp::croak( "Unknown unary operator '$op' at " . $self->_loc($ast) );
    }

    method _emit_fuel_check( $line, $col ) {

        # Disabled: body-block register-indirect memory access corrupts PE binary.
        # See Bug 9 - call-site fuel check binary corruption.
        # Phase S0 will re-enable with a proper fix.
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
        my $callee_has_heap_base = $callee->params->@* && defined $callee->params->[0]->name && $callee->params->[0]->name eq '%__heap_base';
        if ($callee_has_heap_base) {
            my $hb = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
            push @args, $hb;
        }
        my $callee_has_want
            = $callee_has_heap_base && $callee->params->@* >= 2 && defined $callee->params->[1]->name && $callee->params->[1]->name eq '%__want';
        if ($callee_has_want) {
            my $want_val = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $symbols->{'__want'}, undef, $line, $col );
            push @args, $want_val;
        }
        my $param_idx = ( $callee_has_heap_base ? 1 : 0 ) + ( $callee_has_want ? 1 : 0 );
        for my $arg ( $ast->args->@* ) {
            my $val = $self->lower_expression($arg);
            if ( $param_idx < $callee->params->@* ) {
                $val = $self->maybe_convert_type( $val, $callee->params->[$param_idx]->type );
            }
            push @args, $val;
            $param_idx++;
        }
        $self->_emit_fuel_check( $line, $col );
        return $builder->build_call( $callee, \@args, undef, $line, $col );
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
            my $hb
                = $symbols->{'__heap_base'} ?
                $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col ) :
                undef;
            return $builder->build_box( $val, undef, $line, $col, $hb );
        }

        # Unbox: dynamic -> native
        if ( $val->type->kind eq 'dynamic' && $target_type->kind ne 'dynamic' ) {

            # Reinterpret: dynamic -> ptr is a no-op; Any vars ARE pointers to fat scalars
            return $val if $target_type->kind eq 'ptr';
            return $builder->build_unbox( $val, $target_type, undef, $line, $col );
        }

        # Integer widening: zero-extend for unsigned, sign-extend for signed
        # Integer narrowing: mask to target bit width (AND with mask)
        if ( $val->type->kind eq 'int' && $target_type->kind eq 'int' ) {
            if ( $val->type->bits < $target_type->bits ) {
                if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                    return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => $val->value );
                }
                return ( $val->type->is_signed && $val->type->bits > 1 ) ? $builder->build_sext( $val, $target_type, undef, $line, $col ) :
                    $builder->build_zext( $val, $target_type, undef, $line, $col );
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
                return $builder->build_and( $val, $mask_val, undef, $line, $col );
            }
        }

        # Integer -> float (sitofp)
        if ( $val->type->kind eq 'int' && $target_type->kind eq 'float' ) {
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => 0.0 + $val->value );
            }
            return $builder->build_sitofp( $val, $target_type, undef, $line, $col );
        }

        # Float -> integer (fptosi)
        if ( $val->type->kind eq 'float' && $target_type->kind eq 'int' ) {
            if ( $val->isa('Brocken::Lindsay::IR::Constant') ) {
                return Brocken::Lindsay::IR::Constant->new( type => $target_type, value => int( $val->value ) );
            }
            return $builder->build_fptosi( $val, $target_type, undef, $line, $col );
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
        my ( $line, $col ) = ( $ast->line, $ast->col );
        my $hb       = $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'}, undef, $line, $col );
        my $want_val = $builder->build_load( Brocken::Lindsay::IR::Type::i64(), $symbols->{'__want'},      undef, $line, $col );
        if ( $obj_is_class && $ast->method eq 'new' ) {
            my $cd            = $classes->{$class_name};
            my $total_size    = $cd->{total_size};
            my $bump_alloc_fn = $functions->{'Brocken::Runtime::bump_alloc'};
            Carp::croak( "Runtime function bump_alloc not found at " . $self->_loc($ast) ) unless $bump_alloc_fn;
            my $size_const = Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::i64(), value => $total_size );
            $self->_emit_fuel_check( $line, $col );
            my $self_ptr = $builder->build_call( $bump_alloc_fn, [ $hb, $size_const ], undef, $line, $col );

            # Only named constructors supported: new(x => 100, y => 150)
            my $args = $ast->args;
            Carp::croak("Positional constructors are not supported. Use named syntax: class->new(field => value)")
                unless $args->@* == 1 && $args->[0]->isa('Brocken::Katsuro::AST::Expr::Hash');
            my $hash = $args->[0];
            my %field_idx;
            for my $i ( 0 .. $cd->{fields}->@* - 1 ) {
                $field_idx{ $cd->{fields}[$i]{name} } = $i;
            }
            my %seen;
            for my $pair ( $hash->pairs->@* ) {
                my $key_expr = $pair->{key};
                next unless $key_expr->isa('Brocken::Katsuro::AST::Expr::Const') && $key_expr->type eq 'String';
                my $field_name = $key_expr->value;
                my $fi         = $field_idx{$field_name};
                Carp::croak( "Unknown field '$field_name' in class '$class_name' at " . $self->_loc($ast) ) unless defined $fi;
                my $fd  = $cd->{fields}[$fi];
                my $val = $self->lower_expression( $pair->{value} );
                $val = $self->maybe_convert_type( $val, $fd->{ir_type} );
                my $field_ptr = $builder->build_struct_gep( $cd->{struct_type}, $self_ptr, $fi, '%' . $fd->{name} . '.init', $line, $col );
                $builder->build_store( $val, $field_ptr, $line, $col );
                $seen{$field_name} = 1;
            }
            for my $f ( $cd->{fields}->@* ) {
                next if $seen{ $f->{name} };
                next unless defined $f->{default};
                my $default_val = $self->lower_expression( $f->{default} );
                $default_val = $self->maybe_convert_type( $default_val, $f->{ir_type} );
                my $field_ptr = $builder->build_struct_gep( $cd->{struct_type}, $self_ptr, $f->{idx}, '%' . $f->{name} . '.default', $line, $col );
                $builder->build_store( $default_val, $field_ptr, $line, $col );
            }
            my $adjust_fn = $functions->{ $class_name . '::ADJUST' };
            if ($adjust_fn) {
                $builder->build_call( $adjust_fn, [ $hb, $want_val, $self_ptr ], undef, $line, $col );
            }
            return $self_ptr;
        }
        my $callee = $functions->{$full_name};
        Carp::croak( "Undefined method '" . $ast->method . "' in class '" . $class_name . "' at " . $self->_loc($ast) ) unless $callee;
        my $obj_ptr = $obj_is_class ? Brocken::Lindsay::IR::Constant->new( type => Brocken::Lindsay::IR::Type::ptr(), value => 0 ) :
            $self->lower_expression( $ast->obj );
        my @args      = ( $hb, $want_val, $obj_ptr );
        my $param_idx = 3;
        for my $arg ( $ast->args->@* ) {
            my $val = $self->lower_expression($arg);
            if ( $param_idx < $callee->params->@* ) {
                $val = $self->maybe_convert_type( $val, $callee->params->[$param_idx]->type );
            }
            push @args, $val;
            $param_idx++;
        }
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
        my $i64_type = Brocken::Lindsay::IR::Type::i64();
        my $ptr_type = Brocken::Lindsay::IR::Type::ptr();
        my @elements;
        for my $elem ( $ast->elements->@* ) {
            push @elements, $self->lower_expression($elem);
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
        my $i64_type   = Brocken::Lindsay::IR::Type::i64();
        my $ptr_type   = Brocken::Lindsay::IR::Type::ptr();
        my @pairs      = $ast->pairs->@*;
        my $pair_count = scalar @pairs;
        my @keys;
        my @vals;
        for my $pair (@pairs) {
            push @keys, $self->lower_expression( $pair->{key} );
            push @vals, $self->lower_expression( $pair->{value} );
        }
        my $hb            = $builder->build_load( $ptr_type, $symbols->{'__heap_base'}, undef, $line, $col );
        my $total_size    = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 16 + $pair_count * 16 );
        my $bump_alloc_fn = $functions->{'Brocken::Runtime::bump_alloc'};
        Carp::croak( "Runtime function bump_alloc not found at " . $self->_loc($ast) ) unless $bump_alloc_fn;
        my $hash_ptr   = $builder->build_call( $bump_alloc_fn, [ $hb, $total_size ], undef, $line, $col );
        my $header_val = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 8 << 24 );
        $builder->build_store( $header_val, $hash_ptr, $line, $col );
        my $count_val  = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => $pair_count );
        my $count_addr = $builder->build_add( $hash_ptr, Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 8 ), undef, $line, $col );
        $builder->build_store( $count_val, $count_addr, $line, $col );

        for my $i ( 0 .. $#pairs ) {
            my $key_offset = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 16 + $i * 16 );
            my $val_offset = Brocken::Lindsay::IR::Constant->new( type => $i64_type, value => 16 + $i * 16 + 8 );
            my $key_addr   = $builder->build_add( $hash_ptr, $key_offset, undef, $line, $col );
            my $val_addr   = $builder->build_add( $hash_ptr, $val_offset, undef, $line, $col );
            $builder->build_store( $keys[$i], $key_addr, $line, $col );
            $builder->build_store( $vals[$i], $val_addr, $line, $col );
        }
        return $hash_ptr;
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
        $symbols  = {};
        $needs_rc = {};
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
                $needs_rc->{$pname} = 1;
            }
        }
        $self->lower_block_body( $method_ast->body );
        unless ( $current_block && $current_block->terminator ) {
            my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
            for my $name ( sort keys %$needs_rc ) {
                my $addr   = $symbols->{$name} or next;
                my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::i64(), $addr );
                $builder->build_decref( $loaded, 0, 0, $decref_hb );
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

    method lower_adjust( $class_name, $adjust_ast ) {
        my $full_name = $class_name . '::ADJUST';
        $current_func = $functions->{$full_name};
        return unless $current_func;
        $symbols  = {};
        $needs_rc = {};
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
        $self->lower_block_body( $adjust_ast->body );
        unless ( $current_block && $current_block->terminator ) {
            my $decref_hb = $symbols->{'__heap_base'} ? $builder->build_load( Brocken::Lindsay::IR::Type::ptr(), $symbols->{'__heap_base'} ) : undef;
            for my $name ( sort keys %$needs_rc ) {
                my $addr   = $symbols->{$name} or next;
                my $loaded = $builder->build_load( $addr->allocated_type // Brocken::Lindsay::IR::Type::i64(), $addr );
                $builder->build_decref( $loaded, 0, 0, $decref_hb );
            }
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
        my $self_val    = $current_func->params->[2];
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
        my $self_val    = $current_func->params->[2];
        my $value_val   = $current_func->params->[3];
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
