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
  )
}

pub fn new_state() -> State {
  State(next_id: 0, subst: dict.new(), annotations: [])
}

pub fn new_env() -> Env {
  Env(values: dict.new(), aliases: dict.new())
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

    glance.FieldAccess(..) -> panic as "field access not yet supported"
    glance.RecordUpdate(..) -> panic as "record update not yet supported"
    glance.BitString(..) -> panic as "bit arrays not yet supported"
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
  let #(arg_types, st) = infer_each(env, st, list.map(arguments, field_item))
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
      let arg_patterns = list.map(arguments, field_pattern)
      list.fold(list.zip(arg_patterns, field_types), #(env, st), fn(acc, pair) {
        let #(env, st) = acc
        let #(pattern, t) = pair
        infer_pattern(env, st, pattern, t)
      })
    }

    glance.PatternBitString(..) ->
      panic as "bit array patterns not yet supported"
  }
}

fn field_pattern(field: glance.Field(glance.Pattern)) -> glance.Pattern {
  case field {
    glance.UnlabelledField(item) -> item
    glance.LabelledField(_, _, item) -> item
    glance.ShorthandField(label, location) ->
      glance.PatternVariable(location, label)
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
        _, _ -> {
          let module = option.unwrap(module, types.prelude_module)
          #(#(Named(module, name, arg_types), st), names)
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
  let #(body_type, st) = infer_statements(body_env, st, function.body)
  let st = case function.return {
    Some(ann) -> {
      let #(t, st, _names) = hydrate_threaded(env, names, st, ann)
      unify(st, body_type, t)
    }
    None -> st
  }
  #(Fn(list.reverse(rev_param_types), body_type), st)
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
  let return_type = Named("", custom_type.name, param_vars)

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
    #(bind_value(env, variant.name, Scheme(param_ids, ctor_type)), st)
  })
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
