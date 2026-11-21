// Helpers for the probe tests (`group_inference_test`,
// `constant_context_test`): annotate a probe's source with in-memory imports
// and read back a signature, a constant's type, an error, a resolution at a
// snippet, the annotations at a span, or the module's dependency order.

import girard
import girard/internal/reference
import glance
import gleam/dict
import gleam/list
import gleam/string

pub fn options_with(modules: List(#(String, String))) -> girard.Options {
  let table = dict.from_list(modules)
  girard.default_options()
  |> girard.with_resolver(fn(path) { dict.get(table, path) })
}

pub fn annotated(
  source: String,
  modules: List(#(String, String)),
) -> girard.AnnotatedModule {
  let assert Ok(annotated) = girard.annotate(source, options_with(modules))
  annotated
}

// The rendered signature of the top-level function `name`.
pub fn signature(
  source: String,
  modules: List(#(String, String)),
  name: String,
) -> String {
  case list.key_find(annotated(source, modules).functions, name) {
    Ok(scheme) -> girard.type_to_string(scheme.type_)
    Error(_) -> panic as { "no function named " <> name }
  }
}

// The rendered type of the top-level constant `name`.
pub fn constant(
  source: String,
  modules: List(#(String, String)),
  name: String,
) -> String {
  case list.key_find(annotated(source, modules).constants, name) {
    Ok(scheme) -> girard.type_to_string(scheme.type_)
    Error(_) -> panic as { "no constant named " <> name }
  }
}

pub fn error_with(
  source: String,
  modules: List(#(String, String)),
) -> girard.Error {
  let assert Error(error) = girard.annotate(source, options_with(modules))
  error
}

// What the `n`th occurrence (from 1) of `snippet` resolved to.
pub fn resolution(
  source: String,
  modules: List(#(String, String)),
  snippet: String,
  n: Int,
) -> girard.Resolution {
  resolution_at(source, modules, nth_span(source, snippet, n))
}

// What the callee of the `n`th occurrence of the call `snippet` resolved to:
// a bare name in call position is resolved at the name alone.
pub fn callee_resolution(
  source: String,
  modules: List(#(String, String)),
  snippet: String,
  n: Int,
) -> girard.Resolution {
  let assert Ok(#(callee, _)) = string.split_once(snippet, "(")
  let call = nth_span(source, snippet, n)
  resolution_at(
    source,
    modules,
    glance.Span(call.start, call.start + string.byte_size(callee)),
  )
}

fn resolution_at(
  source: String,
  modules: List(#(String, String)),
  span: glance.Span,
) -> girard.Resolution {
  case
    list.find(annotated(source, modules).resolutions, fn(r) { r.span == span })
  {
    Ok(reference) -> reference.resolution
    Error(_) -> panic as "no resolution at that span"
  }
}

pub fn nth_span(source: String, snippet: String, n: Int) -> glance.Span {
  let parts = string.split(source, snippet)
  let before = list.take(parts, n) |> string.join(snippet)
  let start = string.byte_size(before)
  case list.length(parts) > n {
    True -> glance.Span(start, start + string.byte_size(snippet))
    False -> panic as { "fewer occurrences of " <> snippet }
  }
}

// The module's dependency order, as the compiler's call graph gives it.
pub fn order(source: String) -> List(List(String)) {
  let assert Ok(module) = glance.module(source)
  reference.dependency_order(
    list.map(module.functions, fn(d) { d.definition }),
    list.map(module.constants, fn(d) { d.definition }),
  )
}

// Every type recorded at the span of the `n`th occurrence of `snippet`.
pub fn annotations(
  source: String,
  modules: List(#(String, String)),
  snippet: String,
  n: Int,
) -> List(String) {
  let span = nth_span(source, snippet, n)
  annotated(source, modules).expressions
  |> list.filter(fn(a) { a.span == span })
  |> list.map(fn(a) { girard.type_to_string(a.type_) })
}
