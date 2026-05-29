//// girard: a type annotator for Gleam, written in Gleam.
////
//// Parses a single Gleam module with `glance`, runs Hindley-Milner type
//// inference (see `girard/infer`), and reports the inferred type of every
//// expression (by source span) along with each top-level function's signature.
////
//// Errors are not reported: invalid or unsupported input `panic`s.

import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/set
import gleam/string
import glance
import girard/infer
import girard/printer
import girard/references
import girard/scc
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

  // 2. Order top-level functions by dependency: build the call graph and group
  //    it into strongly-connected components so each function is inferred and
  //    generalized before its dependents (letting helpers stay polymorphic).
  let functions = list.map(module.functions, fn(d) { d.definition })
  let by_name = dict.from_list(list.map(functions, fn(f) { #(f.name, f) }))
  let names = list.map(functions, fn(f) { f.name })
  let name_set = set.from_list(names)
  let edges =
    dict.from_list(
      list.map(functions, fn(f) {
        let referenced =
          list.filter(references.in_function(f), set.contains(name_set, _))
        #(f.name, referenced)
      }),
    )
  let order = scc.components(names, edges)

  // 3. Infer each component. Members of a component are mutually recursive and
  //    inferred monomorphically together; afterwards each is generalized
  //    against the surrounding environment and added back for later components.
  let #(final_env, st) =
    list.fold(order, #(base_env, st), fn(acc, group) {
      let #(env, st) = acc
      let #(group_env, group_vars, st) =
        list.fold(group, #(env, [], st), fn(acc, name) {
          let #(env, vars, st) = acc
          let #(var, st) = infer.fresh_var(st)
          #(infer.define(env, name, Scheme([], var)), [#(name, var), ..vars], st)
        })
      let st =
        list.fold(group_vars, st, fn(st, pair) {
          let #(name, var) = pair
          let assert Ok(function) = dict.get(by_name, name)
          let #(inferred, st) = infer.infer_function(group_env, st, function)
          infer.unify(st, var, inferred)
        })
      let env =
        list.fold(group_vars, env, fn(env, pair) {
          let #(name, var) = pair
          infer.define(env, name, infer.generalize(st, env, var))
        })
      #(env, st)
    })

  // 4. Collect signatures in source order from the final environment.
  let printer_names = printer.new_names()
  let #(signatures, printer_names) =
    list.fold(functions, #([], printer_names), fn(acc, function) {
      let #(sigs, printer_names) = acc
      let assert Ok(scheme) = infer.lookup(final_env, function.name)
      let #(rendered, printer_names) = print_scheme(printer_names, scheme)
      #([#(function.name, rendered), ..sigs], printer_names)
    })
  let names = printer_names

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
