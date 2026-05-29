//// girard: a type annotator for Gleam, written in Gleam.
////
//// Parses a Gleam module with `glance`, runs Hindley-Milner type inference
//// (see `girard/infer`), and reports the inferred type of every expression (by
//// source span) along with each top-level definition's signature.
////
//// Imported modules are resolved through a `Resolver` and inferred to obtain
//// their public interfaces. Inference is total: `annotate` returns a `Result`
//// describing why a module could not be typed rather than crashing.

import argv
import girard/infer.{type ModuleInterface}
import girard/printer
import girard/references
import girard/scc
import girard/types.{type Scheme, type Type, Scheme}
import glance
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

/// Why a module could not be typed (re-exported from `girard/infer`).
pub type Error =
  infer.Error

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
) -> Result(#(Type, infer.State), Error) {
  case def {
    FunctionDef(f) -> infer.infer_function(env, st, f)
    ConstantDef(c) -> infer.infer_constant(env, st, c)
  }
}

/// Annotate a Gleam source string, resolving imports from disk.
pub fn annotate(source: String) -> Result(Annotated, Error) {
  annotate_with(source, disk_resolver)
}

/// Annotate a Gleam source string, resolving imports with a custom resolver.
pub fn annotate_with(
  source: String,
  resolver: Resolver,
) -> Result(Annotated, Error) {
  use module <- result.try(parse(source))
  use #(#(env, st), _interface) <- result.try(infer_module(
    resolver,
    set.new(),
    "",
    module,
  ))
  Ok(render(module, env, st))
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
) -> Result(#(#(infer.Env, infer.State), ModuleInterface), Error) {
  let #(prelude_env, st) = infer.prelude()
  let env = infer.set_module(prelude_env, module_name)

  // 1. Imports.
  use env <- result.try(process_imports(resolver, loading, env, module.imports))

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
      infer.register_field_map(
        env,
        f.name,
        list.map(f.parameters, fn(p) { p.label }),
      )
    })

  // 3. Infer definitions in strongly-connected-component order.
  let functions =
    list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants =
    list.map(module.constants, fn(d) { ConstantDef(d.definition) })
  let defs = list.append(functions, constants)
  use #(final_env, st) <- result.try(infer_defs(env, st, defs))

  let interface =
    infer.build_interface(
      final_env,
      st,
      module_name,
      public_value_names(module),
      public_type_names(module),
    )
  Ok(#(#(final_env, st), interface))
}

fn infer_defs(
  env: infer.Env,
  st: infer.State,
  defs: List(Def),
) -> Result(#(infer.Env, infer.State), Error) {
  let by_name = dict.from_list(list.map(defs, fn(d) { #(def_name(d), d) }))
  let names = list.map(defs, def_name)
  let name_set = set.from_list(names)
  let edges =
    dict.from_list(
      list.map(defs, fn(d) {
        #(def_name(d), list.filter(def_refs(d), set.contains(name_set, _)))
      }),
    )
  // Each component is a group of mutually recursive definitions, in dependency
  // order. Resolve the names back to definitions up front.
  let groups =
    list.map(scc.components(names, edges), fn(group) {
      list.filter_map(group, dict.get(by_name, _))
    })

  // Members of a component are inferred monomorphically together; afterwards
  // each is generalized against the surrounding environment and added back for
  // later components.
  list.try_fold(groups, #(env, st), fn(acc, group) {
    let #(env, st) = acc
    let #(group_env, group_vars, st) =
      list.fold(group, #(env, [], st), fn(acc, def) {
        let #(env, vars, st) = acc
        let #(var, st) = infer.fresh_var(st)
        #(
          infer.define(env, def_name(def), Scheme([], var)),
          [#(def, var), ..vars],
          st,
        )
      })
    use st <- result.try(
      list.try_fold(group_vars, st, fn(st, pair) {
        let #(def, var) = pair
        use #(inferred, st) <- result.try(infer_def(group_env, st, def))
        infer.unify(st, var, inferred)
      }),
    )
    // The component's bodies are fully inferred, so any field accesses deferred
    // because their record type was unknown can now be resolved — before we
    // generalize, so the field types are reflected in the schemes.
    use st <- result.try(infer.resolve_pending(group_env, st))
    let env =
      list.fold(group_vars, env, fn(env, pair) {
        let #(def, var) = pair
        infer.define(env, def_name(def), infer.generalize(st, env, var))
      })
    Ok(#(env, st))
  })
}

// --- Imports ---------------------------------------------------------------

fn process_imports(
  resolver: Resolver,
  loading: Set(String),
  env: infer.Env,
  imports: List(glance.Definition(glance.Import)),
) -> Result(infer.Env, Error) {
  list.try_fold(imports, env, fn(env, definition) {
    let import_ = definition.definition
    let path = import_.module
    case set.contains(loading, path) {
      // Cyclic import: break the cycle by skipping.
      True -> Ok(env)
      False -> {
        use maybe_interface <- result.try(resolve_interface(
          resolver,
          loading,
          path,
        ))
        case maybe_interface {
          // Unresolvable or unparsable: best effort, skip (uses of it surface
          // later as unbound variables).
          None -> Ok(env)
          Some(interface) -> {
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
            Ok(
              list.fold(import_.unqualified_types, env, fn(env, u) {
                infer.import_type(
                  env,
                  option.unwrap(u.alias, u.name),
                  interface,
                  u.name,
                )
              }),
            )
          }
        }
      }
    }
  })
}

fn resolve_interface(
  resolver: Resolver,
  loading: Set(String),
  path: String,
) -> Result(Option(ModuleInterface), Error) {
  case resolver(path) {
    Error(_) -> Ok(None)
    Ok(source) ->
      case glance.module(source) {
        Error(_) -> Ok(None)
        Ok(module) -> {
          use #(_, interface) <- result.try(infer_module(
            resolver,
            set.insert(loading, path),
            path,
            module,
          ))
          Ok(Some(interface))
        }
      }
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
  first_readable(["src/" <> path <> ".gleam", ..dependency_candidates(path)])
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

fn render(module: glance.Module, env: infer.Env, st: infer.State) -> Annotated {
  let functions =
    list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants =
    list.map(module.constants, fn(d) { ConstantDef(d.definition) })

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
/// type-variable names stable across the shared printer context. Definitions
/// the environment somehow lacks are skipped.
fn collect_signatures(
  defs: List(Def),
  env: infer.Env,
  printer_names: printer.Names,
) -> #(List(#(String, String)), printer.Names) {
  let #(rev, printer_names) =
    list.fold(defs, #([], printer_names), fn(acc, def) {
      let #(sigs, printer_names) = acc
      let name = def_name(def)
      case infer.lookup(env, name) {
        Ok(scheme) -> {
          let #(rendered, printer_names) = print_scheme(printer_names, scheme)
          #([#(name, rendered), ..sigs], printer_names)
        }
        Error(_) -> #(sigs, printer_names)
      }
    })
  #(list.reverse(rev), printer_names)
}

/// Render an annotated module as text (the human-facing report). On failure the
/// report is a single `// error:` line.
pub fn format(source: String) -> String {
  case annotate(source) {
    Error(error) -> "// error: " <> describe_error(error)
    Ok(annotated) -> {
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
  }
}

/// A short human description of an inference error.
pub fn describe_error(error: Error) -> String {
  case error {
    infer.TypeMismatch(a, b) ->
      "type mismatch: "
      <> printer.to_string(a)
      <> " vs "
      <> printer.to_string(b)
    infer.ArityMismatch -> "wrong number of arguments"
    infer.RecursiveType(_, type_) ->
      "recursive type: " <> printer.to_string(type_)
    infer.UnboundVariable(name) -> "unbound variable: " <> name
    infer.UnknownConstructor(name) -> "unknown constructor: " <> name
    infer.UnknownModule(alias) -> "unknown module: " <> alias
    infer.NoSuchExport(module, name) ->
      "module `" <> module <> "` has no `" <> name <> "`"
    infer.NoSuchField(type_name, label) ->
      "type `" <> type_name <> "` has no field `" <> label <> "`"
    infer.NotARecord -> "field access or update on a non-record value"
    infer.NotATuple -> "tuple index on a non-tuple value"
    infer.TupleIndexOutOfRange(index) ->
      "tuple index out of range: " <> int.to_string(index)
    infer.UnknownLabel(label) -> "unknown argument label: " <> label
    infer.AmbiguousCall -> "labelled arguments to an unknown callable"
    infer.MissingArgument -> "missing argument"
    infer.Unsupported(feature) -> "unsupported: " <> feature
    infer.ParseFailed(_) -> "could not parse source"
  }
}

fn parse(source: String) -> Result(glance.Module, Error) {
  glance.module(source) |> result.map_error(infer.ParseFailed)
}

fn print_scheme(
  names: printer.Names,
  scheme: Scheme,
) -> #(String, printer.Names) {
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

// --- CLI -------------------------------------------------------------------

/// `gleam run -- <file.gleam>` annotates a file; `gleam run -- -` (or no
/// arguments, or piped input) annotates stdin. Imports are resolved from disk.
pub fn main() -> Nil {
  case argv.load().arguments {
    ["--help"] | ["-h"] -> io.println(usage())
    [] | ["-"] -> emit(read_stdin())
    [path] -> emit(read_file(path))
    _ -> {
      io.println_error("error: expected a single file path, `-`, or no input")
      io.println_error(usage())
    }
  }
}

fn emit(source: Result(String, String)) -> Nil {
  case source {
    Ok(text) -> io.println(format(text))
    Error(message) -> io.println_error("error: " <> message)
  }
}

fn read_file(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.replace_error("could not read file: " <> path)
}

fn read_stdin() -> Result(String, String) {
  simplifile.read("/dev/stdin")
  |> result.replace_error("could not read stdin")
}

fn usage() -> String {
  "girard — a type annotator for Gleam

Usage:
  gleam run -- <file.gleam>     annotate a file
  gleam run -- -                annotate stdin
  cat file.gleam | gleam run    annotate stdin

Output: each top-level definition's inferred signature, then one
`<start>-<end>: <type>` line per expression (by source byte span)."
}
