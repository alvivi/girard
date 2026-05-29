//// Hindley-Milner type inference over glance's AST, mirroring the Gleam
//// compiler's algorithm (compiler-core/src/type_/expression.rs) closely enough
//// to annotate every expression with its inferred type.
////
//// Mutability model: the real compiler mutates `Arc<RefCell<TypeVar>>` in place.
//// Here a `Var(id)` is looked up in a substitution `Dict(Int, Type)` carried in
//// the threaded `State`. Unbound variables are simply absent from the dict;
//// binding a variable inserts it. Generalization is tracked separately via
//// `Scheme` (only module-level definitions are generalized — like Gleam, local
//// `let` bindings are monomorphic).
////
//// We do not report errors: anything ill-typed `panic`s.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import glance
import girard/types.{type Scheme, type Type, Fn, Named, Scheme, Tuple, Var}

// --- State & environment ---------------------------------------------------

pub type State {
  State(
    next_id: Int,
    /// Bound type variables. Absence means unbound.
    subst: Dict(Int, Type),
    /// Inferred type recorded for each annotated source span, in reverse order
    /// of discovery. Types are stored "live" and zonked at the end.
    annotations: List(#(glance.Span, Type)),
  )
}

pub type Env {
  Env(
    /// Value bindings in scope: locals, parameters, top-level functions and
    /// custom-type constructors.
    values: Dict(String, Scheme),
    /// Type aliases: name -> (parameter names, aliased type AST), expanded
    /// during hydration.
    aliases: Dict(String, #(List(String), glance.Type)),
    /// Record field accessors: type name -> label -> a scheme for
    /// `fn(record) -> field`, generalized over the type's parameters.
    accessors: Dict(String, Dict(String, Scheme)),
    /// In-scope type names -> (origin module, arity). Covers types defined in
    /// the current module and types brought in by unqualified imports. Used
    /// during hydration to resolve a bare type name to its module.
    local_types: Dict(String, #(String, Int)),
    /// Field maps for callables (functions and constructors): name -> the
    /// label of each positional parameter (`None` where unlabelled). Used to
    /// reorder labelled and shorthand arguments at call/pattern sites.
    field_maps: Dict(String, List(Option(String))),
    /// The name of the module currently being inferred. Local types are minted
    /// with this module so they stay distinct from imported types.
    current_module: String,
    /// Imported modules available for qualified access, keyed by the alias used
    /// in source (e.g. `list` for `import gleam/list`).
    modules: Dict(String, ModuleInterface),
  )
}

/// The public surface of a module, used when importing it elsewhere.
pub type ModuleInterface {
  ModuleInterface(
    name: String,
    values: Dict(String, Scheme),
    types: Dict(String, #(String, Int)),
    aliases: Dict(String, #(List(String), glance.Type)),
    accessors: Dict(String, Dict(String, Scheme)),
    field_maps: Dict(String, List(Option(String))),
  )
}

pub fn new_state() -> State {
  State(next_id: 0, subst: dict.new(), annotations: [])
}

pub fn new_env() -> Env {
  Env(
    values: dict.new(),
    aliases: dict.new(),
    accessors: dict.new(),
    local_types: dict.new(),
    field_maps: dict.new(),
    current_module: "",
    modules: dict.new(),
  )
}

/// Set the name of the module currently being inferred.
pub fn set_module(env: Env, name: String) -> Env {
  Env(..env, current_module: name)
}

/// Register the field map (per-position labels) of a callable.
pub fn register_field_map(
  env: Env,
  name: String,
  labels: List(Option(String)),
) -> Env {
  // Only worth recording if at least one position is labelled.
  case list.any(labels, fn(l) { l != None }) {
    True -> Env(..env, field_maps: dict.insert(env.field_maps, name, labels))
    False -> env
  }
}

/// Declare a local type name (and arity) so references to it during hydration
/// resolve to the current module. Call this for every custom type before
/// registering any of them, so forward references resolve correctly.
pub fn declare_type(env: Env, name: String, arity: Int) -> Env {
  Env(
    ..env,
    local_types: dict.insert(env.local_types, name, #(env.current_module, arity)),
  )
}

/// Register a type alias so references to it expand during hydration.
pub fn register_type_alias(env: Env, alias: glance.TypeAlias) -> Env {
  Env(
    ..env,
    aliases: dict.insert(env.aliases, alias.name, #(
      alias.parameters,
      alias.aliased,
    )),
  )
}

fn fresh(st: State) -> #(Type, State) {
  #(Var(st.next_id), State(..st, next_id: st.next_id + 1))
}

/// Public access to a fresh type variable for the driver in `girard.gleam`.
pub fn fresh_var(st: State) -> #(Type, State) {
  fresh(st)
}

/// Bind a value scheme into the environment (used to register top-level
/// functions and constructors).
pub fn define(env: Env, name: String, scheme: Scheme) -> Env {
  bind_value(env, name, scheme)
}

/// The initial environment and state, seeded with the prelude value
/// constructors (`True`, `False`, `Nil`, `Ok`, `Error`).
pub fn prelude() -> #(Env, State) {
  let st = new_state()
  let env =
    new_env()
    |> bind_value("True", Scheme([], types.bool()))
    |> bind_value("False", Scheme([], types.bool()))
    |> bind_value("Nil", Scheme([], types.nil()))

  // Ok(a) -> Result(a, e)
  let #(ok_a, st) = fresh(st)
  let #(ok_e, st) = fresh(st)
  let env =
    bind_value(
      env,
      "Ok",
      Scheme([var_id(ok_a), var_id(ok_e)], Fn([ok_a], types.result(ok_a, ok_e))),
    )

  // Error(e) -> Result(a, e)
  let #(err_a, st) = fresh(st)
  let #(err_e, st) = fresh(st)
  let env =
    bind_value(
      env,
      "Error",
      Scheme(
        [var_id(err_a), var_id(err_e)],
        Fn([err_e], types.result(err_a, err_e)),
      ),
    )

  #(env, st)
}

fn var_id(type_: Type) -> Int {
  case type_ {
    Var(id) -> id
    _ -> panic as "expected a type variable"
  }
}

fn bind_value(env: Env, name: String, scheme: Scheme) -> Env {
  Env(..env, values: dict.insert(env.values, name, scheme))
}

/// Look up a value's scheme in the environment.
pub fn lookup(env: Env, name: String) -> Result(Scheme, Nil) {
  dict.get(env.values, name)
}

// --- Module interfaces & imports -------------------------------------------

/// Build the public interface of an inferred module by keeping only the named
/// public values and types.
pub fn build_interface(
  env: Env,
  name: String,
  value_names: List(String),
  type_names: List(String),
) -> ModuleInterface {
  ModuleInterface(
    name: name,
    values: take(env.values, value_names),
    types: take(env.local_types, type_names),
    aliases: take(env.aliases, type_names),
    accessors: take(env.accessors, type_names),
    field_maps: take(env.field_maps, value_names),
  )
}

fn take(d: Dict(String, v), keys: List(String)) -> Dict(String, v) {
  list.fold(keys, dict.new(), fn(acc, key) {
    case dict.get(d, key) {
      Ok(value) -> dict.insert(acc, key, value)
      Error(_) -> acc
    }
  })
}

/// Make a module available for qualified access (`alias.value`/`alias.Type`).
pub fn import_qualified(env: Env, alias: String, interface: ModuleInterface) -> Env {
  Env(..env, modules: dict.insert(env.modules, alias, interface))
}

/// Bring a single value (function/constant/constructor) into scope unqualified.
pub fn import_value(
  env: Env,
  local: String,
  interface: ModuleInterface,
  original: String,
) -> Env {
  let env = case dict.get(interface.values, original) {
    Ok(scheme) -> bind_value(env, local, scheme)
    Error(_) -> env
  }
  case dict.get(interface.field_maps, original) {
    Ok(field_map) ->
      Env(..env, field_maps: dict.insert(env.field_maps, local, field_map))
    Error(_) -> env
  }
}

/// Bring a single type into scope unqualified.
pub fn import_type(
  env: Env,
  local: String,
  interface: ModuleInterface,
  original: String,
) -> Env {
  let env = case dict.get(interface.types, original) {
    Ok(info) -> Env(..env, local_types: dict.insert(env.local_types, local, info))
    Error(_) -> env
  }
  let env = case dict.get(interface.aliases, original) {
    Ok(alias) -> Env(..env, aliases: dict.insert(env.aliases, local, alias))
    Error(_) -> env
  }
  case dict.get(interface.accessors, original) {
    Ok(accessors) ->
      Env(..env, accessors: dict.insert(env.accessors, local, accessors))
    Error(_) -> env
  }
}

fn record(st: State, span: glance.Span, type_: Type) -> State {
  State(..st, annotations: [#(span, type_), ..st.annotations])
}

// --- Substitution: resolve / zonk / free variables -------------------------

/// Follow bound variables one level to expose the head constructor.
pub fn resolve(st: State, type_: Type) -> Type {
  case type_ {
    Var(id) ->
      case dict.get(st.subst, id) {
        Ok(bound) -> resolve(st, bound)
        Error(_) -> type_
      }
    _ -> type_
  }
}

/// Fully apply the substitution, leaving only unbound variables as `Var`.
pub fn zonk(st: State, type_: Type) -> Type {
  case resolve(st, type_) {
    Named(module, name, args) ->
      Named(module, name, list.map(args, zonk(st, _)))
    Fn(args, ret) -> Fn(list.map(args, zonk(st, _)), zonk(st, ret))
    Tuple(elements) -> Tuple(list.map(elements, zonk(st, _)))
    Var(id) -> Var(id)
  }
}

fn free_vars(st: State, type_: Type) -> List(Int) {
  free_vars_loop(zonk(st, type_), [])
}

fn free_vars_loop(type_: Type, acc: List(Int)) -> List(Int) {
  case type_ {
    Var(id) ->
      case list.contains(acc, id) {
        True -> acc
        False -> [id, ..acc]
      }
    Named(_, _, args) -> list.fold(args, acc, fn(a, t) { free_vars_loop(t, a) })
    Fn(args, ret) ->
      free_vars_loop(ret, list.fold(args, acc, fn(a, t) {
        free_vars_loop(t, a)
      }))
    Tuple(elements) ->
      list.fold(elements, acc, fn(a, t) { free_vars_loop(t, a) })
  }
}

fn env_free_vars(st: State, env: Env) -> List(Int) {
  dict.fold(env.values, [], fn(acc, _name, scheme) {
    // Quantified variables of a scheme are not free.
    let fv = free_vars(st, scheme.type_)
    let fv = list.filter(fv, fn(id) { !list.contains(scheme.vars, id) })
    list.append(fv, acc)
  })
}

// --- Unification -----------------------------------------------------------

pub fn unify(st: State, a: Type, b: Type) -> State {
  let a = resolve(st, a)
  let b = resolve(st, b)
  case a, b {
    Var(i), Var(j) if i == j -> st
    Var(i), other -> bind_var(st, i, other)
    other, Var(j) -> bind_var(st, j, other)

    Named(m1, n1, a1), Named(m2, n2, a2) if m1 == m2 && n1 == n2 ->
      unify_many(st, a1, a2)

    Fn(args1, r1), Fn(args2, r2) -> unify(unify_many(st, args1, args2), r1, r2)

    Tuple(e1), Tuple(e2) -> unify_many(st, e1, e2)

    _, _ -> panic as "type mismatch during unification"
  }
}

fn unify_many(st: State, a: List(Type), b: List(Type)) -> State {
  case a, b {
    [], [] -> st
    [x, ..xs], [y, ..ys] -> unify_many(unify(st, x, y), xs, ys)
    _, _ -> panic as "type mismatch: differing arity"
  }
}

fn bind_var(st: State, id: Int, type_: Type) -> State {
  case occurs(st, id, type_) {
    True -> panic as "infinite type (occurs check)"
    False -> State(..st, subst: dict.insert(st.subst, id, type_))
  }
}

fn occurs(st: State, id: Int, type_: Type) -> Bool {
  list.contains(free_vars(st, type_), id)
}

// --- Generalization & instantiation ----------------------------------------

/// Generalize a type into a scheme, quantifying variables that are free in the
/// type but not in the surrounding environment.
pub fn generalize(st: State, env: Env, type_: Type) -> Scheme {
  let zonked = zonk(st, type_)
  let env_vars = env_free_vars(st, env)
  let quantified =
    list.filter(free_vars(st, zonked), fn(id) { !list.contains(env_vars, id) })
  Scheme(quantified, zonked)
}

/// Instantiate a scheme by replacing each quantified variable with a fresh one.
pub fn instantiate(st: State, scheme: Scheme) -> #(Type, State) {
  let #(mapping, st) =
    list.fold(scheme.vars, #(dict.new(), st), fn(acc, old) {
      let #(mapping, st) = acc
      let #(fresh_type, st) = fresh(st)
      #(dict.insert(mapping, old, fresh_type), st)
    })
  #(substitute(mapping, scheme.type_), st)
}

fn substitute(mapping: Dict(Int, Type), type_: Type) -> Type {
  case type_ {
    Var(id) ->
      case dict.get(mapping, id) {
        Ok(replacement) -> replacement
        Error(_) -> type_
      }
    Named(module, name, args) ->
      Named(module, name, list.map(args, substitute(mapping, _)))
    Fn(args, ret) ->
      Fn(list.map(args, substitute(mapping, _)), substitute(mapping, ret))
    Tuple(elements) -> Tuple(list.map(elements, substitute(mapping, _)))
  }
}

// --- Expression inference --------------------------------------------------

pub fn infer_expr(env: Env, st: State, expr: glance.Expression) -> #(Type, State) {
  let #(type_, st) = infer_expr_inner(env, st, expr)
  #(type_, record(st, span(expr), type_))
}

fn infer_expr_inner(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> #(Type, State) {
  case expr {
    glance.Int(..) -> #(types.int(), st)
    glance.Float(..) -> #(types.float(), st)
    glance.String(..) -> #(types.string(), st)

    glance.Variable(_, name) ->
      case dict.get(env.values, name) {
        Ok(scheme) -> instantiate(st, scheme)
        Error(_) -> panic as { "unbound variable: " <> name }
      }

    glance.NegateInt(_, value) -> {
      let #(t, st) = infer_expr(env, st, value)
      #(types.int(), unify(st, t, types.int()))
    }

    glance.NegateBool(_, value) -> {
      let #(t, st) = infer_expr(env, st, value)
      #(types.bool(), unify(st, t, types.bool()))
    }

    glance.Tuple(_, elements) -> {
      let #(types_, st) = infer_each(env, st, elements)
      #(Tuple(types_), st)
    }

    glance.List(_, elements, rest) -> {
      let #(elem, st) = fresh(st)
      let st =
        list.fold(elements, st, fn(st, e) {
          let #(t, st) = infer_expr(env, st, e)
          unify(st, t, elem)
        })
      let st = case rest {
        Some(r) -> {
          let #(t, st) = infer_expr(env, st, r)
          unify(st, t, types.list(elem))
        }
        None -> st
      }
      #(types.list(elem), st)
    }

    glance.Fn(_, params, return_annotation, body) ->
      infer_fn(env, st, params, return_annotation, body)

    glance.Call(span, function, arguments) ->
      infer_call(env, st, span, function, arguments)

    glance.FnCapture(span, label, function, before, after) ->
      infer_capture(env, st, span, label, function, before, after)

    glance.BinaryOperator(span, op, left, right) ->
      infer_binop(env, st, span, op, left, right)

    glance.Block(_, statements) -> infer_statements(env, st, statements)

    glance.Case(_, subjects, clauses) ->
      infer_case(env, st, subjects, clauses)

    glance.TupleIndex(_, tuple, index) -> {
      let #(t, st) = infer_expr(env, st, tuple)
      case resolve(st, t) {
        Tuple(elements) ->
          case list_at(elements, index) {
            Ok(element) -> #(element, st)
            Error(_) -> panic as "tuple index out of range"
          }
        _ -> panic as "tuple index on non-tuple"
      }
    }

    glance.Todo(..) | glance.Panic(..) -> fresh(st)

    glance.Echo(_, expression, _message) ->
      case expression {
        Some(e) -> infer_expr(env, st, e)
        None -> #(types.nil(), st)
      }

    glance.FieldAccess(_, container, label) -> {
      // `module.value` (qualified access) takes precedence over record field
      // access when the container names an imported module not shadowed by a
      // local value.
      let module_access = case container {
        glance.Variable(_, name) ->
          case !dict.has_key(env.values, name), dict.get(env.modules, name) {
            True, Ok(interface) -> Ok(interface)
            _, _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
      case module_access {
        Ok(interface) ->
          case dict.get(interface.values, label) {
            Ok(scheme) -> instantiate(st, scheme)
            Error(_) ->
              panic as { "module has no value `" <> label <> "`" }
          }
        Error(_) -> {
          let #(container_type, st) = infer_expr(env, st, container)
          case resolve(st, container_type) {
            Named(_, type_name, _) -> {
              let #(accessor_type, st) =
                instantiate(st, accessor(env, type_name, label))
              let #(field, st) = fresh(st)
              let st = unify(st, accessor_type, Fn([container_type], field))
              #(field, st)
            }
            _ -> panic as "field access on a value of unknown type"
          }
        }
      }
    }

    glance.RecordUpdate(_, _module, _constructor, record, fields) -> {
      let #(record_type, st) = infer_expr(env, st, record)
      case resolve(st, record_type) {
        Named(_, type_name, _) -> {
          let st =
            list.fold(fields, st, fn(st, field) {
              let #(value_type, st) = case field.item {
                Some(value) -> infer_expr(env, st, value)
                // Shorthand `label:` refers to the variable named `label`.
                None ->
                  case dict.get(env.values, field.label) {
                    Ok(scheme) -> instantiate(st, scheme)
                    Error(_) ->
                      panic as { "unbound variable: " <> field.label }
                  }
              }
              let #(accessor_type, st) =
                instantiate(st, accessor(env, type_name, field.label))
              let #(field_type, st) = fresh(st)
              let st = unify(st, accessor_type, Fn([record_type], field_type))
              unify(st, value_type, field_type)
            })
          #(record_type, st)
        }
        _ -> panic as "record update on a value of unknown type"
      }
    }

    glance.BitString(_, segments) -> {
      let st =
        list.fold(segments, st, fn(st, segment) {
          let #(value, options) = segment
          let st = check(env, st, value, segment_value_type(options))
          list.fold(options, st, fn(st, option) {
            case option {
              glance.SizeValueOption(size) -> check(env, st, size, types.int())
              _ -> st
            }
          })
        })
      #(types.bit_array(), st)
    }
  }
}

fn infer_each(
  env: Env,
  st: State,
  exprs: List(glance.Expression),
) -> #(List(Type), State) {
  let #(rev, st) =
    list.fold(exprs, #([], st), fn(acc, e) {
      let #(types_, st) = acc
      let #(t, st) = infer_expr(env, st, e)
      #([t, ..types_], st)
    })
  #(list.reverse(rev), st)
}

fn infer_fn(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
) -> #(Type, State) {
  let #(param_types, body_env, st) =
    list.fold(params, #([], env, st), fn(acc, param) {
      let #(types_, env, st) = acc
      let #(t, st) = case param.type_ {
        Some(ann) -> hydrate(env, st, ann)
        None -> fresh(st)
      }
      let env = case param.name {
        glance.Named(name) -> bind_value(env, name, Scheme([], t))
        glance.Discarded(_) -> env
      }
      #([t, ..types_], env, st)
    })
  let #(body_type, st) = infer_statements(body_env, st, body)
  let st = case return_annotation {
    Some(ann) -> {
      let #(t, st) = hydrate(env, st, ann)
      unify(st, body_type, t)
    }
    None -> st
  }
  #(Fn(list.reverse(param_types), body_type), st)
}

fn infer_call(
  env: Env,
  st: State,
  span: glance.Span,
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> #(Type, State) {
  let #(fn_type, st) = infer_expr(env, st, function)
  let ordered =
    order_fields(env, function, arguments, fn(label, location) {
      glance.Variable(location, label)
    })
  let #(arg_types, st) = infer_each(env, st, ordered)
  let #(result, st) = fresh(st)
  let st = unify(st, fn_type, Fn(arg_types, result))
  // Record the result type at the call span too.
  #(result, record(st, span, result))
}

fn field_item(field: glance.Field(glance.Expression)) -> glance.Expression {
  case field {
    glance.UnlabelledField(item) -> item
    glance.LabelledField(_, _, item) -> item
    glance.ShorthandField(label, location) -> glance.Variable(location, label)
  }
}

/// Reorder labelled/shorthand call or pattern arguments into positional order
/// using the callee's field map. If every argument is positional we don't need
/// the field map (this also covers calls to anonymous functions).
fn order_fields(
  env: Env,
  callee: glance.Expression,
  fields: List(glance.Field(t)),
  shorthand: fn(String, glance.Span) -> t,
) -> List(t) {
  case list.all(fields, is_unlabelled) {
    True -> list.map(fields, unlabelled_item)
    False -> {
      let labels = case callee {
        glance.Variable(_, name) -> dict.get(env.field_maps, name)
        glance.FieldAccess(_, _, name) -> dict.get(env.field_maps, name)
        _ -> Error(Nil)
      }
      case labels {
        Ok(labels) -> reorder(fields, labels, shorthand)
        Error(_) -> panic as "labelled arguments to an unknown callable"
      }
    }
  }
}

fn is_unlabelled(field: glance.Field(t)) -> Bool {
  case field {
    glance.UnlabelledField(..) -> True
    _ -> False
  }
}

fn unlabelled_item(field: glance.Field(t)) -> t {
  case field {
    glance.UnlabelledField(item) -> item
    _ -> panic as "expected an unlabelled field"
  }
}

fn reorder(
  fields: List(glance.Field(t)),
  labels: List(Option(String)),
  shorthand: fn(String, glance.Span) -> t,
) -> List(t) {
  let index_of =
    list.index_fold(labels, dict.new(), fn(acc, label, index) {
      case label {
        Some(name) -> dict.insert(acc, name, index)
        None -> acc
      }
    })
  let #(placed, _next) =
    list.fold(fields, #(dict.new(), 0), fn(acc, field) {
      let #(placed, next) = acc
      case field {
        glance.UnlabelledField(item) -> #(dict.insert(placed, next, item), next + 1)
        glance.LabelledField(label, _, item) -> #(
          dict.insert(placed, label_index(index_of, label), item),
          next,
        )
        glance.ShorthandField(label, location) -> #(
          dict.insert(placed, label_index(index_of, label), shorthand(
            label,
            location,
          )),
          next,
        )
      }
    })
  list.index_map(labels, fn(_label, index) {
    case dict.get(placed, index) {
      Ok(item) -> item
      Error(_) -> panic as "missing argument when reordering labelled fields"
    }
  })
}

fn label_index(index_of: Dict(String, Int), label: String) -> Int {
  case dict.get(index_of, label) {
    Ok(index) -> index
    Error(_) -> panic as { "unknown argument label: " <> label }
  }
}

fn infer_capture(
  env: Env,
  st: State,
  span: glance.Span,
  _label: Option(String),
  function: glance.Expression,
  before: List(glance.Field(glance.Expression)),
  after: List(glance.Field(glance.Expression)),
) -> #(Type, State) {
  // `f(a, _, b)` becomes `fn(x) { f(a, x, b) }`.
  let #(hole, st) = fresh(st)
  let #(fn_type, st) = infer_expr(env, st, function)
  let #(before_types, st) =
    infer_each(env, st, list.map(before, field_item))
  let #(after_types, st) = infer_each(env, st, list.map(after, field_item))
  let arg_types = list.flatten([before_types, [hole], after_types])
  let #(result, st) = fresh(st)
  let st = unify(st, fn_type, Fn(arg_types, result))
  let captured = Fn([hole], result)
  #(captured, record(st, span, captured))
}

fn infer_binop(
  env: Env,
  st: State,
  span: glance.Span,
  op: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> #(Type, State) {
  case op {
    glance.Pipe -> infer_pipe(env, st, span, left, right)

    glance.And | glance.Or -> {
      let st = check(env, st, left, types.bool())
      let st = check(env, st, right, types.bool())
      #(types.bool(), st)
    }

    glance.Eq | glance.NotEq -> {
      let #(lt, st) = infer_expr(env, st, left)
      let #(rt, st) = infer_expr(env, st, right)
      #(types.bool(), unify(st, lt, rt))
    }

    glance.Concatenate -> {
      let st = check(env, st, left, types.string())
      let st = check(env, st, right, types.string())
      #(types.string(), st)
    }

    glance.AddInt
    | glance.SubInt
    | glance.MultInt
    | glance.DivInt
    | glance.RemainderInt -> {
      let st = check(env, st, left, types.int())
      let st = check(env, st, right, types.int())
      #(types.int(), st)
    }

    glance.AddFloat | glance.SubFloat | glance.MultFloat | glance.DivFloat -> {
      let st = check(env, st, left, types.float())
      let st = check(env, st, right, types.float())
      #(types.float(), st)
    }

    glance.LtInt | glance.LtEqInt | glance.GtInt | glance.GtEqInt -> {
      let st = check(env, st, left, types.int())
      let st = check(env, st, right, types.int())
      #(types.bool(), st)
    }

    glance.LtFloat | glance.LtEqFloat | glance.GtFloat | glance.GtEqFloat -> {
      let st = check(env, st, left, types.float())
      let st = check(env, st, right, types.float())
      #(types.bool(), st)
    }
  }
}

fn infer_pipe(
  env: Env,
  st: State,
  span: glance.Span,
  left: glance.Expression,
  right: glance.Expression,
) -> #(Type, State) {
  case right {
    // `left |> f(args)` becomes `f(left, args)`.
    glance.Call(call_span, function, arguments) ->
      infer_call(env, st, call_span, function, [
        glance.UnlabelledField(left),
        ..arguments
      ])
    // `left |> f` becomes `f(left)`.
    _ -> {
      let #(lt, st) = infer_expr(env, st, left)
      let #(ft, st) = infer_expr(env, st, right)
      let #(result, st) = fresh(st)
      let st = unify(st, ft, Fn([lt], result))
      #(result, record(st, span, result))
    }
  }
}

/// Infer an expression and unify it against an expected type.
fn check(env: Env, st: State, expr: glance.Expression, expected: Type) -> State {
  let #(t, st) = infer_expr(env, st, expr)
  unify(st, t, expected)
}

// --- Statements ------------------------------------------------------------

fn infer_statements(
  env: Env,
  st: State,
  statements: List(glance.Statement),
) -> #(Type, State) {
  case statements {
    [] -> #(types.nil(), st)
    // `use pats <- rhs` turns the remaining statements into a trailing callback.
    [glance.Use(_, patterns, function), ..rest] ->
      infer_use(env, st, patterns, function, rest)
    [last] -> {
      let #(t, _env, st) = infer_statement(env, st, last)
      #(t, st)
    }
    [first, ..rest] -> {
      let #(_t, env, st) = infer_statement(env, st, first)
      infer_statements(env, st, rest)
    }
  }
}

/// Desugar `use a, b <- rhs` followed by `rest` into `rhs(.., fn(a, b) { rest })`
/// and infer the resulting call.
fn infer_use(
  env: Env,
  st: State,
  use_patterns: List(glance.UsePattern),
  function: glance.Expression,
  rest: List(glance.Statement),
) -> #(Type, State) {
  // Build the callback: its parameters are the use patterns, its body is the
  // rest of the block.
  let #(rev_param_types, callback_env, st) =
    list.fold(use_patterns, #([], env, st), fn(acc, use_pattern) {
      let #(types_, env, st) = acc
      let #(param, st) = case use_pattern.annotation {
        Some(ann) -> hydrate(env, st, ann)
        None -> fresh(st)
      }
      let #(env, st) = infer_pattern(env, st, use_pattern.pattern, param)
      #([param, ..types_], env, st)
    })
  let param_types = list.reverse(rev_param_types)
  let #(body_type, st) = infer_statements(callback_env, st, rest)
  let callback_type = Fn(param_types, body_type)

  // The right-hand side is called with the callback appended as its last
  // argument.
  let #(result, st) = fresh(st)
  let st = case function {
    glance.Call(_, callee, arguments) -> {
      let #(callee_type, st) = infer_expr(env, st, callee)
      let ordered =
        order_fields(env, callee, arguments, fn(label, location) {
          glance.Variable(location, label)
        })
      let #(arg_types, st) = infer_each(env, st, ordered)
      unify(st, callee_type, Fn(list.append(arg_types, [callback_type]), result))
    }
    other -> {
      let #(callee_type, st) = infer_expr(env, st, other)
      unify(st, callee_type, Fn([callback_type], result))
    }
  }
  #(result, st)
}

/// Infer one statement, returning its type and the (possibly extended)
/// environment to thread to following statements.
fn infer_statement(
  env: Env,
  st: State,
  statement: glance.Statement,
) -> #(Type, Env, State) {
  case statement {
    glance.Expression(expr) -> {
      let #(t, st) = infer_expr(env, st, expr)
      #(t, env, st)
    }

    glance.Assignment(_, _kind, pattern, annotation, value) -> {
      let #(value_type, st) = infer_expr(env, st, value)
      let st = case annotation {
        Some(ann) -> {
          let #(t, st) = hydrate(env, st, ann)
          unify(st, value_type, t)
        }
        None -> st
      }
      let #(env, st) = infer_pattern(env, st, pattern, value_type)
      #(value_type, env, st)
    }

    glance.Assert(_, expression, _message) -> {
      let st = check(env, st, expression, types.bool())
      #(types.nil(), env, st)
    }

    glance.Use(..) -> panic as "use expressions not yet supported"
  }
}

// --- Case expressions ------------------------------------------------------

fn infer_case(
  env: Env,
  st: State,
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
) -> #(Type, State) {
  let #(subject_types, st) = infer_each(env, st, subjects)
  let #(result, st) = fresh(st)
  let st =
    list.fold(clauses, st, fn(st, clause) {
      infer_clause(env, st, clause, subject_types, result)
    })
  #(result, st)
}

fn infer_clause(
  env: Env,
  st: State,
  clause: glance.Clause,
  subject_types: List(Type),
  result: Type,
) -> State {
  // Each clause may have several alternative pattern lists (`a | b ->`); each
  // binds the same variables and is checked against the subject types.
  list.fold(clause.patterns, st, fn(st, patterns) {
    let #(clause_env, st) =
      list.fold(
        list.zip(patterns, subject_types),
        #(env, st),
        fn(acc, pair) {
          let #(env, st) = acc
          let #(pattern, subject) = pair
          infer_pattern(env, st, pattern, subject)
        },
      )
    let st = case clause.guard {
      Some(guard) -> check(clause_env, st, guard, types.bool())
      None -> st
    }
    let #(body_type, st) = infer_expr(clause_env, st, clause.body)
    unify(st, body_type, result)
  })
}

// --- Patterns --------------------------------------------------------------

fn infer_pattern(
  env: Env,
  st: State,
  pattern: glance.Pattern,
  expected: Type,
) -> #(Env, State) {
  case pattern {
    glance.PatternInt(..) -> #(env, unify(st, expected, types.int()))
    glance.PatternFloat(..) -> #(env, unify(st, expected, types.float()))
    glance.PatternString(..) -> #(env, unify(st, expected, types.string()))
    glance.PatternDiscard(..) -> #(env, st)

    glance.PatternVariable(_, name) -> #(
      bind_value(env, name, Scheme([], expected)),
      st,
    )

    glance.PatternTuple(_, elements) -> {
      let #(elem_types, st) =
        list.fold(elements, #([], st), fn(acc, _) {
          let #(types_, st) = acc
          let #(t, st) = fresh(st)
          #([t, ..types_], st)
        })
      let elem_types = list.reverse(elem_types)
      let st = unify(st, expected, Tuple(elem_types))
      list.fold(list.zip(elements, elem_types), #(env, st), fn(acc, pair) {
        let #(env, st) = acc
        let #(pattern, t) = pair
        infer_pattern(env, st, pattern, t)
      })
    }

    glance.PatternList(_, elements, tail) -> {
      let #(elem, st) = fresh(st)
      let st = unify(st, expected, types.list(elem))
      let #(env, st) =
        list.fold(elements, #(env, st), fn(acc, p) {
          let #(env, st) = acc
          infer_pattern(env, st, p, elem)
        })
      case tail {
        Some(t) -> infer_pattern(env, st, t, types.list(elem))
        None -> #(env, st)
      }
    }

    glance.PatternAssignment(_, pattern, name) -> {
      let env = bind_value(env, name, Scheme([], expected))
      infer_pattern(env, st, pattern, expected)
    }

    glance.PatternConcatenate(_, _prefix, _prefix_name, rest_name) -> {
      let st = unify(st, expected, types.string())
      let env = case rest_name {
        glance.Named(name) -> bind_value(env, name, Scheme([], types.string()))
        glance.Discarded(_) -> env
      }
      #(env, st)
    }

    glance.PatternVariant(_, _module, constructor, arguments, _spread) -> {
      let scheme = case dict.get(env.values, constructor) {
        Ok(scheme) -> scheme
        Error(_) -> panic as { "unknown constructor: " <> constructor }
      }
      let #(ctor_type, st) = instantiate(st, scheme)
      // A constructor with fields is a function; one without is the value.
      let #(field_types, ret) = case ctor_type {
        Fn(args, ret) -> #(args, ret)
        other -> #([], other)
      }
      let st = unify(st, expected, ret)
      let arg_patterns =
        order_pattern_args(env, constructor, arguments, list.length(field_types))
      list.fold(list.zip(arg_patterns, field_types), #(env, st), fn(acc, pair) {
        let #(env, st) = acc
        let #(pattern, t) = pair
        infer_pattern(env, st, pattern, t)
      })
    }

    glance.PatternBitString(_, segments) -> {
      let st = unify(st, expected, types.bit_array())
      list.fold(segments, #(env, st), fn(acc, segment) {
        let #(env, st) = acc
        let #(pattern, options) = segment
        let #(env, st) =
          infer_pattern(env, st, pattern, segment_value_type(options))
        list.fold(options, #(env, st), fn(acc, option) {
          let #(env, st) = acc
          case option {
            glance.SizeValueOption(size) ->
              infer_pattern(env, st, size, types.int())
            _ -> #(env, st)
          }
        })
      })
    }
  }
}

/// The value type of a bit-array segment, inferred from its options
/// (defaulting to `Int`).
fn segment_value_type(options: List(glance.BitStringSegmentOption(t))) -> Type {
  list.fold(options, types.int(), fn(acc, option) {
    case option {
      glance.FloatOption -> types.float()
      glance.Utf8Option | glance.Utf16Option | glance.Utf32Option ->
        types.string()
      glance.Utf8CodepointOption
      | glance.Utf16CodepointOption
      | glance.Utf32CodepointOption -> types.utf_codepoint()
      glance.BytesOption | glance.BitsOption -> types.bit_array()
      glance.IntOption -> types.int()
      _ -> acc
    }
  })
}

/// Place constructor-pattern arguments into positional order, reordering by the
/// constructor's field map and filling positions omitted via `..` with
/// discards.
fn order_pattern_args(
  env: Env,
  constructor: String,
  arguments: List(glance.Field(glance.Pattern)),
  arity: Int,
) -> List(glance.Pattern) {
  let labels = case dict.get(env.field_maps, constructor) {
    Ok(labels) -> labels
    Error(_) -> []
  }
  let index_of =
    list.index_fold(labels, dict.new(), fn(acc, label, index) {
      case label {
        Some(name) -> dict.insert(acc, name, index)
        None -> acc
      }
    })
  let #(placed, _next) =
    list.fold(arguments, #(dict.new(), 0), fn(acc, field) {
      let #(placed, next) = acc
      case field {
        glance.UnlabelledField(item) -> #(dict.insert(placed, next, item), next + 1)
        glance.LabelledField(label, _, item) -> #(
          dict.insert(placed, label_index(index_of, label), item),
          next,
        )
        glance.ShorthandField(label, location) -> #(
          dict.insert(
            placed,
            label_index(index_of, label),
            glance.PatternVariable(location, label),
          ),
          next,
        )
      }
    })
  list.map(indices(arity), fn(index) {
    case dict.get(placed, index) {
      Ok(pattern) -> pattern
      // Omitted via `..`: bind nothing.
      Error(_) -> glance.PatternDiscard(glance.Span(0, 0), "_")
    }
  })
}

/// `[0, 1, ..., n - 1]`.
fn indices(n: Int) -> List(Int) {
  indices_loop(n - 1, [])
}

fn indices_loop(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> indices_loop(i - 1, [i, ..acc])
  }
}

// --- Type annotation hydration ---------------------------------------------

/// Convert a written type annotation into an internal `Type`. Type-variable
/// names introduced here all become fresh unbound variables (sufficient for
/// milestone 1; named-variable sharing across one signature is a refinement).
pub fn hydrate(env: Env, st: State, ast: glance.Type) -> #(Type, State) {
  hydrate_with(env, dict.new(), st, ast).0
}

fn hydrate_with(
  env: Env,
  names: Dict(String, Type),
  st: State,
  ast: glance.Type,
) -> #(#(Type, State), Dict(String, Type)) {
  case ast {
    glance.NamedType(_, name, module, parameters) -> {
      let #(arg_types, st, names) =
        list.fold(parameters, #([], st, names), fn(acc, p) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, p)
          #([t, ..types_], st, names)
        })
      let arg_types = list.reverse(arg_types)
      // A local reference to a type alias is expanded to its definition.
      case module, dict.get(env.aliases, name) {
        None, Ok(#(params, aliased)) -> {
          let alias_names = dict.from_list(list.zip(params, arg_types))
          let #(#(t, st), _) = hydrate_with(env, alias_names, st, aliased)
          #(#(t, st), names)
        }
        // A bare type name: resolve it to its origin module if known,
        // otherwise assume it is a prelude type.
        None, _ ->
          case dict.get(env.local_types, name) {
            Ok(#(origin, _arity)) -> #(#(Named(origin, name, arg_types), st), names)
            Error(_) -> #(
              #(Named(types.prelude_module, name, arg_types), st),
              names,
            )
          }
        // A qualified type name `alias.Name`: resolve via the imported module.
        Some(alias), _ -> {
          let origin = case dict.get(env.modules, alias) {
            Ok(interface) ->
              case dict.get(interface.types, name) {
                Ok(#(origin, _arity)) -> origin
                Error(_) -> alias
              }
            Error(_) -> alias
          }
          #(#(Named(origin, name, arg_types), st), names)
        }
      }
    }

    glance.TupleType(_, elements) -> {
      let #(elem_types, st, names) =
        list.fold(elements, #([], st, names), fn(acc, e) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, e)
          #([t, ..types_], st, names)
        })
      #(#(Tuple(list.reverse(elem_types)), st), names)
    }

    glance.FunctionType(_, parameters, return) -> {
      let #(param_types, st, names) =
        list.fold(parameters, #([], st, names), fn(acc, p) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, p)
          #([t, ..types_], st, names)
        })
      let #(#(ret, st), names) = hydrate_with(env, names, st, return)
      #(#(Fn(list.reverse(param_types), ret), st), names)
    }

    glance.VariableType(_, name) ->
      case dict.get(names, name) {
        Ok(t) -> #(#(t, st), names)
        Error(_) -> {
          let #(t, st) = fresh(st)
          #(#(t, st), dict.insert(names, name, t))
        }
      }

    glance.HoleType(..) -> {
      let #(t, st) = fresh(st)
      #(#(t, st), names)
    }
  }
}

// --- Top-level definitions -------------------------------------------------

/// Infer a top-level function, returning its (still ungeneralized) `Fn` type.
pub fn infer_function(
  env: Env,
  st: State,
  function: glance.Function,
) -> #(Type, State) {
  // Type-variable names are shared across the whole signature so that, e.g.,
  // a parameter `a` and the return `a` refer to the same variable.
  let #(rev_param_types, body_env, st, names) =
    list.fold(function.parameters, #([], env, st, dict.new()), fn(acc, param) {
      let #(types_, env, st, names) = acc
      let #(t, st, names) = case param.type_ {
        Some(ann) -> hydrate_threaded(env, names, st, ann)
        None -> {
          let #(t, st) = fresh(st)
          #(t, st, names)
        }
      }
      let env = case param.name {
        glance.Named(name) -> bind_value(env, name, Scheme([], t))
        glance.Discarded(_) -> env
      }
      #([t, ..types_], env, st, names)
    })
  let param_types = list.reverse(rev_param_types)
  case function.body {
    // External functions (e.g. `@external`) have no body; their type comes
    // entirely from the signature annotations.
    [] -> {
      let #(return_type, st) = case function.return {
        Some(ann) -> {
          let #(t, st, _names) = hydrate_threaded(env, names, st, ann)
          #(t, st)
        }
        None -> fresh(st)
      }
      #(Fn(param_types, return_type), st)
    }
    _ -> {
      let #(body_type, st) = infer_statements(body_env, st, function.body)
      let st = case function.return {
        Some(ann) -> {
          let #(t, st, _names) = hydrate_threaded(env, names, st, ann)
          unify(st, body_type, t)
        }
        None -> st
      }
      #(Fn(param_types, body_type), st)
    }
  }
}

/// Infer a module constant, returning its type (an annotation, if present, is
/// applied).
pub fn infer_constant(
  env: Env,
  st: State,
  constant: glance.Constant,
) -> #(Type, State) {
  let #(value_type, st) = infer_expr(env, st, constant.value)
  case constant.annotation {
    Some(ann) -> {
      let #(t, st) = hydrate(env, st, ann)
      #(value_type, unify(st, value_type, t))
    }
    None -> #(value_type, st)
  }
}

/// Register a custom type's constructors as value schemes in the environment,
/// generalized over the type's parameters.
pub fn register_custom_type(
  env: Env,
  st: State,
  custom_type: glance.CustomType,
) -> #(Env, State) {
  // Record the type as local first so its own fields can refer to it.
  let env = declare_type(env, custom_type.name, list.length(custom_type.parameters))
  let #(rev_param_vars, st) =
    list.fold(custom_type.parameters, #([], st), fn(acc, _name) {
      let #(vars, st) = acc
      let #(v, st) = fresh(st)
      #([v, ..vars], st)
    })
  let param_vars = list.reverse(rev_param_vars)
  let names = dict.from_list(list.zip(custom_type.parameters, param_vars))
  let param_ids =
    list.map(param_vars, fn(v) {
      case v {
        Var(id) -> id
        _ -> panic as "expected fresh var"
      }
    })
  let return_type = Named(env.current_module, custom_type.name, param_vars)

  let #(env, st) =
    list.fold(custom_type.variants, #(env, st), fn(acc, variant) {
      let #(env, st) = acc
      let #(rev_field_types, st) =
        list.fold(variant.fields, #([], st), fn(acc, field) {
          let #(types_, st) = acc
          let #(t, st) = hydrate_in(env, names, st, variant_field_type(field))
          #([t, ..types_], st)
        })
      let field_types = list.reverse(rev_field_types)
      let ctor_type = case field_types {
        [] -> return_type
        _ -> Fn(field_types, return_type)
      }
      let env =
        register_field_map(env, variant.name, list.map(variant.fields, fn(f) {
          case f {
            glance.LabelledVariantField(_, label) -> Some(label)
            glance.UnlabelledVariantField(..) -> None
          }
        }))
      #(bind_value(env, variant.name, Scheme(param_ids, ctor_type)), st)
    })

  // Register field accessors. We currently only do this for single-variant
  // records; shared fields across variants are a later refinement.
  case custom_type.variants {
    [variant] -> {
      let #(accessors, st) =
        list.fold(variant.fields, #(dict.new(), st), fn(acc, field) {
          let #(accessors, st) = acc
          case field {
            glance.LabelledVariantField(item, label) -> {
              let #(field_type, st) = hydrate_in(env, names, st, item)
              let scheme = Scheme(param_ids, Fn([return_type], field_type))
              #(dict.insert(accessors, label, scheme), st)
            }
            glance.UnlabelledVariantField(..) -> #(accessors, st)
          }
        })
      let env =
        Env(
          ..env,
          accessors: dict.insert(env.accessors, custom_type.name, accessors),
        )
      #(env, st)
    }
    _ -> #(env, st)
  }
}

/// Look up the accessor scheme for `type_name`.`label`.
fn accessor(env: Env, type_name: String, label: String) -> Scheme {
  case dict.get(env.accessors, type_name) {
    Ok(labels) ->
      case dict.get(labels, label) {
        Ok(scheme) -> scheme
        Error(_) -> panic as { "no field `" <> label <> "` on " <> type_name }
      }
    Error(_) -> panic as { "no accessors for type " <> type_name }
  }
}

fn variant_field_type(field: glance.VariantField) -> glance.Type {
  case field {
    glance.LabelledVariantField(item, _label) -> item
    glance.UnlabelledVariantField(item) -> item
  }
}

/// Hydrate using (and threading) a fixed type-variable name map.
fn hydrate_in(
  env: Env,
  names: Dict(String, Type),
  st: State,
  ast: glance.Type,
) -> #(Type, State) {
  hydrate_with(env, names, st, ast).0
}

/// Hydrate while threading the type-variable name map so repeated names within
/// one signature resolve to the same variable.
fn hydrate_threaded(
  env: Env,
  names: Dict(String, Type),
  st: State,
  ast: glance.Type,
) -> #(Type, State, Dict(String, Type)) {
  let #(#(t, st), names) = hydrate_with(env, names, st, ast)
  #(t, st, names)
}

// --- Small helpers ---------------------------------------------------------

fn span(expr: glance.Expression) -> glance.Span {
  case expr {
    glance.Int(s, _) -> s
    glance.Float(s, _) -> s
    glance.String(s, _) -> s
    glance.Variable(s, _) -> s
    glance.NegateInt(s, _) -> s
    glance.NegateBool(s, _) -> s
    glance.Block(s, _) -> s
    glance.Panic(s, _) -> s
    glance.Todo(s, _) -> s
    glance.Tuple(s, _) -> s
    glance.List(s, _, _) -> s
    glance.Fn(s, _, _, _) -> s
    glance.RecordUpdate(s, _, _, _, _) -> s
    glance.FieldAccess(s, _, _) -> s
    glance.Call(s, _, _) -> s
    glance.TupleIndex(s, _, _) -> s
    glance.FnCapture(s, _, _, _, _) -> s
    glance.BitString(s, _) -> s
    glance.Case(s, _, _) -> s
    glance.BinaryOperator(s, _, _, _) -> s
    glance.Echo(s, _, _) -> s
  }
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}
