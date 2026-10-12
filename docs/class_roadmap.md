# Brocken Class System Roadmap

**Status:** Planning
**Targets:** v0.0.1 = `perlclass` (`use feature 'class'`) parity; v0.0.2 = selected `Object::Pad` features.

This document is the written plan for Brocken's object system. It records what ships today, what
v0.0.1 must add to match Perl's core `class` feature, and which `Object::Pad` features are worth
bringing forward in v0.0.2 — with a decision (adopt / adapt / defer / reject) and a rationale for each.

The language *design* lives in [`spec.md`](spec.md) 7–8; this file is the implementation roadmap and
the feature-by-feature adjudication. [`TODO.md`](../TODO.md) remains the shipped-vs-outstanding
checklist.

Legend: **Shipped** (works today, exercised by tests) · **Partial** (works only for the simple case) ·
**Planned** (agreed, not built) · **Proposed** (recommended here, needs sign-off).

---

## 0. Baseline: what ships today

The current front end (`Brocken::Katsuro`) and lowerer implement a deliberately small, statically-typed subset. Everything below is verified against `lib/Brocken/Katsuro/{Lexer,Parser,AST,Lowerer}.pm`.

| Area | Supported today | Notes |
|---|---|---|
| Declaration | `class NAME { ... }` block form only | No version, no class attributes, no `;` statement form |
| Fields | `field TYPE $name [:attr...] [= EXPR \| //= EXPR \| \|\|= EXPR];` | Scalar only. `TYPE` is required (a Brocken extension over `perlclass`) |
| Field attributes | `:param`, `:reader`, `:writer`, `:accessor` | `:accessor` expands to a reader plus a chaining writer. `:weak` is documented in spec 7.4 but **not implemented** |
| Accessor names | Fixed: reader = field name, writer = `set_<field>` | No `:reader(NAME)` / `:writer(NAME)` |
| Methods | `method NAME(TYPE $p, ...) :returns(RET) { ... }` | Typed params required; `RET` explicit or inferred; `$self` is a hidden receiver |
| ADJUST | `ADJUST { ... }` | Any number of blocks, run in declaration order; each sees `$self` and fields declared so far |
| `__CLASS__` | Partial | Usable inside methods and field initializers (the constructor now runs with class context); its *value* is still the placeholder from TODO F15 |
| Constructor | `Class->new(...)` (synthesised, never declared) | Positional values for `:param` fields in declaration order, then an optional trailing Hash of `name => value` overrides; `=`/`//=`/`||=` defaults; then `ADJUST`. Inlined at **every** call site, not emitted as a single `Class::new` function |
| Field access | Bare `$field` inside methods/`ADJUST`; `$obj->field` outside | Bare access is a compile-time GEP, not a call |
| Dispatch | Fully static: `$obj->m` resolves to `Class::m` from the receiver's static class | No vtable, no runtime lookup |
| Instance | `bump_alloc(total_size)`; 8-byte header `refcount \| (tag << 24)`; fields packed from offset 8 | No alignment padding between fields |

### 0.1 Gaps against `perlclass` (the v0.0.1 work)

These are the differences that stand between the current subset and parity with `use feature 'class'`.
Brocken intentionally diverges in a few places (typed fields/methods, positional constructor args);
those are marked **Diverge** and argued in 1.6.

| # | `perlclass` feature | Brocken today | Disposition |
|---|---|---|---|
| C1 | `class NAME VERSION :ATTRS BLOCK` | Block, no version/attrs | Planned |
| C2 | `class NAME;` statement form | Missing | Planned |
| C3 | Untyped fields `field $x`, `@x`, `%x` | Type required; scalar only | Diverge (types) + Planned (array/hash) |
| C4 | `:param(NAME)` + `_`-stripping default names | Custom param names and one-underscore stripping | **Shipped** |
| C5 | `:reader(NAME)` / `:writer(NAME)` + `_`-stripping | Custom accessor names and one-underscore stripping | **Shipped** |
| C6 | `:reader` on array/hash (list = contents, scalar = count) | Missing | Planned (with C3) |
| C7 | `:writer` returns `$self` for chaining | Writer returns `ptr` (`$self`), so `$obj->set_x(1)->set_y(2)` chains | **Shipped** |
| C8 | `:writer` scalar-only | Writer is scalar-only | Match |
| C9 | Default operators `=`, `//=`, `||=` | All three; `||=` applies when the supplied value is false | **Shipped** |
| C10 | Multiple `ADJUST`, run in declaration order | `adjusts` is a list, lowered in order into one `Class::ADJUST` | **Shipped** |
| C11 | Superclass `ADJUST` blocks merged and run | No inheritance | Planned (with C13) |
| C12 | Field initializers see earlier fields' values and may use `__CLASS__` | Initializers run with class context and see earlier fields; `__CLASS__` no longer croaks (its value is still TODO F15) | **Shipped** |
| C13 | `:isa(CLASS [VER])`, single superclass, `require` on demand | Missing | Planned |
| C14 | Inherited methods callable; fields *not* inherited | Missing | Planned (with C13) |
| C15 | `SUPER::` static ancestor call | Missing | Planned (with C13) |
| C16 | Method auto-signatures (defaults) | Typed, no defaults | Planned (defaults) |
| C17 | Anonymous `method { ... }` | Missing | Planned |
| C18 | Lexical `my method` | Missing | Planned |
| C19 | Constructor takes `%arguments` named hash; fields looked up by name | Accepts positional **and** trailing hash | Diverge (superset) |
| C20 | `reftype($obj) eq "OBJECT"` | Native value; no Perl `reftype` | Diverge (n/a) |
| C21 | `DESTROY` (spec 8.1) | Missing | Planned (see TODO 2) |
| C22 | `:returns(Type)` return annotation replacing `-> RET` | `:returns(Type)` (single type) | Shipped; multi-type tuples pending (TODO 3) |
| C23 | Roles | Missing | v0.0.2 (perlclass still lists roles as TODO) |
| C24 | `ADJUST` parameters | Missing | v0.0.2 (perlclass still TODO) |
| C25 | Metaprogramming API (PPC0022) | Missing | Defer |
| C26 | Extension attributes | Missing | Defer |

`perlclass` itself still lists C23–C26 as TODO, so "parity" for v0.0.1 means C1–C22 minus the ones
`perlclass` has not shipped either.

---

## 1. v0.0.1 — `perlclass` parity

### 1.1 Declarations and versions (C1, C2)

Add optional `VERSION` and class attributes to `parse_class_decl`, plus the statement form. The
statement form matters less for a single-file AOT compiler and can land last.

```
class Point 1.0 :isa(Base) { ... }
class Point;
```

Store `version` and an attribute list on `AST::Stmt::ClassDecl`; validate that `:isa` names a class declared in the compilation unit (see 1.5 for cross-unit `require`).

### 1.2 Fields, accessors, defaults (C3–C9, C12)

- **Types stay.** Brocken is statically typed; `field` keeps its required `TYPE`. A bare `field $x` can default to `Any` so `perlclass` code ports, but the type must remain expressible.
- **Array/hash fields.** Extend the layout and `populate_field_geps` to `@`/`%` fields; a hash field stores a pointer to heap hash data, an array field to heap array data (matching the existing `ArrayDecl`/`Hash` lowering). `:reader` on these returns contents in list context / count in scalar context; implement via the existing array/hash runtime helpers.
- **Accessor naming (done).** The parser now reads attributes as `{name, arg}` records, so `:reader(NAME)` / `:writer(NAME)` / `:param(NAME)` carry their payloads, and the default accessor/param name strips exactly one leading underscore from the field name, matching `perlclass` (`$_x :param` is `new(x => ...)`, `$_x :reader` is `x()`, `$_x :writer` is `set_x()`). Chained writer calls resolve through a writer-method map rather than the `set_` prefix, so custom writer names chain too. Tests: `t/10000_katsuro/10960_class_accessor_names.t` (runtime, all native targets), parser and lowerer cases.
- **Chaining (done).** `:writer` returns `$self` (registered as `ptr`); `_expr_class` in the Lowerer resolves the class of a chained writer call so `$obj->set_x(1)->set_y(2)` type-checks.
- **`||= defaults` (done).** Accepted in `parse_field_decl` and threaded through the constructor lowering: when a value is supplied and is false, the default replaces it (`icmp eq 0` + `select`); when the field is absent, the default is stored directly. The operators themselves were then generalised off fields: `//`, `//=`, and `||=` now work on ordinary variables and in expressions (`my Any $x; $x //= 5;`, `$a // $b // 0`), with `//=`/`//` testing a `ptr`/`Any` slot against null and `||=` against zero (TODO §3, spec §4.6).
- **Field-init visibility (C12) (done).** Field defaults are lowered in the inlined constructor with class context: the constructor binds `$self`, sets `$current_class` (so `__CLASS__` and `$self->m` resolve), and binds each field's GEP to its name as the field is assigned, so `field $y = $x + 1` reads an earlier field — whether it was set positionally, by name, or by its own initializer. All bindings are restored at the end so they never leak into the caller, and class context is established only around the initializers so a caller passing its own field to a constructor still gets its own type. Tests: `t/10000_katsuro/10965_field_init_visibility.t` (runtime, native targets). Note: the *value* of `__CLASS__` is still the placeholder pointer (TODO F15), so a default may mention it without croaking but cannot yet use it as a real class handle.

### 1.3 Methods (C16–C18, C22)

- **`:returns(Type)`.** Done: the attribute form is now the only spelled return annotation on both `sub` and `method`, and the old `-> RET` form has been removed from the parser, core runtime, tests, and examples (TODO 3). Still to do: `:returns(i64, bool)` register tuples per the spec, which need the `AST`/`Lowerer` to model more than one return value; the parser currently accepts the attribute and first type, then rejects the comma with a clear error.
- **Parameter defaults (done).** `method greet(String $name = "someone")`. A default parses as an expression after `=`, and omitted *trailing* parameters are filled at the call site: a default may reference any earlier parameter (including one that was itself defaulted), because each value that lands in a parameter is bound to the parameter's name while the call lowers. Filling stops at the first omitted parameter without a default. Defaults evaluate in the caller's context, so they can use caller-scope variables but not the callee's fields or `$self`. Tests: `t/10000_katsuro/10950_param_defaults.t` (runtime, cross-target), parser and lowerer cases.
- **Lexical `my method`** and **anonymous `method { ... }`.** Lexical methods are a scoping change in the parser plus a private symbol naming scheme. Anonymous methods need a code-pointer value; if the body captures no fields/locals it can lower to a raw code address (like the existing non-capturing anonymous `sub`), otherwise it needs the closure environment planned for logic. Recommend shipping the non-capturing form first, and documenting the capture limitation.
- **Method attributes** beyond `:returns` (`:override`, `:common`, `:lvalue`) are Object::Pad territory; see 2.

### 1.4 ADJUST (C10, C11, C12)

- **Multiple blocks (done).** `ClassDecl::adjusts` stores a *list*; `lower_adjust` lowers each body into one `Class::ADJUST` in declaration order.
- When inheritance lands, the constructor runs the merged ancestor→descendant ADJUST chain.
- Keep the current behaviour that ADJUST sees `$self` and fields assigned so far.

### 1.5 Inheritance and `SUPER::` (C13–C15)

This is the centrepiece of v0.0.1 and the only structural change to the object model.

**Surface.** `class NAME :isa(PARENT [VERSION])`. A single superclass. `SUPER::method(args)` resolves to the nearest ancestor (starting at the parent of the *statically known* current class) that defines `method`.

**Layout.** An instance of a derived class is the parent's field block followed by the child's field
block; `total_size` is the sum over the whole chain. Field indices are absolute into this layout, so
an inherited method still addresses its own fields at the same offsets. This mirrors `perlclassguts`
(`xhv_class_next_fieldix`, `fieldstash`), where a subclass's fields start after the parent's.

**Privacy.** Fields are lexical: a subclass method binds GEPs only for fields *it* declares, never
the parent's. Inheritance of *methods* is public; inheritance of fields is not.

**Dispatch.** Static. `resolve_class_name` already yields the receiver's static class; extend it to
walk ancestors until it finds the method. Because the class is known at compile time, this stays a
direct call — no vtable. The trade-off is documented: a single call site cannot dispatch
polymorphically across sibling subclasses unless the receiver's static type is the common ancestor, in
which case it resolves to the ancestor's implementation. See 4-Q1 for the dynamic-dispatch question.

**Construction.** Give each class a `:param` name map (`name → absolute field index`) copied from
its parent and extended with its own params, replicating `xhv_class_param_map`. `new` on the most
derived class:
1. allocate `total_size`,
2. walk root→derived field initializers, consuming named args and applying defaults,
3. walk root→derived ADJUST blocks.

**`SUPER::` lowering.** When lowering a method of class `C`, a `SUPER::m` call binds to the nearest
ancestor of `C` (strictly above `C`) whose own method table has `m`. This is the forward-looking
example currently in spec 8 (`DatabaseConnection::Static :isa(DatabaseConnection)` calling
`$self->SUPER::commit`).

**`require` on demand.** `perlclass` will `require` a superclass module if it is not loaded. Brocken
has no module loader yet (see TODO 11 and spec 17.4); within one compilation unit the class is
simply looked up. Cross-unit `require` is gated on the module system and should be a follow-up, not a
v0.0.1 blocker.

### 1.6 Destructor (C21)

`DESTROY { ... }` is specified in spec 8.1 and tracked in TODO 2. It needs:
- parsing `DESTROY` as a class-body member (the lexer already reserves the keyword),
- a generated `Class::DESTROY` that chains derived→root,
- cascading `decref` of every managed field after user code runs,
- a hard abort if a destructor throws during unwinding.

This pairs naturally with the inheritance layout work: teardown walks the same absolute field map.

### 1.7 Deliberate divergences from `perlclass`

These are intentional and should be recorded, not "fixed":

1. **Typed fields and methods.** `perlclass` is untyped; Brocken requires/propagates static types.
2. **Positional constructor arguments.** `perlclass` accepts only `%arguments`. Brocken accepts
   positional `:param` values *and* a trailing named hash. Superset, kept for ergonomics.
3. **No `reftype`/`bless` identity.** Instances are native structs, not `SVt_PVOBJ`. `Brocken::*`
   introspection is the equivalent, if and when a metaprogramming API lands.
4. **Static dispatch.** By design; see 1.5 and 4-Q1.

---

## 2. v0.0.2 — `Object::Pad` features

`Object::Pad` is a superset of `perlclass` that experimented first and shipped more. This section
adjudicates each feature against Brocken's constraints (AOT, static types, no Perl runtime, static
dispatch, RC/Immix). Decisions are recommendations for sign-off.

### 2.1 Adopt — fits the model directly

| Feature | What it is | Why adopt | Work |
|---|---|---|---|
| `:abstract` + bodyless methods | Class may not be instantiated until subclasses supply required method bodies | Pure compile-time check; ideal for AOT | Moderate |
| `:lexical_new` | Constructor is not installed as a named method | Compile-time scoping; lets a class own its constructors | Small |
| `my class` / anonymous `class {}` | Lexically scoped / anonymous classes | Front-end scoping; anonymous classes are just unnamed struct types | Small |
| `inherit` | Newer spelling of `:isa` with a flexible argument list | Adopt as the preferred spelling once `:isa` exists; keep `:isa` as an alias | Small (on top of C13) |
| `:strict(params)` | Constructor rejects unknown named args | Better diagnostics; cheap once the `:param` map exists | Small |
| ADJUST `:params` (and/or `ADJUSTPARAMS`) | ADJUST blocks consume named constructor params | Direct extension of the `:param` map; typed in Brocken | Moderate |
| `:mutator` | lvalue accessor for a scalar field | Static lowering to get/set; useful sugar | Small |
| `:accessor` | Combined reader/writer | Implemented as an M0 win (reader + chaining writer) | Done |
| `:weak` | Accessor/constructor assignments don't take ownership | Maps to a no-`incref` store in the RC contract | Small–moderate |
| `:reader`/`:writer`/`:param(NAME)` + `_` rule | Custom accessor names | Same as C4/C5; adopt fully | Done (C4/C5) |
| Default `//=` and `||=` | Field default operators | `||=` implemented (C9); custom names still planned | Done (`||=`) |
| Method `:override` | Assert a method overrides an ancestor's | Compile-time check over the static method table | Small |
| Lexical / anonymous methods | Private methods; method values | Same as C17/C18 | Moderate |

### 2.2 Adapt — adopt the intent, redesign for a typed static language

| Feature | `Object::Pad` semantics | Brocken plan |
|---|---|---|
| `role` + `:does` / `apply` / `requires` (+ role `:does`) | Compile-time composition; a role provides methods, fields, and required-method declarations; applied at compile time | **Flatten at compile time.** A role is a fragment of methods + fields + `requires`. On `apply`/`:does`, copy the role's members into the applying class, dedup, run `requires` checks, and error on conflicting definitions. Field indices are assigned at the point of application in a deterministic order. Role methods are not directly invokable (no `:compat`). This mirrors what `Object::Pad` does conceptually while staying vtable-free. |
| `BUILDARGS` | A class method that munges the constructor arg list before fields are assigned | **Adopt, typed.** Let a declared class method `BUILDARGS` receive the raw typed argument list and return the `:param` values. Since Brocken arguments are typed, the "arbitrary bag" nature is bounded. Lower it as an ordinary static method returning a known shape. |
| `BUILD` | Per-component phaser receiving the raw constructor args after fields are assigned | **Defer or adapt.** `BUILD`'s ability to inspect an arbitrary arg bag conflicts with typed constructors. If adopted, restrict `BUILD` to params declared by ADJUST `:params`, so its signature is statically known. Recommend deferring until ADJUST `:params` and roles exist. |
| Method `:common` | A method that is not selected when resolving bareword function-call names (so a class method `new` can coexist with the constructor) | **Adopt as a naming-namespace rule.** Brocken already distinguishes `Class::method` from a bare function; encode `:common` to suppress the bareword alias if/when one is introduced. |

### 2.3 Defer

| Feature | Why defer |
|---|---|
| Metaprogramming API (PPC0022) | Requires a runtime class/method/field registry. A native AOT image could emit a static descriptor table, but this is a whole sub-project. |
| Extension attributes (user-defined class/field attributes) | Needs a compile-time plugin interface; wait until the built-in attribute set is stable. |
| Field initialization *blocks* `field $x { ... }` | `Object::Pad` allows full statements; Brocken can support expression defaults first and add statement blocks later. |
| `:inheritable` field inheritance | Directly contradicts the lexical-privacy rule that makes fields safe. If needed, expose fields through generated accessors instead. |
| `:lvalue` methods | Needs first-class lvalue/reference returns, which Brocken does not have yet. |

### 2.4 Reject

| Feature | Why reject |
|---|---|
| `:repr(native/HASH/keys/magic/pvobj/autoselect)` | These select a *host Perl* representation. Brocken's representation is already a native struct; there is no host object to select. Accept-and-ignore `:repr(native)` for portability, error otherwise. |
| `:compat(invokable)` | Exists so role methods can be invoked on non-`Object::Pad` Perl objects during migration. Brocken has no Perl objects to migrate, and flattening already covers the legitimate use. |
| `has` (removed in `Object::Pad` 0.813) | Dead keyword; `field` is the spelling. |
| `ADJUSTPARAMS` *and* `ADJUST :params` simultaneously | Pick one spelling. Recommend `ADJUST :params` (typed) and reject `ADJUSTPARAMS` as too untyped. |

---

## 3. Object-model internals to build

Ordered by dependency.

1. **Class metadata registry.** Extend the `classes` hash entry with `parent`, `version`, `abstract`, `roles`, `required_methods`, and a `param_map` copied from the parent chain. This is the Brocken analogue of `xhv_class_*` in `perlclassguts`.
2. **Field map and alignment.** Absolute field indices over the whole chain; introduce alignment padding in `register_class` (currently fields are packed with no padding, which is fine for the i64-only tests but not for mixed widths).
3. **Accessor attribute records.** `[{name, arg}]` instead of bare strings; custom names and `_`-stripping are handled (a name is stored with the record that overrides it, and the registry keeps each field's resolved `param_name`).
4. **Constructor chaining.** Emit a real `Class::new` function instead of inlining the constructor at every call site (today it is inlined, which duplicates field initializers and has no class context). `new` walks root => derived initializers and ADJUST blocks over the merged `param_map`; `:strict(params)` checks leftovers; ADJUST `:params` consumes named args.
5. **Static ancestor resolution + `SUPER::`.** Extend `resolve_class_name`/`lower_method_call` to walk the chain; add an AST node for `SUPER::m`.
6. **`DESTROY` chaining + cascading teardown.**
7. **Role flattening.** Compose members at class-registration time; run `requires`/`:abstract` checks after all declarations are known.
8. **Anonymous/lexical methods.** Private naming; code-pointer lowering for non-capturing bodies.

---

## 4. Open design questions

- **Q1 — Dynamic dispatch.** Do we ever need a vtable? Heterogeneous collections of sibling
  subclasses, plugin registries, and `:abstract` interfaces all want it. Proposal: keep static
  monomorphic dispatch as the default (zero cost), and add an explicit opt-in interface/`does`-based
  dispatch later rather than baking a vtable into every object. Needs a decision before roles ship,
  since roles are the usual path to interface-style polymorphism.
- **Q2 — Constructor argument model.** Keep the positional superset, or move to `perlclass`'s
  named-only `%arguments`? Keeping both is friendlier but complicates `:strict(params)` and
  `BUILDARGS`.
- **Q3 — Cross-unit `:isa`/`require`.** Depends on the module system (spec 17.4). Until then, `:isa`
  is restricted to classes in the same compilation unit.
- **Q4 — Field initializer restriction.** `Object::Pad` forbids control-flow that leaves a field
  initializer. Brocken should decide whether to enforce this or allow it (the current lowering simply
  inlines defaults into the constructor).
- **Q5 — `:param` on inherited fields.** Fields are not inherited, but `:param` *names* are (the map is
  copied). Confirm that a subclass constructor still accepts a parent's `:param(NAME)` — `perlclass`
  says yes.
- **Q6 — Anonymous method captures.** Ship non-capturing only, or block on the closure environment?

---

## 5. Suggested sequencing

1. **M0 (v0.0.1, no model change):** `:returns`, parameter defaults, `||=`, custom accessor names, `_`-stripping, `:writer` chaining return, multiple `ADJUST`, field-init visibility, `:accessor`, `:weak`, array/hash fields.
   *Done so far:* `:returns` (C22), `||=` (C9), `:writer` chaining (C7), multiple `ADJUST` (C10), `:accessor`, custom accessor names + `_`-stripping (C4, C5), parameter defaults, field-init visibility (C12). *Remaining:* `:weak`, array/hash fields.
2. **M1 (v0.0.1, object model):** field-map/alignment rework; class versions and attributes; `:isa`; static ancestor resolution; `SUPER::`; constructor chaining; `DESTROY`.
3. **M2 (v0.0.2):** `role`/`apply`/`:does`/`requires` flattening; `:abstract`; ADJUST `:params`; `:strict(params)`; `:lexical_new`; `my class`; `inherit`; `:override`/`:common`; lexical/anonymous
   methods.
4. **M3 (v0.0.2+):** `BUILDARGS`; metaprogramming descriptor tables; extension attributes; lvalue methods.

Each milestone should add a focused test alongside the feature (the existing class tests live in
`t/10000_katsuro/` and `t/40000_runtime/40200_runtime_alloc.t`).
