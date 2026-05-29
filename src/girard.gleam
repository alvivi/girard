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
import girard/types.{type Scheme, type Type, Scheme}

/// The inferred type of a single expression, identified by its source span.
pub type Annotation {
  Annotation(span: glance.Span, type_: String)
}

/// The full result of annotating a module.
pub type Annotated {
  Annotated(
    /// Top-level function name to inferred signature, in source order.
    functions: List(#(String, String)),
    /// Top-level constant name to inferred type, in source order.
    constants: List(#(String, String)),
    /// Expression span to inferred type, sorted by start offset.
    expressions: List(Annotation),
  )
}

/// A top-level definition that participates in the dependency graph.
type Def {
  FunctionDef(glance.Function)
  ConstantDef(glance.Constant)
}

fn def_name(def: Def) -> String {
  case def {
    FunctionDef(f) -> f.name
    ConstantDef(c) -> c.name
  }
}

fn def_refs(def: Def) -> List(String) {
  case def {
    FunctionDef(f) -> references.in_function(f)
    ConstantDef(c) -> references.in_constant(c)
  }
}

fn infer_def(env: infer.Env, st: infer.State, def: Def) -> #(Type, infer.State) {
  case def {
    FunctionDef(f) -> infer.infer_function(env, st, f)
    ConstantDef(c) -> infer.infer_constant(env, st, c)
  }
}

/// Annotate a Gleam source string.
pub fn annotate(source: String) -> Annotated {
  let module = case glance.module(source) {
    Ok(module) -> module
    Error(_) -> panic as "failed to parse source"
  }

  // 1. Register type aliases and custom-type constructors into the base
  //    environment.
  let #(prelude_env, prelude_st) = infer.prelude()
  let base_env =
    list.fold(module.type_aliases, prelude_env, fn(env, definition) {
      infer.register_type_alias(env, definition.definition)
    })
  let #(base_env, st) =
    list.fold(module.custom_types, #(base_env, prelude_st), fn(acc, definition) {
      let #(env, st) = acc
      infer.register_custom_type(env, st, definition.definition)
    })

  // 2. Order top-level definitions (functions and constants) by dependency:
  //    build the call graph and group it into strongly-connected components so
  //    each definition is inferred and generalized before its dependents.
  let functions = list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants = list.map(module.constants, fn(d) { ConstantDef(d.definition) })
  let defs = list.append(functions, constants)
  let by_name = dict.from_list(list.map(defs, fn(d) { #(def_name(d), d) }))
  let names = list.map(defs, def_name)
  let name_set = set.from_list(names)
  let edges =
    dict.from_list(
      list.map(defs, fn(d) {
        #(def_name(d), list.filter(def_refs(d), set.contains(name_set, _)))
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
          let assert Ok(def) = dict.get(by_name, name)
          let #(inferred, st) = infer_def(group_env, st, def)
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
    collect_signatures(functions, final_env, printer_names)
  let #(constant_types, printer_names) =
    collect_signatures(constants, final_env, printer_names)
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
    functions: signatures,
    constants: constant_types,
    expressions: sort_by_span(list.reverse(expressions)),
  )
}

/// Render the inferred signature of each definition, in source order, keeping
/// type-variable names stable across the shared printer context.
fn collect_signatures(
  defs: List(Def),
  env: infer.Env,
  printer_names: printer.Names,
) -> #(List(#(String, String)), printer.Names) {
  let #(rev, printer_names) =
    list.fold(defs, #([], printer_names), fn(acc, def) {
      let #(sigs, printer_names) = acc
      let name = def_name(def)
      let assert Ok(scheme) = infer.lookup(env, name)
      let #(rendered, printer_names) = print_scheme(printer_names, scheme)
      #([#(name, rendered), ..sigs], printer_names)
    })
  #(list.reverse(rev), printer_names)
}

/// Render an annotated module as text (the human-facing report).
pub fn format(source: String) -> String {
  let annotated = annotate(source)
  let signatures =
    list.map(
      list.append(annotated.functions, annotated.constants),
      fn(f) { f.0 <> ": " <> f.1 },
    )
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
