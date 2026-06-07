//// A type annotator for Gleam, written in Gleam.
////
//// Reports the inferred type of every expression — keyed by its source span —
//// and the signature of every top-level function and constant, for a single
//// module ([`annotate`](#annotate)) or a whole package
//// ([`annotate_package`](#annotate_package)). Give it source text or a
//// `glance` AST you parsed yourself.
////
//// Imported modules are resolved through a [`Resolver`](#Resolver) to obtain
//// their public interfaces.

import argv
import girard/internal/infer.{type ModuleInterface}
import girard/internal/prelude
import girard/internal/printer
import girard/internal/reference
import girard/internal/scc
import girard/types.{type Error as TypeError, type Scheme, type Type, Scheme}
import glance
import gleam/bool
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

/// Why a module could not be typed (re-exported from `girard/types`).
pub type Error =
  TypeError

/// The inferred type of a single expression, identified by its source span.
/// `type_` is a structured `Type` you can pattern-match on; render it with
/// [`type_to_string`](#type_to_string).
pub type Annotation {
  Annotation(span: glance.Span, type_: Type)
}

/// Everything girard inferred for one module: each top-level definition's
/// signature, plus the type of every expression in their bodies.
///
/// `functions` and `constants` have one entry per top-level definition — its
/// generalized `Scheme` (a `type_` plus the ids of its quantified `Var`s).
/// `expressions` is finer-grained: the `Type` of *every* expression — literals,
/// calls, operators, sub-expressions — keyed by its `glance` source span, so
/// you can join inferred types onto your own AST. Render any type with
/// [`type_to_string`](#type_to_string).
pub type AnnotatedModule {
  AnnotatedModule(
    /// Top-level function name to inferred signature scheme, in source order.
    functions: List(#(String, Scheme)),
    /// Top-level constant name to inferred scheme, in source order.
    constants: List(#(String, Scheme)),
    /// Expression span to inferred type, sorted by start offset.
    expressions: List(Annotation),
  )
}

/// Resolves an imported module path (e.g. `"gleam/list"`) to its source.
pub type Resolver =
  fn(String) -> Result(String, Nil)

/// The build target a module is compiled for. The target is a whole-build
/// setting in Gleam, so it applies to every module in one annotation run.
/// Definitions and imports annotated `@target(...)` are kept only when they
/// match the active target. `default_options()` selects `Erlang` (matching
/// `gleam build`'s default); use `with_target` for JavaScript.
pub type Target {
  Erlang
  JavaScript
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

/// `#(value references, field-access qualifier names)` of a definition.
fn def_refs(def: Def) -> #(List(String), List(String)) {
  case def {
    FunctionDef(f) -> reference.in_function(f)
    ConstantDef(c) -> reference.in_constant(c)
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

/// How a module is annotated: which [`Resolver`](#Resolver) finds imported
/// modules, and which build [`Target`](#Target) to type for. Build one from
/// [`default_options`](#default_options) and customize it with
/// [`with_target`](#with_target) and [`with_resolver`](#with_resolver):
///
/// ```gleam
/// default_options()
/// |> with_target(JavaScript)
/// ```
pub opaque type Options {
  Options(resolver: Resolver, target: Target)
}

/// Default options: resolve imports from disk (`disk_resolver()`) and type for
/// the `Erlang` target (matching `gleam build`'s default).
pub fn default_options() -> Options {
  Options(resolver: disk_resolver(), target: Erlang)
}

/// Resolve imported modules with `resolver` — e.g. `fn(_) { Error(Nil) }` to
/// resolve none, or a custom in-memory resolver.
pub fn with_resolver(options: Options, resolver: Resolver) -> Options {
  Options(..options, resolver:)
}

/// Type for `target`. `@target(...)` definitions that do not match are dropped,
/// exactly as the compiler omits them from the build.
pub fn with_target(options: Options, target: Target) -> Options {
  Options(..options, target:)
}

/// Annotate a Gleam source string: parse it with `glance`, then annotate as
/// [`annotate_module`](#annotate_module). Returns the inferred error if the
/// module does not type. The quick path is `annotate(source, default_options())`.
pub fn annotate(
  source: String,
  options: Options,
) -> Result(AnnotatedModule, Error) {
  use module <- result.try(parse(source))
  annotate_module(module, options)
}

/// Annotate an already-parsed `glance.Module`. Use this when you have parsed the
/// source with `glance` yourself — the returned spans are glance's, so they line
/// up with your AST's node spans and you avoid parsing the same source twice.
/// (Imported modules are still parsed internally, via the resolver.) Returns the
/// inferred error if the module does not type; for partial results on an
/// ill-typed module, use [`annotate_package`](#annotate_package).
pub fn annotate_module(
  module: glance.Module,
  options: Options,
) -> Result(AnnotatedModule, Error) {
  use #(#(env, st), _interface, _cache, _skipped) <- result.try(infer_module(
    options,
    set.new(),
    dict.new(),
    "",
    module,
    best_effort: False,
  ))
  Ok(render(module, env, st))
}

/// A reusable cache of inferred module interfaces, threaded across
/// [`annotate_with_cache`](#annotate_with_cache) calls. Annotating a module
/// infers every module it imports — transitively — to obtain their interfaces;
/// without a shared cache each call repeats that work, so a tool re-checking a
/// module or walking a package re-infers the same dependencies again and again.
/// Carrying a `Cache` between calls infers each imported module once and reuses
/// it thereafter.
///
/// A cache keys interfaces by module path and assumes a fixed
/// [`Resolver`](#Resolver) and [`Target`](#Target): do not reuse one across
/// different resolvers or targets, or it would hand back interfaces built from
/// the wrong sources. Create one with [`new_cache`](#new_cache); when a module's
/// source changes, drop it with [`invalidate`](#invalidate).
pub opaque type Cache {
  Cache(interfaces: InterfaceCache)
}

/// An empty [`Cache`](#Cache) to seed a run of
/// [`annotate_with_cache`](#annotate_with_cache) calls.
pub fn new_cache() -> Cache {
  Cache(dict.new())
}

/// Annotate a source string like [`annotate`](#annotate), but reuse and extend
/// `cache`: imported modules already inferred in it are taken from the cache
/// rather than resolved and inferred again, and any newly inferred ones are
/// added. Returns the result and the updated cache to thread into the next call.
///
/// `annotate_with_cache(source, options, new_cache())` matches
/// [`annotate`](#annotate)`(source, options)` exactly; the cache only pays off
/// when shared across calls that import overlapping modules — an editor
/// re-checking a file as it changes, or a walk over a package's modules.
pub fn annotate_with_cache(
  source: String,
  options: Options,
  cache: Cache,
) -> #(Result(AnnotatedModule, Error), Cache) {
  case parse(source) {
    Error(error) -> #(Error(error), cache)
    Ok(module) ->
      case
        infer_module(
          options,
          set.new(),
          cache.interfaces,
          "",
          module,
          best_effort: False,
        )
      {
        Error(error) -> #(Error(error), cache)
        Ok(#(#(env, st), _interface, interfaces, _skipped)) -> #(
          Ok(render(module, env, st)),
          Cache(interfaces),
        )
      }
  }
}

/// Drop the cached interface for `path` (the module path, e.g.
/// `"my_app/router"`), so the next [`annotate_with_cache`](#annotate_with_cache)
/// that needs it re-infers it from source. Use this when a module changes.
///
/// Only the named module is dropped. A cached module that *imports* the changed
/// one keeps its own (now possibly stale) interface, so after a change that
/// alters a module's public surface, also invalidate its importers — or start
/// from a [`new_cache`](#new_cache).
pub fn invalidate(cache: Cache, path: String) -> Cache {
  Cache(dict.delete(cache.interfaces, path))
}

/// The result of annotating one module of a package: its
/// [`AnnotatedModule`](#AnnotatedModule) plus the definitions that could not be
/// typed. `skipped` names each top-level function or constant girard declined,
/// with the error that declined it; a definition in `skipped` is absent from
/// `annotated`.
pub type ModuleResult {
  ModuleResult(annotated: AnnotatedModule, skipped: List(#(String, Error)))
}

/// Annotate every module in a package in one pass, sharing inference of common
/// imports across modules. `modules` maps each module's path (e.g.
/// `"my_app/router"`) to its parsed `glance.Module`; the result maps the same
/// paths to a [`ModuleResult`](#ModuleResult).
///
/// This is the batch counterpart to [`annotate_module`](#annotate_module): a
/// dependency imported by several modules is inferred once for the whole run
/// rather than once per
/// importing module. Cross-module references *within* the package are resolved
/// through the options' resolver, so it must also resolve the package's own
/// modules (a resolver wrapping the build's module sources does); a module
/// reached only that way is inferred for its interface and again here for its
/// annotations.
///
/// Best-effort per definition: a top-level function or constant that does not
/// type — along with any that depend on it — is reported in that module's
/// `skipped` list rather than failing the module, while every other definition
/// is still annotated. A module thus always appears in the result; a fully
/// strict check is `result.skipped == []`.
pub fn annotate_package(
  modules: List(#(String, glance.Module)),
  options: Options,
) -> dict.Dict(String, ModuleResult) {
  let #(results, _cache) =
    list.fold(modules, #(dict.new(), dict.new()), fn(acc, entry) {
      let #(results, cache) = acc
      let #(path, module) = entry
      case
        infer_module(options, set.new(), cache, path, module, best_effort: True)
      {
        // Best-effort inference does not fail; on the impossible error, omit the
        // module rather than crash.
        Error(_) -> #(results, cache)
        Ok(#(#(env, st), interface, cache, skipped)) -> {
          // Seed this module's own interface so a later module that imports it
          // hits the cache instead of re-resolving it through the resolver.
          let cache = dict.insert(cache, path, interface)
          let result = ModuleResult(render(module, env, st), skipped)
          #(dict.insert(results, path, result), cache)
        }
      }
    })
  results
}

/// Interfaces resolved so far in this run, keyed by module path. Resolving a
/// module is expensive (it infers the whole module), and a deep import graph
/// imports the same dependency many times; memoizing keeps each module inferred
/// once rather than re-inferring it exponentially.
type InterfaceCache =
  dict.Dict(String, ModuleInterface)

// --- Module inference ------------------------------------------------------

/// Fully infer a module: resolve imports, register types, and infer every
/// definition in dependency order. Returns the final environment and state
/// plus the module's public interface.
fn infer_module(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  module_name: String,
  module: glance.Module,
  best_effort best_effort: Bool,
) -> Result(
  #(
    #(infer.Env, infer.State),
    ModuleInterface,
    InterfaceCache,
    List(#(String, Error)),
  ),
  Error,
) {
  // Drop definitions and imports compiled only for another target — a
  // `@target(javascript)` sibling (e.g. simplifile's JS `do_file_info`
  // returning a different error type) must not shadow the matching one when
  // typing for Erlang, and vice versa.
  let module = for_target(module, options.target)
  let #(prelude_env, st) = infer.prelude()
  let env = infer.set_module(prelude_env, module_name)

  // 1. Imports.
  use #(env, cache) <- result.try(process_imports(
    options,
    loading,
    cache,
    env,
    module.imports,
    best_effort:,
  ))

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
      let function = d.definition
      infer.register_field_map(
        env,
        function.name,
        list.map(function.parameters, fn(p) { p.label }),
      )
    })

  // 3. Infer definitions in strongly-connected-component order.
  let functions =
    list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants =
    list.map(module.constants, fn(d) { ConstantDef(d.definition) })
  let defs = list.append(functions, constants)
  // Names in scope as imported modules. A field access `name.member` whose
  // `name` is one of these is qualified module access, not a dependency on a
  // same-named local definition.
  let module_aliases =
    set.from_list(
      list.filter_map(module.imports, fn(d) { qualified_alias(d.definition) }),
    )
  use #(#(final_env, st), skipped) <- result.try(infer_defs(
    env,
    st,
    module_aliases,
    defs,
    best_effort:,
  ))

  let interface =
    infer.build_interface(
      final_env,
      st,
      module_name,
      public_value_names(module),
      public_type_names(module),
      public_accessor_type_names(module),
    )
  Ok(#(#(final_env, st), interface, cache, skipped))
}

fn infer_defs(
  env: infer.Env,
  st: infer.State,
  module_aliases: Set(String),
  defs: List(Def),
  best_effort best_effort: Bool,
) -> Result(#(#(infer.Env, infer.State), List(#(String, Error))), Error) {
  let by_name = dict.from_list(list.map(defs, fn(d) { #(def_name(d), d) }))
  let names = list.map(defs, def_name)
  let name_set = set.from_list(names)
  let edges =
    dict.from_list(
      list.map(defs, fn(d) {
        let #(values, qualifiers) = def_refs(d)
        // A qualifier edge survives only for a local definition that is not a
        // shadowed module name; value references always count.
        let kept_qualifiers =
          list.filter(qualifiers, fn(name) {
            !set.contains(module_aliases, name)
          })
        let refs =
          list.filter(list.append(values, kept_qualifiers), set.contains(
            name_set,
            _,
          ))
        #(def_name(d), refs)
      }),
    )
  // Each component is a group of mutually recursive definitions, in dependency
  // order. Resolve the names back to definitions up front.
  let groups =
    list.map(scc.components(names, edges), fn(group) {
      list.filter_map(group, dict.get(by_name, _))
    })

  // Strict mode stops at the first component that fails to type, returning its
  // error. Best-effort mode keeps the pre-component environment on a failure —
  // discarding that component's partial annotations and substitution — records
  // every definition in it as skipped (with the error), and carries on; a later
  // component referring to a skipped one fails in turn (an unbound variable) and
  // cascades naturally.
  case best_effort {
    False -> {
      use #(env, st) <- result.map(
        list.try_fold(groups, #(env, st), fn(acc, group) {
          let #(env, st) = acc
          infer_group(env, st, group)
        }),
      )
      #(#(env, st), [])
    }
    True -> Ok(list.fold(groups, #(#(env, st), []), best_effort_group))
  }
}

/// One best-effort step over a strongly-connected component: on success adopt
/// the new environment; on failure keep the prior one (discarding the
/// component's partial work) and record every definition in it as skipped.
fn best_effort_group(
  acc: #(#(infer.Env, infer.State), List(#(String, Error))),
  group: List(Def),
) -> #(#(infer.Env, infer.State), List(#(String, Error))) {
  let #(#(env, st), skipped) = acc
  case infer_group(env, st, group) {
    Ok(env_st) -> #(env_st, skipped)
    Error(error) -> {
      let entries = list.map(group, fn(d) { #(def_name(d), error) })
      #(#(env, st), list.append(skipped, entries))
    }
  }
}

/// Infer one strongly-connected component of mutually recursive definitions,
/// then generalize each against the surrounding environment and add it back for
/// later components.
///
/// A function with signature variables is pre-registered at a scheme over those
/// variables so recursion and siblings see it polymorphically; its body is
/// checked against the signature with those variables rigid, and within its own
/// body it sees itself at the rigid monotype (no polymorphic recursion). Every
/// other definition is inferred monomorphically against a fresh placeholder.
/// The members are marked *live* (see `infer.mark_live`): a reference to a
/// sibling resolves its scheme through the current substitution, so once a
/// member's body has settled an unannotated part (absorbing it into a signature
/// variable) a later sibling sees the resolved type — the compiler's shared
/// mutable cells, reproduced through girard's threaded substitution. Because of
/// that, bodies are inferred *provider-first*: a member whose signature has an
/// unannotated part is typed before the fully-annotated members that consume it
/// (a dependency-respecting order within the component, as Tarjan provides).
fn infer_group(
  env: infer.Env,
  st: infer.State,
  group: List(Def),
) -> Result(#(infer.Env, infer.State), Error) {
  let #(group_env, rev_items, st) =
    list.fold(group, #(env, [], st), fn(acc, def) {
      let #(env, items, st) = acc
      prereg_def(env, items, st, def)
    })
  let group_env = infer.mark_live(group_env, list.map(group, def_name))
  let items = list.reverse(rev_items)
  // Type members with an unannotated parameter or return first: their bodies
  // settle those placeholders, which a later sibling reference then resolves.
  let #(providers, consumers) =
    list.partition(items, fn(item) {
      case item {
        AnnotatedDef(_, f, _, _) ->
          f.return == option.None
          || list.any(f.parameters, fn(p) { p.type_ == option.None })
        PlaceholderDef(..) -> False
      }
    })
  use st <- result.try(
    list.try_fold(list.append(providers, consumers), st, fn(st, item) {
      case item {
        AnnotatedDef(def, f, params, return_type) -> {
          // Inside its own body the function sees itself at the rigid
          // (un-generalized) signature, so a self-recursive call must be at
          // the same type — no polymorphic recursion. Bind the self-name
          // first, then the parameters on top, so a parameter that shares the
          // function's name shadows it (as in the source).
          let body_env =
            infer.bind_params(
              infer.define(
                group_env,
                def_name(def),
                infer.rigid_self_scheme(params, return_type),
              ),
              f,
              params,
            )
          infer.check_body(body_env, st, f, return_type)
        }
        PlaceholderDef(def, var) -> {
          use #(inferred, st) <- result.try(infer_def(group_env, st, def))
          infer.unify(st, var, inferred)
        }
      }
    }),
  )
  // The component's bodies are fully inferred, so any field accesses deferred
  // because their record type was unknown can now be resolved — before we
  // generalize, so the field types are reflected in the schemes.
  use st <- result.try(infer.resolve_pending(group_env, st))
  let env =
    list.fold(items, env, fn(env, item) {
      case item {
        AnnotatedDef(def, _, params, return_type) ->
          infer.define(
            env,
            def_name(def),
            infer.function_scheme(env, st, params, return_type),
          )
        PlaceholderDef(def, var) ->
          infer.define(env, def_name(def), infer.generalize(st, env, var))
      }
    })
  Ok(#(env, st))
}

/// A member of a strongly-connected component during inference.
type GroupItem {
  /// A fully-annotated function: bound at its declared scheme up front; its body
  /// is checked against the signature (rigid variables).
  AnnotatedDef(
    def: Def,
    function: glance.Function,
    params: List(Type),
    return_type: Type,
  )
  /// Any other definition: inferred monomorphically against `var`, then
  /// generalized.
  PlaceholderDef(def: Def, var: Type)
}

fn placeholder(
  env: infer.Env,
  items: List(GroupItem),
  st: infer.State,
  def: Def,
) -> #(infer.Env, List(GroupItem), infer.State) {
  let #(var, st) = infer.fresh_var(st)
  #(
    infer.define(env, def_name(def), Scheme([], var)),
    [PlaceholderDef(def, var), ..items],
    st,
  )
}

/// Pre-register one SCC member: a function with signature variables is bound at
/// its declared scheme (`AnnotatedDef`); any other definition gets a fresh
/// monomorphic placeholder.
fn prereg_def(
  env: infer.Env,
  items: List(GroupItem),
  st: infer.State,
  def: Def,
) -> #(infer.Env, List(GroupItem), infer.State) {
  let annotated = case def {
    FunctionDef(f) ->
      case infer.has_annotation_vars(f) {
        True -> Ok(f)
        False -> Error(Nil)
      }
    ConstantDef(_) -> Error(Nil)
  }
  case annotated {
    Error(_) -> placeholder(env, items, st, def)
    Ok(f) -> {
      let #(params, return_type, rigid_ids, st) =
        infer.signature_skeleton(env, st, f)
      #(
        infer.define(
          env,
          def_name(def),
          infer.rigid_scheme(rigid_ids, params, return_type),
        ),
        [AnnotatedDef(def, f, params, return_type), ..items],
        st,
      )
    }
  }
}

// --- Imports ---------------------------------------------------------------

fn process_imports(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  env: infer.Env,
  imports: List(glance.Definition(glance.Import)),
  best_effort best_effort: Bool,
) -> Result(#(infer.Env, InterfaceCache), Error) {
  list.try_fold(imports, #(env, cache), fn(acc, definition) {
    let #(env, cache) = acc
    let import_ = definition.definition
    let path = import_.module
    // Cyclic import: break the cycle by skipping.
    use <- bool.guard(
      when: set.contains(loading, path),
      return: Ok(#(env, cache)),
    )
    use #(maybe_interface, cache) <- result.try(resolve_interface(
      options,
      loading,
      cache,
      path,
      best_effort:,
    ))
    case maybe_interface {
      // Unresolvable or unparsable: best effort, skip (uses of it surface later
      // as unbound variables).
      None -> Ok(#(env, cache))
      Some(interface) -> Ok(#(import_items(env, import_, interface), cache))
    }
  })
}

/// Bring an import's qualified alias and unqualified values/types into scope.
fn import_items(
  env: infer.Env,
  import_: glance.Import,
  interface: ModuleInterface,
) -> infer.Env {
  // A discarded alias (`import x as _y`) imports the module for its unqualified
  // items only — it must NOT be bound under any qualified name, or we'd bind it
  // under the module's last segment and shadow a real import sharing that name
  // (mist's `gleam/http as _ghttp` vs `mist/internal/http`).
  let env = case qualified_alias(import_) {
    Ok(alias) -> infer.import_qualified(env, alias, interface)
    Error(_) -> env
  }
  let env =
    list.fold(import_.unqualified_values, env, fn(env, u) {
      infer.import_value(env, option.unwrap(u.alias, u.name), interface, u.name)
    })
  list.fold(import_.unqualified_types, env, fn(env, u) {
    infer.import_type(env, option.unwrap(u.alias, u.name), interface, u.name)
  })
}

fn resolve_interface(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  path: String,
  best_effort best_effort: Bool,
) -> Result(#(Option(ModuleInterface), InterfaceCache), Error) {
  // `import gleam` refers to the built-in prelude module, which has no source
  // file; resolve it to a synthetic interface of the prelude's types/values.
  use <- bool.lazy_guard(when: path == prelude.prelude_module, return: fn() {
    Ok(#(Some(infer.prelude_interface()), cache))
  })
  case dict.get(cache, path) {
    // Already inferred in this run: reuse it rather than inferring again.
    Ok(interface) -> Ok(#(Some(interface), cache))
    Error(_) -> resolve_uncached(options, loading, cache, path, best_effort:)
  }
}

fn resolve_uncached(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  path: String,
  best_effort best_effort: Bool,
) -> Result(#(Option(ModuleInterface), InterfaceCache), Error) {
  case options.resolver(path) {
    Error(_) -> Ok(#(None, cache))
    Ok(source) ->
      case glance.module(source) {
        Error(_) -> Ok(#(None, cache))
        Ok(module) -> {
          // An import's own skipped definitions (best-effort) are irrelevant to
          // the importer; only its public interface, partial or not, matters.
          use #(_, interface, cache, _skipped) <- result.try(infer_module(
            options,
            set.insert(loading, path),
            cache,
            path,
            module,
            best_effort:,
          ))
          Ok(#(Some(interface), dict.insert(cache, path, interface)))
        }
      }
  }
}

/// The name under which an import is accessible for qualified access, or
/// `Error` when the module is imported with a discarded alias (`as _x`) and so
/// has no qualified name at all.
fn qualified_alias(import_: glance.Import) -> Result(String, Nil) {
  case import_.alias {
    Some(glance.Named(alias)) -> Ok(alias)
    Some(glance.Discarded(_)) -> Error(Nil)
    None -> Ok(last_segment(import_.module))
  }
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(segment) -> segment
    Error(_) -> path
  }
}

/// Keep only the definitions and imports compiled for `target`: those with no
/// `@target` attribute, or one naming the active target. A definition annotated
/// for the other target is dropped, exactly as the compiler omits it.
fn for_target(module: glance.Module, target: Target) -> glance.Module {
  glance.Module(
    imports: list.filter(module.imports, on_target(_, target)),
    custom_types: list.filter(module.custom_types, on_target(_, target)),
    type_aliases: list.filter(module.type_aliases, on_target(_, target)),
    constants: list.filter(module.constants, on_target(_, target)),
    functions: list.filter(module.functions, on_target(_, target)),
  )
}

fn on_target(definition: glance.Definition(a), target: Target) -> Bool {
  let active = case target {
    Erlang -> "erlang"
    JavaScript -> "javascript"
  }
  list.all(definition.attributes, fn(attr) {
    case attr.name, attr.arguments {
      "target", [glance.Variable(_, t)] -> t == active
      _, _ -> True
    }
  })
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

/// Public types whose field accessors are reachable from other modules: public,
/// non-opaque custom types. An `opaque` type's fields are private to its
/// defining module, so its accessors are not exported — a same-named module
/// function then wins over the (inaccessible) field at an external call site, as
/// the compiler does (kata's opaque `Schema` with a `decode` field and a
/// `decode` function).
fn public_accessor_type_names(module: glance.Module) -> List(String) {
  list.filter_map(module.custom_types, fn(d) {
    case d.definition.publicity, d.definition.opaque_ {
      glance.Public, False -> Ok(d.definition.name)
      _, _ -> Error(Nil)
    }
  })
}

// --- Default disk resolver -------------------------------------------------

/// The default resolver: looks for an imported module's source under `src/` and
/// the `build/packages/*/src` dependency sources, relative to the current
/// working directory. The `build/packages` listing is read once and captured,
/// so resolving many imports does not re-scan the directory each time.
pub fn disk_resolver() -> Resolver {
  let packages = case simplifile.read_directory("build/packages") {
    Ok(packages) -> packages
    Error(_) -> []
  }
  fn(path: String) -> Result(String, Nil) {
    let candidates =
      list.map(packages, fn(pkg) {
        "build/packages/" <> pkg <> "/src/" <> path <> ".gleam"
      })
    first_readable(["src/" <> path <> ".gleam", ..candidates])
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
) -> AnnotatedModule {
  let functions =
    list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants =
    list.map(module.constants, fn(d) { ConstantDef(d.definition) })

  // `st.annotations` is in reverse discovery order; reverse it so that when a
  // span was recorded more than once (e.g. a polymorphic reference and its
  // use-instantiated type), the later, stable sort keeps the same one the
  // string-based renderer did.
  let expressions =
    list.map(list.reverse(st.annotations), fn(entry) {
      let #(span, type_) = entry
      Annotation(span, infer.zonk(st, type_))
    })

  AnnotatedModule(
    functions: collect_schemes(functions, env),
    constants: collect_schemes(constants, env),
    expressions: sort_by_span(expressions),
  )
}

/// The inferred (generalized) scheme of each definition, in source order.
/// Definitions the environment somehow lacks are skipped.
fn collect_schemes(defs: List(Def), env: infer.Env) -> List(#(String, Scheme)) {
  list.filter_map(defs, fn(def) {
    let name = def_name(def)
    case infer.lookup(env, name) {
      Ok(scheme) -> Ok(#(name, scheme))
      Error(_) -> Error(Nil)
    }
  })
}

/// Render an inferred `Type` to Gleam syntax (e.g. `fn(Int) -> a`), naming type
/// variables `a, b, c, …`. Each call names variables independently: an `a` in
/// one rendered type is unrelated to an `a` in another.
pub fn type_to_string(type_: Type) -> String {
  printer.to_string(type_)
}

/// Annotate a source string and render the result as a human-readable text
/// report (signatures and per-expression types). On failure the report is a
/// single `// error:` line.
///
/// ## Example
///
/// ```gleam
/// report("pub fn double(x) { x + x }")
/// ```
///
/// ```text
/// double: fn(Int) -> Int
/// 19-20: Int
/// 19-24: Int
/// 23-24: Int
/// ```
pub fn report(source: String) -> String {
  case annotate(source, default_options()) {
    Error(error) -> "// error: " <> describe_error(error)
    Ok(annotated) -> {
      // Share one printer context so type-variable names are consistent across
      // every signature and expression in the report.
      let names = printer.new_names()
      let #(rev_sigs, names) =
        list.fold(
          list.append(annotated.functions, annotated.constants),
          #([], names),
          fn(acc, def) {
            let #(lines, names) = acc
            let #(text, names) = printer.print(names, { def.1 }.type_)
            #([def.0 <> ": " <> text, ..lines], names)
          },
        )
      let #(rev_exprs, _names) =
        list.fold(annotated.expressions, #([], names), fn(acc, a) {
          let #(lines, names) = acc
          let #(text, names) = printer.print(names, a.type_)
          let line =
            int.to_string(a.span.start)
            <> "-"
            <> int.to_string(a.span.end)
            <> ": "
            <> text
          #([line, ..lines], names)
        })
      string.join(
        list.append(list.reverse(rev_sigs), list.reverse(rev_exprs)),
        "\n",
      )
    }
  }
}

/// A short, human-readable description of an inference error.
pub fn describe_error(error: Error) -> String {
  case error {
    types.TypeMismatch(a, b) ->
      "type mismatch: "
      <> printer.to_string(a)
      <> " vs "
      <> printer.to_string(b)
    types.ArityMismatch -> "wrong number of arguments"
    types.RecursiveType(_, type_) ->
      "recursive type: " <> printer.to_string(type_)
    types.UnboundVariable(name) -> "unbound variable: " <> name
    types.UnknownConstructor(name) -> "unknown constructor: " <> name
    types.UnknownModule(alias) -> "unknown module: " <> alias
    types.NoSuchExport(module, name) ->
      "module `" <> module <> "` has no `" <> name <> "`"
    types.NoSuchField(type_name, label) ->
      "type `" <> type_name <> "` has no field `" <> label <> "`"
    types.NotARecord -> "field access or update on a non-record value"
    types.NotATuple -> "tuple index on a non-tuple value"
    types.TupleIndexOutOfRange(index) ->
      "tuple index out of range: " <> int.to_string(index)
    types.UnknownLabel(label) -> "unknown argument label: " <> label
    types.AmbiguousCall -> "labelled arguments to an unknown callable"
    types.MissingArgument -> "missing argument"
    types.Unsupported(feature) -> "unsupported: " <> feature
    types.ParseFailed(_) -> "could not parse source"
  }
}

fn parse(source: String) -> Result(glance.Module, Error) {
  glance.module(source) |> result.map_error(types.ParseFailed)
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

/// Why the CLI could not read its input.
type InputError {
  FileUnreadable(path: String)
  StdinUnreadable
}

fn emit(source: Result(String, InputError)) -> Nil {
  case source {
    Ok(text) -> io.println(report(text))
    Error(error) -> io.println_error("error: " <> input_error_message(error))
  }
}

fn input_error_message(error: InputError) -> String {
  case error {
    FileUnreadable(path) -> "could not read file: " <> path
    StdinUnreadable -> "could not read stdin"
  }
}

fn read_file(path: String) -> Result(String, InputError) {
  simplifile.read(path)
  |> result.replace_error(FileUnreadable(path))
}

fn read_stdin() -> Result(String, InputError) {
  simplifile.read("/dev/stdin")
  |> result.replace_error(StdinUnreadable)
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
