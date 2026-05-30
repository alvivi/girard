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
//// Inference is total: anything that cannot be typed returns a `Result` with an
//// `Error` rather than crashing.

import girard/types.{type Scheme, type Type, Fn, Named, Scheme, Tuple, Var}
import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// --- Errors ----------------------------------------------------------------

/// A reason inference could not assign a type. We do not attempt recovery or
/// rich diagnostics; this is enough to explain and bucket failures.
pub type Error {
  TypeMismatch(left: Type, right: Type)
  ArityMismatch
  RecursiveType(id: Int, type_: Type)
  UnboundVariable(name: String)
  UnknownConstructor(name: String)
  UnknownModule(alias: String)
  NoSuchExport(module: String, name: String)
  NoSuchField(type_name: String, label: String)
  NotARecord
  NotATuple
  TupleIndexOutOfRange(index: Int)
  UnknownLabel(label: String)
  AmbiguousCall
  MissingArgument
  Unsupported(feature: String)
  ParseFailed(glance.Error)
}

// --- State & environment ---------------------------------------------------

pub type State {
  State(
    next_id: Int,
    /// Bound type variables. Absence means unbound.
    subst: Dict(Int, Type),
    /// Inferred type recorded for each annotated source span, in reverse order
    /// of discovery. Types are stored "live" and zonked at the end.
    annotations: List(#(glance.Span, Type)),
    /// Field accesses and tuple indexes whose container type was not yet known
    /// when encountered; resolved by `resolve_pending` once inference has fixed
    /// the container type (deferred resolution, like the real compiler).
    pending: List(Pending),
  )
}

/// A deferred access awaiting its container's type.
pub type Pending {
  /// `record.label` — the field type goes in `result`.
  PendingField(container: Type, label: String, result: Type)
  /// `tuple.index` — the element type goes in `result`.
  PendingIndex(container: Type, index: Int, result: Type)
}

pub type Env {
  Env(
    /// Value bindings in scope: locals, parameters, top-level functions and
    /// custom-type constructors.
    values: Dict(String, Scheme),
    /// Locally-defined type aliases: name -> (parameter names, aliased type
    /// AST), expanded during hydration in this module's environment.
    aliases: Dict(String, #(List(String), glance.Type)),
    /// Type aliases brought in by unqualified imports, already resolved to a
    /// type with the alias's parameters as variables (param ids + body), so
    /// they need no re-hydration in this module's environment.
    imported_aliases: Dict(String, #(List(Int), Type)),
    /// Record field accessors: type name -> label -> a scheme for
    /// `fn(record) -> field`, generalized over the type's parameters.
    accessors: Dict(String, Dict(String, Scheme)),
    /// In-scope type names -> (origin module, origin name, arity). Covers types
    /// defined in the current module and types brought in by unqualified
    /// imports. Used during hydration to resolve a bare type name to its module
    /// and to the name it has *there* — an `import x.{type T as U}` is in scope
    /// as `U` but must hydrate to `x`'s `T`, not a phantom `x.U`.
    local_types: Dict(String, #(String, String, Int)),
    /// Field maps for callables (functions and constructors): name -> the
    /// label of each positional parameter (`None` where unlabelled). Used to
    /// reorder labelled and shorthand arguments at call/pattern sites.
    field_maps: Dict(String, List(Option(String))),
    /// Variables that a pattern has narrowed to a specific constructor variant
    /// (e.g. `Element(..) as e`), mapping the variable to that variant's
    /// `label -> field type` for the bound value. This lets `e.field` reach a
    /// field present in only some variants, mirroring the compiler's inferred
    /// variant narrowing. Field types are tied to the variable's own type.
    variants: Dict(String, Dict(String, Type)),
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
    types: Dict(String, #(String, String, Int)),
    /// Public type aliases, resolved to a type with the alias's parameters as
    /// variables (param ids + body).
    aliases: Dict(String, #(List(Int), Type)),
    accessors: Dict(String, Dict(String, Scheme)),
    field_maps: Dict(String, List(Option(String))),
    /// The modules this one imports, so a type it exposes from another module
    /// (e.g. a `glance.Span` field) keeps its accessors reachable transitively.
    modules: Dict(String, ModuleInterface),
  )
}

fn new_state() -> State {
  State(next_id: 0, subst: dict.new(), annotations: [], pending: [])
}

fn new_env() -> Env {
  Env(
    values: dict.new(),
    aliases: dict.new(),
    imported_aliases: dict.new(),
    accessors: dict.new(),
    local_types: dict.new(),
    field_maps: dict.new(),
    variants: dict.new(),
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
    local_types: dict.insert(env.local_types, name, #(
      env.current_module,
      name,
      arity,
    )),
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

fn fresh_id(st: State) -> #(Int, State) {
  #(st.next_id, State(..st, next_id: st.next_id + 1))
}

fn fresh(st: State) -> #(Type, State) {
  let #(id, st) = fresh_id(st)
  #(Var(id), st)
}

fn var_id(type_: Type) -> Int {
  case type_ {
    Var(id) -> id
    _ -> 0
  }
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
  let #(ok_a, st) = fresh_id(st)
  let #(ok_e, st) = fresh_id(st)
  let env =
    bind_value(
      env,
      "Ok",
      Scheme([ok_a, ok_e], Fn([Var(ok_a)], types.result(Var(ok_a), Var(ok_e)))),
    )

  // Error(e) -> Result(a, e)
  let #(err_a, st) = fresh_id(st)
  let #(err_e, st) = fresh_id(st)
  let env =
    bind_value(
      env,
      "Error",
      Scheme(
        [err_a, err_e],
        Fn([Var(err_e)], types.result(Var(err_a), Var(err_e))),
      ),
    )

  #(env, st)
}

/// The implicit `gleam` prelude module's public interface, used to resolve
/// `import gleam` / `import gleam.{Error as Err}`. The prelude has no source
/// file; the compiler treats `gleam` as a built-in module exposing the prelude
/// types and value constructors.
pub fn prelude_interface() -> ModuleInterface {
  let m = types.prelude_module
  let values =
    dict.from_list([
      #("True", Scheme([], types.bool())),
      #("False", Scheme([], types.bool())),
      #("Nil", Scheme([], types.nil())),
      #("Ok", Scheme([0, 1], Fn([Var(0)], types.result(Var(0), Var(1))))),
      #("Error", Scheme([0, 1], Fn([Var(1)], types.result(Var(0), Var(1))))),
    ])
  let types_ =
    dict.from_list([
      #("Int", #(m, "Int", 0)),
      #("Float", #(m, "Float", 0)),
      #("String", #(m, "String", 0)),
      #("Bool", #(m, "Bool", 0)),
      #("Nil", #(m, "Nil", 0)),
      #("BitArray", #(m, "BitArray", 0)),
      #("UtfCodepoint", #(m, "UtfCodepoint", 0)),
      #("List", #(m, "List", 1)),
      #("Result", #(m, "Result", 2)),
    ])
  ModuleInterface(
    name: m,
    values: values,
    types: types_,
    aliases: dict.new(),
    accessors: dict.new(),
    field_maps: dict.new(),
    modules: dict.new(),
  )
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
  st: State,
  name: String,
  value_names: List(String),
  type_names: List(String),
) -> ModuleInterface {
  ModuleInterface(
    name: name,
    values: take(env.values, value_names),
    types: take(env.local_types, type_names),
    aliases: resolve_aliases(env, st, type_names),
    accessors: take(env.accessors, type_names),
    field_maps: take(env.field_maps, value_names),
    modules: env.modules,
  )
}

/// Resolve each named public alias to a concrete type, in this module's full
/// environment, with the alias's parameters as variables. Resolving here (not
/// when the alias is used elsewhere) keeps the bodies' type references — which
/// may be imported into this module — correctly attributed.
fn resolve_aliases(
  env: Env,
  st: State,
  type_names: List(String),
) -> Dict(String, #(List(Int), Type)) {
  list.fold(type_names, #(dict.new(), st), fn(acc, name) {
    let #(resolved, st) = acc
    case dict.get(env.aliases, name) {
      Error(_) -> #(resolved, st)
      Ok(#(params, body)) -> {
        let #(param_vars, st) = fresh_n(st, list.length(params))
        let param_ids = list.map(param_vars, var_id)
        let names = dict.from_list(list.zip(params, param_vars))
        let #(type_, st) = hydrate_in(env, names, st, body)
        #(dict.insert(resolved, name, #(param_ids, type_)), st)
      }
    }
  }).0
}

/// Instantiate a resolved alias `#(param ids, body)` with concrete arguments.
fn instantiate_alias(
  params: List(Int),
  body: Type,
  arguments: List(Type),
) -> Type {
  substitute(dict.from_list(list.zip(params, arguments)), body)
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
pub fn import_qualified(
  env: Env,
  alias: String,
  interface: ModuleInterface,
) -> Env {
  // Bring the module's own imports along (under their aliases, but not
  // overriding the importer's direct imports) so types it exposes from other
  // modules keep their accessors reachable. Then bind the module itself.
  let modules =
    dict.fold(env.modules, interface.modules, fn(acc, alias, interface) {
      dict.insert(acc, alias, interface)
    })
  Env(..env, modules: dict.insert(modules, alias, interface))
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
    Ok(info) ->
      Env(..env, local_types: dict.insert(env.local_types, local, info))
    Error(_) -> env
  }
  let env = case dict.get(interface.aliases, original) {
    Ok(alias) ->
      Env(
        ..env,
        imported_aliases: dict.insert(env.imported_aliases, local, alias),
      )
    Error(_) -> env
  }
  case dict.get(interface.accessors, original) {
    Ok(accessors) ->
      Env(..env, accessors: dict.insert(env.accessors, local, accessors))
    Error(_) -> env
  }
}

// --- Substitution: resolve / zonk / free variables -------------------------

/// Follow bound variables one level to expose the head constructor.
fn resolve(st: State, type_: Type) -> Type {
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
      free_vars_loop(
        ret,
        list.fold(args, acc, fn(a, t) { free_vars_loop(t, a) }),
      )
    Tuple(elements) ->
      list.fold(elements, acc, fn(a, t) { free_vars_loop(t, a) })
  }
}

fn env_free_vars(st: State, env: Env) -> List(Int) {
  dict.fold(env.values, [], fn(acc, _name, scheme) {
    // A scheme's quantified variables are bound *within the scheme*; they must
    // not be resolved against the ambient substitution. This matters because
    // imported schemes carry variable ids minted in their own module, which can
    // collide with — and have since been bound to unrelated types by — the
    // importing module's substitution. Treating them as opaque (rather than
    // zonking them) keeps such collisions from leaking phantom free variables
    // that would wrongly block generalization here.
    scheme_free_vars(st, scheme.type_, scheme.vars, acc)
  })
}

/// Free variables of `type_`, treating `bound` ids as opaque: a bound id
/// contributes nothing and is never resolved through the substitution, while a
/// free id is resolved and its remaining variables collected.
fn scheme_free_vars(
  st: State,
  type_: Type,
  bound: List(Int),
  acc: List(Int),
) -> List(Int) {
  case type_ {
    Var(id) ->
      case list.contains(bound, id) {
        True -> acc
        False ->
          case resolve(st, type_) {
            Var(resolved) ->
              case list.contains(acc, resolved) {
                True -> acc
                False -> [resolved, ..acc]
              }
            other -> scheme_free_vars(st, other, bound, acc)
          }
      }
    Named(_, _, args) ->
      list.fold(args, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) })
    Fn(args, ret) ->
      scheme_free_vars(
        st,
        ret,
        bound,
        list.fold(args, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) }),
      )
    Tuple(elements) ->
      list.fold(elements, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) })
  }
}

// --- Unification -----------------------------------------------------------

pub fn unify(st: State, a: Type, b: Type) -> Result(State, Error) {
  let a = resolve(st, a)
  let b = resolve(st, b)
  case a, b {
    Var(i), Var(j) if i == j -> Ok(st)
    Var(i), other -> bind_var(st, i, other)
    other, Var(j) -> bind_var(st, j, other)

    Named(m1, n1, a1), Named(m2, n2, a2) if m1 == m2 && n1 == n2 ->
      unify_many(st, a1, a2)

    Fn(args1, r1), Fn(args2, r2) -> {
      use st <- result.try(unify_many(st, args1, args2))
      unify(st, r1, r2)
    }

    Tuple(e1), Tuple(e2) -> unify_many(st, e1, e2)

    _, _ -> Error(TypeMismatch(a, b))
  }
}

fn unify_many(st: State, a: List(Type), b: List(Type)) -> Result(State, Error) {
  case a, b {
    [], [] -> Ok(st)
    [x, ..xs], [y, ..ys] -> {
      use st <- result.try(unify(st, x, y))
      unify_many(st, xs, ys)
    }
    _, _ -> Error(ArityMismatch)
  }
}

fn bind_var(st: State, id: Int, type_: Type) -> Result(State, Error) {
  case occurs(st, id, type_) {
    True -> Error(RecursiveType(id, type_))
    False -> Ok(State(..st, subst: dict.insert(st.subst, id, type_)))
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

/// Generalize a type over a specific set of candidate variable ids only (the
/// rest stay monomorphic). Used for a `let`-bound function, which Gleam makes
/// polymorphic over exactly the type variables written in its annotations.
fn generalize_over(
  st: State,
  env: Env,
  type_: Type,
  candidate_ids: List(Int),
) -> Scheme {
  let zonked = zonk(st, type_)
  let env_vars = env_free_vars(st, env)
  let free = free_vars(st, zonked)
  // Each annotation var may have been unified with another; follow it to its
  // representative and keep it only if it is still a free variable of the type.
  let reps =
    list.filter_map(candidate_ids, fn(id) {
      case zonk(st, Var(id)) {
        Var(rep) -> Ok(rep)
        _ -> Error(Nil)
      }
    })
  let quantified =
    list.unique(
      list.filter(reps, fn(id) {
        list.contains(free, id) && !list.contains(env_vars, id)
      }),
    )
  Scheme(quantified, zonked)
}

/// The type-variable names written in a `fn`'s parameter and return annotations.
fn fn_annotation_var_names(
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
) -> List(String) {
  let from_params =
    list.flat_map(params, fn(p) {
      case p.type_ {
        Some(t) -> type_var_names(t)
        None -> []
      }
    })
  case return_annotation {
    Some(t) -> list.append(from_params, type_var_names(t))
    None -> from_params
  }
}

fn type_var_names(ast: glance.Type) -> List(String) {
  case ast {
    glance.VariableType(_, name) -> [name]
    glance.NamedType(_, _, _, parameters) ->
      list.flat_map(parameters, type_var_names)
    glance.TupleType(_, elements) -> list.flat_map(elements, type_var_names)
    glance.FunctionType(_, parameters, return) ->
      list.append(list.flat_map(parameters, type_var_names), type_var_names(
        return,
      ))
    glance.HoleType(..) -> []
  }
}

/// Instantiate a scheme by replacing each quantified variable with a fresh one.
fn instantiate(st: State, scheme: Scheme) -> #(Type, State) {
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

fn infer_expr(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(Type, State), Error) {
  use #(type_, st) <- result.try(infer_expr_inner(env, st, expr))
  Ok(#(type_, record(st, span(expr), type_)))
}

fn infer_expr_inner(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(Type, State), Error) {
  case expr {
    glance.Int(..) -> Ok(#(types.int(), st))
    glance.Float(..) -> Ok(#(types.float(), st))
    glance.String(..) -> Ok(#(types.string(), st))

    glance.Variable(_, name) ->
      case dict.get(env.values, name) {
        Ok(scheme) -> Ok(instantiate(st, scheme))
        Error(_) -> Error(UnboundVariable(name))
      }

    glance.NegateInt(_, value) -> {
      use #(t, st) <- result.try(infer_expr(env, st, value))
      use st <- result.try(unify(st, t, types.int()))
      Ok(#(types.int(), st))
    }

    glance.NegateBool(_, value) -> {
      use #(t, st) <- result.try(infer_expr(env, st, value))
      use st <- result.try(unify(st, t, types.bool()))
      Ok(#(types.bool(), st))
    }

    glance.Tuple(_, elements) -> {
      use #(elem_types, st) <- result.try(infer_each(env, st, elements))
      Ok(#(Tuple(elem_types), st))
    }

    glance.List(_, elements, rest) -> {
      let #(elem, st) = fresh(st)
      use st <- result.try(
        list.try_fold(elements, st, fn(st, e) {
          use #(t, st) <- result.try(infer_expr(env, st, e))
          unify(st, t, elem)
        }),
      )
      use st <- result.try(case rest {
        Some(r) -> {
          use #(t, st) <- result.try(infer_expr(env, st, r))
          unify(st, t, types.list(elem))
        }
        None -> Ok(st)
      })
      Ok(#(types.list(elem), st))
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

    glance.Case(_, subjects, clauses) -> infer_case(env, st, subjects, clauses)

    glance.TupleIndex(_, tuple, index) -> {
      use #(t, st) <- result.try(infer_expr(env, st, tuple))
      case resolve(st, t) {
        Tuple(elements) ->
          case list_at(elements, index) {
            Ok(element) -> Ok(#(element, st))
            Error(_) -> Error(TupleIndexOutOfRange(index))
          }
        // The tuple type is not known yet; defer until inference fixes it.
        Var(_) -> {
          let #(element, st) = fresh(st)
          let st =
            State(..st, pending: [PendingIndex(t, index, element), ..st.pending])
          Ok(#(element, st))
        }
        _ -> Error(NotATuple)
      }
    }

    glance.Todo(..) | glance.Panic(..) -> Ok(fresh(st))

    glance.Echo(_, expression, _message) ->
      case expression {
        Some(e) -> infer_expr(env, st, e)
        None -> Ok(#(types.nil(), st))
      }

    glance.FieldAccess(_, container, label) ->
      infer_field_access(env, st, container, label)

    glance.RecordUpdate(_, module, constructor, record, fields) ->
      infer_record_update(env, st, module, constructor, record, fields)

    glance.BitString(_, segments) -> {
      use st <- result.try(
        list.try_fold(segments, st, fn(st, segment) {
          let #(value, options) = segment
          let default = case value {
            glance.String(..) -> types.string()
            glance.Float(..) -> types.float()
            _ -> types.int()
          }
          use st <- result.try(check(
            env,
            st,
            value,
            segment_value_type(options, default),
          ))
          list.try_fold(options, st, fn(st, option) {
            case option {
              glance.SizeValueOption(size) -> check(env, st, size, types.int())
              _ -> Ok(st)
            }
          })
        }),
      )
      Ok(#(types.bit_array(), st))
    }
  }
}

fn infer_field_access(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
) -> Result(#(Type, State), Error) {
  // A variable narrowed to a variant by a pattern (`Ctor(..) as v`) resolves
  // `v.field` from that variant's recorded fields, reaching fields not shared
  // by every variant.
  let variant_field = case container {
    glance.Variable(_, name) ->
      case dict.get(env.variants, name) {
        Ok(fields) -> dict.get(fields, label)
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  // `module.value` qualified access. This is only a *candidate*: a local value
  // of the same spelling shadows the module (lexical scoping), so a value whose
  // type is a record exposing `label` wins. A value that is not such a record
  // (e.g. a `dynamic` constant beside a `gleam/dynamic` import) falls through to
  // the module export.
  let module_access = case container {
    glance.Variable(_, name) ->
      case dict.get(env.modules, name) {
        Ok(interface) -> dict.get(interface.values, label)
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case variant_field {
    Ok(field) -> Ok(#(field, st))
    Error(_) ->
      case container {
        // A bound value whose type is a record exposing `label` resolves to
        // that field, even when its name also spells an imported module (a
        // `compression` parameter beside a `compression` module). A value whose
        // type lacks the field (a `dict` parameter beside the `gleam/dict`
        // module, accessing `dict.fold`) falls through to the module export.
        glance.Variable(_, name) ->
          case dict.has_key(env.values, name) {
            True -> value_field(env, st, container, label, module_access)
            False -> module_or_record(env, st, container, label, module_access)
          }
        _ -> module_or_record(env, st, container, label, module_access)
      }
  }
}

/// Field access where the container names a bound value: prefer a record field
/// when the value's type has it, else a same-named module export.
fn value_field(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
  module_access: Result(Scheme, Nil),
) -> Result(#(Type, State), Error) {
  use #(container_type, st) <- result.try(infer_expr(env, st, container))
  case resolve(st, container_type) {
    Named(_, _, _) as record ->
      case accessor(env, record, label) {
        Ok(_) -> field_type(env, st, record, label)
        // Not a field of this record; a same-named module may export it.
        Error(field_error) ->
          case module_access {
            Ok(scheme) -> Ok(instantiate(st, scheme))
            Error(_) -> Error(field_error)
          }
      }
    // The record type is not known yet. Prefer a same-named module export;
    // otherwise defer until inference fixes the type.
    Var(_) ->
      case module_access {
        Ok(scheme) -> Ok(instantiate(st, scheme))
        Error(_) -> {
          let #(field, st) = fresh(st)
          let st =
            State(..st, pending: [
              PendingField(container_type, label, field),
              ..st.pending
            ])
          Ok(#(field, st))
        }
      }
    _ ->
      case module_access {
        Ok(scheme) -> Ok(instantiate(st, scheme))
        Error(_) -> Error(NotARecord)
      }
  }
}

/// Field access where the container is not a bound value: a qualified module
/// export takes precedence, else it is a record field on the container's value.
fn module_or_record(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
  module_access: Result(Scheme, Nil),
) -> Result(#(Type, State), Error) {
  case module_access {
    Ok(scheme) -> Ok(instantiate(st, scheme))
    Error(_) -> {
      use #(container_type, st) <- result.try(infer_expr(env, st, container))
      case resolve(st, container_type) {
        Named(_, _, _) as record -> {
          use #(field, st) <- result.try(field_type(env, st, record, label))
          Ok(#(field, st))
        }
        Var(_) -> {
          let #(field, st) = fresh(st)
          let st =
            State(..st, pending: [
              PendingField(container_type, label, field),
              ..st.pending
            ])
          Ok(#(field, st))
        }
        _ -> Error(NotARecord)
      }
    }
  }
}

/// Resolve `record.label` for a known record type, returning the field type.
fn field_type(
  env: Env,
  st: State,
  record: Type,
  label: String,
) -> Result(#(Type, State), Error) {
  // Resolve through the substitution: a caller may pass a variable that has
  // since been bound to the record type (e.g. record-update's kept fields).
  use accessor_scheme <- result.try(accessor(env, resolve(st, record), label))
  let #(accessor_type, st) = instantiate(st, accessor_scheme)
  let #(field, st) = fresh(st)
  use st <- result.try(unify(st, accessor_type, Fn([record], field)))
  Ok(#(field, st))
}

fn infer_record_update(
  env: Env,
  st: State,
  module: Option(String),
  constructor: String,
  record: glance.Expression,
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> Result(#(Type, State), Error) {
  // A record update produces a *fresh* value of the type: updated fields take
  // their new value's type and kept fields are copied from the record. This is
  // what lets an update change a type parameter, as in
  // `Request(..req, body:)` : `fn(Request(a), b) -> Request(b)` — the kept
  // fields tie only the parameters they share, not all of them.
  use scheme <- result.try(constructor_scheme(env, module, constructor))
  let #(ctor_type, st) = instantiate(st, scheme)
  let #(field_types, return_type) = case ctor_type {
    Fn(arguments, return) -> #(arguments, return)
    other -> #([], other)
  }
  case return_type {
    Named(type_module, type_name, type_parameters) -> {
      let labels = constructor_field_map(env, module, constructor)
      let label_types =
        list.fold(list.zip(labels, field_types), dict.new(), fn(acc, pair) {
          case pair.0 {
            Some(label) -> dict.insert(acc, label, pair.1)
            None -> acc
          }
        })
      let updated = list.map(fields, fn(field) { field.label })

      // Fix the record's head to this type with independent parameters, so its
      // own type variables aren't conflated with the result's.
      let #(record_parameters, st) = fresh_n(st, list.length(type_parameters))
      use #(record_type, st) <- result.try(infer_expr(env, st, record))
      use st <- result.try(unify(
        st,
        record_type,
        Named(type_module, type_name, record_parameters),
      ))

      // Updated fields take their new value's type.
      use st <- result.try(
        list.try_fold(fields, st, fn(st, field) {
          use #(value_type, st) <- result.try(case field.item {
            Some(value) -> infer_expr(env, st, value)
            // Shorthand `label:` refers to the variable named `label`.
            None ->
              case dict.get(env.values, field.label) {
                Ok(scheme) -> Ok(instantiate(st, scheme))
                Error(_) -> Error(UnboundVariable(field.label))
              }
          })
          case dict.get(label_types, field.label) {
            Ok(expected) -> unify(st, value_type, expected)
            Error(_) -> Error(NoSuchField(type_name, field.label))
          }
        }),
      )

      // Kept fields are copied from the record. The record carries the same
      // constructor, so each kept field's type is the constructor's field type
      // with the result's parameters swapped for the record's. Unifying the two
      // ties only the parameters a kept field actually uses, which is what lets
      // an *updated* field change a parameter. Deriving this from the named
      // constructor (rather than a field accessor) means it works even for
      // fields not shared by every variant of a multi-variant type.
      let to_record_params =
        dict.from_list(list.zip(
          list.map(type_parameters, var_id),
          record_parameters,
        ))
      use st <- result.try(
        list.try_fold(dict.to_list(label_types), st, fn(st, pair) {
          let #(label, expected) = pair
          case list.contains(updated, label) {
            True -> Ok(st)
            False -> unify(st, substitute(to_record_params, expected), expected)
          }
        }),
      )

      Ok(#(return_type, st))
    }
    _ -> Error(NotARecord)
  }
}

/// The per-position labels of a constructor, looked up locally or in the module
/// that defines it.
fn constructor_field_map(
  env: Env,
  module: Option(String),
  constructor: String,
) -> List(Option(String)) {
  let maps = case module {
    Some(alias) ->
      case dict.get(env.modules, alias) {
        Ok(interface) -> interface.field_maps
        Error(_) -> env.field_maps
      }
    None -> env.field_maps
  }
  case dict.get(maps, constructor) {
    Ok(labels) -> labels
    Error(_) -> []
  }
}

/// If `expr` is a direct constructor call (`Ctor(..)` or `module.Ctor(..)`),
/// its `#(module, constructor)`. Constructors are recognised by their leading
/// upper-case letter, the Gleam naming convention.
fn constructor_call(
  expr: glance.Expression,
) -> Result(#(Option(String), String), Nil) {
  let callee = case expr {
    glance.Call(_, function, _) -> function
    _ -> expr
  }
  case callee {
    glance.Variable(_, name) ->
      case is_upper(name) {
        True -> Ok(#(None, name))
        False -> Error(Nil)
      }
    glance.FieldAccess(_, glance.Variable(_, module), name) ->
      case is_upper(name) {
        True -> Ok(#(Some(module), name))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn is_upper(name: String) -> Bool {
  case string.first(name) {
    Ok(c) -> string.uppercase(c) == c && string.lowercase(c) != c
    Error(_) -> False
  }
}

/// Record, for a variable bound by `Ctor(..) as name`, that variant's labelled
/// fields with types tied to `value_type` (the variable's own type). Later
/// `name.field` reads from this even when the field is absent from other
/// variants. Best-effort: on any failure the environment is left unchanged.
fn record_variant(
  env: Env,
  st: State,
  module: Option(String),
  constructor: String,
  value_type: Type,
  name: String,
) -> #(Env, State) {
  let recorded = {
    use scheme <- result.try(constructor_scheme(env, module, constructor))
    let #(ctor_type, st) = instantiate(st, scheme)
    let #(field_types, ret) = case ctor_type {
      Fn(args, ret) -> #(args, ret)
      other -> #([], other)
    }
    // Tie this fresh instance to the variable's actual type so the recorded
    // field types resolve correctly later.
    use st <- result.try(unify(st, value_type, ret))
    let labels = constructor_field_map(env, module, constructor)
    let fields =
      list.fold(list.zip(labels, field_types), dict.new(), fn(acc, pair) {
        case pair.0 {
          Some(label) -> dict.insert(acc, label, resolve(st, pair.1))
          None -> acc
        }
      })
    Ok(#(fields, st))
  }
  case recorded {
    Ok(#(fields, st)) -> #(
      Env(..env, variants: dict.insert(env.variants, name, fields)),
      st,
    )
    Error(_) -> #(env, st)
  }
}

fn infer_each(
  env: Env,
  st: State,
  exprs: List(glance.Expression),
) -> Result(#(List(Type), State), Error) {
  use #(rev, st) <- result.try(
    list.try_fold(exprs, #([], st), fn(acc, e) {
      let #(types_, st) = acc
      use #(t, st) <- result.try(infer_expr(env, st, e))
      Ok(#([t, ..types_], st))
    }),
  )
  Ok(#(list.reverse(rev), st))
}

fn infer_fn(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
) -> Result(#(Type, State), Error) {
  // No expected type: each parameter starts as a fresh variable.
  let #(seeds, st) = fresh_n(st, list.length(params))
  infer_lambda(env, st, params, return_annotation, body, seeds, None, dict.new())
}

/// Infer a lambda whose parameters are seeded with `seed_params` (the expected
/// argument types when known, otherwise fresh variables) and whose body is
/// optionally checked against `expected_return`.
fn infer_lambda(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
  seed_params: List(Type),
  expected_return: Option(Type),
  // Pre-seeded type-variable names (name -> Var). When a `let`-bound function is
  // generalized over its explicit annotation variables, those share these ids
  // across every annotation in the lambda; otherwise this is empty.
  names: Dict(String, Type),
) -> Result(#(Type, State), Error) {
  use #(rev_param_types, body_env, st) <- result.try(
    list.try_fold(list.zip(params, seed_params), #([], env, st), fn(acc, pair) {
      let #(types_, env, st) = acc
      let #(param, seed) = pair
      use #(t, st) <- result.try(case param.type_ {
        Some(ann) -> {
          let #(annotated, st) = hydrate_in(env, names, st, ann)
          use st <- result.try(unify(st, annotated, seed))
          Ok(#(seed, st))
        }
        None -> Ok(#(seed, st))
      })
      let env = case param.name {
        glance.Named(name) -> bind_value(env, name, Scheme([], t))
        glance.Discarded(_) -> env
      }
      Ok(#([t, ..types_], env, st))
    }),
  )
  let param_types = list.reverse(rev_param_types)
  use #(body_type, st) <- result.try(infer_statements(body_env, st, body))
  use st <- result.try(case return_annotation {
    Some(ann) -> {
      let #(t, st) = hydrate_in(env, names, st, ann)
      unify(st, body_type, t)
    }
    None -> Ok(st)
  })
  use st <- result.try(case expected_return {
    Some(expected) -> unify(st, body_type, expected)
    None -> Ok(st)
  })
  Ok(#(Fn(param_types, body_type), st))
}

/// Infer the callee of a call. In call position a same-named module export
/// wins over a record field of a shadowing value: `cache.events(cache)` calls
/// the module's `events` function even though the `cache` value has an `events`
/// field (the field is not callable). Outside call position the field wins
/// (`compression.deflate` reads the field), handled by `infer_field_access`.
fn infer_callee(
  env: Env,
  st: State,
  function: glance.Expression,
) -> Result(#(Type, State), Error) {
  let module_export = case function {
    glance.FieldAccess(_, glance.Variable(_, name), label) ->
      case dict.get(env.modules, name) {
        Ok(interface) -> dict.get(interface.values, label)
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case module_export {
    Ok(scheme) -> {
      let #(type_, st) = instantiate(st, scheme)
      Ok(#(type_, record(st, span(function), type_)))
    }
    Error(_) -> infer_expr(env, st, function)
  }
}

fn infer_call(
  env: Env,
  st: State,
  span: glance.Span,
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> Result(#(Type, State), Error) {
  use #(fn_type, st) <- result.try(infer_callee(env, st, function))
  use ordered <- result.try(
    order_fields(env, function, arguments, fn(label, location) {
      glance.Variable(location, label)
    }),
  )
  // Unify the callee with a function shape first, so each argument's expected
  // type is known before it is checked. This lets a lambda argument's body see
  // the types of its parameters (bidirectional checking) — e.g. the callback
  // in `list.map(rows, fn(row) { row.field })`.
  let #(arg_holes, st) = fresh_n(st, list.length(ordered))
  let #(result, st) = fresh(st)
  use st <- result.try(unify(st, fn_type, Fn(arg_holes, result)))
  // Arguments are checked left to right, so types flowing from earlier
  // arguments (e.g. the list element type) constrain later ones (the callback).
  use st <- result.try(
    list.try_fold(list.zip(ordered, arg_holes), st, fn(st, pair) {
      check(env, st, pair.0, pair.1)
    }),
  )
  Ok(#(result, record(st, span, result)))
}

fn fresh_n(st: State, n: Int) -> #(List(Type), State) {
  case n <= 0 {
    True -> #([], st)
    False -> {
      let #(t, st) = fresh(st)
      let #(rest, st) = fresh_n(st, n - 1)
      #([t, ..rest], st)
    }
  }
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
) -> Result(List(t), Error) {
  case list.all(fields, is_unlabelled) {
    True ->
      Ok(
        list.filter_map(fields, fn(field) {
          case field {
            glance.UnlabelledField(item) -> Ok(item)
            _ -> Error(Nil)
          }
        }),
      )
    False ->
      case callee_labels(env, callee) {
        Ok(labels) -> reorder(fields, labels, shorthand)
        Error(_) -> Error(AmbiguousCall)
      }
  }
}

/// The field map (per-position labels) of a call's callee, if known.
fn callee_labels(
  env: Env,
  callee: glance.Expression,
) -> Result(List(Option(String)), Nil) {
  case callee {
    glance.Variable(_, name) -> dict.get(env.field_maps, name)
    // Qualified call `module.fn`: take the field map from the module.
    glance.FieldAccess(_, glance.Variable(_, alias), name) ->
      case dict.get(env.modules, alias) {
        Ok(interface) -> dict.get(interface.field_maps, name)
        Error(_) -> dict.get(env.field_maps, name)
      }
    _ -> Error(Nil)
  }
}

fn label_indices(labels: List(Option(String))) -> Dict(String, Int) {
  list.index_fold(labels, dict.new(), fn(acc, label, index) {
    case label {
      Some(name) -> dict.insert(acc, name, index)
      None -> acc
    }
  })
}

fn is_unlabelled(field: glance.Field(t)) -> Bool {
  case field {
    glance.UnlabelledField(..) -> True
    _ -> False
  }
}

fn reorder(
  fields: List(glance.Field(t)),
  labels: List(Option(String)),
  shorthand: fn(String, glance.Span) -> t,
) -> Result(List(t), Error) {
  let index_of = label_indices(labels)
  // Labelled and shorthand arguments are placed at their declared index;
  // positional arguments then fill the remaining positions in order.
  use labelled <- result.try(
    list.try_fold(fields, dict.new(), fn(placed, field) {
      case field {
        glance.UnlabelledField(..) -> Ok(placed)
        glance.LabelledField(label, _, item) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, item))
        }
        glance.ShorthandField(label, location) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, shorthand(label, location)))
        }
      }
    }),
  )
  let positional =
    list.filter_map(fields, fn(field) {
      case field {
        glance.UnlabelledField(item) -> Ok(item)
        _ -> Error(Nil)
      }
    })
  let free =
    list.filter(indices(list.length(labels)), fn(i) {
      !dict.has_key(labelled, i)
    })
  let placed =
    list.fold(list.zip(free, positional), labelled, fn(placed, pair) {
      dict.insert(placed, pair.0, pair.1)
    })
  list.try_map(indices(list.length(labels)), fn(index) {
    case dict.get(placed, index) {
      Ok(item) -> Ok(item)
      Error(_) -> Error(MissingArgument)
    }
  })
}

fn label_index(
  index_of: Dict(String, Int),
  label: String,
) -> Result(Int, Error) {
  case dict.get(index_of, label) {
    Ok(index) -> Ok(index)
    Error(_) -> Error(UnknownLabel(label))
  }
}

fn infer_capture(
  env: Env,
  st: State,
  span: glance.Span,
  label: Option(String),
  function: glance.Expression,
  before: List(glance.Field(glance.Expression)),
  after: List(glance.Field(glance.Expression)),
) -> Result(#(Type, State), Error) {
  // `f(a, _, b)` becomes `fn(x) { f(a, x, b) }`. The hole and the surrounding
  // arguments are reordered into the callee's positional order exactly as a
  // direct call would be — labels (including the hole's own, `value: _`) move
  // each argument to its declared slot, so a labelled hole lands in the right
  // parameter even when it is written out of order.
  let #(hole, st) = fresh(st)
  use #(fn_type, st) <- result.try(infer_expr(env, st, function))
  use #(before_typed, st) <- result.try(infer_fields_typed(env, st, before))
  use #(after_typed, st) <- result.try(infer_fields_typed(env, st, after))
  let hole_field = case label {
    Some(name) -> glance.LabelledField(name, span, hole)
    None -> glance.UnlabelledField(hole)
  }
  let fields = list.flatten([before_typed, [hole_field], after_typed])
  // Fields are already typed, so the shorthand materializer is never invoked.
  use arg_types <- result.try(
    order_fields(env, function, fields, fn(_, _) { hole }),
  )
  let #(result, st) = fresh(st)
  use st <- result.try(unify(st, fn_type, Fn(arg_types, result)))
  let captured = Fn([hole], result)
  Ok(#(captured, record(st, span, captured)))
}

/// Infer each call field's value, keeping its label so the arguments can be
/// reordered into positional order. Shorthand fields (`label:`) are resolved to
/// the in-scope `label` and recorded as labelled.
fn infer_fields_typed(
  env: Env,
  st: State,
  fields: List(glance.Field(glance.Expression)),
) -> Result(#(List(glance.Field(Type)), State), Error) {
  use #(rev, st) <- result.try(
    list.try_fold(fields, #([], st), fn(acc, field) {
      let #(typed, st) = acc
      case field {
        glance.UnlabelledField(item) -> {
          use #(t, st) <- result.try(infer_expr(env, st, item))
          Ok(#([glance.UnlabelledField(t), ..typed], st))
        }
        glance.LabelledField(label, location, item) -> {
          use #(t, st) <- result.try(infer_expr(env, st, item))
          Ok(#([glance.LabelledField(label, location, t), ..typed], st))
        }
        glance.ShorthandField(label, location) -> {
          use #(t, st) <- result.try(infer_expr(
            env,
            st,
            glance.Variable(location, label),
          ))
          Ok(#([glance.LabelledField(label, location, t), ..typed], st))
        }
      }
    }),
  )
  Ok(#(list.reverse(rev), st))
}

fn infer_binop(
  env: Env,
  st: State,
  span: glance.Span,
  op: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(Type, State), Error) {
  case op {
    glance.Pipe -> infer_pipe(env, st, span, left, right)

    glance.And | glance.Or -> {
      use st <- result.try(check(env, st, left, types.bool()))
      use st <- result.try(check(env, st, right, types.bool()))
      Ok(#(types.bool(), st))
    }

    glance.Eq | glance.NotEq -> {
      use #(lt, st) <- result.try(infer_expr(env, st, left))
      use #(rt, st) <- result.try(infer_expr(env, st, right))
      use st <- result.try(unify(st, lt, rt))
      Ok(#(types.bool(), st))
    }

    glance.Concatenate -> {
      use st <- result.try(check(env, st, left, types.string()))
      use st <- result.try(check(env, st, right, types.string()))
      Ok(#(types.string(), st))
    }

    glance.AddInt
    | glance.SubInt
    | glance.MultInt
    | glance.DivInt
    | glance.RemainderInt -> {
      use st <- result.try(check(env, st, left, types.int()))
      use st <- result.try(check(env, st, right, types.int()))
      Ok(#(types.int(), st))
    }

    glance.AddFloat | glance.SubFloat | glance.MultFloat | glance.DivFloat -> {
      use st <- result.try(check(env, st, left, types.float()))
      use st <- result.try(check(env, st, right, types.float()))
      Ok(#(types.float(), st))
    }

    glance.LtInt | glance.LtEqInt | glance.GtInt | glance.GtEqInt -> {
      use st <- result.try(check(env, st, left, types.int()))
      use st <- result.try(check(env, st, right, types.int()))
      Ok(#(types.bool(), st))
    }

    glance.LtFloat | glance.LtEqFloat | glance.GtFloat | glance.GtEqFloat -> {
      use st <- result.try(check(env, st, left, types.float()))
      use st <- result.try(check(env, st, right, types.float()))
      Ok(#(types.bool(), st))
    }
  }
}

fn infer_pipe(
  env: Env,
  st: State,
  span: glance.Span,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(Type, State), Error) {
  case right {
    glance.Call(call_span, function, arguments) -> {
      // `left |> f(args)` is `f(left, args)` when `f` takes one more argument
      // than is supplied. But if `f(args)` is already a saturated call that
      // returns a function, the pipe applies `left` to that result:
      // `f(args)(left)`. Distinguish on the callee's arity.
      use #(ft, st) <- result.try(infer_expr(env, st, function))
      let saturated = case resolve(st, ft) {
        Fn(params, _) -> list.length(params) == list.length(arguments)
        _ -> False
      }
      case saturated {
        True -> {
          use #(call_type, st) <- result.try(infer_call(
            env,
            st,
            call_span,
            function,
            arguments,
          ))
          use #(lt, st) <- result.try(infer_expr(env, st, left))
          let #(result, st) = fresh(st)
          use st <- result.try(unify(st, call_type, Fn([lt], result)))
          Ok(#(result, record(st, span, result)))
        }
        False ->
          infer_call(env, st, call_span, function, [
            glance.UnlabelledField(left),
            ..arguments
          ])
      }
    }
    // `left |> f` becomes `f(left)`.
    _ -> {
      use #(lt, st) <- result.try(infer_expr(env, st, left))
      use #(ft, st) <- result.try(infer_expr(env, st, right))
      let #(result, st) = fresh(st)
      use st <- result.try(unify(st, ft, Fn([lt], result)))
      Ok(#(result, record(st, span, result)))
    }
  }
}

/// Infer an expression and unify it against an expected type. A lambda is
/// checked against the expected type so its parameters are seeded from the
/// expected argument types before its body is inferred.
fn check(
  env: Env,
  st: State,
  expr: glance.Expression,
  expected: Type,
) -> Result(State, Error) {
  let seeded = case expr {
    glance.Fn(_, params, _, _) ->
      case resolve(st, expected) {
        Fn(expected_params, expected_return) ->
          case list.length(expected_params) == list.length(params) {
            True -> Ok(#(expected_params, expected_return))
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case expr, seeded {
    glance.Fn(span, params, return_annotation, body), Ok(#(seeds, ret)) -> {
      use #(fn_type, st) <- result.try(infer_lambda(
        env,
        st,
        params,
        return_annotation,
        body,
        seeds,
        Some(ret),
        dict.new(),
      ))
      let st = record(st, span, fn_type)
      unify(st, fn_type, expected)
    }
    _, _ -> {
      use #(t, st) <- result.try(infer_expr(env, st, expr))
      unify(st, t, expected)
    }
  }
}

// --- Statements ------------------------------------------------------------

fn infer_statements(
  env: Env,
  st: State,
  statements: List(glance.Statement),
) -> Result(#(Type, State), Error) {
  case statements {
    [] -> Ok(#(types.nil(), st))
    // `use pats <- rhs` turns the remaining statements into a trailing callback.
    [glance.Use(_, patterns, function), ..rest] ->
      infer_use(env, st, patterns, function, rest)
    [last] -> {
      use #(t, _env, st) <- result.try(infer_statement(env, st, last))
      Ok(#(t, st))
    }
    [first, ..rest] -> {
      use #(_t, env, st) <- result.try(infer_statement(env, st, first))
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
) -> Result(#(Type, State), Error) {
  // Build the callback: its parameters are the use patterns, its body is the
  // rest of the block.
  use #(rev_param_types, callback_env, st) <- result.try(
    list.try_fold(use_patterns, #([], env, st), fn(acc, use_pattern) {
      let #(types_, env, st) = acc
      let #(param, st) = case use_pattern.annotation {
        Some(ann) -> hydrate(env, st, ann)
        None -> fresh(st)
      }
      use #(env, st) <- result.try(infer_pattern(
        env,
        st,
        use_pattern.pattern,
        param,
      ))
      Ok(#([param, ..types_], env, st))
    }),
  )
  let param_types = list.reverse(rev_param_types)
  use #(body_type, st) <- result.try(infer_statements(callback_env, st, rest))
  let callback_type = Fn(param_types, body_type)

  // The right-hand side is called with the callback as its final argument.
  let #(result, st) = fresh(st)
  use st <- result.try(case function {
    glance.Call(_, callee, arguments) ->
      infer_use_call(env, st, callee, arguments, callback_type, result)
    other -> {
      use #(callee_type, st) <- result.try(infer_expr(env, st, other))
      unify(st, callee_type, Fn([callback_type], result))
    }
  })
  Ok(#(result, st))
}

/// Infer `use ... <- callee(args)`: the callback is the final positional
/// argument. When the explicit arguments are all positional we simply append
/// the callback; when some are labelled we place them by their field map and
/// the callback fills the remaining slot (e.g. the `otherwise` of `bool.guard`).
fn infer_use_call(
  env: Env,
  st: State,
  callee: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
  callback_type: Type,
  result: Type,
) -> Result(State, Error) {
  use #(callee_type, st) <- result.try(infer_expr(env, st, callee))
  case list.all(arguments, is_unlabelled) {
    True -> {
      use #(arg_types, st) <- result.try(infer_each(
        env,
        st,
        list.map(arguments, field_item),
      ))
      unify(
        st,
        callee_type,
        Fn(list.append(arg_types, [callback_type]), result),
      )
    }
    False -> {
      use labels <- result.try(result.replace_error(
        callee_labels(env, callee),
        AmbiguousCall,
      ))
      let index_of = label_indices(labels)
      // Infer the explicit arguments, splitting labelled (placed by index) from
      // positional (which, with the trailing callback, fill the free slots).
      use #(labelled, rev_positional, st) <- result.try(
        list.try_fold(arguments, #(dict.new(), [], st), fn(acc, field) {
          let #(labelled, positional, st) = acc
          case field {
            glance.UnlabelledField(item) -> {
              use #(t, st) <- result.try(infer_expr(env, st, item))
              Ok(#(labelled, [t, ..positional], st))
            }
            glance.LabelledField(label, _, item) -> {
              use index <- result.try(label_index(index_of, label))
              use #(t, st) <- result.try(infer_expr(env, st, item))
              Ok(#(dict.insert(labelled, index, t), positional, st))
            }
            glance.ShorthandField(label, location) -> {
              use index <- result.try(label_index(index_of, label))
              use #(t, st) <- result.try(infer_expr(
                env,
                st,
                glance.Variable(location, label),
              ))
              Ok(#(dict.insert(labelled, index, t), positional, st))
            }
          }
        }),
      )
      let trailing = list.append(list.reverse(rev_positional), [callback_type])
      let free =
        list.filter(indices(list.length(labels)), fn(i) {
          !dict.has_key(labelled, i)
        })
      let placed =
        list.fold(list.zip(free, trailing), labelled, fn(placed, pair) {
          dict.insert(placed, pair.0, pair.1)
        })
      use arg_types <- result.try(
        list.try_map(indices(list.length(labels)), fn(index) {
          result.replace_error(dict.get(placed, index), MissingArgument)
        }),
      )
      unify(st, callee_type, Fn(arg_types, result))
    }
  }
}

/// Infer one statement, returning its type and the (possibly extended)
/// environment to thread to following statements.
fn infer_statement(
  env: Env,
  st: State,
  statement: glance.Statement,
) -> Result(#(Type, Env, State), Error) {
  case statement {
    glance.Expression(expr) -> {
      use #(t, st) <- result.try(infer_expr(env, st, expr))
      Ok(#(t, env, st))
    }

    // `let name = fn(...)` whose annotations name type variables is generalized
    // over exactly those variables — Gleam makes such a local binding
    // polymorphic (`let id = fn(x: a) -> a { x }` may then be used at several
    // types), unlike an unannotated `let id = fn(x) { x }`, which stays
    // monomorphic.
    glance.Assignment(
      _,
      _kind,
      glance.PatternVariable(_, name) as pattern,
      None,
      glance.Fn(fspan, fparams, freturn, fbody) as value,
    ) ->
      case fn_annotation_var_names(fparams, freturn) {
        [] -> infer_expr_assignment(env, st, pattern, None, value)
        ann_names -> {
          let #(names, ann_ids, st) =
            list.fold(ann_names, #(dict.new(), [], st), fn(acc, nm) {
              let #(names, ids, st) = acc
              let #(id, st) = fresh_id(st)
              #(dict.insert(names, nm, Var(id)), [id, ..ids], st)
            })
          let #(seeds, st) = fresh_n(st, list.length(fparams))
          use #(value_type, st) <- result.try(infer_lambda(
            env,
            st,
            fparams,
            freturn,
            fbody,
            seeds,
            None,
            names,
          ))
          let st = record(st, fspan, value_type)
          let scheme = generalize_over(st, env, value_type, ann_ids)
          Ok(#(value_type, bind_value(env, name, scheme), st))
        }
      }

    glance.Assignment(_, _kind, pattern, annotation, value) ->
      infer_expr_assignment(env, st, pattern, annotation, value)

    glance.Assert(_, expression, _message) -> {
      use st <- result.try(check(env, st, expression, types.bool()))
      Ok(#(types.nil(), env, st))
    }

    // `use` is handled by infer_statements before reaching here.
    glance.Use(..) -> Error(Unsupported("use in non-tail position"))
  }
}

/// The general `let pattern = value` case: infer the value, optionally check it
/// against the binding's annotation, then bind the pattern monomorphically.
fn infer_expr_assignment(
  env: Env,
  st: State,
  pattern: glance.Pattern,
  annotation: Option(glance.Type),
  value: glance.Expression,
) -> Result(#(Type, Env, State), Error) {
  use #(value_type, st) <- result.try(infer_expr(env, st, value))
  use st <- result.try(case annotation {
    Some(ann) -> {
      let #(t, st) = hydrate(env, st, ann)
      unify(st, value_type, t)
    }
    None -> Ok(st)
  })
  use #(env, st) <- result.try(infer_pattern(env, st, pattern, value_type))
  // `let x = Ctor(..)` narrows `x` to that variant (the compiler's inferred
  // variant), so a later `x.field` reaches a field present only in `Ctor`.
  let #(env, st) = case pattern, constructor_call(value) {
    glance.PatternVariable(_, name), Ok(#(module, constructor)) ->
      record_variant(env, st, module, constructor, value_type, name)
    _, _ -> #(env, st)
  }
  Ok(#(value_type, env, st))
}

// --- Case expressions ------------------------------------------------------

fn infer_case(
  env: Env,
  st: State,
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
) -> Result(#(Type, State), Error) {
  use #(subject_types, st) <- result.try(infer_each(env, st, subjects))
  let #(result, st) = fresh(st)
  use st <- result.try(
    list.try_fold(clauses, st, fn(st, clause) {
      infer_clause(env, st, clause, subjects, subject_types, result)
    }),
  )
  Ok(#(result, st))
}

fn infer_clause(
  env: Env,
  st: State,
  clause: glance.Clause,
  subjects: List(glance.Expression),
  subject_types: List(Type),
  result: Type,
) -> Result(State, Error) {
  // Each clause may have several alternative pattern lists (`a | b ->`); each
  // binds the same variables and is checked against the subject types.
  list.try_fold(clause.patterns, st, fn(st, patterns) {
    use #(clause_env, st) <- result.try(
      list.try_fold(
        list.zip(patterns, list.zip(subjects, subject_types)),
        #(env, st),
        fn(acc, pair) {
          let #(env, st) = acc
          let #(pattern, #(subject, subject_type)) = pair
          use #(env, st) <- result.try(infer_pattern(
            env,
            st,
            pattern,
            subject_type,
          ))
          // When a clause matches a bare subject variable against a variant
          // pattern, that variable is narrowed to the variant within the clause
          // (the compiler's inferred-variant narrowing), so its non-shared
          // fields become accessible.
          case subject, pattern {
            glance.Variable(_, name),
              glance.PatternVariant(_, module, constructor, _, _)
            ->
              Ok(record_variant(
                env,
                st,
                module,
                constructor,
                subject_type,
                name,
              ))
            _, _ -> Ok(#(env, st))
          }
        },
      ),
    )
    use st <- result.try(case clause.guard {
      Some(guard) -> check(clause_env, st, guard, types.bool())
      None -> Ok(st)
    })
    use #(body_type, st) <- result.try(infer_expr(clause_env, st, clause.body))
    unify(st, body_type, result)
  })
}

// --- Patterns --------------------------------------------------------------

fn infer_pattern(
  env: Env,
  st: State,
  pattern: glance.Pattern,
  expected: Type,
) -> Result(#(Env, State), Error) {
  case pattern {
    glance.PatternInt(..) -> with_env(env, unify(st, expected, types.int()))
    glance.PatternFloat(..) -> with_env(env, unify(st, expected, types.float()))
    glance.PatternString(..) ->
      with_env(env, unify(st, expected, types.string()))
    glance.PatternDiscard(..) -> Ok(#(env, st))

    glance.PatternVariable(_, name) ->
      Ok(#(bind_value(env, name, Scheme([], expected)), st))

    glance.PatternTuple(_, elements) -> {
      let #(elem_types, st) =
        list.fold(elements, #([], st), fn(acc, _) {
          let #(types_, st) = acc
          let #(t, st) = fresh(st)
          #([t, ..types_], st)
        })
      let elem_types = list.reverse(elem_types)
      use st <- result.try(unify(st, expected, Tuple(elem_types)))
      list.try_fold(list.zip(elements, elem_types), #(env, st), fn(acc, pair) {
        let #(env, st) = acc
        let #(pattern, t) = pair
        infer_pattern(env, st, pattern, t)
      })
    }

    glance.PatternList(_, elements, tail) -> {
      let #(elem, st) = fresh(st)
      use st <- result.try(unify(st, expected, types.list(elem)))
      use #(env, st) <- result.try(
        list.try_fold(elements, #(env, st), fn(acc, p) {
          let #(env, st) = acc
          infer_pattern(env, st, p, elem)
        }),
      )
      case tail {
        Some(t) -> infer_pattern(env, st, t, types.list(elem))
        None -> Ok(#(env, st))
      }
    }

    glance.PatternAssignment(_, pattern, name) -> {
      let env = bind_value(env, name, Scheme([], expected))
      // `Ctor(..) as name` narrows `name` to that variant: record the variant's
      // fields so a later `name.field` reaches fields present only in it.
      let #(env, st) = case pattern {
        glance.PatternVariant(_, module, constructor, _, _) ->
          record_variant(env, st, module, constructor, expected, name)
        _ -> #(env, st)
      }
      infer_pattern(env, st, pattern, expected)
    }

    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) -> {
      use st <- result.try(unify(st, expected, types.string()))
      // Both the matched prefix (`"a" as c <> rest`) and the remainder bind to
      // String. The prefix binding is optional (`<> rest` with no `as`).
      let bind_name = fn(env, name) {
        case name {
          glance.Named(n) -> bind_value(env, n, Scheme([], types.string()))
          glance.Discarded(_) -> env
        }
      }
      let env = case prefix_name {
        Some(name) -> bind_name(env, name)
        None -> env
      }
      Ok(#(bind_name(env, rest_name), st))
    }

    glance.PatternVariant(_, module, constructor, arguments, _spread) -> {
      use scheme <- result.try(constructor_scheme(env, module, constructor))
      let #(ctor_type, st) = instantiate(st, scheme)
      // A constructor with fields is a function; one without is the value.
      let #(field_types, ret) = case ctor_type {
        Fn(args, ret) -> #(args, ret)
        other -> #([], other)
      }
      use st <- result.try(unify(st, expected, ret))
      use arg_patterns <- result.try(order_pattern_args(
        env,
        module,
        constructor,
        arguments,
        list.length(field_types),
      ))
      list.try_fold(
        list.zip(arg_patterns, field_types),
        #(env, st),
        fn(acc, pair) {
          let #(env, st) = acc
          let #(pattern, t) = pair
          infer_pattern(env, st, pattern, t)
        },
      )
    }

    glance.PatternBitString(_, segments) -> {
      use st <- result.try(unify(st, expected, types.bit_array()))
      list.try_fold(segments, #(env, st), fn(acc, segment) {
        let #(env, st) = acc
        let #(pattern, options) = segment
        let default = case pattern {
          glance.PatternString(..) -> types.string()
          glance.PatternFloat(..) -> types.float()
          _ -> types.int()
        }
        use #(env, st) <- result.try(infer_pattern(
          env,
          st,
          pattern,
          segment_value_type(options, default),
        ))
        list.try_fold(options, #(env, st), fn(acc, option) {
          let #(env, st) = acc
          case option {
            glance.SizeValueOption(size) ->
              infer_pattern(env, st, size, types.int())
            _ -> Ok(#(env, st))
          }
        })
      })
    }
  }
}

/// Pair a (possibly failed) new state with an unchanged environment.
fn with_env(
  env: Env,
  st: Result(State, Error),
) -> Result(#(Env, State), Error) {
  result.map(st, fn(st) { #(env, st) })
}

/// Resolve a constructor name (optionally module-qualified) to its scheme.
fn constructor_scheme(
  env: Env,
  module: Option(String),
  constructor: String,
) -> Result(Scheme, Error) {
  case module {
    Some(alias) ->
      case dict.get(env.modules, alias) {
        Ok(interface) ->
          case dict.get(interface.values, constructor) {
            Ok(scheme) -> Ok(scheme)
            Error(_) -> Error(NoSuchExport(alias, constructor))
          }
        Error(_) -> Error(UnknownModule(alias))
      }
    None ->
      case dict.get(env.values, constructor) {
        Ok(scheme) -> Ok(scheme)
        Error(_) -> Error(UnknownConstructor(constructor))
      }
  }
}

/// The value type of a bit-array segment given its options and the default to
/// use when no type option is present (`Int` for numeric segments, `String`
/// for string-literal segments, etc.).
fn segment_value_type(
  options: List(glance.BitStringSegmentOption(t)),
  default: Type,
) -> Type {
  list.fold(options, default, fn(acc, option) {
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
/// constructor's field map and filling positions omitted via `..` with discards.
fn order_pattern_args(
  env: Env,
  module: Option(String),
  constructor: String,
  arguments: List(glance.Field(glance.Pattern)),
  arity: Int,
) -> Result(List(glance.Pattern), Error) {
  // A qualified constructor pattern takes its field map from the module that
  // defines the constructor, not the local environment.
  let field_maps = case module {
    Some(alias) ->
      case dict.get(env.modules, alias) {
        Ok(interface) -> interface.field_maps
        Error(_) -> env.field_maps
      }
    None -> env.field_maps
  }
  let labels = case dict.get(field_maps, constructor) {
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
  use labelled <- result.try(
    list.try_fold(arguments, dict.new(), fn(placed, field) {
      case field {
        glance.UnlabelledField(..) -> Ok(placed)
        glance.LabelledField(label, _, item) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, item))
        }
        glance.ShorthandField(label, location) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, glance.PatternVariable(location, label)))
        }
      }
    }),
  )
  let positional =
    list.filter_map(arguments, fn(field) {
      case field {
        glance.UnlabelledField(item) -> Ok(item)
        _ -> Error(Nil)
      }
    })
  let free = list.filter(indices(arity), fn(i) { !dict.has_key(labelled, i) })
  let placed =
    list.fold(list.zip(free, positional), labelled, fn(placed, pair) {
      dict.insert(placed, pair.0, pair.1)
    })
  Ok(
    list.map(indices(arity), fn(index) {
      case dict.get(placed, index) {
        Ok(pattern) -> pattern
        // Omitted via `..`: bind nothing.
        Error(_) -> glance.PatternDiscard(glance.Span(0, 0), "_")
      }
    }),
  )
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

/// Convert a written type annotation into an internal `Type`. Unknown
/// type-variable names become fresh unbound variables. Hydration never fails:
/// references it cannot resolve fall back to a plausible interpretation.
fn hydrate(env: Env, st: State, ast: glance.Type) -> #(Type, State) {
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
      case module {
        None ->
          case dict.get(env.aliases, name) {
            // A local alias: expand its AST in this environment.
            Ok(#(params, aliased)) -> {
              let alias_names = dict.from_list(list.zip(params, arg_types))
              let #(#(t, st), _) = hydrate_with(env, alias_names, st, aliased)
              #(#(t, st), names)
            }
            Error(_) ->
              case dict.get(env.imported_aliases, name) {
                // An unqualified imported alias: already resolved.
                Ok(#(params, body)) -> #(
                  #(instantiate_alias(params, body, arg_types), st),
                  names,
                )
                // Otherwise a named type: its origin module if known, else the
                // prelude.
                Error(_) ->
                  case dict.get(env.local_types, name) {
                    Ok(#(origin, origin_name, _arity)) -> #(
                      #(Named(origin, origin_name, arg_types), st),
                      names,
                    )
                    Error(_) -> #(
                      #(Named(types.prelude_module, name, arg_types), st),
                      names,
                    )
                  }
              }
          }
        // A qualified type name `alias.Name`: resolve via the imported module.
        Some(alias) ->
          case dict.get(env.modules, alias) {
            Ok(interface) ->
              case dict.get(interface.aliases, name) {
                Ok(#(params, body)) -> #(
                  #(instantiate_alias(params, body, arg_types), st),
                  names,
                )
                Error(_) -> {
                  let origin = case dict.get(interface.types, name) {
                    Ok(#(origin, _origin_name, _arity)) -> origin
                    Error(_) -> alias
                  }
                  #(#(Named(origin, name, arg_types), st), names)
                }
              }
            Error(_) -> #(#(Named(alias, name, arg_types), st), names)
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
) -> Result(#(Type, State), Error) {
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
      Ok(#(Fn(param_types, return_type), st))
    }
    _ -> {
      use #(body_type, st) <- result.try(infer_statements(
        body_env,
        st,
        function.body,
      ))
      use st <- result.try(case function.return {
        Some(ann) -> {
          let #(t, st, _names) = hydrate_threaded(env, names, st, ann)
          unify(st, body_type, t)
        }
        None -> Ok(st)
      })
      Ok(#(Fn(param_types, body_type), st))
    }
  }
}

/// Infer a module constant, returning its type (an annotation, if present, is
/// applied).
pub fn infer_constant(
  env: Env,
  st: State,
  constant: glance.Constant,
) -> Result(#(Type, State), Error) {
  use #(value_type, st) <- result.try(infer_expr(env, st, constant.value))
  case constant.annotation {
    Some(ann) -> {
      let #(t, st) = hydrate(env, st, ann)
      use st <- result.try(unify(st, value_type, t))
      Ok(#(value_type, st))
    }
    None -> Ok(#(value_type, st))
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
  let env =
    declare_type(env, custom_type.name, list.length(custom_type.parameters))
  let #(rev_param_ids, st) =
    list.fold(custom_type.parameters, #([], st), fn(acc, _name) {
      let #(ids, st) = acc
      let #(id, st) = fresh_id(st)
      #([id, ..ids], st)
    })
  let param_ids = list.reverse(rev_param_ids)
  let param_vars = list.map(param_ids, Var)
  let names = dict.from_list(list.zip(custom_type.parameters, param_vars))
  let return_type = Named(env.current_module, custom_type.name, param_vars)

  // Build constructors, collecting each variant's labelled-field types so we
  // can later expose accessors for labels shared across all variants.
  let #(env, st, rev_variant_labels) =
    list.fold(custom_type.variants, #(env, st, []), fn(acc, variant) {
      let #(env, st, variant_labels) = acc
      let #(rev_field_types, labelled, st) =
        list.fold(variant.fields, #([], dict.new(), st), fn(acc, field) {
          let #(types_, labelled, st) = acc
          let #(t, st) = hydrate_in(env, names, st, variant_field_type(field))
          let labelled = case field {
            glance.LabelledVariantField(_, label) ->
              dict.insert(labelled, label, t)
            glance.UnlabelledVariantField(..) -> labelled
          }
          #([t, ..types_], labelled, st)
        })
      let field_types = list.reverse(rev_field_types)
      let ctor_type = case field_types {
        [] -> return_type
        _ -> Fn(field_types, return_type)
      }
      let env =
        register_field_map(
          env,
          variant.name,
          list.map(variant.fields, fn(f) {
            case f {
              glance.LabelledVariantField(_, label) -> Some(label)
              glance.UnlabelledVariantField(..) -> None
            }
          }),
        )
      let env = bind_value(env, variant.name, Scheme(param_ids, ctor_type))
      #(env, st, [labelled, ..variant_labels])
    })

  // A label is accessible iff it appears in every variant with the same type.
  // (Single-variant records are the degenerate case where every label qualifies.)
  let accessors =
    shared_accessors(list.reverse(rev_variant_labels), param_ids, return_type)
  let env =
    Env(
      ..env,
      accessors: dict.insert(env.accessors, custom_type.name, accessors),
    )
  #(env, st)
}

/// Accessor schemes for the labels present in every variant with a consistent
/// type, given each variant's `label -> field type` map.
fn shared_accessors(
  variants: List(Dict(String, Type)),
  param_ids: List(Int),
  return_type: Type,
) -> Dict(String, Scheme) {
  case variants {
    [] -> dict.new()
    [first, ..rest] ->
      dict.fold(first, dict.new(), fn(accessors, label, field_type) {
        let shared =
          list.all(rest, fn(variant) {
            dict.get(variant, label) == Ok(field_type)
          })
        case shared {
          True ->
            dict.insert(
              accessors,
              label,
              Scheme(param_ids, Fn([return_type], field_type)),
            )
          False -> accessors
        }
      })
  }
}

/// Look up the accessor scheme for `type_name`.`label`.
/// Look up the accessor scheme for `label` on a (resolved) record type. The
/// accessors live with whichever module defined the type — the current module,
/// or an imported one identified by the type's origin module.
fn accessor(env: Env, record: Type, label: String) -> Result(Scheme, Error) {
  case record {
    Named(module, name, _) -> {
      let accessors = accessors_of_module(env, module)
      case dict.get(accessors, name) {
        Ok(labels) ->
          case dict.get(labels, label) {
            Ok(scheme) -> Ok(scheme)
            Error(_) -> Error(NoSuchField(name, label))
          }
        Error(_) -> Error(NoSuchField(name, label))
      }
    }
    _ -> Error(NotARecord)
  }
}

fn accessors_of_module(
  env: Env,
  module: String,
) -> Dict(String, Dict(String, Scheme)) {
  case module == env.current_module {
    True -> env.accessors
    False ->
      case find_module_interface(dict.values(env.modules), module, []) {
        Ok(interface) -> interface.accessors
        Error(_) -> env.accessors
      }
  }
}

/// Find an interface for `target` by module name, searching the directly
/// reachable interfaces and, transitively, the modules they expose. A type can
/// surface from a module the current one never imports directly (a helper that
/// returns another module's record), and an alias collision can evict that
/// module from the top-level alias map — so resolving accessors by origin name
/// must look through the nested `modules` maps too. `seen` guards the DAG.
fn find_module_interface(
  interfaces: List(ModuleInterface),
  target: String,
  seen: List(String),
) -> Result(ModuleInterface, Nil) {
  case interfaces {
    [] -> Error(Nil)
    [interface, ..rest] ->
      case interface.name == target {
        True -> Ok(interface)
        False ->
          case list.contains(seen, interface.name) {
            True -> find_module_interface(rest, target, seen)
            False ->
              case
                find_module_interface(
                  dict.values(interface.modules),
                  target,
                  [interface.name, ..seen],
                )
              {
                Ok(found) -> Ok(found)
                Error(_) -> find_module_interface(rest, target, seen)
              }
          }
      }
  }
}

/// Resolve field accesses that were deferred because the record type was
/// unknown when first seen. By now inference has fixed the record types; any
/// that are still unknown are genuinely ambiguous (the compiler rejects these
/// too).
pub fn resolve_pending(env: Env, st: State) -> Result(State, Error) {
  // Process in discovery order so inner accesses of a chain (`a.b.c`) resolve
  // before the outer ones, and loop to a fixpoint for any remaining cross
  // dependencies. Anything still unresolved is genuinely ambiguous.
  let pending = list.reverse(st.pending)
  resolve_pending_loop(
    env,
    State(..st, pending: []),
    pending,
    list.length(pending),
  )
}

fn resolve_pending_loop(
  env: Env,
  st: State,
  pending: List(Pending),
  fuel: Int,
) -> Result(State, Error) {
  case pending, fuel <= 0 {
    [], _ -> Ok(st)
    [_, ..], True -> Error(NotARecord)
    _, False -> {
      use #(st, remaining, progressed) <- result.try(
        list.try_fold(pending, #(st, [], False), fn(acc, item) {
          let #(st, remaining, progressed) = acc
          use #(st, resolved) <- result.try(resolve_one(env, st, item))
          case resolved {
            True -> Ok(#(st, remaining, True))
            False -> Ok(#(st, [item, ..remaining], progressed))
          }
        }),
      )
      case progressed {
        True -> resolve_pending_loop(env, st, list.reverse(remaining), fuel - 1)
        False -> Error(NotARecord)
      }
    }
  }
}

/// Try to resolve one deferred access. Returns `#(state, resolved?)`: `False`
/// means the container is still an unbound variable, so keep it for a later
/// pass. A container fixed to the wrong shape is a hard error.
fn resolve_one(
  env: Env,
  st: State,
  item: Pending,
) -> Result(#(State, Bool), Error) {
  case item {
    PendingField(container, label, field) ->
      case resolve(st, container) {
        Named(_, _, _) as record -> {
          use scheme <- result.try(accessor(env, record, label))
          let #(accessor_type, st) = instantiate(st, scheme)
          use st <- result.try(unify(st, accessor_type, Fn([container], field)))
          Ok(#(st, True))
        }
        Var(_) -> Ok(#(st, False))
        _ -> Error(NotARecord)
      }
    PendingIndex(container, index, result) ->
      case resolve(st, container) {
        Tuple(elements) ->
          case list_at(elements, index) {
            Ok(element) -> {
              use st <- result.try(unify(st, element, result))
              Ok(#(st, True))
            }
            Error(_) -> Error(TupleIndexOutOfRange(index))
          }
        Var(_) -> Ok(#(st, False))
        _ -> Error(NotATuple)
      }
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

fn record(st: State, span: glance.Span, type_: Type) -> State {
  State(..st, annotations: [#(span, type_), ..st.annotations])
}

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
