//// The dependency graph between a module's top-level definitions, built as
//// Gleam 1.19.2's `compiler-core/src/call_graph.rs` builds it, over glance's
//// AST, and ordered by `girard/internal/scc`'s port of petgraph 0.8.3.
////
//// Nodes are the functions in source order, then the constants in source
//// order. Each definition's references are collected in the compiler's walk
//// order and kept newest first, duplicates included, which is the order
//// petgraph's `StableGraph` yields a node's neighbours in.
////
//// The walk threads the compiler's `names` scope: what its walk has defined
//// locally, with the compiler's quirks (Q1-Q6 in girard's PR H notes). The
//// graph is exactly the compiler's. Where the compiler's walk misses a real
//// reference (a `let assert` message reading a top-level function its own
//// pattern shadows), inference finds the function through its module-wide
//// registration, as the compiler does.

import girard/internal/scc
import glance
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

// The graph

/// Each top-level definition's neighbours, in node order: functions sorted by
/// source position, then constants sorted by source position. A node's
/// neighbours are the definitions it references, newest first, with
/// duplicates kept.
pub fn dependency_edges(
  functions: List(glance.Function),
  constants: List(glance.Constant),
) -> List(#(String, List(String))) {
  let functions =
    list.sort(functions, fn(a, b) {
      int.compare(a.location.start, b.location.start)
    })
  let constants =
    list.sort(constants, fn(a, b) {
      int.compare(a.location.start, b.location.start)
    })
  let function_names = list.map(functions, fn(f) { f.name })
  let constant_names = list.map(constants, fn(c) { c.name })
  let context =
    Context(nodes: set.from_list(list.append(function_names, constant_names)))
  list.append(
    list.map(functions, fn(f) { #(f.name, in_function(context, f)) }),
    list.map(constants, fn(c) { #(c.name, in_constant(context, c)) }),
  )
}

/// The compiler's dependency order: groups of mutually recursive definitions,
/// dependencies first, each listing its members in the order the compiler
/// infers them.
pub fn dependency_order(
  functions: List(glance.Function),
  constants: List(glance.Constant),
) -> List(List(String)) {
  let edges = dependency_edges(functions, constants)
  scc.components(list.map(edges, fn(edge) { edge.0 }), dict.from_list(edges))
}

/// The `as` message of a `let assert`, which a plain `let` cannot have.
pub fn assignment_message(
  kind: glance.AssignmentKind,
) -> Option(glance.Expression) {
  case kind {
    glance.LetAssert(message:) -> message
    glance.Let -> None
  }
}

/// Whether the compiler parses this guard subtree as a constant
/// (`parse_case_clause_guard_unit`, `parse.rs:1895-2010`) rather than as a
/// guard form. Guard forms are a variable, a `.label` or `.0` chain on one,
/// `!`, a `{ … }` block and a binary operator; a qualified constructor
/// (`m.Box`, `m.Box(1)`) and everything else are constants. A bare uppercase
/// constructor (`None`) is a glance `Variable` and so classified as a guard
/// form, where the compiler parses a record constant: nothing qualified can
/// sit beneath it, so the answer is never read.
pub fn guard_constant(expr: glance.Expression) -> Bool {
  case expr {
    glance.Variable(..)
    | glance.TupleIndex(..)
    | glance.NegateBool(..)
    | glance.Block(..)
    | glance.BinaryOperator(..) -> False
    glance.FieldAccess(_, _, label) -> is_upper(label)
    _ -> True
  }
}

/// Whether a name starts with an uppercase letter: a constructor or a type,
/// never a value.
pub fn is_upper(name: String) -> Bool {
  case string.first(name) {
    Ok(first) ->
      string.uppercase(first) == first && string.lowercase(first) != first
    Error(_) -> False
  }
}

// The walk

// What every walk step needs to know about the module.
type Context {
  Context(nodes: Set(String))
}

// The compiler's `names`: the names the walk has defined locally, which shadow
// a top-level definition.
type Scope =
  Set(String)

// How a sub-expression is walked: by the expression rules or by the constant
// rules. The shared helpers below take one, so a constant reuses them.
type Walk =
  fn(Context, glance.Expression, Scope, List(String)) -> List(String)

fn empty_scope() -> Scope {
  set.new()
}

fn define(scope: Scope, name: String) -> Scope {
  set.insert(scope, name)
}

// A function's or a `fn`'s parameters bind in both scopes.
fn define_parameters(
  scope: Scope,
  names: List(glance.AssignmentName),
) -> Scope {
  list.fold(list.flat_map(names, assignment_name), scope, define)
}

fn in_function(context: Context, function: glance.Function) -> List(String) {
  let scope =
    define_parameters(
      empty_scope(),
      list.map(function.parameters, fn(p) { p.name }),
    )
  statements(context, function.body, scope, [])
}

fn in_constant(context: Context, constant: glance.Constant) -> List(String) {
  constant_value(context, constant.value, empty_scope(), [])
}

// The compiler's `referenced`: a name the walk has not shadowed that names a
// top-level definition is an edge.
fn referenced(
  context: Context,
  scope: Scope,
  name: String,
  refs: List(String),
) -> List(String) {
  let recorded = set.contains(context.nodes, name) && !set.contains(scope, name)
  use <- bool.guard(when: !recorded, return: refs)
  [name, ..refs]
}

// `call_graph.rs:142-148`: a statement's bindings last until the end of the
// enclosing statement list.
fn statements(
  context: Context,
  statements: List(glance.Statement),
  scope: Scope,
  refs: List(String),
) -> List(String) {
  let #(_scope, refs) =
    list.fold(statements, #(scope, refs), fn(acc, statement) {
      let #(scope, refs) = acc
      in_statement(context, statement, scope, refs)
    })
  refs
}

fn in_statement(
  context: Context,
  statement: glance.Statement,
  scope: Scope,
  refs: List(String),
) -> #(Scope, List(String)) {
  case statement {
    glance.Expression(expr) -> #(scope, expression(context, expr, scope, refs))

    // Value, then the pattern, then the message (`call_graph.rs:155-166`),
    // so the pattern's names shadow in the message (Q4).
    glance.Assignment(_, kind, pattern, _, value) -> {
      let refs = expression(context, value, scope, refs)
      let #(after, refs) = in_pattern(context, pattern, scope, refs)
      #(
        after,
        optional(expression, context, assignment_message(kind), after, refs),
      )
    }

    glance.Use(_, use_patterns, function) -> {
      let refs = expression(context, function, scope, refs)
      patterns(
        context,
        list.map(use_patterns, fn(p) { p.pattern }),
        scope,
        refs,
      )
    }

    glance.Assert(_, expr, message) -> {
      let refs = expression(context, expr, scope, refs)
      #(scope, optional(expression, context, message, scope, refs))
    }
  }
}

fn optional(
  walk: Walk,
  context: Context,
  expr: Option(glance.Expression),
  scope: Scope,
  refs: List(String),
) -> List(String) {
  case expr {
    Some(expr) -> walk(context, expr, scope, refs)
    None -> refs
  }
}

fn expressions(
  walk: Walk,
  context: Context,
  exprs: List(glance.Expression),
  scope: Scope,
  refs: List(String),
) -> List(String) {
  list.fold(exprs, refs, fn(refs, expr) { walk(context, expr, scope, refs) })
}

// A call's or a record's fields in order; a shorthand field reads its label.
fn fields(
  walk: Walk,
  context: Context,
  fields: List(glance.Field(glance.Expression)),
  scope: Scope,
  refs: List(String),
) -> List(String) {
  list.fold(fields, refs, fn(refs, field) {
    case field {
      glance.UnlabelledField(item) | glance.LabelledField(_, _, item) ->
        walk(context, item, scope, refs)
      glance.ShorthandField(label, _) -> referenced(context, scope, label, refs)
    }
  })
}

// A record update: the base, then each field; a shorthand field reads its
// label.
fn record_update(
  walk: Walk,
  context: Context,
  record: glance.Expression,
  update_fields: List(glance.RecordUpdateField(glance.Expression)),
  scope: Scope,
  refs: List(String),
) -> List(String) {
  list.fold(update_fields, walk(context, record, scope, refs), fn(refs, field) {
    case field.item {
      Some(item) -> walk(context, item, scope, refs)
      None -> referenced(context, scope, field.label, refs)
    }
  })
}

// Each `size` option of a bit-array segment, in order.
fn size_options(
  options: List(glance.BitStringSegmentOption(t)),
  refs: List(String),
  walk: fn(t, List(String)) -> List(String),
) -> List(String) {
  list.fold(options, refs, fn(refs, option) {
    case option {
      glance.SizeValueOption(size) -> walk(size, refs)
      _ -> refs
    }
  })
}

// `call_graph.rs:184-325`.
fn expression(
  context: Context,
  expr: glance.Expression,
  scope: Scope,
  refs: List(String),
) -> List(String) {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> refs

    glance.Variable(_, name) -> referenced(context, scope, name, refs)

    glance.NegateInt(_, inner)
    | glance.NegateBool(_, inner)
    | glance.TupleIndex(_, inner, _) -> expression(context, inner, scope, refs)

    glance.Block(_, body) -> statements(context, body, scope, refs)

    glance.Panic(_, message) | glance.Todo(_, message) ->
      optional(expression, context, message, scope, refs)

    glance.Tuple(_, elements) ->
      expressions(expression, context, elements, scope, refs)

    glance.List(_, elements, rest) ->
      expressions(expression, context, elements, scope, refs)
      |> optional(expression, context, rest, scope, _)

    glance.Fn(_, arguments, _, body) -> {
      let scope =
        define_parameters(scope, list.map(arguments, fn(a) { a.name }))
      statements(context, body, scope, refs)
    }

    glance.RecordUpdate(_, _, _, record, update_fields) ->
      record_update(expression, context, record, update_fields, scope, refs)

    // Any container is walked, so `name.label` references a top-level `name`
    // even when it is module access (Q1).
    glance.FieldAccess(_, glance.Variable(_, name), _) ->
      referenced(context, scope, name, refs)
    glance.FieldAccess(_, container, _) ->
      expression(context, container, scope, refs)

    glance.Call(_, function, arguments) ->
      expression(context, function, scope, refs)
      |> fields(expression, context, arguments, scope, _)

    // The compiler's desugared call has the hole between the two lists, and
    // the hole is a local.
    glance.FnCapture(_, _, function, before, after) ->
      expression(context, function, scope, refs)
      |> fields(expression, context, before, scope, _)
      |> fields(expression, context, after, scope, _)

    // Per segment: the value, then the `size` option (`call_graph.rs:273-282`).
    glance.BitString(_, segments) ->
      list.fold(segments, refs, fn(refs, segment) {
        expression(context, segment.0, scope, refs)
        |> size_options(segment.1, _, fn(size, refs) {
          expression(context, size, scope, refs)
        })
      })

    // Per clause, scoped: the first alternative's patterns only (Q2), the
    // guard, then the body.
    glance.Case(_, subjects, clauses) ->
      list.fold(
        clauses,
        expressions(expression, context, subjects, scope, refs),
        fn(refs, clause) {
          let first = result.unwrap(list.first(clause.patterns), [])
          let #(clause_scope, refs) = patterns(context, first, scope, refs)
          let refs = case clause.guard {
            Some(guard) -> in_guard(context, guard, clause_scope, refs)
            None -> refs
          }
          expression(context, clause.body, clause_scope, refs)
        },
      )

    glance.BinaryOperator(_, _, left, right) ->
      expression(context, right, scope, expression(context, left, scope, refs))

    glance.Echo(_, inner, message) ->
      optional(expression, context, inner, scope, refs)
      |> optional(expression, context, message, scope, _)
  }
}

// `call_graph.rs:327-388`: a pattern defines as it goes.
fn in_pattern(
  context: Context,
  pattern: glance.Pattern,
  scope: Scope,
  refs: List(String),
) -> #(Scope, List(String)) {
  case pattern {
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..) -> #(scope, refs)

    glance.PatternVariable(_, name) -> #(define(scope, name), refs)

    // Only the right-hand name is defined (Q3).
    glance.PatternConcatenate(_, _, _, rest_name) -> #(
      list.fold(assignment_name(rest_name), scope, define),
      refs,
    )

    glance.PatternTuple(_, elements) -> patterns(context, elements, scope, refs)

    glance.PatternList(_, elements, tail) -> {
      let #(scope, refs) = patterns(context, elements, scope, refs)
      case tail {
        Some(tail) -> in_pattern(context, tail, scope, refs)
        None -> #(scope, refs)
      }
    }

    // The name is defined before the inner pattern is walked (Q5).
    glance.PatternAssignment(_, inner, name) ->
      in_pattern(context, inner, define(scope, name), refs)

    // Arguments in written order (Q6); a shorthand defines its label.
    glance.PatternVariant(_, _, _, arguments, _) ->
      list.fold(arguments, #(scope, refs), fn(acc, field) {
        let #(scope, refs) = acc
        case field {
          glance.UnlabelledField(inner) | glance.LabelledField(_, _, inner) ->
            in_pattern(context, inner, scope, refs)
          glance.ShorthandField(label, _) -> #(define(scope, label), refs)
        }
      })

    // Per segment: the options first, then the segment's own pattern.
    glance.PatternBitString(_, segments) ->
      list.fold(segments, #(scope, refs), fn(acc, segment) {
        let #(scope, refs) = acc
        let refs =
          size_options(segment.1, refs, fn(size, refs) {
            size_refs(context, size, scope, refs)
          })
        in_pattern(context, segment.0, scope, refs)
      })
  }
}

fn patterns(
  context: Context,
  patterns: List(glance.Pattern),
  scope: Scope,
  refs: List(String),
) -> #(Scope, List(String)) {
  list.fold(patterns, #(scope, refs), fn(acc, pattern) {
    let #(scope, refs) = acc
    in_pattern(context, pattern, scope, refs)
  })
}

// `call_graph.rs:390-400`.
fn size_refs(
  context: Context,
  size: glance.BitArraySize,
  scope: Scope,
  refs: List(String),
) -> List(String) {
  case size {
    glance.BitArraySizeInt(..) -> refs
    glance.BitArraySizeVariable(_, name) ->
      referenced(context, scope, name, refs)
    glance.BitArraySizeBinaryOperator(_, _, left, right) ->
      size_refs(context, right, scope, size_refs(context, left, scope, refs))
    glance.BitArraySizeBlock(_, inner) -> size_refs(context, inner, scope, refs)
  }
}

// `call_graph.rs:435-458`: guard forms recurse as guards; a subtree the
// compiler parses as a constant is walked by the constant rules.
fn in_guard(
  context: Context,
  guard: glance.Expression,
  scope: Scope,
  refs: List(String),
) -> List(String) {
  use <- bool.lazy_guard(when: guard_constant(guard), return: fn() {
    constant_value(context, guard, scope, refs)
  })
  case guard {
    glance.Variable(_, name) -> referenced(context, scope, name, refs)
    glance.FieldAccess(_, glance.Variable(_, name), _) ->
      referenced(context, scope, name, refs)
    glance.FieldAccess(_, container, _)
    | glance.TupleIndex(_, container, _)
    | glance.NegateBool(_, container) ->
      in_guard(context, container, scope, refs)
    glance.BinaryOperator(_, _, left, right) ->
      in_guard(context, right, scope, in_guard(context, left, scope, refs))
    glance.Block(_, body) ->
      list.fold(body, refs, fn(refs, statement) {
        case statement {
          glance.Expression(inner) -> in_guard(context, inner, scope, refs)
          _ -> in_statement(context, statement, scope, refs).1
        }
      })
    // Every other form is a constant, walked above.
    _ -> refs
  }
}

// `call_graph.rs:460-525`: a constant initializer, or a guard subtree the
// compiler parses as a constant. `module.name` and a qualified constructor
// reference nothing; a record walks its arguments, never its constructor; a
// bit array walks each segment's options before its value.
fn constant_value(
  context: Context,
  expr: glance.Expression,
  scope: Scope,
  refs: List(String),
) -> List(String) {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> refs
    glance.Variable(_, name) -> referenced(context, scope, name, refs)
    glance.FieldAccess(..) -> refs
    glance.Call(_, _, arguments) ->
      fields(constant_value, context, arguments, scope, refs)
    glance.RecordUpdate(_, _, _, record, update_fields) ->
      record_update(constant_value, context, record, update_fields, scope, refs)
    glance.BitString(_, segments) ->
      list.fold(segments, refs, fn(refs, segment) {
        size_options(segment.1, refs, fn(size, refs) {
          constant_value(context, size, scope, refs)
        })
        |> constant_value(context, segment.0, scope, _)
      })
    glance.List(_, elements, rest) ->
      expressions(constant_value, context, elements, scope, refs)
      |> optional(constant_value, context, rest, scope, _)
    glance.Tuple(_, elements) ->
      expressions(constant_value, context, elements, scope, refs)
    glance.BinaryOperator(_, _, left, right) ->
      constant_value(context, left, scope, refs)
      |> constant_value(context, right, scope, _)
    glance.Todo(_, message) | glance.Panic(_, message) ->
      optional(constant_value, context, message, scope, refs)
    glance.NegateInt(_, inner) | glance.NegateBool(_, inner) ->
      constant_value(context, inner, scope, refs)
    // Not constant syntax; walked as an expression should glance accept it.
    glance.Block(..)
    | glance.Fn(..)
    | glance.Case(..)
    | glance.FnCapture(..)
    | glance.TupleIndex(..)
    | glance.Echo(..) -> expression(context, expr, scope, refs)
  }
}

// Bound-name extraction

fn assignment_name(name: glance.AssignmentName) -> List(String) {
  case name {
    glance.Named(n) -> [n]
    glance.Discarded(_) -> []
  }
}

/// Every variable a pattern binds, as the typer binds them: a string prefix's
/// `as` name included. Inference needs it to know which names a pattern
/// rebinds, since a rebound name is not narrowed.
pub fn pattern_names(pattern: glance.Pattern) -> List(String) {
  case pattern {
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..) -> []

    glance.PatternVariable(_, name) -> [name]

    glance.PatternTuple(_, elements) -> list.flat_map(elements, pattern_names)

    glance.PatternList(_, elements, tail) ->
      case tail {
        Some(t) ->
          list.append(list.flat_map(elements, pattern_names), pattern_names(t))
        None -> list.flat_map(elements, pattern_names)
      }

    glance.PatternAssignment(_, pattern, name) -> [
      name,
      ..pattern_names(pattern)
    ]

    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) ->
      list.append(
        case prefix_name {
          Some(n) -> assignment_name(n)
          None -> []
        },
        assignment_name(rest_name),
      )

    glance.PatternBitString(_, segments) ->
      list.flat_map(segments, fn(segment) { pattern_names(segment.0) })

    // A shorthand field in a constructor pattern (`Work(work:, receive:)`)
    // binds the label as a variable.
    glance.PatternVariant(_, _module, _constructor, arguments, _spread) ->
      list.flat_map(arguments, fn(field) {
        case field {
          glance.UnlabelledField(p) -> pattern_names(p)
          glance.LabelledField(_, _, p) -> pattern_names(p)
          glance.ShorthandField(label, _) -> [label]
        }
      })
  }
}
