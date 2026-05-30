//// Collect the names a definition's body refers to, used to build the call
//// graph between top-level definitions. This is an over-approximation: it
//// gathers `Variable` references without tracking local shadowing.
////
//// References are split into two kinds:
////   - *values*: names used in value position (`f`, `f(x)`, shorthand fields).
////   - *qualifiers*: the bare name of a field access (`x` in `x.label`), which
////     is usually qualified module access (`string.trim`) rather than a real
////     dependency. The caller keeps a qualifier edge only when the name is a
////     local definition rather than an imported module — so a `string` helper
////     does not get grouped with `gleam/string`, while a `config.field` access
////     on a local `config` constant still orders that constant first.

import glance
import gleam/list
import gleam/option.{type Option, None, Some}

/// `#(value references, field-access qualifier names)` in a function body.
pub fn in_function(function: glance.Function) -> #(List(String), List(String)) {
  in_statements(function.body, #([], []))
}

/// `#(value references, field-access qualifier names)` in a constant's value.
pub fn in_constant(constant: glance.Constant) -> #(List(String), List(String)) {
  in_expr(constant.value, #([], []))
}

type Acc =
  #(List(String), List(String))

fn value(acc: Acc, name: String) -> Acc {
  #([name, ..acc.0], acc.1)
}

fn qualifier(acc: Acc, name: String) -> Acc {
  #(acc.0, [name, ..acc.1])
}

fn in_statements(statements: List(glance.Statement), acc: Acc) -> Acc {
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

fn in_optional(expr: Option(glance.Expression), acc: Acc) -> Acc {
  case expr {
    Some(e) -> in_expr(e, acc)
    None -> acc
  }
}

fn in_exprs(exprs: List(glance.Expression), acc: Acc) -> Acc {
  list.fold(exprs, acc, fn(acc, e) { in_expr(e, acc) })
}

fn in_fields(fields: List(glance.Field(glance.Expression)), acc: Acc) -> Acc {
  list.fold(fields, acc, fn(acc, field) {
    case field {
      glance.UnlabelledField(item) -> in_expr(item, acc)
      glance.LabelledField(_, _, item) -> in_expr(item, acc)
      glance.ShorthandField(label, _) -> value(acc, label)
    }
  })
}

fn in_expr(expr: glance.Expression, acc: Acc) -> Acc {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> acc

    glance.Variable(_, name) -> value(acc, name)

    glance.NegateInt(_, v) | glance.NegateBool(_, v) -> in_expr(v, acc)

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

    // `x.label` with a bare-name container records `x` as a *qualifier*: it is
    // usually module access (`string.trim`). A non-variable container
    // (`f().field`) is a real value reference.
    glance.FieldAccess(_, glance.Variable(_, name), _label) ->
      qualifier(acc, name)
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
