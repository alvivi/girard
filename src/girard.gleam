//// girard: a type annotator for Gleam, written in Gleam.
////
//// Parses a single Gleam module with `glance`, runs Hindley-Milner type
//// inference (see `girard/infer`), and reports the inferred type of every
//// expression (by source span) along with each top-level function's signature.
////
//// Errors are not reported: invalid or unsupported input `panic`s.

import gleam/int
import gleam/list
import gleam/order
import gleam/string
import glance
import girard/infer
import girard/printer
import girard/types.{type Scheme, Scheme}

/// The inferred type of a single expression, identified by its source span.
pub type Annotation {
  Annotation(span: glance.Span, type_: String)
}

/// The full result of annotating a module.
pub type Annotated {
  Annotated(
    /// Top-level function name to inferred signature, in source order.
    functions: List(#(String, String)),
    /// Expression span to inferred type, sorted by start offset.
    expressions: List(Annotation),
  )
}

/// Annotate a Gleam source string.
pub fn annotate(source: String) -> Annotated {
  let module = case glance.module(source) {
    Ok(module) -> module
    Error(_) -> panic as "failed to parse source"
  }

  // 1. Register custom-type constructors into the base environment.
  let #(base_env, st) =
    list.fold(
      module.custom_types,
      infer.prelude(),
      fn(acc, definition) {
        let #(env, st) = acc
        infer.register_custom_type(env, st, definition.definition)
      },
    )

  // 2. Bind every top-level function to a fresh variable so the whole module
  //    can be inferred as one (mutually recursive) group.
  let functions = list.map(module.functions, fn(d) { d.definition })
  let #(group_env, fn_vars, st) =
    list.fold(functions, #(base_env, [], st), fn(acc, function) {
      let #(env, vars, st) = acc
      let #(var, st) = infer.fresh_var(st)
      let env = infer.define(env, function.name, Scheme([], var))
      #(env, [#(function.name, var), ..vars], st)
    })
  let fn_vars = list.reverse(fn_vars)

  // 3. Infer each function body, tying it to its variable.
  let st =
    list.fold(list.zip(functions, fn_vars), st, fn(st, pair) {
      let #(function, #(_name, var)) = pair
      let #(inferred, st) = infer.infer_function(group_env, st, function)
      infer.unify(st, var, inferred)
    })

  // 4. Generalize each function against the base environment (constructors
  //    only) so signatures come out fully polymorphic.
  let names = printer.new_names()
  let #(signatures, names) =
    list.fold(fn_vars, #([], names), fn(acc, pair) {
      let #(sigs, names) = acc
      let #(name, var) = pair
      let scheme = infer.generalize(st, base_env, var)
      let #(rendered, names) = print_scheme(names, scheme)
      #([#(name, rendered), ..sigs], names)
    })

  // 5. Render every recorded expression annotation, keeping variable names
  //    consistent across the whole module.
  let #(expressions, _names) =
    list.fold(list.reverse(st.annotations), #([], names), fn(acc, entry) {
      let #(rendered, names) = acc
      let #(span, type_) = entry
      let #(text, names) = printer.print(names, infer.zonk(st, type_))
      #([Annotation(span, text), ..rendered], names)
    })

  Annotated(
    functions: list.reverse(signatures),
    expressions: sort_by_span(list.reverse(expressions)),
  )
}

/// Render an annotated module as text (the human-facing report).
pub fn format(source: String) -> String {
  let annotated = annotate(source)
  let signatures = list.map(annotated.functions, fn(f) { f.0 <> ": " <> f.1 })
  let expressions =
    list.map(annotated.expressions, fn(a) {
      int.to_string(a.span.start)
      <> "-"
      <> int.to_string(a.span.end)
      <> ": "
      <> a.type_
    })
  string.join(list.append(signatures, expressions), "\n")
}

fn print_scheme(names: printer.Names, scheme: Scheme) -> #(String, printer.Names) {
  printer.print(names, scheme.type_)
}

fn sort_by_span(annotations: List(Annotation)) -> List(Annotation) {
  list.sort(annotations, fn(a, b) {
    case int.compare(a.span.start, b.span.start) {
      order.Eq -> int.compare(a.span.end, b.span.end)
      other -> other
    }
  })
}
