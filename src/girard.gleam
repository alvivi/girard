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
import girard/internal/reference
import girard/internal/scc
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

// Public types
//
// The vocabulary a consumer pattern-matches on: the structured `Type` and
// its generalized `Scheme`, the inference `Error`, the per-expression
// `Annotation` and whole-module `AnnotatedModule` results, and the
// `Resolver` and `Target` knobs that configure a run.

/// The structured type girard infers for an expression or definition. Pattern-
/// match on its variants to inspect an inferred type, or render it to Gleam
/// syntax with [`type_to_string`](#type_to_string).
pub type Type {
  /// A named, nominal type such as `Int`, `List(a)`, `Result(a, e)` or a
  /// user-defined custom type. `module` is `"gleam"` for prelude types.
  Named(module: String, name: String, arguments: List(Type))
  /// A function type `fn(a, b) -> c`.
  Fn(arguments: List(Type), return: Type)
  /// A type variable identified by `id`. During inference the substitution
  /// table may bind that id to another type; in a `Scheme`, `vars` identifies
  /// which ids are universally quantified (generic).
  Var(id: Int)
  /// A tuple type `#(a, b, c)`.
  Tuple(elements: List(Type))
}

/// A polymorphic type scheme `forall vars. type_`: the generalized type of a
/// top-level function or constant. `vars` are the ids of the `Var`s in `type_`
/// that are universally quantified (generic); a monomorphic binding is
/// `Scheme([], type_)`.
pub type Scheme {
  Scheme(vars: List(Int), type_: Type)
}

/// Why a module could not be typed. Variants describe the failure in terms of
/// the type system and the offending source construct.
pub type Error {
  TypeMismatch(left: Type, right: Type)
  ArityMismatch
  RecursiveType(id: Int, type_: Type)
  UnboundVariable(name: String)
  UnknownConstructor(name: String)
  UnknownModule(alias: String)
  NoSuchExport(module: String, name: String)
  NoSuchField(type_name: String, label: String)
  NotARecord
  NotATuple
  TupleIndexOutOfRange(index: Int)
  UnknownLabel(label: String)
  AmbiguousCall
  MissingArgument
  Unsupported(feature: String)
  ParseFailed(glance.Error)
}

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

// Options
//
// How a module is annotated — the resolver that finds imported modules and
// the build target to type for. Build one with `default_options` and adjust
// it with the `with_*` helpers.

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

// Default resolver
//
// The resolver `default_options` uses: read an imported module's source from
// `src/` or the installed packages under `build/packages`.

/// The default resolver: looks for an imported module's source under `src/`
/// first, then the `build/packages/*/src` dependency sources, relative to the
/// current working directory. Constructing the resolver touches no filesystem;
/// the `build/packages` listing and every source read happen lazily, when the
/// resolver is invoked. A missing `build/packages` or an unreadable source is
/// not an error here — the import is simply not found, surfaced as `Error(Nil)`
/// at resolution time.
pub fn disk_resolver() -> Resolver {
  fn(path: String) -> Result(String, Nil) {
    // Prefer the project's own sources; only scan the installed packages when
    // the module is not found under `src/`, so in-project imports never pay for
    // the directory listing.
    case simplifile.read("src/" <> path <> ".gleam") {
      Ok(source) -> Ok(source)
      Error(_) -> {
        let packages =
          result.unwrap(simplifile.read_directory("build/packages"), [])
        first_readable(
          list.map(packages, fn(pkg) {
            "build/packages/" <> pkg <> "/src/" <> path <> ".gleam"
          }),
        )
      }
    }
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

// Annotating a module
//
// The primary entry points. Annotate source text or a pre-parsed `glance`
// module, inferring every expression and top-level signature, or return the
// first inference error.

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

fn parse(source: String) -> Result(glance.Module, Error) {
  glance.module(source) |> result.map_error(ParseFailed)
}

// Caching
//
// A reusable cache of inferred module interfaces, threaded across annotation
// calls so a shared import is resolved and inferred once rather than
// repeatedly — an editor re-checking a file, or a walk over a package.

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
/// `annotate(source, options)` exactly; the cache only pays off
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

// Annotating a package
//
// Annotate every module of a package in one pass, sharing inference of common
// imports. Best-effort per definition: one ill-typed definition (and its
// dependants) is reported as skipped while the rest are still annotated.

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
/// is still annotated. Definition failures therefore leave the module present
/// in the result; a fully strict check is `result.skipped == []`.
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
        // Best-effort mode converts definition failures to skipped entries, so
        // `infer_module` should not fail. If that invariant is broken, omit the
        // module rather than crashing the whole package run.
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

// Reporting
//
// Human-readable rendering of inferred types and errors: a single `Type` to
// Gleam syntax, a whole module to a text report, or an `Error` to a short
// description.

/// A short, human-readable description of an inference error.
pub fn describe_error(error: Error) -> String {
  case error {
    TypeMismatch(a, b) ->
      "type mismatch: " <> to_string(a) <> " vs " <> to_string(b)
    ArityMismatch -> "wrong number of arguments"
    RecursiveType(_, type_) -> "recursive type: " <> to_string(type_)
    UnboundVariable(name) -> "unbound variable: " <> name
    UnknownConstructor(name) -> "unknown constructor: " <> name
    UnknownModule(alias) -> "unknown module: " <> alias
    NoSuchExport(module, name) ->
      "module `" <> module <> "` has no `" <> name <> "`"
    NoSuchField(type_name, label) ->
      "type `" <> type_name <> "` has no field `" <> label <> "`"
    NotARecord -> "field access or update on a non-record value"
    NotATuple -> "tuple index on a non-tuple value"
    TupleIndexOutOfRange(index) ->
      "tuple index out of range: " <> int.to_string(index)
    UnknownLabel(label) -> "unknown argument label: " <> label
    AmbiguousCall -> "labelled arguments to an unknown callable"
    MissingArgument -> "missing argument"
    Unsupported(feature) -> "unsupported: " <> feature
    ParseFailed(_) -> "could not parse source"
  }
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
      let names = new_names()
      let #(rev_sigs, names) =
        list.fold(
          list.append(annotated.functions, annotated.constants),
          #([], names),
          fn(acc, def) {
            let #(lines, names) = acc
            let #(text, names) = print(names, { def.1 }.type_)
            #([def.0 <> ": " <> text, ..lines], names)
          },
        )
      let #(rev_exprs, _names) =
        list.fold(annotated.expressions, #([], names), fn(acc, a) {
          let #(lines, names) = acc
          let #(text, names) = print(names, a.type_)
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

/// Render an inferred `Type` to Gleam syntax (e.g. `fn(Int) -> a`), naming type
/// variables `a, b, c, …`. Each call names variables independently: an `a` in
/// one rendered type is unrelated to an `a` in another.
pub fn type_to_string(type_: Type) -> String {
  to_string(type_)
}

// Command-line interface
//
// `gleam run` annotates a file or stdin and prints the text report.

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

// Why the CLI could not read its input.
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

// Inference state and environment
//
// The threaded inference `State` and lexical `Env`, plus the prelude seeding
// that starts every run. `State` carries the substitution, recorded
// annotations, deferred accesses and rigid variables; `Env` carries the
// value, type, alias, accessor and module bindings in scope.
//
// `ModuleInterface` is the public surface of an inferred module, consumed
// when importing it elsewhere.

type State {
  State(
    next_id: Int,
    // Bound type variables. Absence means unbound.
    subst: Dict(Int, Type),
    // Inferred type recorded for each annotated source span, in reverse order
    // of discovery. Types are stored "live" and zonked at the end.
    annotations: List(#(glance.Span, Type)),
    // Field accesses and tuple indexes whose container type was not yet known
    // when encountered; resolved by `resolve_pending` once inference has fixed
    // the container type (deferred resolution, like the real compiler).
    pending: List(Pending),
    // Variable ids that are *rigid*: a type variable written in a function's
    // signature annotation, skolemized for that function's body. A rigid var
    // unifies only with itself or a flexible var (which binds to it), never
    // with a concrete type or a different rigid — matching the compiler, which
    // keeps annotated type variables generic and rejects pinning them.
    rigid: Set(Int),
  )
}

// A deferred access awaiting its container's type.
type Pending {
  // `record.label` — the field type goes in `result`.
  PendingField(container: Type, label: String, result: Type)
  // `tuple.index` — the element type goes in `result`.
  PendingIndex(container: Type, index: Int, result: Type)
}

type Env {
  Env(
    // Value bindings in scope: locals, parameters, top-level functions and
    // custom-type constructors.
    values: Dict(String, Scheme),
    // The subset of `values` that can contribute free type variables to the
    // environment — bindings whose scheme has a type variable not bound by its
    // own quantifier (live monomorphic bindings: locals, parameters, SCC
    // members mid-inference). Fully-generalized and imported schemes quantify
    // every variable in their type, so they contribute nothing regardless of
    // the substitution and are omitted. `env_free_vars` scans only these, which
    // are few, instead of every binding in scope (mostly closed imports).
    // Maintained alongside `values` in `bind_value`, its sole writer.
    open_values: Dict(String, Scheme),
    // Locally-defined type aliases: name -> (parameter names, aliased type
    // AST), expanded during hydration in this module's environment.
    aliases: Dict(String, #(List(String), glance.Type)),
    // Type aliases brought in by unqualified imports, already resolved to a
    // type with the alias's parameters as variables (param ids + body), so
    // they need no re-hydration in this module's environment.
    imported_aliases: Dict(String, #(List(Int), Type)),
    // Record field accessors: type name -> label -> a scheme for
    // `fn(record) -> field`, generalized over the type's parameters.
    accessors: Dict(String, Dict(String, Scheme)),
    // In-scope type names -> (origin module, origin name, arity). Covers types
    // defined in the current module and types brought in by unqualified
    // imports. Used during hydration to resolve a bare type name to its module
    // and to the name it has *there* — an `import x.{type T as U}` is in scope
    // as `U` but must hydrate to `x`'s `T`, not a phantom `x.U`.
    local_types: Dict(String, #(String, String, Int)),
    // Field maps for callables (functions and constructors): name -> the
    // label of each positional parameter (`None` where unlabelled). Used to
    // reorder labelled and shorthand arguments at call/pattern sites.
    field_maps: Dict(String, List(Option(String))),
    // Variables that a pattern has narrowed to a specific constructor variant
    // (e.g. `Element(..) as e`), mapping the variable to that variant and its
    // `label -> field type` for the bound value. This lets `e.field` reach a
    // field present in only some variants, mirroring the compiler's inferred
    // variant narrowing. Field types are tied to the variable's own type.
    variants: Dict(String, Narrowed),
    // The name of the module currently being inferred. Local types are minted
    // with this module so they stay distinct from imported types.
    current_module: String,
    // Imported modules available for qualified access, keyed by the alias used
    // in source (e.g. `list` for `import gleam/list`).
    modules: Dict(String, ModuleInterface),
    // Every interface reachable from `modules` (directly imported modules and,
    // transitively, the modules they expose), keyed by its real module name
    // (`interface.name`, the full path — unique per run, unlike an alias). A
    // flat index of the same graph `modules` spans, maintained alongside it in
    // `import_qualified`, so resolving a type's accessors by origin module
    // (`accessors_of_module`) is one `dict.get` rather than a transitive walk
    // of the whole interface graph on every field access.
    module_index: Dict(String, ModuleInterface),
    // Names of the strongly-connected-component members currently being
    // inferred. A reference to one of these resolves its bound scheme through
    // the current substitution before instantiating, so a type the provider's
    // already-inferred body has settled (an unannotated parameter absorbed into
    // a signature variable, say) is seen by a later sibling — the compiler's
    // shared mutable type cells, in girard's threaded substitution. Empty
    // outside an SCC, so finished schemes instantiate verbatim.
    live: Set(String),
  )
}

// The public surface of a module, used when importing it elsewhere.
type ModuleInterface {
  ModuleInterface(
    name: String,
    values: Dict(String, Scheme),
    types: Dict(String, #(String, String, Int)),
    // Public type aliases, resolved to a type with the alias's parameters as
    // variables (param ids + body).
    aliases: Dict(String, #(List(Int), Type)),
    accessors: Dict(String, Dict(String, Scheme)),
    field_maps: Dict(String, List(Option(String))),
    // The modules this one imports, so a type it exposes from another module
    // (e.g. a `glance.Span` field) keeps its accessors reachable transitively.
    modules: Dict(String, ModuleInterface),
  )
}

fn new_state() -> State {
  State(
    next_id: 0,
    subst: dict.new(),
    annotations: [],
    pending: [],
    rigid: set.new(),
  )
}

fn mark_rigid(st: State, ids: List(Int)) -> State {
  State(..st, rigid: list.fold(ids, st.rigid, set.insert))
}

fn is_rigid(st: State, id: Int) -> Bool {
  set.contains(st.rigid, id)
}

fn new_env() -> Env {
  Env(
    values: dict.new(),
    open_values: dict.new(),
    aliases: dict.new(),
    imported_aliases: dict.new(),
    accessors: dict.new(),
    local_types: dict.new(),
    field_maps: dict.new(),
    variants: dict.new(),
    current_module: "",
    modules: dict.new(),
    module_index: dict.new(),
    live: set.new(),
  )
}

// Set the name of the module currently being inferred.
fn set_module(env: Env, name: String) -> Env {
  Env(..env, current_module: name)
}

// Register the field map (per-position labels) of a callable.
fn register_field_map(
  env: Env,
  name: String,
  labels: List(Option(String)),
) -> Env {
  // Only worth recording if at least one position is labelled.
  use <- bool.guard(when: !list.any(labels, fn(l) { l != None }), return: env)
  Env(..env, field_maps: dict.insert(env.field_maps, name, labels))
}

// Declare a local type name (and arity) so references to it during hydration
// resolve to the current module. Call this for every custom type before
// registering any of them, so forward references resolve correctly.
fn declare_type(env: Env, name: String, arity: Int) -> Env {
  Env(
    ..env,
    local_types: dict.insert(env.local_types, name, #(
      env.current_module,
      name,
      arity,
    )),
  )
}

// Register a type alias so references to it expand during hydration.
fn register_type_alias(env: Env, alias: glance.TypeAlias) -> Env {
  Env(
    ..env,
    aliases: dict.insert(env.aliases, alias.name, #(
      alias.parameters,
      alias.aliased,
    )),
  )
}

fn fresh_id(st: State) -> #(Int, State) {
  #(st.next_id, State(..st, next_id: st.next_id + 1))
}

fn fresh(st: State) -> #(Type, State) {
  let #(id, st) = fresh_id(st)
  #(Var(id), st)
}

// The id of a type variable. Callers pass freshly-minted `Var`s (custom-type
// parameters, instantiated constructor heads), so a non-`Var` is `Error` rather
// than a fabricated id.
fn var_id(type_: Type) -> Result(Int, Nil) {
  case type_ {
    Var(id) -> Ok(id)
    _ -> Error(Nil)
  }
}

// Mint a fresh type variable (a thin wrapper over `fresh`).
fn fresh_var(st: State) -> #(Type, State) {
  fresh(st)
}

// Bind a value scheme into the environment (used to register top-level
// functions and constructors).
fn define(env: Env, name: String, scheme: Scheme) -> Env {
  bind_value(env, name, scheme)
}

// Mark `names` as the live members of the strongly-connected component being
// inferred, so a reference to one resolves its scheme through the current
// substitution before instantiating (see `Env.live`).
fn mark_live(env: Env, names: List(String)) -> Env {
  Env(..env, live: set.from_list(names))
}

// The initial environment and state, seeded with the prelude value
// constructors (`True`, `False`, `Nil`, `Ok`, `Error`).
fn prelude() -> #(Env, State) {
  let st = new_state()
  let env =
    new_env()
    |> bind_value("True", Scheme([], prelude_bool()))
    |> bind_value("False", Scheme([], prelude_bool()))
    |> bind_value("Nil", Scheme([], prelude_nil()))

  // Ok(a) -> Result(a, e)
  let #(ok_a, st) = fresh_id(st)
  let #(ok_e, st) = fresh_id(st)
  let env =
    bind_value(
      env,
      "Ok",
      Scheme(
        [ok_a, ok_e],
        Fn([Var(ok_a)], prelude_result(Var(ok_a), Var(ok_e))),
      ),
    )

  // Error(e) -> Result(a, e)
  let #(err_a, st) = fresh_id(st)
  let #(err_e, st) = fresh_id(st)
  let env =
    bind_value(
      env,
      "Error",
      Scheme(
        [err_a, err_e],
        Fn([Var(err_e)], prelude_result(Var(err_a), Var(err_e))),
      ),
    )

  #(env, st)
}

// The implicit `gleam` prelude module's public interface, used to resolve
// `import gleam` / `import gleam.{Error as Err}`. The prelude has no source
// file; the compiler treats `gleam` as a built-in module exposing the prelude
// types and value constructors.
fn prelude_interface() -> ModuleInterface {
  let module = prelude_module
  let values =
    dict.from_list([
      #("True", Scheme([], prelude_bool())),
      #("False", Scheme([], prelude_bool())),
      #("Nil", Scheme([], prelude_nil())),
      #("Ok", Scheme([0, 1], Fn([Var(0)], prelude_result(Var(0), Var(1))))),
      #("Error", Scheme([0, 1], Fn([Var(1)], prelude_result(Var(0), Var(1))))),
    ])
  let types_ =
    dict.from_list([
      #("Int", #(module, "Int", 0)),
      #("Float", #(module, "Float", 0)),
      #("String", #(module, "String", 0)),
      #("Bool", #(module, "Bool", 0)),
      #("Nil", #(module, "Nil", 0)),
      #("BitArray", #(module, "BitArray", 0)),
      #("UtfCodepoint", #(module, "UtfCodepoint", 0)),
      #("List", #(module, "List", 1)),
      #("Result", #(module, "Result", 2)),
    ])
  ModuleInterface(
    name: module,
    values: values,
    types: types_,
    aliases: dict.new(),
    accessors: dict.new(),
    field_maps: dict.new(),
    modules: dict.new(),
  )
}

fn bind_value(env: Env, name: String, scheme: Scheme) -> Env {
  // A new binding for `name` is a different value, so any variant narrowing
  // recorded for the previous binding of that name no longer applies — drop it
  // (a parameter shadowing a `let x = Ctor(..)`-narrowed outer variable must not
  // inherit the outer value's recorded fields). `record_variant` re-adds the
  // narrowing afterwards for bindings that are themselves narrowed.
  Env(
    ..env,
    values: dict.insert(env.values, name, scheme),
    // Track whether this binding can contribute environment free variables, so
    // `env_free_vars` need not re-walk every closed scheme. A closed scheme
    // shadowing an open one must evict the stale open entry, hence the delete.
    open_values: case scheme_is_closed(scheme) {
      True -> dict.delete(env.open_values, name)
      False -> dict.insert(env.open_values, name, scheme)
    },
    variants: dict.delete(env.variants, name),
  )
}

// Whether a scheme can never contribute a free variable to the environment:
// every type variable in its type is bound by its own quantifier. This is
// purely syntactic and so substitution-independent — `scheme_free_vars`
// resolves and collects only variables *not* in `bound`, so a scheme with none
// such yields nothing for any substitution, now or later.
fn scheme_is_closed(scheme: Scheme) -> Bool {
  let bound = set.from_list(scheme.vars)
  all_vars_bound(scheme.type_, bound)
}

fn all_vars_bound(type_: Type, bound: Set(Int)) -> Bool {
  case type_ {
    Var(id) -> set.contains(bound, id)
    Named(_, _, args) -> list.all(args, all_vars_bound(_, bound))
    Fn(args, ret) ->
      list.all(args, all_vars_bound(_, bound)) && all_vars_bound(ret, bound)
    Tuple(elements) -> list.all(elements, all_vars_bound(_, bound))
  }
}

// Look up a value's scheme in the environment.
fn lookup(env: Env, name: String) -> Result(Scheme, Nil) {
  dict.get(env.values, name)
}

// Module inference
//
// The driver: fully infer a module by resolving imports, registering types,
// ordering definitions by strongly-connected component, and inferring each
// component before generalizing at the top-level boundary. Best-effort mode
// keeps going past a component that fails to type.

// A top-level definition that participates in the dependency graph.
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

// `#(value references, field-access qualifier names)` of a definition.
fn def_refs(def: Def) -> #(List(String), List(String)) {
  case def {
    FunctionDef(f) -> reference.in_function(f)
    ConstantDef(c) -> reference.in_constant(c)
  }
}

fn infer_def(env: Env, st: State, def: Def) -> Result(#(Type, State), Error) {
  case def {
    FunctionDef(f) -> infer_function(env, st, f)
    ConstantDef(c) -> infer_constant(env, st, c)
  }
}

// Interfaces resolved so far in this run, keyed by module path. Resolving a
// module is expensive (it infers the whole module), and a deep import graph
// imports the same dependency many times; memoizing keeps each module inferred
// once rather than re-inferring it exponentially.
type InterfaceCache =
  dict.Dict(String, ModuleInterface)

// Fully infer a module: resolve imports, register types, and infer every
// definition in dependency order. Returns the final environment and state
// plus the module's public interface.
fn infer_module(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  module_name: String,
  module: glance.Module,
  best_effort best_effort: Bool,
) -> Result(
  #(#(Env, State), ModuleInterface, InterfaceCache, List(#(String, Error))),
  Error,
) {
  // Drop definitions and imports compiled only for another target. A pair of
  // target-specific siblings may have different types, so the inactive one
  // must not shadow the active definition.
  let module = for_target(module, options.target)
  let #(prelude_env, st) = prelude()
  let env = set_module(prelude_env, module_name)

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
      declare_type(env, ct.name, list.length(ct.parameters))
    })
  let env =
    list.fold(module.type_aliases, env, fn(env, d) {
      register_type_alias(env, d.definition)
    })
  let #(env, st) =
    list.fold(module.custom_types, #(env, st), fn(acc, d) {
      let #(env, st) = acc
      register_custom_type(env, st, d.definition)
    })
  let env =
    list.fold(module.functions, env, fn(env, d) {
      let function = d.definition
      register_field_map(
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
    build_interface(
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
  env: Env,
  st: State,
  module_aliases: Set(String),
  defs: List(Def),
  best_effort best_effort: Bool,
) -> Result(#(#(Env, State), List(#(String, Error))), Error) {
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

// One best-effort step over a strongly-connected component: on success adopt
// the new environment; on failure keep the prior one (discarding the
// component's partial work) and record every definition in it as skipped.
fn best_effort_group(
  acc: #(#(Env, State), List(#(String, Error))),
  group: List(Def),
) -> #(#(Env, State), List(#(String, Error))) {
  let #(#(env, st), skipped) = acc
  case infer_group(env, st, group) {
    Ok(env_st) -> #(env_st, skipped)
    Error(error) -> {
      let entries = list.map(group, fn(d) { #(def_name(d), error) })
      #(#(env, st), list.append(skipped, entries))
    }
  }
}

// Infer one strongly-connected component of mutually recursive definitions,
// then generalize each against the surrounding environment and add it back for
// later components.
//
// A function with signature variables is pre-registered at a scheme over those
// variables so recursion and siblings see it polymorphically; its body is
// checked against the signature with those variables rigid, and within its own
// body it sees itself at the rigid monotype (no polymorphic recursion). Every
// other definition is inferred monomorphically against a fresh placeholder.
// The members are marked *live* (see `mark_live`): a reference to a
// sibling resolves its scheme through the current substitution, so once a
// member's body has settled an unannotated part (absorbing it into a signature
// variable) a later sibling sees the resolved type — the compiler's shared
// mutable cells, reproduced through girard's threaded substitution. Because of
// that, bodies are inferred *provider-first*: a member whose signature has an
// unannotated part is typed before the fully-annotated members that consume it
// (a dependency-respecting order within the component, as Tarjan provides).
fn infer_group(
  env: Env,
  st: State,
  group: List(Def),
) -> Result(#(Env, State), Error) {
  let #(group_env, rev_items, st) =
    list.fold(group, #(env, [], st), fn(acc, def) {
      let #(env, items, st) = acc
      prereg_def(env, items, st, def)
    })
  let group_env = mark_live(group_env, list.map(group, def_name))
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
            bind_params(
              define(
                group_env,
                def_name(def),
                rigid_self_scheme(params, return_type),
              ),
              f,
              params,
            )
          check_body(body_env, st, f, return_type)
        }
        PlaceholderDef(def, var) -> {
          use #(inferred, st) <- result.try(infer_def(group_env, st, def))
          unify(st, var, inferred)
        }
      }
    }),
  )
  // The component's bodies are fully inferred, so any field accesses deferred
  // because their record type was unknown can now be resolved — before we
  // generalize, so the field types are reflected in the schemes.
  use st <- result.try(resolve_pending(group_env, st))
  let env =
    list.fold(items, env, fn(env, item) {
      case item {
        AnnotatedDef(def, _, params, return_type) ->
          define(
            env,
            def_name(def),
            function_scheme(env, st, params, return_type),
          )
        PlaceholderDef(def, var) ->
          define(env, def_name(def), generalize(st, env, var))
      }
    })
  Ok(#(env, st))
}

// A member of a strongly-connected component during inference.
type GroupItem {
  // A fully-annotated function: bound at its declared scheme up front; its body
  // is checked against the signature (rigid variables).
  AnnotatedDef(
    def: Def,
    function: glance.Function,
    params: List(Type),
    return_type: Type,
  )
  // Any other definition: inferred monomorphically against `var`, then
  // generalized.
  PlaceholderDef(def: Def, var: Type)
}

fn placeholder(
  env: Env,
  items: List(GroupItem),
  st: State,
  def: Def,
) -> #(Env, List(GroupItem), State) {
  let #(var, st) = fresh_var(st)
  #(
    define(env, def_name(def), Scheme([], var)),
    [PlaceholderDef(def, var), ..items],
    st,
  )
}

// Pre-register one SCC member: a function with signature variables is bound at
// its declared scheme (`AnnotatedDef`); any other definition gets a fresh
// monomorphic placeholder.
fn prereg_def(
  env: Env,
  items: List(GroupItem),
  st: State,
  def: Def,
) -> #(Env, List(GroupItem), State) {
  let annotated = case def {
    FunctionDef(f) ->
      case has_annotation_vars(f) {
        True -> Ok(f)
        False -> Error(Nil)
      }
    ConstantDef(_) -> Error(Nil)
  }
  case annotated {
    Error(_) -> placeholder(env, items, st, def)
    Ok(f) -> {
      let #(params, return_type, rigid_ids, st) = signature_skeleton(env, st, f)
      #(
        define(env, def_name(def), rigid_scheme(rigid_ids, params, return_type)),
        [AnnotatedDef(def, f, params, return_type), ..items],
        st,
      )
    }
  }
}

// Import resolution
//
// Resolve each import to a `ModuleInterface` — from the run's cache, the
// prelude, or by inferring the imported module's source through the resolver
// — and bring its qualified alias and unqualified items into scope.

fn process_imports(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  env: Env,
  imports: List(glance.Definition(glance.Import)),
  best_effort best_effort: Bool,
) -> Result(#(Env, InterfaceCache), Error) {
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

// Bring an import's qualified alias and unqualified values/types into scope.
fn import_items(
  env: Env,
  import_: glance.Import,
  interface: ModuleInterface,
) -> Env {
  // A discarded alias (`import x as _y`) imports the module for its unqualified
  // items only — it must NOT be bound under any qualified name, or we'd bind it
  // under the module's last segment and shadow a real import sharing that name
  // (mist's `gleam/http as _ghttp` vs `mist/internal/http`).
  let env = case qualified_alias(import_) {
    Ok(alias) -> import_qualified(env, alias, interface)
    Error(_) -> env
  }
  let env =
    list.fold(import_.unqualified_values, env, fn(env, u) {
      import_value(env, option.unwrap(u.alias, u.name), interface, u.name)
    })
  list.fold(import_.unqualified_types, env, fn(env, u) {
    import_type(env, option.unwrap(u.alias, u.name), interface, u.name)
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
  use <- bool.lazy_guard(when: path == prelude_module, return: fn() {
    Ok(#(Some(prelude_interface()), cache))
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

// The name under which an import is accessible for qualified access, or
// `Error` when the module is imported with a discarded alias (`as _x`) and so
// has no qualified name at all.
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

// Module interfaces
//
// Build an inferred module's public interface, and bring an imported
// interface's values, types, aliases and accessors into the environment
// (under a qualified alias, or unqualified).

// Build the public interface of an inferred module by keeping only the named
// public values and types.
fn build_interface(
  env: Env,
  st: State,
  name: String,
  value_names: List(String),
  type_names: List(String),
  accessor_type_names: List(String),
) -> ModuleInterface {
  ModuleInterface(
    name: name,
    values: take(env.values, value_names),
    types: take(env.local_types, type_names),
    aliases: resolve_aliases(env, st, type_names),
    // Only non-opaque public types expose their field accessors: an opaque
    // type's fields are private to its defining module.
    accessors: take(env.accessors, accessor_type_names),
    field_maps: take(env.field_maps, value_names),
    modules: env.modules,
  )
}

// Resolve each named public alias to a concrete type, in this module's full
// environment, with the alias's parameters as variables. Resolving here (not
// when the alias is used elsewhere) keeps the bodies' type references — which
// may be imported into this module — correctly attributed.
fn resolve_aliases(
  env: Env,
  st: State,
  type_names: List(String),
) -> Dict(String, #(List(Int), Type)) {
  list.fold(type_names, #(dict.new(), st), fn(acc, name) {
    let #(resolved, st) = acc
    case dict.get(env.aliases, name) {
      Error(_) -> #(resolved, st)
      Ok(#(params, body)) -> {
        let #(param_vars, st) = fresh_n(st, list.length(params))
        let param_ids = list.filter_map(param_vars, var_id)
        let names = dict.from_list(list.zip(params, param_vars))
        let #(type_, st) = hydrate_in(env, names, st, body)
        #(dict.insert(resolved, name, #(param_ids, type_)), st)
      }
    }
  }).0
}

// Instantiate a resolved alias `#(param ids, body)` with concrete arguments.
fn instantiate_alias(
  params: List(Int),
  body: Type,
  arguments: List(Type),
) -> Type {
  substitute(dict.from_list(list.zip(params, arguments)), body)
}

fn take(d: Dict(String, v), keys: List(String)) -> Dict(String, v) {
  list.fold(keys, dict.new(), fn(acc, key) {
    case dict.get(d, key) {
      Ok(value) -> dict.insert(acc, key, value)
      Error(_) -> acc
    }
  })
}

// Make a module available for qualified access (`alias.value`/`alias.Type`).
fn import_qualified(
  env: Env,
  alias: String,
  interface: ModuleInterface,
) -> Env {
  // Bring the module's own imports along (under their aliases, but not
  // overriding the importer's direct imports) so types it exposes from other
  // modules keep their accessors reachable. Then bind the module itself.
  let modules =
    dict.fold(env.modules, interface.modules, fn(acc, alias, interface) {
      dict.insert(acc, alias, interface)
    })
  Env(
    ..env,
    modules: dict.insert(modules, alias, interface),
    // Index the newly reachable interfaces by real name. The bound interface's
    // transitive closure covers everything merged in above (each merged module
    // is itself within that closure), so one walk keeps the index complete.
    module_index: index_interface(env.module_index, interface),
  )
}

// Add `interface` and every interface it transitively exposes to `index`,
// keyed by real module name. First insert wins (a name already present is left
// as-is), which both guards the DAG against re-walking shared modules and is
// unambiguous: a real module name resolves to one inferred interface per run.
fn index_interface(
  index: Dict(String, ModuleInterface),
  interface: ModuleInterface,
) -> Dict(String, ModuleInterface) {
  // Already indexed: stop. Guards the DAG against re-walking shared modules.
  use <- bool.guard(when: dict.has_key(index, interface.name), return: index)
  dict.fold(
    interface.modules,
    dict.insert(index, interface.name, interface),
    fn(acc, _alias, nested) { index_interface(acc, nested) },
  )
}

// Bring a single value (function/constant/constructor) into scope unqualified.
fn import_value(
  env: Env,
  local: String,
  interface: ModuleInterface,
  original: String,
) -> Env {
  let env = case dict.get(interface.values, original) {
    Ok(scheme) -> bind_value(env, local, scheme)
    Error(_) -> env
  }
  case dict.get(interface.field_maps, original) {
    Ok(field_map) ->
      Env(..env, field_maps: dict.insert(env.field_maps, local, field_map))
    Error(_) -> env
  }
}

// Bring a single type into scope unqualified.
fn import_type(
  env: Env,
  local: String,
  interface: ModuleInterface,
  original: String,
) -> Env {
  let env = case dict.get(interface.types, original) {
    Ok(info) ->
      Env(..env, local_types: dict.insert(env.local_types, local, info))
    Error(_) -> env
  }
  let env = case dict.get(interface.aliases, original) {
    Ok(alias) ->
      Env(
        ..env,
        imported_aliases: dict.insert(env.imported_aliases, local, alias),
      )
    Error(_) -> env
  }
  case dict.get(interface.accessors, original) {
    Ok(accessors) ->
      Env(..env, accessors: dict.insert(env.accessors, local, accessors))
    Error(_) -> env
  }
}

// Target filtering and public surface
//
// Drop definitions and imports compiled for the other build target, and
// collect the names of a module's public values, types and field-accessor
// types for its interface.

// Keep only the definitions and imports compiled for `target`: those with no
// `@target` attribute, or one naming the active target. A definition annotated
// for the other target is dropped, exactly as the compiler omits it.
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

// Public types whose field accessors are reachable from other modules: public,
// non-opaque custom types. An `opaque` type's fields are private to its
// defining module, so its accessors are not exported — a same-named module
// function then wins over the inaccessible field at an external call site, as
// with an opaque `Schema` that has both a private `decode` field and a public
// `decode` function.
fn public_accessor_type_names(module: glance.Module) -> List(String) {
  list.filter_map(module.custom_types, fn(d) {
    case d.definition.publicity, d.definition.opaque_ {
      glance.Public, False -> Ok(d.definition.name)
      _, _ -> Error(Nil)
    }
  })
}

// Substitution
//
// Resolve a variable to its head constructor, fully apply the substitution
// (`zonk`), and collect free variables — treating a scheme's own quantified
// variables as opaque.

// Follow bound variables one level to expose the head constructor.
fn resolve(st: State, type_: Type) -> Type {
  case type_ {
    Var(id) ->
      case dict.get(st.subst, id) {
        Ok(bound) -> resolve(st, bound)
        Error(_) -> type_
      }
    _ -> type_
  }
}

// Fully apply the substitution, leaving only unbound variables as `Var`.
fn zonk(st: State, type_: Type) -> Type {
  case resolve(st, type_) {
    Named(module, name, args) ->
      Named(module, name, list.map(args, zonk(st, _)))
    Fn(args, ret) -> Fn(list.map(args, zonk(st, _)), zonk(st, ret))
    Tuple(elements) -> Tuple(list.map(elements, zonk(st, _)))
    Var(id) -> Var(id)
  }
}

fn free_vars(st: State, type_: Type) -> List(Int) {
  free_vars_loop(zonk(st, type_), [])
}

fn free_vars_loop(type_: Type, acc: List(Int)) -> List(Int) {
  case type_ {
    Var(id) ->
      case list.contains(acc, id) {
        True -> acc
        False -> [id, ..acc]
      }
    Named(_, _, args) -> list.fold(args, acc, fn(a, t) { free_vars_loop(t, a) })
    Fn(args, ret) ->
      free_vars_loop(
        ret,
        list.fold(args, acc, fn(a, t) { free_vars_loop(t, a) }),
      )
    Tuple(elements) ->
      list.fold(elements, acc, fn(a, t) { free_vars_loop(t, a) })
  }
}

fn env_free_vars(st: State, env: Env) -> List(Int) {
  // Only open bindings can contribute; closed schemes (the bulk — every import
  // and generalized definition) are omitted from `open_values`, so this scans a
  // handful of live monomorphic bindings rather than the whole environment.
  dict.fold(env.open_values, [], fn(acc, _name, scheme) {
    // A scheme's quantified variables are bound *within the scheme*; they must
    // not be resolved against the ambient substitution. This matters because
    // imported schemes carry variable ids minted in their own module, which can
    // collide with — and have since been bound to unrelated types by — the
    // importing module's substitution. Treating them as opaque (rather than
    // zonking them) keeps such collisions from leaking phantom free variables
    // that would wrongly block generalization here.
    scheme_free_vars(st, scheme.type_, scheme.vars, acc)
  })
}

// Free variables of `type_`, treating `bound` ids as opaque: a bound id
// contributes nothing and is never resolved through the substitution, while a
// free id is resolved and its remaining variables collected.
fn scheme_free_vars(
  st: State,
  type_: Type,
  bound: List(Int),
  acc: List(Int),
) -> List(Int) {
  case type_ {
    Var(id) ->
      case list.contains(bound, id) {
        True -> acc
        False ->
          case resolve(st, type_) {
            Var(resolved) ->
              case list.contains(acc, resolved) {
                True -> acc
                False -> [resolved, ..acc]
              }
            other -> scheme_free_vars(st, other, bound, acc)
          }
      }
    Named(_, _, args) ->
      list.fold(args, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) })
    Fn(args, ret) ->
      scheme_free_vars(
        st,
        ret,
        bound,
        list.fold(args, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) }),
      )
    Tuple(elements) ->
      list.fold(elements, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) })
  }
}

// Unification
//
// Unify two types, binding flexible variables and rejecting rigid ones, with
// the occurs check that guards against infinite types.

fn unify(st: State, left: Type, right: Type) -> Result(State, Error) {
  let left = resolve(st, left)
  let right = resolve(st, right)
  case left, right {
    Var(i), Var(j) if i == j -> Ok(st)
    // A rigid variable never binds; a flexible one may bind to it. Two distinct
    // rigid variables, or a rigid variable against a concrete type, mismatch.
    Var(i), Var(j) ->
      case is_rigid(st, i), is_rigid(st, j) {
        True, True -> Error(TypeMismatch(left, right))
        True, False -> bind_var(st, j, left)
        False, _ -> bind_var(st, i, right)
      }
    Var(i), other ->
      case is_rigid(st, i) {
        True -> Error(TypeMismatch(left, right))
        False -> bind_var(st, i, other)
      }
    other, Var(j) ->
      case is_rigid(st, j) {
        True -> Error(TypeMismatch(left, right))
        False -> bind_var(st, j, other)
      }

    Named(m1, n1, a1), Named(m2, n2, a2) if m1 == m2 && n1 == n2 ->
      unify_many(st, a1, a2)

    Fn(args1, r1), Fn(args2, r2) -> {
      use st <- result.try(unify_many(st, args1, args2))
      unify(st, r1, r2)
    }

    Tuple(e1), Tuple(e2) -> unify_many(st, e1, e2)

    _, _ -> Error(TypeMismatch(left, right))
  }
}

fn unify_many(
  st: State,
  left: List(Type),
  right: List(Type),
) -> Result(State, Error) {
  case left, right {
    [], [] -> Ok(st)
    [x, ..xs], [y, ..ys] -> {
      use st <- result.try(unify(st, x, y))
      unify_many(st, xs, ys)
    }
    _, _ -> Error(ArityMismatch)
  }
}

fn bind_var(st: State, id: Int, type_: Type) -> Result(State, Error) {
  use <- bool.guard(
    when: occurs(st, id, type_),
    return: Error(RecursiveType(id, type_)),
  )
  Ok(State(..st, subst: dict.insert(st.subst, id, type_)))
}

fn occurs(st: State, id: Int, type_: Type) -> Bool {
  list.contains(free_vars(st, type_), id)
}

// Generalization and instantiation
//
// Generalize a type into a scheme at a definition boundary — quantifying
// variables free in the type but not the environment — and instantiate a
// scheme back to a monotype with fresh variables.

fn generalize(st: State, env: Env, type_: Type) -> Scheme {
  let zonked = zonk(st, type_)
  let env_vars = env_free_vars(st, env)
  let quantified =
    list.filter(free_vars(st, zonked), fn(id) { !list.contains(env_vars, id) })
  Scheme(quantified, zonked)
}

// Generalize a type over a specific set of candidate variable ids only (the
// rest stay monomorphic). Used for a `let`-bound function, which Gleam makes
// polymorphic over exactly the type variables written in its annotations.
fn generalize_over(
  st: State,
  env: Env,
  type_: Type,
  candidate_ids: List(Int),
) -> Scheme {
  let zonked = zonk(st, type_)
  let env_vars = env_free_vars(st, env)
  let free = free_vars(st, zonked)
  // Each annotation var may have been unified with another; follow it to its
  // representative and keep it only if it is still a free variable of the type.
  let reps =
    list.filter_map(candidate_ids, fn(id) {
      case zonk(st, Var(id)) {
        Var(rep) -> Ok(rep)
        _ -> Error(Nil)
      }
    })
  let quantified =
    list.unique(
      list.filter(reps, fn(id) {
        list.contains(free, id) && !list.contains(env_vars, id)
      }),
    )
  Scheme(quantified, zonked)
}

// The type-variable names written in a `fn`'s parameter and return annotations.
fn fn_annotation_var_names(
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
) -> List(String) {
  let from_params =
    list.flat_map(params, fn(p) {
      case p.type_ {
        Some(t) -> type_var_names(t)
        None -> []
      }
    })
  case return_annotation {
    Some(t) -> list.append(from_params, type_var_names(t))
    None -> from_params
  }
}

fn type_var_names(ast: glance.Type) -> List(String) {
  case ast {
    glance.VariableType(_, name) -> [name]
    glance.NamedType(_, _, _, parameters) ->
      list.flat_map(parameters, type_var_names)
    glance.TupleType(_, elements) -> list.flat_map(elements, type_var_names)
    glance.FunctionType(_, parameters, return) ->
      list.append(
        list.flat_map(parameters, type_var_names),
        type_var_names(return),
      )
    glance.HoleType(..) -> []
  }
}

// Instantiate a scheme by replacing each quantified variable with a fresh one.
fn instantiate(st: State, scheme: Scheme) -> #(Type, State) {
  let #(mapping, st) =
    list.fold(scheme.vars, #(dict.new(), st), fn(acc, old) {
      let #(mapping, st) = acc
      let #(fresh_type, st) = fresh(st)
      #(dict.insert(mapping, old, fresh_type), st)
    })
  #(substitute(mapping, scheme.type_), st)
}

// Instantiate `name`'s scheme. For a live SCC member, resolve its type through
// the current substitution first, so a variable the provider's body has since
// settled (e.g. an unannotated parameter absorbed into a quantified signature
// variable) is reflected — and then freshened along with the quantified set,
// exactly as the compiler's shared mutable cells propagate to a sibling. For
// any other binding the scheme is already final, so this is plain instantiate.
fn instantiate_in(
  env: Env,
  st: State,
  name: String,
  scheme: Scheme,
) -> #(Type, State) {
  case set.contains(env.live, name) {
    True -> instantiate(st, Scheme(scheme.vars, zonk(st, scheme.type_)))
    False -> instantiate(st, scheme)
  }
}

fn substitute(mapping: Dict(Int, Type), type_: Type) -> Type {
  case type_ {
    Var(id) ->
      case dict.get(mapping, id) {
        Ok(replacement) -> replacement
        Error(_) -> type_
      }
    Named(module, name, args) ->
      Named(module, name, list.map(args, substitute(mapping, _)))
    Fn(args, ret) ->
      Fn(list.map(args, substitute(mapping, _)), substitute(mapping, ret))
    Tuple(elements) -> Tuple(list.map(elements, substitute(mapping, _)))
  }
}

// Top-level definitions
//
// Infer a top-level function or constant and register a custom type's
// constructors and accessors, then resolve the field and tuple accesses
// deferred until inference fixed their container types.

// Whether a function's signature names any type variable. The compiler makes
// such a variable rigid for the body and keeps the function polymorphic over it
// in its own recursion / SCC (rather than inferring it monomorphically against
// a placeholder, which would pin a phantom parameter). A function with only
// concrete annotations, or none, takes the ordinary placeholder path.
fn has_annotation_vars(function: glance.Function) -> Bool {
  function_annotation_var_names(function) != []
}

fn function_annotation_var_names(function: glance.Function) -> List(String) {
  let from_params =
    list.flat_map(function.parameters, fn(p) {
      case p.type_ {
        Some(t) -> type_var_names(t)
        None -> []
      }
    })
  case function.return {
    Some(t) -> list.append(from_params, type_var_names(t))
    None -> from_params
  }
}

// Hydrate a function's signature into a *skeleton*: each annotated part uses
// its written type with the signature's type variables made rigid (skolemized)
// for the body; each unannotated part is a fresh flexible variable (inferred
// and shared monomorphically, like a placeholder). Returns the parameter types,
// return type, and the ids made rigid; those ids are also recorded in `State`.
fn signature_skeleton(
  env: Env,
  st: State,
  function: glance.Function,
) -> #(List(Type), Type, List(Int), State) {
  // One rigid id per distinct annotation variable name, shared across the whole
  // signature (so a parameter `a` and the return `a` are the same variable).
  let #(names, rigid_ids, st) =
    list.fold(
      list.unique(function_annotation_var_names(function)),
      #(dict.new(), [], st),
      fn(acc, name) {
        let #(names, ids, st) = acc
        let #(id, st) = fresh_id(st)
        #(dict.insert(names, name, Var(id)), [id, ..ids], st)
      },
    )
  let st = mark_rigid(st, rigid_ids)
  let #(rev_param_types, st) =
    list.fold(function.parameters, #([], st), fn(acc, param) {
      let #(types_, st) = acc
      let #(t, st) = case param.type_ {
        Some(ann) -> hydrate_in(env, names, st, ann)
        None -> fresh(st)
      }
      #([t, ..types_], st)
    })
  let #(return_type, st) = case function.return {
    Some(ann) -> hydrate_in(env, names, st, ann)
    None -> fresh(st)
  }
  #(list.reverse(rev_param_types), return_type, rigid_ids, st)
}

// Bind a function's parameters to the given types in `env`.
fn bind_params(
  env: Env,
  function: glance.Function,
  param_types: List(Type),
) -> Env {
  list.fold(list.zip(function.parameters, param_types), env, fn(env, pair) {
    let #(param, t) = pair
    case param.name {
      glance.Named(name) -> bind_value(env, name, Scheme([], t))
      glance.Discarded(_) -> env
    }
  })
}

// Infer a fully-annotated function's body and check it against the declared
// return type. `@external` functions have no body and pass trivially.
fn check_body(
  env: Env,
  st: State,
  function: glance.Function,
  return_type: Type,
) -> Result(State, Error) {
  case function.body {
    [] -> Ok(st)
    _ -> {
      use #(body_type, st) <- result.try(infer_statements(
        env,
        st,
        function.body,
      ))
      unify(st, body_type, return_type)
    }
  }
}

// The scheme a function with signature variables is bound at within its SCC:
// polymorphic over its rigid signature variables, but with any unannotated
// (flexible placeholder) parts left free, so they stay shared/monomorphic
// across the component until the body fixes them.
fn rigid_scheme(
  rigid_ids: List(Int),
  param_types: List(Type),
  return_type: Type,
) -> Scheme {
  Scheme(rigid_ids, Fn(param_types, return_type))
}

// Generalize a function's final parameter/return types into a scheme,
// quantifying every variable still free after the body is inferred.
fn function_scheme(
  env: Env,
  st: State,
  param_types: List(Type),
  return_type: Type,
) -> Scheme {
  generalize(st, env, Fn(param_types, return_type))
}

// The *monomorphic* scheme a fully-annotated function sees for itself inside
// its own body. Its signature variables stay rigid (un-quantified), so a
// self-recursive call must be at the same type — Gleam has no polymorphic
// recursion, and recursing at a concrete type where the signature is generic
// is a mismatch, exactly as the compiler reports.
fn rigid_self_scheme(param_types: List(Type), return_type: Type) -> Scheme {
  Scheme([], Fn(param_types, return_type))
}

// Infer a top-level function, returning its (still ungeneralized) `Fn` type.
fn infer_function(
  env: Env,
  st: State,
  function: glance.Function,
) -> Result(#(Type, State), Error) {
  // Type-variable names are shared across the whole signature so that, e.g.,
  // a parameter `a` and the return `a` refer to the same variable.
  let #(rev_param_types, body_env, st, names) =
    list.fold(function.parameters, #([], env, st, dict.new()), fn(acc, param) {
      let #(types_, env, st, names) = acc
      let #(t, st, names) = case param.type_ {
        Some(ann) -> hydrate_threaded(env, names, st, ann)
        None -> {
          let #(t, st) = fresh(st)
          #(t, st, names)
        }
      }
      let env = case param.name {
        glance.Named(name) -> bind_value(env, name, Scheme([], t))
        glance.Discarded(_) -> env
      }
      #([t, ..types_], env, st, names)
    })
  let param_types = list.reverse(rev_param_types)
  case function.body {
    // External functions (e.g. `@external`) have no body; their type comes
    // entirely from the signature annotations.
    [] -> {
      let #(return_type, st) = case function.return {
        Some(ann) -> {
          let #(t, st, _names) = hydrate_threaded(env, names, st, ann)
          #(t, st)
        }
        None -> fresh(st)
      }
      Ok(#(Fn(param_types, return_type), st))
    }
    _ -> {
      use #(body_type, st) <- result.try(infer_statements(
        body_env,
        st,
        function.body,
      ))
      use st <- result.try(case function.return {
        Some(ann) -> {
          let #(t, st, _names) = hydrate_threaded(env, names, st, ann)
          unify(st, body_type, t)
        }
        None -> Ok(st)
      })
      Ok(#(Fn(param_types, body_type), st))
    }
  }
}

// Infer a module constant, returning its type (an annotation, if present, is
// applied).
fn infer_constant(
  env: Env,
  st: State,
  constant: glance.Constant,
) -> Result(#(Type, State), Error) {
  use #(value_type, st) <- result.try(infer_expr(env, st, constant.value))
  case constant.annotation {
    Some(ann) -> {
      let #(t, st) = hydrate(env, st, ann)
      use st <- result.try(unify(st, value_type, t))
      Ok(#(value_type, st))
    }
    None -> Ok(#(value_type, st))
  }
}

// Register a custom type's constructors as value schemes in the environment,
// generalized over the type's parameters.
fn register_custom_type(
  env: Env,
  st: State,
  custom_type: glance.CustomType,
) -> #(Env, State) {
  // Record the type as local first so its own fields can refer to it.
  let env =
    declare_type(env, custom_type.name, list.length(custom_type.parameters))
  let #(rev_param_ids, st) =
    list.fold(custom_type.parameters, #([], st), fn(acc, _name) {
      let #(ids, st) = acc
      let #(id, st) = fresh_id(st)
      #([id, ..ids], st)
    })
  let param_ids = list.reverse(rev_param_ids)
  let param_vars = list.map(param_ids, Var)
  let names = dict.from_list(list.zip(custom_type.parameters, param_vars))
  let return_type = Named(env.current_module, custom_type.name, param_vars)

  // Build constructors, keeping each variant's fields in declaration order
  // (label and type per position) so we can later expose accessors for labels
  // shared across all variants.
  let #(env, st, rev_variant_fields) =
    list.fold(custom_type.variants, #(env, st, []), fn(acc, variant) {
      let #(env, st, variant_fields) = acc
      let #(rev_fields, st) =
        list.fold(variant.fields, #([], st), fn(acc, field) {
          let #(fields, st) = acc
          let #(t, st) = hydrate_in(env, names, st, variant_field_type(field))
          let label = case field {
            glance.LabelledVariantField(_, label) -> Some(label)
            glance.UnlabelledVariantField(..) -> None
          }
          #([#(label, t), ..fields], st)
        })
      let fields = list.reverse(rev_fields)
      let ctor_type = case fields {
        [] -> return_type
        _ -> Fn(list.map(fields, fn(field) { field.1 }), return_type)
      }
      let env =
        register_field_map(
          env,
          variant.name,
          list.map(fields, fn(field) { field.0 }),
        )
      let env = bind_value(env, variant.name, Scheme(param_ids, ctor_type))
      #(env, st, [fields, ..variant_fields])
    })

  // A label is accessible iff every variant declares it at the same position
  // with the same type. (Single-variant records are the degenerate case where
  // every label qualifies.)
  let accessors =
    shared_accessors(list.reverse(rev_variant_fields), param_ids, return_type)
  let env =
    Env(
      ..env,
      accessors: dict.insert(env.accessors, custom_type.name, accessors),
    )
  #(env, st)
}

// Accessor schemes for the labels every variant declares at the same position
// with the same type, given each variant's fields in declaration order. This
// is the compiler's `get_compatible_record_fields`: it walks the first
// variant's labelled fields by index and keeps a label only when every other
// variant has that label, with that type, at that index.
fn shared_accessors(
  variants: List(List(#(Option(String), Type))),
  param_ids: List(Int),
  return_type: Type,
) -> Dict(String, Scheme) {
  case variants {
    [] -> dict.new()
    [first, ..rest] ->
      list.index_fold(first, dict.new(), fn(accessors, field, index) {
        case field {
          #(None, _) -> accessors
          #(Some(label), field_type) -> {
            let shared =
              list.all(rest, fn(variant) {
                list_at(variant, index) == Ok(#(Some(label), field_type))
              })
            case shared {
              True ->
                dict.insert(
                  accessors,
                  label,
                  Scheme(param_ids, Fn([return_type], field_type)),
                )
              False -> accessors
            }
          }
        }
      })
  }
}

// Look up the accessor scheme for `label` on a (resolved) record type. The
// accessors live with whichever module defined the type — the current module,
// or an imported one identified by the type's origin module.
fn accessor(env: Env, record: Type, label: String) -> Result(Scheme, Error) {
  case record {
    Named(module, name, _) -> {
      let accessors = accessors_of_module(env, module)
      case dict.get(accessors, name) {
        Ok(labels) ->
          case dict.get(labels, label) {
            Ok(scheme) -> Ok(scheme)
            Error(_) -> Error(NoSuchField(name, label))
          }
        Error(_) -> Error(NoSuchField(name, label))
      }
    }
    _ -> Error(NotARecord)
  }
}

fn accessors_of_module(
  env: Env,
  module: String,
) -> Dict(String, Dict(String, Scheme)) {
  // A type can surface from a module the current one never imports directly (a
  // helper returning another module's record), and an alias collision can evict
  // that module from the alias-keyed `modules` map — so resolve by origin name
  // through `module_index`, which holds the whole transitively-reachable graph.
  case module == env.current_module {
    True -> env.accessors
    False ->
      case dict.get(env.module_index, module) {
        Ok(interface) -> interface.accessors
        Error(_) -> env.accessors
      }
  }
}

// Resolve field accesses that were deferred because the record type was
// unknown when first seen. By now inference has fixed the record types; any
// that are still unknown are genuinely ambiguous (the compiler rejects these
// too).
fn resolve_pending(env: Env, st: State) -> Result(State, Error) {
  // Process in discovery order so inner accesses of a chain (`a.b.c`) resolve
  // before the outer ones, and loop to a fixpoint for any remaining cross
  // dependencies. Anything still unresolved is genuinely ambiguous.
  let pending = list.reverse(st.pending)
  resolve_pending_loop(
    env,
    State(..st, pending: []),
    pending,
    list.length(pending),
  )
}

fn resolve_pending_loop(
  env: Env,
  st: State,
  pending: List(Pending),
  fuel: Int,
) -> Result(State, Error) {
  case pending, fuel <= 0 {
    [], _ -> Ok(st)
    [_, ..], True -> Error(NotARecord)
    _, False -> {
      use #(st, remaining, progressed) <- result.try(
        list.try_fold(pending, #(st, [], False), fn(acc, item) {
          let #(st, remaining, progressed) = acc
          use #(st, resolved) <- result.try(resolve_one(env, st, item))
          case resolved {
            True -> Ok(#(st, remaining, True))
            False -> Ok(#(st, [item, ..remaining], progressed))
          }
        }),
      )
      case progressed {
        True -> resolve_pending_loop(env, st, list.reverse(remaining), fuel - 1)
        False -> Error(NotARecord)
      }
    }
  }
}

// Try to resolve one deferred access. Returns `#(state, resolved?)`: `False`
// means the container is still an unbound variable, so keep it for a later
// pass. A container fixed to the wrong shape is a hard error.
fn resolve_one(
  env: Env,
  st: State,
  item: Pending,
) -> Result(#(State, Bool), Error) {
  case item {
    PendingField(container, label, field) ->
      case resolve(st, container) {
        Named(_, _, _) as record -> {
          use scheme <- result.try(accessor(env, record, label))
          let #(accessor_type, st) = instantiate(st, scheme)
          use st <- result.try(unify(st, accessor_type, Fn([container], field)))
          Ok(#(st, True))
        }
        Var(_) -> Ok(#(st, False))
        _ -> Error(NotARecord)
      }
    PendingIndex(container, index, result) ->
      case resolve(st, container) {
        Tuple(elements) ->
          case list_at(elements, index) {
            Ok(element) -> {
              use st <- result.try(unify(st, element, result))
              Ok(#(st, True))
            }
            Error(_) -> Error(TupleIndexOutOfRange(index))
          }
        Var(_) -> Ok(#(st, False))
        _ -> Error(NotATuple)
      }
  }
}

fn variant_field_type(field: glance.VariantField) -> glance.Type {
  case field {
    glance.LabelledVariantField(item, _label) -> item
    glance.UnlabelledVariantField(item) -> item
  }
}

// Expression inference
//
// Infer the type of every expression: literals, variables, calls and
// captures, operators and pipes, field access and record updates, tuples,
// lists, lambdas, blocks and bit arrays — with the reordering that labelled
// and shorthand arguments need to reach their declared positions.

fn infer_expr(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(Type, State), Error) {
  use #(type_, st) <- result.try(infer_expr_inner(env, st, expr))
  Ok(#(type_, record(st, span(expr), type_)))
}

fn infer_expr_inner(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(Type, State), Error) {
  case expr {
    glance.Int(..) -> Ok(#(prelude_int(), st))
    glance.Float(..) -> Ok(#(prelude_float(), st))
    glance.String(..) -> Ok(#(prelude_string(), st))

    glance.Variable(_, name) ->
      case dict.get(env.values, name) {
        Ok(scheme) -> Ok(instantiate_in(env, st, name, scheme))
        Error(_) -> Error(UnboundVariable(name))
      }

    glance.NegateInt(_, value) -> {
      use #(t, st) <- result.try(infer_expr(env, st, value))
      use st <- result.try(unify(st, t, prelude_int()))
      Ok(#(prelude_int(), st))
    }

    glance.NegateBool(_, value) -> {
      use #(t, st) <- result.try(infer_expr(env, st, value))
      use st <- result.try(unify(st, t, prelude_bool()))
      Ok(#(prelude_bool(), st))
    }

    glance.Tuple(_, elements) -> {
      use #(elem_types, st) <- result.try(infer_each(env, st, elements))
      Ok(#(Tuple(elem_types), st))
    }

    glance.List(_, elements, rest) -> {
      let #(elem, st) = fresh(st)
      use st <- result.try(
        list.try_fold(elements, st, fn(st, e) {
          use #(t, st) <- result.try(infer_expr(env, st, e))
          unify(st, t, elem)
        }),
      )
      use st <- result.try(case rest {
        Some(r) -> {
          use #(t, st) <- result.try(infer_expr(env, st, r))
          unify(st, t, prelude_list(elem))
        }
        None -> Ok(st)
      })
      Ok(#(prelude_list(elem), st))
    }

    glance.Fn(_, params, return_annotation, body) ->
      infer_fn(env, st, params, return_annotation, body)

    glance.Call(span, function, arguments) ->
      infer_call(env, st, span, function, arguments)

    glance.FnCapture(span, label, function, before, after) ->
      infer_capture(env, st, span, label, function, before, after)

    glance.BinaryOperator(span, op, left, right) ->
      infer_binop(env, st, span, op, left, right)

    glance.Block(_, statements) -> infer_statements(env, st, statements)

    glance.Case(_, subjects, clauses) -> infer_case(env, st, subjects, clauses)

    glance.TupleIndex(_, tuple, index) -> {
      use #(t, st) <- result.try(infer_expr(env, st, tuple))
      case resolve(st, t) {
        Tuple(elements) ->
          case list_at(elements, index) {
            Ok(element) -> Ok(#(element, st))
            Error(_) -> Error(TupleIndexOutOfRange(index))
          }
        // The tuple type is not known yet; defer until inference fixes it.
        Var(_) -> {
          let #(element, st) = fresh(st)
          let st =
            State(..st, pending: [PendingIndex(t, index, element), ..st.pending])
          Ok(#(element, st))
        }
        _ -> Error(NotATuple)
      }
    }

    // `panic` and `todo` are bottom, so the result is a fresh variable that
    // unifies with anything. The message is still walked — and checked against
    // `String`, as the compiler requires — so its subexpressions get annotated.
    glance.Todo(_, message) | glance.Panic(_, message) ->
      case message {
        Some(m) -> {
          use st <- result.try(check(env, st, m, prelude_string()))
          Ok(fresh(st))
        }
        None -> Ok(fresh(st))
      }

    glance.Echo(_, expression, _message) ->
      case expression {
        Some(e) -> infer_expr(env, st, e)
        None -> Ok(#(prelude_nil(), st))
      }

    glance.FieldAccess(_, container, label) -> {
      use #(type_, _, st) <- result.try(infer_field_access(
        env,
        st,
        container,
        label,
      ))
      Ok(#(type_, st))
    }

    glance.RecordUpdate(_, module, constructor, record, fields) ->
      infer_record_update(env, st, module, constructor, record, fields)

    glance.BitString(_, segments) -> {
      use st <- result.try(
        list.try_fold(segments, st, fn(st, segment) {
          infer_bit_segment(env, st, segment)
        }),
      )
      Ok(#(prelude_bit_array(), st))
    }
  }
}

// Check one record-update field: its new value (or shorthand variable) must
// match the field's declared type.
fn update_field(
  env: Env,
  st: State,
  field: glance.RecordUpdateField(glance.Expression),
  label_types: Dict(String, Type),
  type_name: String,
) -> Result(State, Error) {
  use #(value_type, st) <- result.try(case field.item {
    Some(value) -> infer_expr(env, st, value)
    // Shorthand `label:` refers to the variable named `label`.
    None ->
      case dict.get(env.values, field.label) {
        Ok(scheme) -> Ok(instantiate(st, scheme))
        Error(_) -> Error(UnboundVariable(field.label))
      }
  })
  case dict.get(label_types, field.label) {
    Ok(expected) -> unify(st, value_type, expected)
    Error(_) -> Error(NoSuchField(type_name, field.label))
  }
}

// Check one bit-array segment's value and its size option against their
// expected types.
fn infer_bit_segment(
  env: Env,
  st: State,
  segment: #(
    glance.Expression,
    List(glance.BitStringSegmentOption(glance.Expression)),
  ),
) -> Result(State, Error) {
  let #(value, options) = segment
  let default = case value {
    glance.String(..) -> prelude_string()
    glance.Float(..) -> prelude_float()
    _ -> prelude_int()
  }
  use st <- result.try(check(
    env,
    st,
    value,
    segment_value_type(options, default),
  ))
  list.try_fold(options, st, fn(st, option) {
    case option {
      glance.SizeValueOption(size) -> check(env, st, size, prelude_int())
      _ -> Ok(st)
    }
  })
}

// Which branch a `name.label` access took. A call reads it to pick the
// callee's field map, which is a property of the branch, not of the alias.
type Access {
  // A record field: the compiler's `RecordAccess`, which has no field map.
  Field
  // The export `label` of the module bound to `alias`.
  Export(alias: String)
}

// The one resolver for `name.label`, in projection and in call position
// alike. The compiler's rule: a valid record access wins unconditionally, a
// failing one falls through to a same-named module export, and the record
// error is reported only when neither exists. A variable narrowed to a
// variant by a pattern (`Ctor(..) as v`) resolves `v.field` from that
// variant's recorded fields, reaching fields not shared by every variant.
fn infer_field_access(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
) -> Result(#(Type, Access, State), Error) {
  let variant_field = case container {
    glance.Variable(_, name) ->
      case dict.get(env.variants, name) {
        Ok(narrowed) -> dict.get(narrowed.fields, label)
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  // Precompute a possible qualified module export; a record field takes
  // precedence over it wherever one is reachable.
  let module_access = case container {
    glance.Variable(_, name) ->
      case dict.get(env.modules, name) {
        Ok(interface) ->
          dict.get(interface.values, label)
          |> result.map(fn(scheme) { #(name, scheme) })
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case variant_field {
    Ok(field) -> Ok(#(field, Field, st))
    Error(_) ->
      case container {
        glance.Variable(_, name) ->
          case dict.has_key(env.values, name) {
            True -> value_field(env, st, container, label, module_access)
            False -> module_or_record(env, st, container, label, module_access)
          }
        _ -> module_or_record(env, st, container, label, module_access)
      }
  }
}

// Instantiate a module export: the branch a record access fell through to.
fn module_export(
  st: State,
  export: #(String, Scheme),
) -> Result(#(Type, Access, State), Error) {
  let #(alias, scheme) = export
  let #(type_, st) = instantiate(st, scheme)
  Ok(#(type_, Export(alias), st))
}

// Defer `container.label` until inference fixes the container's type.
fn pending_field(
  st: State,
  container_type: Type,
  label: String,
) -> Result(#(Type, Access, State), Error) {
  let #(field, st) = fresh(st)
  let st =
    State(..st, pending: [
      PendingField(container_type, label, field),
      ..st.pending
    ])
  Ok(#(field, Field, st))
}

// Field access where the container names a bound value: prefer a record field
// when the value's type has it, else a same-named module export.
fn value_field(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
  module_access: Result(#(String, Scheme), Nil),
) -> Result(#(Type, Access, State), Error) {
  use #(container_type, st) <- result.try(infer_expr(env, st, container))
  case resolve(st, container_type) {
    Named(_, _, _) as record ->
      case accessor(env, record, label) {
        Ok(_) -> {
          use #(field, st) <- result.try(field_type(env, st, record, label))
          Ok(#(field, Field, st))
        }
        // Not a field of this record; a same-named module may export it.
        Error(field_error) ->
          case module_access {
            Ok(export) -> module_export(st, export)
            Error(_) -> Error(field_error)
          }
      }
    // The record type is not known yet. Prefer a same-named module export;
    // otherwise defer until inference fixes the type.
    Var(_) ->
      case module_access {
        Ok(export) -> module_export(st, export)
        Error(_) -> pending_field(st, container_type, label)
      }
    _ ->
      case module_access {
        Ok(export) -> module_export(st, export)
        Error(_) -> Error(NotARecord)
      }
  }
}

// Field access where the container is not a bound value: a qualified module
// export takes precedence, else it is a record field on the container's value.
fn module_or_record(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
  module_access: Result(#(String, Scheme), Nil),
) -> Result(#(Type, Access, State), Error) {
  case module_access {
    Ok(export) -> module_export(st, export)
    Error(_) -> {
      use #(container_type, st) <- result.try(infer_expr(env, st, container))
      case resolve(st, container_type) {
        Named(_, _, _) as record -> {
          use #(field, st) <- result.try(field_type(env, st, record, label))
          Ok(#(field, Field, st))
        }
        Var(_) -> pending_field(st, container_type, label)
        _ -> Error(NotARecord)
      }
    }
  }
}

// Resolve `record.label` for a known record type, returning the field type.
fn field_type(
  env: Env,
  st: State,
  record: Type,
  label: String,
) -> Result(#(Type, State), Error) {
  // Resolve through the substitution: a caller may pass a variable that has
  // since been bound to the record type (e.g. record-update's kept fields).
  use accessor_scheme <- result.try(accessor(env, resolve(st, record), label))
  let #(accessor_type, st) = instantiate(st, accessor_scheme)
  let #(field, st) = fresh(st)
  use st <- result.try(unify(st, accessor_type, Fn([record], field)))
  Ok(#(field, st))
}

fn infer_record_update(
  env: Env,
  st: State,
  module: Option(String),
  constructor: String,
  record: glance.Expression,
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> Result(#(Type, State), Error) {
  // A record update produces a *fresh* value of the type: updated fields take
  // their new value's type and kept fields are copied from the record. This is
  // what lets an update change a type parameter, as in
  // `Request(..req, body:)` : `fn(Request(a), b) -> Request(b)` — the kept
  // fields tie only the parameters they share, not all of them.
  use scheme <- result.try(constructor_scheme(env, module, constructor))
  let #(ctor_type, st) = instantiate(st, scheme)
  let #(field_types, return_type) = case ctor_type {
    Fn(arguments, return) -> #(arguments, return)
    other -> #([], other)
  }
  case return_type {
    Named(type_module, type_name, type_parameters) -> {
      let labels = constructor_field_map(env, module, constructor)
      let label_types =
        list.fold(list.zip(labels, field_types), dict.new(), fn(acc, pair) {
          case pair.0 {
            Some(label) -> dict.insert(acc, label, pair.1)
            None -> acc
          }
        })
      let updated = list.map(fields, fn(field) { field.label })

      // Fix the record's head to this type with independent parameters, so its
      // own type variables aren't conflated with the result's.
      let #(record_parameters, st) = fresh_n(st, list.length(type_parameters))
      use #(record_type, st) <- result.try(infer_expr(env, st, record))
      use st <- result.try(unify(
        st,
        record_type,
        Named(type_module, type_name, record_parameters),
      ))

      // Updated fields take their new value's type.
      use st <- result.try(
        list.try_fold(fields, st, fn(st, field) {
          update_field(env, st, field, label_types, type_name)
        }),
      )

      // Kept fields are copied from the record. The record carries the same
      // constructor, so each kept field's type is the constructor's field type
      // with the result's parameters swapped for the record's. Unifying the two
      // ties only the parameters a kept field actually uses, which is what lets
      // an *updated* field change a parameter. Deriving this from the named
      // constructor (rather than a field accessor) means it works even for
      // fields not shared by every variant of a multi-variant type.
      let to_record_params =
        dict.from_list(list.zip(
          list.filter_map(type_parameters, var_id),
          record_parameters,
        ))
      use st <- result.try(
        list.try_fold(dict.to_list(label_types), st, fn(st, pair) {
          let #(label, expected) = pair
          case list.contains(updated, label) {
            True -> Ok(st)
            False -> unify(st, substitute(to_record_params, expected), expected)
          }
        }),
      )

      Ok(#(return_type, st))
    }
    _ -> Error(NotARecord)
  }
}

// The per-position labels of a constructor, looked up locally or in the module
// that defines it.
fn constructor_field_map(
  env: Env,
  module: Option(String),
  constructor: String,
) -> List(Option(String)) {
  let maps = case module {
    Some(alias) ->
      case dict.get(env.modules, alias) {
        Ok(interface) -> interface.field_maps
        Error(_) -> env.field_maps
      }
    None -> env.field_maps
  }
  case dict.get(maps, constructor) {
    Ok(labels) -> labels
    Error(_) -> []
  }
}

// If `expr` is a direct constructor call (`Ctor(..)` or `module.Ctor(..)`),
// its `#(module, constructor)`. Constructors are recognised by their leading
// upper-case letter, the Gleam naming convention.
fn constructor_call(
  expr: glance.Expression,
) -> Result(#(Option(String), String), Nil) {
  let callee = case expr {
    glance.Call(_, function, _) -> function
    _ -> expr
  }
  case callee {
    glance.Variable(_, name) ->
      case is_upper(name) {
        True -> Ok(#(None, name))
        False -> Error(Nil)
      }
    glance.FieldAccess(_, glance.Variable(_, module), name) ->
      case is_upper(name) {
        True -> Ok(#(Some(module), name))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn is_upper(name: String) -> Bool {
  case string.first(name) {
    Ok(c) -> string.uppercase(c) == c && string.lowercase(c) != c
    Error(_) -> False
  }
}

// A variable narrowed to one constructor variant: the constructor as written
// in the pattern, and that variant's `label -> field type` for the bound
// value.
type Narrowed {
  Narrowed(constructor: #(Option(String), String), fields: Dict(String, Type))
}

// Record, for a variable bound by `Ctor(..) as name`, that variant's labelled
// fields with types tied to `value_type` (the variable's own type). Later
// `name.field` reads from this even when the field is absent from other
// variants. Best-effort: on any failure the environment is left unchanged.
fn record_variant(
  env: Env,
  st: State,
  module: Option(String),
  constructor: String,
  value_type: Type,
  name: String,
) -> #(Env, State) {
  let recorded = {
    use scheme <- result.try(constructor_scheme(env, module, constructor))
    let #(ctor_type, st) = instantiate(st, scheme)
    let #(field_types, ret) = case ctor_type {
      Fn(args, ret) -> #(args, ret)
      other -> #([], other)
    }
    // Tie this fresh instance to the variable's actual type so the recorded
    // field types resolve correctly later.
    use st <- result.try(unify(st, value_type, ret))
    let labels = constructor_field_map(env, module, constructor)
    let fields =
      list.fold(list.zip(labels, field_types), dict.new(), fn(acc, pair) {
        case pair.0 {
          Some(label) -> dict.insert(acc, label, resolve(st, pair.1))
          None -> acc
        }
      })
    Ok(#(fields, st))
  }
  case recorded {
    Ok(#(fields, st)) -> {
      let narrowed = Narrowed(constructor: #(module, constructor), fields:)
      #(Env(..env, variants: dict.insert(env.variants, name, narrowed)), st)
    }
    Error(_) -> #(env, st)
  }
}

fn infer_each(
  env: Env,
  st: State,
  exprs: List(glance.Expression),
) -> Result(#(List(Type), State), Error) {
  use #(rev, st) <- result.try(
    list.try_fold(exprs, #([], st), fn(acc, e) {
      let #(types_, st) = acc
      use #(t, st) <- result.try(infer_expr(env, st, e))
      Ok(#([t, ..types_], st))
    }),
  )
  Ok(#(list.reverse(rev), st))
}

fn infer_fn(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
) -> Result(#(Type, State), Error) {
  // Map each type-variable name written in the lambda's annotations to ONE
  // fresh variable, shared across every parameter and the return. A name like
  // `a` in `fn(msg: Message(a, b)) -> Next(_, Message(a, b))` denotes a single
  // type within the signature; without this, each annotation hydrates its own
  // `a` and the two stay distinct whenever the body does not tie them (an actor
  // handler whose returned message type is otherwise free). The lambda itself
  // stays monomorphic — only the names are shared, not generalized.
  let #(names, st) =
    list.fold(
      list.unique(fn_annotation_var_names(params, return_annotation)),
      #(dict.new(), st),
      fn(acc, nm) {
        let #(names, st) = acc
        let #(id, st) = fresh_id(st)
        #(dict.insert(names, nm, Var(id)), st)
      },
    )
  // No expected type: each parameter starts as a fresh variable.
  let #(seeds, st) = fresh_n(st, list.length(params))
  infer_lambda(env, st, params, return_annotation, body, seeds, None, names)
}

// Infer a lambda whose parameters are seeded with `seed_params` (the expected
// argument types when known, otherwise fresh variables) and whose body is
// optionally checked against `expected_return`.
fn infer_lambda(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
  seed_params: List(Type),
  expected_return: Option(Type),
  // Pre-seeded type-variable names (name -> Var). When a `let`-bound function is
  // generalized over its explicit annotation variables, those share these ids
  // across every annotation in the lambda; otherwise this is empty.
  names: Dict(String, Type),
) -> Result(#(Type, State), Error) {
  use #(rev_param_types, body_env, st) <- result.try(
    list.try_fold(list.zip(params, seed_params), #([], env, st), fn(acc, pair) {
      let #(types_, env, st) = acc
      let #(param, seed) = pair
      use #(t, st) <- result.try(case param.type_ {
        Some(ann) -> {
          let #(annotated, st) = hydrate_in(env, names, st, ann)
          use st <- result.try(unify(st, annotated, seed))
          Ok(#(seed, st))
        }
        None -> Ok(#(seed, st))
      })
      let env = case param.name {
        glance.Named(name) -> bind_value(env, name, Scheme([], t))
        glance.Discarded(_) -> env
      }
      Ok(#([t, ..types_], env, st))
    }),
  )
  let param_types = list.reverse(rev_param_types)
  use #(body_type, st) <- result.try(infer_statements(body_env, st, body))
  use st <- result.try(case return_annotation {
    Some(ann) -> {
      let #(t, st) = hydrate_in(env, names, st, ann)
      unify(st, body_type, t)
    }
    None -> Ok(st)
  })
  use st <- result.try(case expected_return {
    Some(expected) -> unify(st, body_type, expected)
    None -> Ok(st)
  })
  Ok(#(Fn(param_types, body_type), st))
}

// Infer the callee of a call, returning its type and its field map when one
// is known. A `name.label` callee resolves exactly as a projection does,
// through `infer_field_access`, and its field map follows the branch that
// won: a module export's own map, or none at all for a record field — the
// compiler's `RecordAccess` has no field map, so a call on a field accepts no
// labelled arguments even when a same-named module exports a labelled
// function under that label. A bare name takes the map registered for it.
fn infer_callee(
  env: Env,
  st: State,
  function: glance.Expression,
) -> Result(#(Type, Result(List(Option(String)), Nil), State), Error) {
  case function {
    glance.FieldAccess(_, glance.Variable(_, _) as container, label) -> {
      use #(type_, access, st) <- result.try(infer_field_access(
        env,
        st,
        container,
        label,
      ))
      let labels = case access {
        Export(alias) -> module_field_map(env, alias, label)
        Field -> Error(Nil)
      }
      Ok(#(type_, labels, record(st, span(function), type_)))
    }
    glance.Variable(_, name) -> {
      use #(type_, st) <- result.try(infer_expr(env, st, function))
      Ok(#(type_, dict.get(env.field_maps, name), st))
    }
    _ -> {
      use #(type_, st) <- result.try(infer_expr(env, st, function))
      Ok(#(type_, Error(Nil), st))
    }
  }
}

// The field map of the export `label` of the module bound to `alias`.
fn module_field_map(
  env: Env,
  alias: String,
  label: String,
) -> Result(List(Option(String)), Nil) {
  use interface <- result.try(dict.get(env.modules, alias))
  dict.get(interface.field_maps, label)
}

fn infer_call(
  env: Env,
  st: State,
  span: glance.Span,
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> Result(#(Type, State), Error) {
  use #(fn_type, labels, st) <- result.try(infer_callee(env, st, function))
  use ordered <- result.try(
    order_fields(labels, arguments, fn(label, location) {
      glance.Variable(location, label)
    }),
  )
  // Unify the callee with a function shape first, so each argument's expected
  // type is known before it is checked. This lets a lambda argument's body see
  // the types of its parameters (bidirectional checking) — e.g. the callback
  // in `list.map(rows, fn(row) { row.field })`.
  let #(arg_holes, st) = fresh_n(st, list.length(ordered))
  let #(result, st) = fresh(st)
  use st <- result.try(unify(st, fn_type, Fn(arg_holes, result)))
  // Arguments are checked left to right, so types flowing from earlier
  // arguments (e.g. the list element type) constrain later ones (the callback).
  use st <- result.try(
    list.try_fold(list.zip(ordered, arg_holes), st, fn(st, pair) {
      check(env, st, pair.0, pair.1)
    }),
  )
  Ok(#(result, record(st, span, result)))
}

fn fresh_n(st: State, n: Int) -> #(List(Type), State) {
  use <- bool.guard(when: n <= 0, return: #([], st))
  let #(t, st) = fresh(st)
  let #(rest, st) = fresh_n(st, n - 1)
  #([t, ..rest], st)
}

fn field_item(field: glance.Field(glance.Expression)) -> glance.Expression {
  case field {
    glance.UnlabelledField(item) -> item
    glance.LabelledField(_, _, item) -> item
    glance.ShorthandField(label, location) -> glance.Variable(location, label)
  }
}

// Reorder labelled/shorthand call or pattern arguments into positional order
// using the callee's field map. If every argument is positional we don't need
// the field map (this also covers calls to anonymous functions).
fn order_fields(
  labels: Result(List(Option(String)), Nil),
  fields: List(glance.Field(t)),
  shorthand: fn(String, glance.Span) -> t,
) -> Result(List(t), Error) {
  // All-unlabelled is the fast path: keep the fields in order.
  use <- bool.lazy_guard(when: list.all(fields, is_unlabelled), return: fn() {
    Ok(
      list.filter_map(fields, fn(field) {
        case field {
          glance.UnlabelledField(item) -> Ok(item)
          _ -> Error(Nil)
        }
      }),
    )
  })
  case labels {
    Ok(labels) -> reorder(fields, labels, shorthand)
    Error(_) -> Error(AmbiguousCall)
  }
}

fn label_indices(labels: List(Option(String))) -> Dict(String, Int) {
  list.index_fold(labels, dict.new(), fn(acc, label, index) {
    case label {
      Some(name) -> dict.insert(acc, name, index)
      None -> acc
    }
  })
}

fn is_unlabelled(field: glance.Field(t)) -> Bool {
  case field {
    glance.UnlabelledField(..) -> True
    _ -> False
  }
}

fn reorder(
  fields: List(glance.Field(t)),
  labels: List(Option(String)),
  shorthand: fn(String, glance.Span) -> t,
) -> Result(List(t), Error) {
  let index_of = label_indices(labels)
  // Labelled and shorthand arguments are placed at their declared index;
  // positional arguments then fill the remaining positions in order.
  use labelled <- result.try(
    list.try_fold(fields, dict.new(), fn(placed, field) {
      case field {
        glance.UnlabelledField(..) -> Ok(placed)
        glance.LabelledField(label, _, item) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, item))
        }
        glance.ShorthandField(label, location) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, shorthand(label, location)))
        }
      }
    }),
  )
  let positional =
    list.filter_map(fields, fn(field) {
      case field {
        glance.UnlabelledField(item) -> Ok(item)
        _ -> Error(Nil)
      }
    })
  let free =
    list.filter(indices(list.length(labels)), fn(i) {
      !dict.has_key(labelled, i)
    })
  let placed =
    list.fold(list.zip(free, positional), labelled, fn(placed, pair) {
      dict.insert(placed, pair.0, pair.1)
    })
  list.try_map(indices(list.length(labels)), fn(index) {
    case dict.get(placed, index) {
      Ok(item) -> Ok(item)
      Error(_) -> Error(MissingArgument)
    }
  })
}

fn label_index(
  index_of: Dict(String, Int),
  label: String,
) -> Result(Int, Error) {
  case dict.get(index_of, label) {
    Ok(index) -> Ok(index)
    Error(_) -> Error(UnknownLabel(label))
  }
}

// Infer one call argument, accumulating labelled arguments by their position
// index and positional ones (reversed) for the free slots.
fn classify_call_arg(
  env: Env,
  index_of: Dict(String, Int),
  acc: #(Dict(Int, Type), List(Type), State),
  field: glance.Field(glance.Expression),
) -> Result(#(Dict(Int, Type), List(Type), State), Error) {
  let #(labelled, positional, st) = acc
  case field {
    glance.UnlabelledField(item) -> {
      use #(t, st) <- result.try(infer_expr(env, st, item))
      Ok(#(labelled, [t, ..positional], st))
    }
    glance.LabelledField(label, _, item) -> {
      use index <- result.try(label_index(index_of, label))
      use #(t, st) <- result.try(infer_expr(env, st, item))
      Ok(#(dict.insert(labelled, index, t), positional, st))
    }
    glance.ShorthandField(label, location) -> {
      use index <- result.try(label_index(index_of, label))
      use #(t, st) <- result.try(infer_expr(
        env,
        st,
        glance.Variable(location, label),
      ))
      Ok(#(dict.insert(labelled, index, t), positional, st))
    }
  }
}

fn infer_capture(
  env: Env,
  st: State,
  span: glance.Span,
  label: Option(String),
  function: glance.Expression,
  before: List(glance.Field(glance.Expression)),
  after: List(glance.Field(glance.Expression)),
) -> Result(#(Type, State), Error) {
  // `f(a, _, b)` becomes `fn(x) { f(a, x, b) }`. The hole and the surrounding
  // arguments are reordered into the callee's positional order exactly as a
  // direct call would be — labels (including the hole's own, `value: _`) move
  // each argument to its declared slot, so a labelled hole lands in the right
  // parameter even when it is written out of order.
  let #(hole, st) = fresh(st)
  use #(fn_type, labels, st) <- result.try(infer_callee(env, st, function))
  use #(before_typed, st) <- result.try(infer_fields_typed(env, st, before))
  use #(after_typed, st) <- result.try(infer_fields_typed(env, st, after))
  let hole_field = case label {
    Some(name) -> glance.LabelledField(name, span, hole)
    None -> glance.UnlabelledField(hole)
  }
  let fields = list.flatten([before_typed, [hole_field], after_typed])
  // Fields are already typed, so the shorthand materializer is never invoked.
  use arg_types <- result.try(order_fields(labels, fields, fn(_, _) { hole }))
  let #(result, st) = fresh(st)
  use st <- result.try(unify(st, fn_type, Fn(arg_types, result)))
  let captured = Fn([hole], result)
  Ok(#(captured, record(st, span, captured)))
}

// Infer each call field's value, keeping its label so the arguments can be
// reordered into positional order. Shorthand fields (`label:`) are resolved to
// the in-scope `label` and recorded as labelled.
fn infer_fields_typed(
  env: Env,
  st: State,
  fields: List(glance.Field(glance.Expression)),
) -> Result(#(List(glance.Field(Type)), State), Error) {
  use #(rev, st) <- result.try(
    list.try_fold(fields, #([], st), fn(acc, field) {
      let #(typed, st) = acc
      case field {
        glance.UnlabelledField(item) -> {
          use #(t, st) <- result.try(infer_expr(env, st, item))
          Ok(#([glance.UnlabelledField(t), ..typed], st))
        }
        glance.LabelledField(label, location, item) -> {
          use #(t, st) <- result.try(infer_expr(env, st, item))
          Ok(#([glance.LabelledField(label, location, t), ..typed], st))
        }
        glance.ShorthandField(label, location) -> {
          use #(t, st) <- result.try(infer_expr(
            env,
            st,
            glance.Variable(location, label),
          ))
          Ok(#([glance.LabelledField(label, location, t), ..typed], st))
        }
      }
    }),
  )
  Ok(#(list.reverse(rev), st))
}

fn infer_binop(
  env: Env,
  st: State,
  span: glance.Span,
  op: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(Type, State), Error) {
  case op {
    glance.Pipe -> infer_pipe(env, st, span, left, right)

    glance.And | glance.Or -> {
      use st <- result.try(check(env, st, left, prelude_bool()))
      use st <- result.try(check(env, st, right, prelude_bool()))
      Ok(#(prelude_bool(), st))
    }

    glance.Eq | glance.NotEq -> {
      use #(lt, st) <- result.try(infer_expr(env, st, left))
      use #(rt, st) <- result.try(infer_expr(env, st, right))
      use st <- result.try(unify(st, lt, rt))
      Ok(#(prelude_bool(), st))
    }

    glance.Concatenate -> {
      use st <- result.try(check(env, st, left, prelude_string()))
      use st <- result.try(check(env, st, right, prelude_string()))
      Ok(#(prelude_string(), st))
    }

    glance.AddInt
    | glance.SubInt
    | glance.MultInt
    | glance.DivInt
    | glance.RemainderInt -> {
      use st <- result.try(check(env, st, left, prelude_int()))
      use st <- result.try(check(env, st, right, prelude_int()))
      Ok(#(prelude_int(), st))
    }

    glance.AddFloat | glance.SubFloat | glance.MultFloat | glance.DivFloat -> {
      use st <- result.try(check(env, st, left, prelude_float()))
      use st <- result.try(check(env, st, right, prelude_float()))
      Ok(#(prelude_float(), st))
    }

    glance.LtInt | glance.LtEqInt | glance.GtInt | glance.GtEqInt -> {
      use st <- result.try(check(env, st, left, prelude_int()))
      use st <- result.try(check(env, st, right, prelude_int()))
      Ok(#(prelude_bool(), st))
    }

    glance.LtFloat | glance.LtEqFloat | glance.GtFloat | glance.GtEqFloat -> {
      use st <- result.try(check(env, st, left, prelude_float()))
      use st <- result.try(check(env, st, right, prelude_float()))
      Ok(#(prelude_bool(), st))
    }
  }
}

fn infer_pipe(
  env: Env,
  st: State,
  span: glance.Span,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(Type, State), Error) {
  case right {
    glance.Call(call_span, function, arguments) -> {
      // `left |> f(args)` is `f(left, args)` when `f` takes one more argument
      // than is supplied. But if `f(args)` is already a saturated call that
      // returns a function, the pipe applies `left` to that result:
      // `f(args)(left)`. Distinguish on the callee's arity.
      use #(ft, st) <- result.try(infer_expr(env, st, function))
      let saturated = case resolve(st, ft) {
        Fn(params, _) -> list.length(params) == list.length(arguments)
        _ -> False
      }
      case saturated {
        True -> {
          use #(call_type, st) <- result.try(infer_call(
            env,
            st,
            call_span,
            function,
            arguments,
          ))
          use #(lt, st) <- result.try(infer_expr(env, st, left))
          let #(result, st) = fresh(st)
          use st <- result.try(unify(st, call_type, Fn([lt], result)))
          Ok(#(result, record(st, span, result)))
        }
        False ->
          infer_call(env, st, call_span, function, [
            glance.UnlabelledField(left),
            ..arguments
          ])
      }
    }
    // `left |> f` becomes `f(left)`.
    _ -> {
      use #(lt, st) <- result.try(infer_expr(env, st, left))
      use #(ft, st) <- result.try(infer_expr(env, st, right))
      let #(result, st) = fresh(st)
      use st <- result.try(unify(st, ft, Fn([lt], result)))
      Ok(#(result, record(st, span, result)))
    }
  }
}

// Infer an expression and unify it against an expected type. A lambda is
// checked against the expected type so its parameters are seeded from the
// expected argument types before its body is inferred.
fn check(
  env: Env,
  st: State,
  expr: glance.Expression,
  expected: Type,
) -> Result(State, Error) {
  let seeded = case expr {
    glance.Fn(_, params, _, _) ->
      case resolve(st, expected) {
        Fn(expected_params, expected_return) ->
          case list.length(expected_params) == list.length(params) {
            True -> Ok(#(expected_params, expected_return))
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case expr, seeded {
    glance.Fn(span, params, return_annotation, body), Ok(#(seeds, ret)) -> {
      use #(fn_type, st) <- result.try(infer_lambda(
        env,
        st,
        params,
        return_annotation,
        body,
        seeds,
        Some(ret),
        dict.new(),
      ))
      let st = record(st, span, fn_type)
      unify(st, fn_type, expected)
    }
    _, _ -> {
      use #(t, st) <- result.try(infer_expr(env, st, expr))
      unify(st, t, expected)
    }
  }
}

// Statements
//
// Infer a block's statements in sequence, threading the environment, and
// desugar `use` into the trailing-callback call it stands for.

fn infer_statements(
  env: Env,
  st: State,
  statements: List(glance.Statement),
) -> Result(#(Type, State), Error) {
  case statements {
    [] -> Ok(#(prelude_nil(), st))
    // `use pats <- rhs` turns the remaining statements into a trailing callback.
    [glance.Use(_, patterns, function), ..rest] ->
      infer_use(env, st, patterns, function, rest)
    [last] -> {
      use #(t, _env, st) <- result.try(infer_statement(env, st, last))
      Ok(#(t, st))
    }
    [first, ..rest] -> {
      use #(_t, env, st) <- result.try(infer_statement(env, st, first))
      infer_statements(env, st, rest)
    }
  }
}

// Desugar `use a, b <- rhs` followed by `rest` into `rhs(.., fn(a, b) { rest })`
// and infer the resulting call.
fn infer_use(
  env: Env,
  st: State,
  use_patterns: List(glance.UsePattern),
  function: glance.Expression,
  rest: List(glance.Statement),
) -> Result(#(Type, State), Error) {
  // Build the callback: its parameters are the use patterns, its body is the
  // rest of the block.
  use #(rev_param_types, callback_env, st) <- result.try(
    list.try_fold(use_patterns, #([], env, st), fn(acc, use_pattern) {
      let #(types_, env, st) = acc
      let #(param, st) = case use_pattern.annotation {
        Some(ann) -> hydrate(env, st, ann)
        None -> fresh(st)
      }
      use #(env, st) <- result.try(infer_pattern(
        env,
        st,
        use_pattern.pattern,
        param,
      ))
      Ok(#([param, ..types_], env, st))
    }),
  )
  let param_types = list.reverse(rev_param_types)
  use #(body_type, st) <- result.try(infer_statements(callback_env, st, rest))
  let callback_type = Fn(param_types, body_type)

  // The right-hand side is called with the callback as its final argument.
  let #(result, st) = fresh(st)
  use st <- result.try(case function {
    glance.Call(_, callee, arguments) ->
      infer_use_call(env, st, callee, arguments, callback_type, result)
    other -> {
      use #(callee_type, st) <- result.try(infer_expr(env, st, other))
      unify(st, callee_type, Fn([callback_type], result))
    }
  })
  Ok(#(result, st))
}

// Infer `use ... <- callee(args)`: the callback is the final positional
// argument. When the explicit arguments are all positional we simply append
// the callback; when some are labelled we place them by their field map and
// the callback fills the remaining slot (e.g. the `otherwise` of `bool.guard`).
fn infer_use_call(
  env: Env,
  st: State,
  callee: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
  callback_type: Type,
  result: Type,
) -> Result(State, Error) {
  use #(callee_type, field_map, st) <- result.try(infer_callee(env, st, callee))
  case list.all(arguments, is_unlabelled) {
    True -> {
      use #(arg_types, st) <- result.try(infer_each(
        env,
        st,
        list.map(arguments, field_item),
      ))
      unify(
        st,
        callee_type,
        Fn(list.append(arg_types, [callback_type]), result),
      )
    }
    False -> {
      use labels <- result.try(result.replace_error(field_map, AmbiguousCall))
      let index_of = label_indices(labels)
      // Infer the explicit arguments, splitting labelled (placed by index) from
      // positional (which, with the trailing callback, fill the free slots).
      use #(labelled, rev_positional, st) <- result.try(
        list.try_fold(arguments, #(dict.new(), [], st), fn(acc, field) {
          classify_call_arg(env, index_of, acc, field)
        }),
      )
      let trailing = list.append(list.reverse(rev_positional), [callback_type])
      let free =
        list.filter(indices(list.length(labels)), fn(i) {
          !dict.has_key(labelled, i)
        })
      let placed =
        list.fold(list.zip(free, trailing), labelled, fn(placed, pair) {
          dict.insert(placed, pair.0, pair.1)
        })
      use arg_types <- result.try(
        list.try_map(indices(list.length(labels)), fn(index) {
          result.replace_error(dict.get(placed, index), MissingArgument)
        }),
      )
      unify(st, callee_type, Fn(arg_types, result))
    }
  }
}

// Infer one statement, returning its type and the (possibly extended)
// environment to thread to following statements.
fn infer_statement(
  env: Env,
  st: State,
  statement: glance.Statement,
) -> Result(#(Type, Env, State), Error) {
  case statement {
    glance.Expression(expr) -> {
      use #(t, st) <- result.try(infer_expr(env, st, expr))
      Ok(#(t, env, st))
    }

    // `let name = fn(...)` whose annotations name type variables is generalized
    // over exactly those variables — Gleam makes such a local binding
    // polymorphic (`let id = fn(x: a) -> a { x }` may then be used at several
    // types), unlike an unannotated `let id = fn(x) { x }`, which stays
    // monomorphic.
    glance.Assignment(
      _,
      _kind,
      glance.PatternVariable(_, name) as pattern,
      None,
      glance.Fn(fspan, fparams, freturn, fbody) as value,
    ) ->
      case fn_annotation_var_names(fparams, freturn) {
        [] -> infer_expr_assignment(env, st, pattern, None, value)
        ann_names -> {
          let #(names, ann_ids, st) =
            list.fold(ann_names, #(dict.new(), [], st), fn(acc, nm) {
              let #(names, ids, st) = acc
              let #(id, st) = fresh_id(st)
              #(dict.insert(names, nm, Var(id)), [id, ..ids], st)
            })
          let #(seeds, st) = fresh_n(st, list.length(fparams))
          use #(value_type, st) <- result.try(infer_lambda(
            env,
            st,
            fparams,
            freturn,
            fbody,
            seeds,
            None,
            names,
          ))
          let st = record(st, fspan, value_type)
          let scheme = generalize_over(st, env, value_type, ann_ids)
          Ok(#(value_type, bind_value(env, name, scheme), st))
        }
      }

    glance.Assignment(_, _kind, pattern, annotation, value) ->
      infer_expr_assignment(env, st, pattern, annotation, value)

    glance.Assert(_, expression, _message) -> {
      use st <- result.try(check(env, st, expression, prelude_bool()))
      Ok(#(prelude_nil(), env, st))
    }

    // `use` is handled by infer_statements before reaching here.
    glance.Use(..) -> Error(Unsupported("use in non-tail position"))
  }
}

// The general `let pattern = value` case: infer the value, optionally check it
// against the binding's annotation, then bind the pattern monomorphically.
fn infer_expr_assignment(
  env: Env,
  st: State,
  pattern: glance.Pattern,
  annotation: Option(glance.Type),
  value: glance.Expression,
) -> Result(#(Type, Env, State), Error) {
  use #(value_type, st) <- result.try(infer_expr(env, st, value))
  use st <- result.try(case annotation {
    Some(ann) -> {
      let #(t, st) = hydrate(env, st, ann)
      unify(st, value_type, t)
    }
    None -> Ok(st)
  })
  use #(env, st) <- result.try(infer_pattern(env, st, pattern, value_type))
  // Inferred-variant narrowing, so a later `x.field` reaches a field present in
  // only one variant.
  let #(env, st) = case pattern, value {
    // `let x = Ctor(..)`: the constructed variant narrows `x`.
    glance.PatternVariable(_, name), _ ->
      case constructor_call(value) {
        Ok(#(module, constructor)) ->
          record_variant(env, st, module, constructor, value_type, name)
        Error(_) -> #(env, st)
      }
    // `let Ctor(..) = x` / `let assert Ctor(..) = x`: matching a variant pattern
    // against a bare variable narrows that variable to the variant.
    glance.PatternVariant(_, module, constructor, _, _),
      glance.Variable(_, name)
    -> record_variant(env, st, module, constructor, value_type, name)
    _, _ -> #(env, st)
  }
  Ok(#(value_type, env, st))
}

// Case expressions
//
// Infer a `case`: unify every clause's patterns against the subjects and
// every clause body against a shared result type, narrowing a matched
// subject variable to its variant.

fn infer_case(
  env: Env,
  st: State,
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
) -> Result(#(Type, State), Error) {
  use #(subject_types, st) <- result.try(infer_each(env, st, subjects))
  let #(result, st) = fresh(st)
  use st <- result.try(
    list.try_fold(clauses, st, fn(st, clause) {
      infer_clause(env, st, clause, subjects, subject_types, result)
    }),
  )
  Ok(#(result, st))
}

fn infer_clause(
  env: Env,
  st: State,
  clause: glance.Clause,
  subjects: List(glance.Expression),
  subject_types: List(Type),
  result: Type,
) -> Result(State, Error) {
  // Each clause may have several alternative pattern lists (`a | b ->`); each
  // binds the same variables and is checked against the subject types. Every
  // alternative is bound first, so the narrowings they disagree on can be
  // dropped before the guard and body are checked under each of them.
  use #(rev_envs, st) <- result.try(
    list.try_fold(clause.patterns, #([], st), fn(acc, patterns) {
      let #(envs, st) = acc
      use #(clause_env, st) <- result.try(bind_alternative(
        env,
        st,
        patterns,
        subjects,
        subject_types,
      ))
      Ok(#([clause_env, ..envs], st))
    }),
  )
  use st <- result.try(
    list.try_fold(
      agree_variants(list.reverse(rev_envs)),
      st,
      fn(st, clause_env) {
        use st <- result.try(case clause.guard {
          Some(guard) -> check(clause_env, st, guard, prelude_bool())
          None -> Ok(st)
        })
        use #(body_type, st) <- result.try(infer_expr(
          clause_env,
          st,
          clause.body,
        ))
        unify(st, body_type, result)
      },
    ),
  )
  Ok(st)
}

// Bind one alternative's patterns against the subjects, narrowing any bare
// subject variable a variant pattern matches.
fn bind_alternative(
  env: Env,
  st: State,
  patterns: List(glance.Pattern),
  subjects: List(glance.Expression),
  subject_types: List(Type),
) -> Result(#(Env, State), Error) {
  list.try_fold(
    list.zip(patterns, list.zip(subjects, subject_types)),
    #(env, st),
    fn(acc, pair) {
      let #(env, st) = acc
      let #(pattern, #(subject, subject_type)) = pair
      use #(env, st) <- result.try(infer_pattern(env, st, pattern, subject_type))
      // When a clause matches a bare subject variable against a variant
      // pattern, that variable is narrowed to the variant within the clause
      // (the compiler's inferred-variant narrowing), so its non-shared
      // fields become accessible.
      case subject, pattern {
        glance.Variable(_, name),
          glance.PatternVariant(_, module, constructor, _, _)
        -> Ok(record_variant(env, st, module, constructor, subject_type, name))
        _, _ -> Ok(#(env, st))
      }
    },
  )
}

// Alternative patterns bind the same names, and the compiler keeps a
// variable's inferred variant only when every alternative infers the same
// one: `Loud(..) as io | Quiet(..) as io` narrows `io` to nothing. Keep a
// narrowing only where every alternative records the same constructor for
// the name, so the body reads the others un-narrowed under each alternative.
fn agree_variants(envs: List(Env)) -> List(Env) {
  case envs {
    [] | [_] -> envs
    [first, ..] -> {
      let agreed =
        dict.filter(first.variants, fn(name, narrowed) {
          list.all(envs, fn(env) {
            case dict.get(env.variants, name) {
              Ok(other) -> other.constructor == narrowed.constructor
              Error(_) -> False
            }
          })
        })
      list.map(envs, fn(env) {
        Env(
          ..env,
          variants: dict.filter(env.variants, fn(name, _) {
            dict.has_key(agreed, name)
          }),
        )
      })
    }
  }
}

// Patterns
//
// Infer a pattern against its expected type, binding the variables it
// introduces — constructor, list, tuple, string-prefix and bit-array
// patterns included.

fn infer_pattern(
  env: Env,
  st: State,
  pattern: glance.Pattern,
  expected: Type,
) -> Result(#(Env, State), Error) {
  case pattern {
    glance.PatternInt(..) -> with_env(env, unify(st, expected, prelude_int()))
    glance.PatternFloat(..) ->
      with_env(env, unify(st, expected, prelude_float()))
    glance.PatternString(..) ->
      with_env(env, unify(st, expected, prelude_string()))
    glance.PatternDiscard(..) -> Ok(#(env, st))

    glance.PatternVariable(_, name) ->
      Ok(#(bind_value(env, name, Scheme([], expected)), st))

    glance.PatternTuple(_, elements) -> {
      let #(elem_types, st) =
        list.fold(elements, #([], st), fn(acc, _) {
          let #(types_, st) = acc
          let #(t, st) = fresh(st)
          #([t, ..types_], st)
        })
      let elem_types = list.reverse(elem_types)
      use st <- result.try(unify(st, expected, Tuple(elem_types)))
      list.try_fold(list.zip(elements, elem_types), #(env, st), fn(acc, pair) {
        let #(env, st) = acc
        let #(pattern, t) = pair
        infer_pattern(env, st, pattern, t)
      })
    }

    glance.PatternList(_, elements, tail) -> {
      let #(elem, st) = fresh(st)
      use st <- result.try(unify(st, expected, prelude_list(elem)))
      use #(env, st) <- result.try(
        list.try_fold(elements, #(env, st), fn(acc, p) {
          let #(env, st) = acc
          infer_pattern(env, st, p, elem)
        }),
      )
      case tail {
        Some(t) -> infer_pattern(env, st, t, prelude_list(elem))
        None -> Ok(#(env, st))
      }
    }

    glance.PatternAssignment(_, pattern, name) -> {
      let env = bind_value(env, name, Scheme([], expected))
      // `Ctor(..) as name` narrows `name` to that variant: record the variant's
      // fields so a later `name.field` reaches fields present only in it.
      let #(env, st) = case pattern {
        glance.PatternVariant(_, module, constructor, _, _) ->
          record_variant(env, st, module, constructor, expected, name)
        _ -> #(env, st)
      }
      infer_pattern(env, st, pattern, expected)
    }

    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) -> {
      use st <- result.try(unify(st, expected, prelude_string()))
      // Both the matched prefix (`"a" as c <> rest`) and the remainder bind to
      // String. The prefix binding is optional (`<> rest` with no `as`).
      let bind_name = fn(env, name) {
        case name {
          glance.Named(n) -> bind_value(env, n, Scheme([], prelude_string()))
          glance.Discarded(_) -> env
        }
      }
      let env = case prefix_name {
        Some(name) -> bind_name(env, name)
        None -> env
      }
      Ok(#(bind_name(env, rest_name), st))
    }

    glance.PatternVariant(_, module, constructor, arguments, _spread) -> {
      use scheme <- result.try(constructor_scheme(env, module, constructor))
      let #(ctor_type, st) = instantiate(st, scheme)
      // A constructor with fields is a function; one without is the value.
      let #(field_types, ret) = case ctor_type {
        Fn(args, ret) -> #(args, ret)
        other -> #([], other)
      }
      use st <- result.try(unify(st, expected, ret))
      use arg_patterns <- result.try(order_pattern_args(
        env,
        module,
        constructor,
        arguments,
        list.length(field_types),
      ))
      list.try_fold(
        list.zip(arg_patterns, field_types),
        #(env, st),
        fn(acc, pair) {
          let #(env, st) = acc
          let #(pattern, t) = pair
          infer_pattern(env, st, pattern, t)
        },
      )
    }

    glance.PatternBitString(_, segments) -> {
      use st <- result.try(unify(st, expected, prelude_bit_array()))
      list.try_fold(segments, #(env, st), fn(acc, segment) {
        let #(env, st) = acc
        infer_bit_pattern_segment(env, st, segment)
      })
    }
  }
}

// Check one bit-array *pattern* segment: bind the segment pattern and check
// its size option, threading the environment for any bound variables.
fn infer_bit_pattern_segment(
  env: Env,
  st: State,
  segment: #(
    glance.Pattern,
    List(glance.BitStringSegmentOption(glance.BitArraySize)),
  ),
) -> Result(#(Env, State), Error) {
  let #(pattern, options) = segment
  let default = case pattern {
    glance.PatternString(..) -> prelude_string()
    glance.PatternFloat(..) -> prelude_float()
    _ -> prelude_int()
  }
  use #(env, st) <- result.try(infer_pattern(
    env,
    st,
    pattern,
    segment_value_type(options, default),
  ))
  list.try_fold(options, #(env, st), fn(acc, option) {
    let #(env, st) = acc
    case option {
      glance.SizeValueOption(size) ->
        with_env(env, check_bit_array_size(env, st, size))
      _ -> Ok(#(env, st))
    }
  })
}

// Check a bit-array *pattern* segment size (glance 7.0+): a restricted
// arithmetic expression over already-bound variables, every part of which is
// an `Int`. Unlike a value size it binds nothing — a variable is a reference
// that must already be in scope and is unified with `Int`; literals, binary
// operators, and parenthesized blocks recurse.
fn check_bit_array_size(
  env: Env,
  st: State,
  size: glance.BitArraySize,
) -> Result(State, Error) {
  case size {
    glance.BitArraySizeInt(..) -> Ok(st)
    glance.BitArraySizeVariable(_, name) ->
      case dict.get(env.values, name) {
        Ok(scheme) -> {
          let #(t, st) = instantiate(st, scheme)
          unify(st, t, prelude_int())
        }
        Error(_) -> Error(UnboundVariable(name))
      }
    glance.BitArraySizeBinaryOperator(_, _, left, right) -> {
      use st <- result.try(check_bit_array_size(env, st, left))
      check_bit_array_size(env, st, right)
    }
    glance.BitArraySizeBlock(_, inner) -> check_bit_array_size(env, st, inner)
  }
}

// Pair a (possibly failed) new state with an unchanged environment.
fn with_env(
  env: Env,
  st: Result(State, Error),
) -> Result(#(Env, State), Error) {
  result.map(st, fn(st) { #(env, st) })
}

// Resolve a constructor name (optionally module-qualified) to its scheme.
fn constructor_scheme(
  env: Env,
  module: Option(String),
  constructor: String,
) -> Result(Scheme, Error) {
  case module {
    Some(alias) ->
      case dict.get(env.modules, alias) {
        Ok(interface) ->
          case dict.get(interface.values, constructor) {
            Ok(scheme) -> Ok(scheme)
            Error(_) -> Error(NoSuchExport(alias, constructor))
          }
        Error(_) -> Error(UnknownModule(alias))
      }
    None ->
      case dict.get(env.values, constructor) {
        Ok(scheme) -> Ok(scheme)
        Error(_) -> Error(UnknownConstructor(constructor))
      }
  }
}

// The value type of a bit-array segment given its options and the default to
// use when no type option is present (`Int` for numeric segments, `String`
// for string-literal segments, etc.).
fn segment_value_type(
  options: List(glance.BitStringSegmentOption(t)),
  default: Type,
) -> Type {
  list.fold(options, default, fn(acc, option) {
    case option {
      glance.FloatOption -> prelude_float()
      glance.Utf8Option | glance.Utf16Option | glance.Utf32Option ->
        prelude_string()
      glance.Utf8CodepointOption
      | glance.Utf16CodepointOption
      | glance.Utf32CodepointOption -> prelude_utf_codepoint()
      glance.BytesOption | glance.BitsOption -> prelude_bit_array()
      glance.IntOption -> prelude_int()
      _ -> acc
    }
  })
}

// Place constructor-pattern arguments into positional order, reordering by the
// constructor's field map and filling positions omitted via `..` with discards.
fn order_pattern_args(
  env: Env,
  module: Option(String),
  constructor: String,
  arguments: List(glance.Field(glance.Pattern)),
  arity: Int,
) -> Result(List(glance.Pattern), Error) {
  // A qualified constructor pattern takes its field map from the module that
  // defines the constructor, not the local environment.
  let field_maps = case module {
    Some(alias) ->
      case dict.get(env.modules, alias) {
        Ok(interface) -> interface.field_maps
        Error(_) -> env.field_maps
      }
    None -> env.field_maps
  }
  let labels = case dict.get(field_maps, constructor) {
    Ok(labels) -> labels
    Error(_) -> []
  }
  let index_of =
    list.index_fold(labels, dict.new(), fn(acc, label, index) {
      case label {
        Some(name) -> dict.insert(acc, name, index)
        None -> acc
      }
    })
  use labelled <- result.try(
    list.try_fold(arguments, dict.new(), fn(placed, field) {
      case field {
        glance.UnlabelledField(..) -> Ok(placed)
        glance.LabelledField(label, _, item) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, item))
        }
        glance.ShorthandField(label, location) -> {
          use index <- result.try(label_index(index_of, label))
          Ok(dict.insert(placed, index, glance.PatternVariable(location, label)))
        }
      }
    }),
  )
  let positional =
    list.filter_map(arguments, fn(field) {
      case field {
        glance.UnlabelledField(item) -> Ok(item)
        _ -> Error(Nil)
      }
    })
  let free = list.filter(indices(arity), fn(i) { !dict.has_key(labelled, i) })
  let placed =
    list.fold(list.zip(free, positional), labelled, fn(placed, pair) {
      dict.insert(placed, pair.0, pair.1)
    })
  Ok(
    list.map(indices(arity), fn(index) {
      case dict.get(placed, index) {
        Ok(pattern) -> pattern
        // Omitted via `..`: bind nothing.
        Error(_) -> glance.PatternDiscard(glance.Span(0, 0), "_")
      }
    }),
  )
}

// `[0, 1, ..., n - 1]`.
fn indices(n: Int) -> List(Int) {
  indices_loop(n - 1, [])
}

fn indices_loop(i: Int, acc: List(Int)) -> List(Int) {
  use <- bool.guard(when: i < 0, return: acc)
  indices_loop(i - 1, [i, ..acc])
}

// Type annotation hydration
//
// Convert a written type annotation into an internal `Type`, expanding aliases
// and attributing named types to their origin module. Hydration never fails:
// unknown type variables become fresh variables. An unresolved unqualified
// name is attributed to the prelude; an unresolved qualified name keeps its
// written module alias.
fn hydrate(env: Env, st: State, ast: glance.Type) -> #(Type, State) {
  hydrate_with(env, dict.new(), st, ast).0
}

// Resolve a (possibly qualified) type name applied to `arg_types` to a concrete
// `Type`, expanding aliases (local, unqualified-imported, or qualified) and
// attributing a named type to its origin module.
fn resolve_named_type(
  env: Env,
  st: State,
  module: Option(String),
  name: String,
  arg_types: List(Type),
) -> #(Type, State) {
  case module {
    None -> resolve_unqualified_type(env, st, name, arg_types)
    Some(alias) -> resolve_qualified_type(env, st, alias, name, arg_types)
  }
}

fn resolve_unqualified_type(
  env: Env,
  st: State,
  name: String,
  arg_types: List(Type),
) -> #(Type, State) {
  case dict.get(env.aliases, name) {
    // A local alias: expand its AST in this environment.
    Ok(#(params, aliased)) -> {
      let alias_names = dict.from_list(list.zip(params, arg_types))
      let #(#(t, st), _) = hydrate_with(env, alias_names, st, aliased)
      #(t, st)
    }
    Error(_) -> #(resolve_named_origin(env, name, arg_types), st)
  }
}

// A non-local-alias unqualified name: an unqualified imported alias (already
// resolved), else a named type at its origin module, else the prelude.
fn resolve_named_origin(env: Env, name: String, arg_types: List(Type)) -> Type {
  case dict.get(env.imported_aliases, name) {
    Ok(#(params, body)) -> instantiate_alias(params, body, arg_types)
    Error(_) ->
      case dict.get(env.local_types, name) {
        Ok(#(origin, origin_name, _arity)) ->
          Named(origin, origin_name, arg_types)
        Error(_) -> Named(prelude_module, name, arg_types)
      }
  }
}

// A qualified type name `alias.Name`: resolve via the imported module's alias
// or type, falling back to the alias as the module name.
fn resolve_qualified_type(
  env: Env,
  st: State,
  alias: String,
  name: String,
  arg_types: List(Type),
) -> #(Type, State) {
  case dict.get(env.modules, alias) {
    Error(_) -> #(Named(alias, name, arg_types), st)
    Ok(interface) ->
      case dict.get(interface.aliases, name) {
        Ok(#(params, body)) -> #(instantiate_alias(params, body, arg_types), st)
        Error(_) -> {
          let origin = case dict.get(interface.types, name) {
            Ok(#(origin, _origin_name, _arity)) -> origin
            Error(_) -> alias
          }
          #(Named(origin, name, arg_types), st)
        }
      }
  }
}

fn hydrate_with(
  env: Env,
  names: Dict(String, Type),
  st: State,
  ast: glance.Type,
) -> #(#(Type, State), Dict(String, Type)) {
  case ast {
    glance.NamedType(_, name, module, parameters) -> {
      let #(arg_types, st, names) =
        list.fold(parameters, #([], st, names), fn(acc, p) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, p)
          #([t, ..types_], st, names)
        })
      let arg_types = list.reverse(arg_types)
      let #(t, st) = resolve_named_type(env, st, module, name, arg_types)
      #(#(t, st), names)
    }

    glance.TupleType(_, elements) -> {
      let #(elem_types, st, names) =
        list.fold(elements, #([], st, names), fn(acc, e) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, e)
          #([t, ..types_], st, names)
        })
      #(#(Tuple(list.reverse(elem_types)), st), names)
    }

    glance.FunctionType(_, parameters, return) -> {
      let #(param_types, st, names) =
        list.fold(parameters, #([], st, names), fn(acc, p) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, p)
          #([t, ..types_], st, names)
        })
      let #(#(ret, st), names) = hydrate_with(env, names, st, return)
      #(#(Fn(list.reverse(param_types), ret), st), names)
    }

    glance.VariableType(_, name) ->
      case dict.get(names, name) {
        Ok(t) -> #(#(t, st), names)
        Error(_) -> {
          let #(t, st) = fresh(st)
          #(#(t, st), dict.insert(names, name, t))
        }
      }

    glance.HoleType(..) -> {
      let #(t, st) = fresh(st)
      #(#(t, st), names)
    }
  }
}

// Hydrate using (and threading) a fixed type-variable name map.
fn hydrate_in(
  env: Env,
  names: Dict(String, Type),
  st: State,
  ast: glance.Type,
) -> #(Type, State) {
  hydrate_with(env, names, st, ast).0
}

// Hydrate while threading the type-variable name map so repeated names within
// one signature resolve to the same variable.
fn hydrate_threaded(
  env: Env,
  names: Dict(String, Type),
  st: State,
  ast: glance.Type,
) -> #(Type, State, Dict(String, Type)) {
  let #(#(t, st), names) = hydrate_with(env, names, st, ast)
  #(t, st, names)
}

// Building the annotated module
//
// Assemble the final `AnnotatedModule` from the inferred environment and
// state: each definition's generalized scheme and every recorded expression
// type, zonked and sorted by span.

fn render(module: glance.Module, env: Env, st: State) -> AnnotatedModule {
  let functions =
    list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants =
    list.map(module.constants, fn(d) { ConstantDef(d.definition) })

  // `st.annotations` is in reverse discovery order. Restore discovery order
  // before the stable span sort, so annotations sharing a span retain the order
  // in which inference recorded them.
  let expressions =
    list.map(list.reverse(st.annotations), fn(entry) {
      let #(span, type_) = entry
      Annotation(span, zonk(st, type_))
    })

  AnnotatedModule(
    functions: collect_schemes(functions, env),
    constants: collect_schemes(constants, env),
    expressions: sort_by_span(expressions),
  )
}

// The inferred (generalized) scheme of each definition, in source order.
// Best-effort inference leaves skipped definitions unbound, so omit them here.
fn collect_schemes(defs: List(Def), env: Env) -> List(#(String, Scheme)) {
  list.filter_map(defs, fn(def) {
    let name = def_name(def)
    case lookup(env, name) {
      Ok(scheme) -> Ok(#(name, scheme))
      Error(_) -> Error(Nil)
    }
  })
}

fn sort_by_span(annotations: List(Annotation)) -> List(Annotation) {
  list.sort(annotations, fn(a, b) {
    case int.compare(a.span.start, b.span.start) {
      order.Eq -> int.compare(a.span.end, b.span.end)
      other -> other
    }
  })
}

// Small helpers
//
// Record an expression's type by span, recover an expression's span, and
// index into a list.

fn record(st: State, span: glance.Span, type_: Type) -> State {
  State(..st, annotations: [#(span, type_), ..st.annotations])
}

fn span(expr: glance.Expression) -> glance.Span {
  case expr {
    glance.Int(s, _) -> s
    glance.Float(s, _) -> s
    glance.String(s, _) -> s
    glance.Variable(s, _) -> s
    glance.NegateInt(s, _) -> s
    glance.NegateBool(s, _) -> s
    glance.Block(s, _) -> s
    glance.Panic(s, _) -> s
    glance.Todo(s, _) -> s
    glance.Tuple(s, _) -> s
    glance.List(s, _, _) -> s
    glance.Fn(s, _, _, _) -> s
    glance.RecordUpdate(s, _, _, _, _) -> s
    glance.FieldAccess(s, _, _) -> s
    glance.Call(s, _, _) -> s
    glance.TupleIndex(s, _, _) -> s
    glance.FnCapture(s, _, _, _, _) -> s
    glance.BitString(s, _) -> s
    glance.Case(s, _, _) -> s
    glance.BinaryOperator(s, _, _, _) -> s
    glance.Echo(s, _, _) -> s
  }
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

// Prelude type constructors
//
// Constructors for the built-in prelude types, all in the `gleam` module.

// The prelude module name shared by all built-in types.
const prelude_module = "gleam"

fn prelude_bit_array() -> Type {
  Named(prelude_module, "BitArray", [])
}

fn prelude_bool() -> Type {
  Named(prelude_module, "Bool", [])
}

fn prelude_float() -> Type {
  Named(prelude_module, "Float", [])
}

fn prelude_int() -> Type {
  Named(prelude_module, "Int", [])
}

fn prelude_list(element: Type) -> Type {
  Named(prelude_module, "List", [element])
}

fn prelude_nil() -> Type {
  Named(prelude_module, "Nil", [])
}

fn prelude_result(ok: Type, error: Type) -> Type {
  Named(prelude_module, "Result", [ok, error])
}

fn prelude_string() -> Type {
  Named(prelude_module, "String", [])
}

fn prelude_utf_codepoint() -> Type {
  Named(prelude_module, "UtfCodepoint", [])
}

// Type printer
//
// Render a `Type` to Gleam syntax, naming type variables `a, b, c, …` and
// skipping reserved words, with a naming context so names stay stable across
// several related types.

type Names {
  Names(map: Dict(Int, String), next: Int)
}

fn new_names() -> Names {
  Names(map: dict.new(), next: 0)
}

// Print a type within a naming context, returning the updated context so a
// caller can keep variable names stable across several related types.
fn print(names: Names, type_: Type) -> #(String, Names) {
  case type_ {
    Named(_module, name, []) -> #(name, names)

    Named(_module, name, args) -> {
      let #(rendered, names) = print_list(names, args)
      #(name <> "(" <> rendered <> ")", names)
    }

    Fn(args, ret) -> {
      let #(rendered_args, names) = print_list(names, args)
      let #(rendered_ret, names) = print(names, ret)
      #("fn(" <> rendered_args <> ") -> " <> rendered_ret, names)
    }

    Tuple(elements) -> {
      let #(rendered, names) = print_list(names, elements)
      #("#(" <> rendered <> ")", names)
    }

    Var(id) -> var_name(names, id)
  }
}

// Convenience wrapper for a single, standalone type.
fn to_string(type_: Type) -> String {
  print(new_names(), type_).0
}

fn print_list(names: Names, types_: List(Type)) -> #(String, Names) {
  let #(rev, names) =
    list.fold(types_, #([], names), fn(acc, t) {
      let #(rendered, names) = acc
      let #(s, names) = print(names, t)
      #([s, ..rendered], names)
    })
  #(string.join(list.reverse(rev), ", "), names)
}

fn var_name(names: Names, id: Int) -> #(String, Names) {
  case dict.get(names.map, id) {
    Ok(name) -> #(name, names)
    Error(_) -> {
      let #(name, next) = next_name(names.next)
      #(name, Names(map: dict.insert(names.map, id, name), next: next))
    }
  }
}

// The next type-variable name, skipping Gleam reserved words (so a variable is
// never spelled like a keyword, e.g. `fn`), matching the compiler.
fn next_name(n: Int) -> #(String, Int) {
  let name = letters(n)
  case is_reserved(name) {
    True -> next_name(n + 1)
    False -> #(name, n + 1)
  }
}

fn is_reserved(name: String) -> Bool {
  case name {
    "as"
    | "assert"
    | "case"
    | "const"
    | "echo"
    | "fn"
    | "if"
    | "import"
    | "let"
    | "opaque"
    | "panic"
    | "pub"
    | "todo"
    | "type"
    | "use" -> True
    _ -> False
  }
}

// 0 -> "a", 25 -> "z", 26 -> "aa", 27 -> "ab", ...
fn letters(n: Int) -> String {
  let letter = string.utf_codepoint(97 + n % 26)
  let prefix = case n / 26 {
    0 -> ""
    higher -> letters(higher - 1)
  }
  case letter {
    Ok(codepoint) -> prefix <> string.from_utf_codepoints([codepoint])
    Error(_) -> "t" <> int.to_string(n)
  }
}
