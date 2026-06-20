# Extending Brocken

This guide covers adding new features to the Brocken compiler.

## Adding new keywords

For this example, let's look at how the `defer` keyword is implemented.

### 1. Add to the Lexer
Update `%KEYWORDS` in `Brocken::Katsuro::Lexer`.

### 2. Update the AST
Add a new AST node class in `Brocken::Katsuro::AST`:
```perl
class Brocken::Katsuro::AST::Stmt::Defer : isa(Brocken::Katsuro::AST::Node) {
    field $block : param : reader;
}
```

### 3. Update the Parser
Register the handler in `%STMT_HANDLERS` in `Parser.pm`:
```perl
method _parse_defer() {
    $self->advance(); # Consumes 'defer'
    my $block = $self->_parse_block_stmt();
    return Brocken::Katsuro::AST::Stmt::Defer->new( block => $block );
}
```

### 4. Update Lowering.pm
Add the defer stack and logic. Defer works by saving a stream of instructions and re-emitting them at scope exit.
```perl
method lower_Defer($node) {
    my @saved = $builder->instructions;
    $builder->set_instructions();
    $self->lower($node->block);
    my @deferred = $builder->instructions;
    $builder->set_instructions(@saved);
    push @defer_stack, \@deferred;
    return (undef, 'void');
}
```

## Adding an IR Instruction

1. Pick a descriptive name (`incref`, `load_field`).
2. Emit it from Lowering: `$builder->emit( 'incref', 'void', [ $val ] );`
3. Add an `elsif` branch to `emit_op` in each `Jenny::Lowerer::*` module to map it to MIR.

## The Self-Hosted Standard Library (`core.brocken`)

The Brocken runtime (`libbrocken`) is not injected as hardcoded MIR strings by the compiler. **It is written in Brocken.**

During initialization, the compiler transparently parses and compiles `src/runtime/core.brocken`, combining its AST with the user's AST.

### Replacing or Extending the GC
Because the GC lives in `core.brocken`, you can modify it using the Native/Unsafe subset of the language.

```perl
# src/runtime/gc.brocken
package Brocken::Runtime::GC {
    use feature 'brocken_native_types';

    sub decref(ptr $obj) : NativeReturn(void) {
        my i64 $rc = Brocken::load_i16($obj);
        $rc = Brocken::sub($rc, 1);
        Brocken::store_i16($obj, $rc);

        if (Brocken::cmp_eq($rc, 0)) {
            destroy_and_free($obj);
        } else {
            buffer_suspect($obj);
        }
    }
}
```
If you need a new intrinsic memory operation, add it to `Lowering.pm` to translate the `Brocken::` pseudo-namespace into raw Lindsay IR.
