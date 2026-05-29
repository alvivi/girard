//// girard: a type annotator for Gleam, written in Gleam.
////
//// Parses a Gleam module with `glance`, runs Hindley-Milner type inference
//// (see `girard/infer`), and reports the inferred type of every expression (by
//// source span) along with each top-level definition's signature.
////
//// Imported modules are resolved through a `Resolver` and inferred to obtain
//// their public interfaces. Errors are not reported: invalid or unsupported
//// input `panic`s.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/order
import gleam/set.{type Set}
import gleam/string
import glance
import simplifile
import girard/infer.{type ModuleInterface}
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

/// Resolves an imported module path (e.g. "gleam/list") to its source.
pub type Resolver =
  fn(String) -> Result(String, Nil)

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

fn infer_def(
  env: infer.Env,
  st: infer.State,
  def: Def,
) -> #(Type, infer.State) {
  case def {
    FunctionDef(f) -> infer.infer_function(env, st, f)
    ConstantDef(c) -> infer.infer_constant(env, st, c)
  }
}

/// Annotate a Gleam source string, resolving imports from disk.
pub fn annotate(source: String) -> Annotated {
  annotate_with(source, disk_resolver)
}

/// Annotate a Gleam source string, resolving imports with a custom resolver.
pub fn annotate_with(source: String, resolver: Resolver) -> Annotated {
  let module = parse(source)
  let #(env, st) = infer_module(resolver, set.new(), "", module).0
  render(module, env, st)
}

// --- Module inference ------------------------------------------------------

/// Fully infer a module: resolve imports, register types, and infer every
/// definition in dependency order. Returns the final environment and state
/// plus the module's public interface.
fn infer_module(
  resolver: Resolver,
  loading: Set(String),
  module_name: String,
  module: glance.Module,
) -> #(#(infer.Env, infer.State), ModuleInterface) {
  let #(prelude_env, st) = infer.prelude()
  let env = infer.set_module(prelude_env, module_name)

  // 1. Imports.
  let env = process_imports(resolver, loading, env, module.imports)

  // 2. Pre-declare local type names so forward references resolve, then
  //    register aliases, custom-type constructors/accessors, and field maps.
  let env =
    list.fold(module.custom_types, env, fn(env, d) {
      let ct = d.definition
      infer.declare_type(env, ct.name, list.length(ct.parameters))
    })
  let env =
    list.fold(module.type_aliases, env, fn(env, d) {
      infer.register_type_alias(env, d.definition)
    })
  let #(env, st) =
    list.fold(module.custom_types, #(env, st), fn(acc, d) {
      let #(env, st) = acc
      infer.register_custom_type(env, st, d.definition)
    })
  let env =
    list.fold(module.functions, env, fn(env, d) {
      let f = d.definition
      infer.register_field_map(env, f.name, list.map(f.parameters, fn(p) {
        p.label
      }))
    })

  // 3. Infer definitions in strongly-connected-component order.
  let functions = list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants = list.map(module.constants, fn(d) { ConstantDef(d.definition) })
  let defs = list.append(functions, constants)
  let #(final_env, st) = infer_defs(env, st, defs)

  let interface =
    infer.build_interface(
      final_env,
      module_name,
      public_value_names(module),
      public_type_names(module),
    )
  #(#(final_env, st), interface)
}

fn infer_defs(
  env: infer.Env,
  st: infer.State,
  defs: List(Def),
) -> #(infer.Env, infer.State) {
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

  // Members of a component are mutually recursive and inferred monomorphically
  // together; afterwards each is generalized against the surrounding
  // environment and added back for later components.
  list.fold(order, #(env, st), fn(acc, group) {
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
}

// --- Imports ---------------------------------------------------------------

fn process_imports(
  resolver: Resolver,
  loading: Set(String),
  env: infer.Env,
  imports: List(glance.Definition(glance.Import)),
) -> infer.Env {
  list.fold(imports, env, fn(env, definition) {
    let import_ = definition.definition
    let path = import_.module
    case set.contains(loading, path), resolve_interface(resolver, loading, path) {
      False, Ok(interface) -> {
        let alias = import_alias(import_)
        let env = infer.import_qualified(env, alias, interface)
        let env =
          list.fold(import_.unqualified_values, env, fn(env, u) {
            infer.import_value(
              env,
              option.unwrap(u.alias, u.name),
              interface,
              u.name,
            )
          })
        list.fold(import_.unqualified_types, env, fn(env, u) {
          infer.import_type(
            env,
            option.unwrap(u.alias, u.name),
            interface,
            u.name,
          )
        })
      }
      // Unresolvable or cyclic import: skip (best effort, no diagnostics).
      _, _ -> env
    }
  })
}

fn resolve_interface(
  resolver: Resolver,
  loading: Set(String),
  path: String,
) -> Result(ModuleInterface, Nil) {
  case resolver(path) {
    Ok(source) ->
      case glance.module(source) {
        Ok(module) -> {
          let #(_, interface) =
            infer_module(resolver, set.insert(loading, path), path, module)
          Ok(interface)
        }
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn import_alias(import_: glance.Import) -> String {
  case import_.alias {
    Some(glance.Named(alias)) -> alias
    _ -> last_segment(import_.module)
  }
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(segment) -> segment
    Error(_) -> path
  }
}

fn public_value_names(module: glance.Module) -> List(String) {
  let functions =
    list.filter_map(module.functions, fn(d) {
      case d.definition.publicity {
        glance.Public -> Ok(d.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  let constants =
    list.filter_map(module.constants, fn(d) {
      case d.definition.publicity {
        glance.Public -> Ok(d.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  // Constructors of public, non-opaque types are public values.
  let constructors =
    list.flat_map(module.custom_types, fn(d) {
      let ct = d.definition
      case ct.publicity, ct.opaque_ {
        glance.Public, False -> list.map(ct.variants, fn(v) { v.name })
        _, _ -> []
      }
    })
  list.flatten([functions, constants, constructors])
}

fn public_type_names(module: glance.Module) -> List(String) {
  let types =
    list.filter_map(module.custom_types, fn(d) {
      case d.definition.publicity {
        glance.Public -> Ok(d.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  let aliases =
    list.filter_map(module.type_aliases, fn(d) {
      case d.definition.publicity {
        glance.Public -> Ok(d.definition.name)
        glance.Private -> Error(Nil)
      }
    })
  list.append(types, aliases)
}

// --- Default disk resolver -------------------------------------------------

/// Look for an imported module's source under `src/` and the `build/packages`
/// dependency sources, relative to the current working directory.
fn disk_resolver(path: String) -> Result(String, Nil) {
  let candidates = [
    "src/" <> path <> ".gleam",
    ..dependency_candidates(path)
  ]
  first_readable(candidates)
}

fn dependency_candidates(path: String) -> List(String) {
  case simplifile.read_directory("build/packages") {
    Ok(packages) ->
      list.map(packages, fn(pkg) {
        "build/packages/" <> pkg <> "/src/" <> path <> ".gleam"
      })
    Error(_) -> []
  }
}

fn first_readable(paths: List(String)) -> Result(String, Nil) {
  case paths {
    [] -> Error(Nil)
    [path, ..rest] ->
      case simplifile.read(path) {
        Ok(source) -> Ok(source)
        Error(_) -> first_readable(rest)
      }
  }
}

// --- Rendering -------------------------------------------------------------

fn render(
  module: glance.Module,
  env: infer.Env,
  st: infer.State,
) -> Annotated {
  let functions = list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants = list.map(module.constants, fn(d) { ConstantDef(d.definition) })

  let printer_names = printer.new_names()
  let #(signatures, printer_names) =
    collect_signatures(functions, env, printer_names)
  let #(constant_types, printer_names) =
    collect_signatures(constants, env, printer_names)

  let #(expressions, _names) =
    list.fold(
      list.reverse(st.annotations),
      #([], printer_names),
      fn(acc, entry) {
        let #(rendered, names) = acc
        let #(span, type_) = entry
        let #(text, names) = printer.print(names, infer.zonk(st, type_))
        #([Annotation(span, text), ..rendered], names)
      },
    )

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
    list.map(list.append(annotated.functions, annotated.constants), fn(f) {
      f.0 <> ": " <> f.1
    })
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

fn parse(source: String) -> glance.Module {
  case glance.module(source) {
    Ok(module) -> module
    Error(_) -> panic as "failed to parse source"
  }
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
