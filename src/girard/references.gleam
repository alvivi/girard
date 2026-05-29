//// Collect the names a definition's body refers to, used to build the
//// call graph between top-level definitions. This is an over-approximation:
//// it gathers every `Variable` reference without tracking local shadowing.
//// Spurious edges can only merge components (reducing polymorphism in rare
//// shadowing cases), never produce an incorrect type.

import gleam/list
import gleam/option.{type Option, None, Some}
import glance

/// All variable names referenced anywhere in a function body.
pub fn in_function(function: glance.Function) -> List(String) {
  in_statements(function.body, [])
}

fn in_statements(
  statements: List(glance.Statement),
  acc: List(String),
) -> List(String) {
  list.fold(statements, acc, fn(acc, statement) {
    case statement {
      glance.Expression(expr) -> in_expr(expr, acc)
      glance.Assignment(_, _, _, _, value) -> in_expr(value, acc)
      glance.Assert(_, expr, message) ->
        in_optional(message, in_expr(expr, acc))
      glance.Use(_, _patterns, function) -> in_expr(function, acc)
    }
  })
}

fn in_optional(
  expr: Option(glance.Expression),
  acc: List(String),
) -> List(String) {
  case expr {
    Some(e) -> in_expr(e, acc)
    None -> acc
  }
}

fn in_exprs(exprs: List(glance.Expression), acc: List(String)) -> List(String) {
  list.fold(exprs, acc, fn(acc, e) { in_expr(e, acc) })
}

fn in_fields(
  fields: List(glance.Field(glance.Expression)),
  acc: List(String),
) -> List(String) {
  list.fold(fields, acc, fn(acc, field) {
    case field {
      glance.UnlabelledField(item) -> in_expr(item, acc)
      glance.LabelledField(_, _, item) -> in_expr(item, acc)
      glance.ShorthandField(label, _) -> [label, ..acc]
    }
  })
}

fn in_expr(expr: glance.Expression, acc: List(String)) -> List(String) {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> acc

    glance.Variable(_, name) -> [name, ..acc]

    glance.NegateInt(_, value) | glance.NegateBool(_, value) ->
      in_expr(value, acc)

    glance.Block(_, statements) -> in_statements(statements, acc)

    glance.Panic(_, message) | glance.Todo(_, message) ->
      in_optional(message, acc)

    glance.Tuple(_, elements) -> in_exprs(elements, acc)

    glance.List(_, elements, rest) -> in_optional(rest, in_exprs(elements, acc))

    glance.Fn(_, _arguments, _return, body) -> in_statements(body, acc)

    glance.RecordUpdate(_, _, _, record, fields) ->
      list.fold(fields, in_expr(record, acc), fn(acc, field) {
        in_optional(field.item, acc)
      })

    glance.FieldAccess(_, container, _label) -> in_expr(container, acc)

    glance.Call(_, function, arguments) ->
      in_fields(arguments, in_expr(function, acc))

    glance.TupleIndex(_, tuple, _index) -> in_expr(tuple, acc)

    glance.FnCapture(_, _label, function, before, after) ->
      in_fields(after, in_fields(before, in_expr(function, acc)))

    glance.BitString(_, segments) ->
      list.fold(segments, acc, fn(acc, segment) { in_expr(segment.0, acc) })

    glance.Case(_, subjects, clauses) ->
      list.fold(clauses, in_exprs(subjects, acc), fn(acc, clause) {
        in_optional(clause.guard, in_expr(clause.body, acc))
      })

    glance.BinaryOperator(_, _name, left, right) ->
      in_expr(right, in_expr(left, acc))

    glance.Echo(_, expression, message) ->
      in_optional(message, in_optional(expression, acc))
  }
}
