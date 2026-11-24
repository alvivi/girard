//// A type annotator for Gleam, written in Gleam.
////
//// Reports the inferred type of every expression — keyed by its source span —
//// and the signature of every top-level function and constant, for a single
//// module ([`annotate`](#annotate)) or a whole package
//// ([`annotate_package`](#annotate_package)). Give it source text or a
//// `glance` AST you parsed yourself.
////
//// Every result also reports which member each reference resolved to — a
//// record field, a module function, constant or constructor under the
//// module's canonical path, a local variable, or unresolved — for every field
//// access and every bare name in call position, and names every top-level
//// definition left out of the build for the other `Target` and every imported
//// module it could not use.
////
//// Imported modules are resolved through a [`Resolver`](#Resolver) to obtain
//// their public interfaces.

import argv
import girard/internal/reference
import girard/internal/scc
import girard/internal/ty
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
// `Annotation` and whole-module `AnnotatedModule` results, the
// `Resolution` / `ResolvedReference` vocabulary `AnnotatedModule` carries,
// and the `Resolver` and `Target` knobs that configure a run.

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
/// signature, the type of every expression in their bodies, and what every
/// field access and every bare name in call position resolved to.
///
/// `functions` and `constants` have one entry per top-level definition — its
/// generalized `Scheme` (a `type_` plus the ids of its quantified `Var`s).
/// `expressions` is finer-grained: the `Type` of *every* expression — literals,
/// calls, operators, sub-expressions — keyed by its `glance` source span, so
/// you can join inferred types onto your own AST. Render any type with
/// [`type_to_string`](#type_to_string). For a module glance parsed, each span
/// has one entry. A `glance.Module` built by hand that reuses one span for
/// several nodes is outside that promise: girard does not deduplicate
/// `expressions` when it publishes them.
///
/// `resolutions` is sorted by span, with one entry per span. The contract is
/// exact: an entry is recorded for every `glance.FieldAccess` girard walked,
/// wherever it sits, and for every bare name in call position — the callee of
/// a call, a capture or a `use`, and a bare pipe target. Nothing else is
/// recorded, so a name read outside call position (`let g = greet`), the
/// constructor of a record update or of a pattern, and a tuple index have no
/// entry. A span with no entry was therefore either not a recorded position or
/// never walked: nothing is recorded inside a definition `dropped` names, and,
/// for a record reached through [`annotate_package`](#annotate_package),
/// nothing inside one the enclosing [`ModuleResult`](#ModuleResult)'s
/// `skipped` names. The strict entry points return no `AnnotatedModule` at all
/// when a definition fails, so from them every walked definition the module
/// declares is in the record.
///
/// A resolution names a module by its canonical path, never the alias it was
/// imported under. The module under analysis is named as girard was given it:
/// its path under [`annotate_package`](#annotate_package), and `""` for a
/// module annotated on its own — the same name its own types carry in `Named`.
///
/// `unavailable` names every module girard could not use while annotating
/// this one, imported directly or reached through any import, with why. An
/// entry is never an error by itself: an unused unavailable import costs
/// nothing, which is why the strict entry points still return `Ok`. What an
/// entry means for the rest of the record:
///
/// - A *value* lookup whose import failed in this inference makes the
///   definition fail. [`annotate_package`](#annotate_package) lists it in
///   `skipped`, typically with `UnboundVariable` naming the import's alias or
///   the unqualified value. The strict entry points fail outright and return
///   no `AnnotatedModule`, so no `unavailable` list either: only a successful
///   strict result or a package result carries one. A listed path does not by
///   itself mean a lookup failed — an entry inherited from a reused interface
///   can sit beside a direct import of the same path that succeeded, and
///   values from that import work normally.
/// - A *type* written against one succeeds, and is published as girard
///   hydrated it: credited to the prelude when unqualified
///   (`Named("gleam", "T", [])`), named after the alias when qualified
///   (`Named("d", "T", [])`). While `unavailable` is non-empty, an annotation
///   may name a type girard could not see.
/// - An entry can come from a cached interface built before the module became
///   available, so a listed path may resolve for this module today while an
///   interface it reused was built without it. Once the source is fixed,
///   clearing the entry means invalidating the stale interface *and every
///   cached importer that carries it*, or starting from
///   [`new_cache`](#new_cache). Invalidating one importer is not enough in a
///   longer chain: if cached `a` imports cached, stale `b`, invalidating `b`
///   leaves `a` intact, and rebuilding `a` over a stale `b` copies the entry
///   back.
///
/// To tell direct entries from transitive ones, compare them with the
/// module's own imports, which you have in its AST.
pub type AnnotatedModule {
  AnnotatedModule(
    /// Top-level function name to inferred signature scheme, in source order.
    functions: List(#(String, Scheme)),
    /// Top-level constant name to inferred scheme, in source order.
    constants: List(#(String, Scheme)),
    /// Expression span to inferred type, sorted by start offset, one entry
    /// per expression span of a module glance parsed.
    expressions: List(Annotation),
    /// What every field access and every bare name in call position resolved
    /// to, sorted by span, one entry per span.
    resolutions: List(ResolvedReference),
    /// Top-level functions and constants dropped for the other build
    /// [`Target`](#Target), with their spans, sorted by span.
    dropped: List(Dropped),
    /// Every module girard could not use while annotating this one, imported
    /// directly or through any dependency, with why. One entry per module,
    /// sorted by module path.
    unavailable: List(UnavailableModule),
  )
}

/// A top-level function or constant left out of the build for the other
/// [`Target`](#Target): its name, and the span glance gave the definition —
/// from its `pub`, `fn` or `const` keyword to its closing token. Everything
/// written above that keyword is outside the span, including the doc comment
/// and the `@target` attribute that is the reason the definition is here at
/// all. It carries no target of its own — there are two, and the active one is
/// in the caller's [`Options`](#Options).
pub type Dropped {
  Dropped(name: String, span: glance.Span)
}

/// A module girard failed to load: its path as written in the `import`, and
/// why. The attempt was made either while annotating this module or while
/// building one of the interfaces it imported, whether that interface was
/// inferred fresh or reused from a cache. An entry records that failed attempt.
/// It does not prove the path is unavailable now, and it does not say which
/// definitions were affected (see [`AnnotatedModule`](#AnnotatedModule)).
pub type UnavailableModule {
  UnavailableModule(module: String, reason: Unavailability)
}

/// Why a module was unavailable.
pub type Unavailability {
  /// The resolver returned `Error(Nil)` for the module's path.
  NotFound
  /// The resolver returned source that glance could not parse. The error's
  /// positions are offsets into that source, not into the module being
  /// annotated.
  Unparsable(error: glance.Error)
}

/// Which member a reference resolved to. The variants are named after the
/// compiler's `ValueConstructorVariant`, which is where the same distinction
/// lives there, plus `RecordField` for the case the compiler reaches through
/// `RecordAccess` rather than through a scope entry.
pub type Resolution {
  /// A field of the accessed value's nominal type — the compiler's
  /// `RecordAccess`. `receiver` is the type of the value the field was read
  /// from, the thing left of the dot. The compiler calls that field `record`;
  /// this is the one place girard does not take its name, because here it
  /// holds a *type* rather than the accessed expression, and because the same
  /// word then has to name both the whole access and one half of it.
  RecordField(receiver: Type, label: String)
  /// A module's function, under the module's canonical path.
  ModuleFn(module: String, name: String)
  /// A module's constant, under the module's canonical path.
  ModuleConstant(module: String, name: String)
  /// A custom-type constructor, under its defining module's canonical path and
  /// its declared name — `Near`, even where it was imported `as Close`. The
  /// compiler calls this variant `Record`; `Constructor` is the name it uses
  /// for the same thing wherever it faces outwards.
  Constructor(module: String, name: String)
  /// A local binding: a `let`, a parameter, or a pattern's binding.
  LocalVariable(name: String)
  /// girard reached no member *at* the reference. The reason says why.
  Unresolved(reason: UnresolvedReason)
}

/// Why girard reached no member at a reference.
pub type UnresolvedReason {
  /// The receiver's type was unknown at the access and no module of its name
  /// exported the label, so girard deferred the access and read the field only
  /// once later inference had fixed the type — after the point where a member
  /// could be named. The [`Annotation`](#Annotation) at the span is still
  /// girard's answer for the field's type; only the member is unreported.
  ///
  /// Named for the compiler error covering the same ground,
  /// `RecordAccessUnknownType`. girard defers where the compiler's own
  /// inference has not fixed the receiver's type at the access either — there
  /// the compiler rejects the program (`Unknown type for record access`) and
  /// girard is the more permissive of the two. Wherever the compiler pushes a
  /// known type into a lambda's parameters before walking its body, girard now
  /// does too, so a receiver the compiler can type is one girard resolves at
  /// the access rather than after it.
  ///
  /// That is measured rather than promised: over the corpora girard is checked
  /// against — its `fixtures/oracle/` and `fixtures/golden/` fixtures, and a resweep of lustre,
  /// mist, wisp, glint, birl, gleam_otp, maud and shore — no accepted program
  /// reports this reason. A finite census is not a proof, so a new one over
  /// code the compiler accepts is a gap in girard's inference order, and worth
  /// reporting as one.
  RecordAccessUnknownType
}

/// One reference and what it resolved to.
///
/// `span` is the whole access — the same span [`Annotation`](#Annotation)
/// carries for it — while `label_span` and `container_span` are the member and
/// the accessed value, named as the compiler names the two spans it computes
/// for a field access. For a bare name in call position the three are the same
/// span.
///
/// Note that the compiler's own `Reference` is a different notion: it records
/// the *syntax* a use took — qualified, unqualified, aliased — for renaming and
/// find-references. A `ResolvedReference` says which member the use reached,
/// and says nothing about how it was spelled.
pub type ResolvedReference {
  ResolvedReference(
    span: glance.Span,
    label_span: glance.Span,
    container_span: glance.Span,
    resolution: Resolution,
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
// module, inferring every expression and top-level signature and resolving
// every reference, or return the first inference error.

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
  use inferred <- result.try(infer_module(
    options,
    set.new(),
    dict.new(),
    "",
    module,
    best_effort: False,
  ))
  Ok(render(inferred))
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
///
/// A cached interface keeps the
/// [`AnnotatedModule.unavailable`](#AnnotatedModule) entries it was built with,
/// and passes them to every importer built over it. After a missing module
/// appears, invalidate the interfaces built without it and their cached
/// importers, as for any interface change.
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
        Ok(inferred) -> #(Ok(render(inferred)), Cache(inferred.cache))
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
/// `annotated`, and nothing inside its span is annotated or resolved.
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
/// in the result; check it with [`is_complete`](#is_complete), which also
/// counts the modules girard could not load.
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
        Ok(inferred) -> {
          // Seed this module's own interface so a later module that imports it
          // hits the cache instead of re-resolving it through the resolver.
          let cache = dict.insert(inferred.cache, path, inferred.interface)
          let result = ModuleResult(render(inferred), inferred.skipped)
          #(dict.insert(results, path, result), cache)
        }
      }
    })
  results
}

/// Whether girard typed every definition of a package module and loaded every
/// module it imports, directly or through its imports: `skipped` and
/// `annotated.unavailable` are both empty. `False` means possibly incomplete,
/// as an unavailable module may have affected nothing (see
/// [`AnnotatedModule`](#AnnotatedModule)). Definitions in `annotated.dropped`
/// do not count.
pub fn is_complete(result: ModuleResult) -> Bool {
  result.skipped == [] && result.annotated.unavailable == []
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
    subst: Dict(Int, ty.Type),
    // Inferred type recorded for each annotated source span, in reverse order
    // of discovery. Types are stored "live" and zonked at the end.
    annotations: List(#(glance.Span, ty.Type)),
    // What every field access and every called bare name resolved to, in
    // reverse order of discovery. An accessed record is stored "live" and
    // zonked at the end, as an annotation's type is.
    references: List(Reference),
    // Field accesses and tuple indexes whose container type was not yet known
    // when encountered; resolved by `resolve_pending` once inference has fixed
    // the container type (deferred resolution, like the real compiler).
    pending: List(Pending),
    // Variable ids that are *rigid*: every generic an annotation ever
    // created, a function signature's or a body annotation's. A rigid var
    // unifies only with itself or a flexible var (which binds to it), never
    // with a concrete type or a different rigid — matching the compiler, whose
    // generics never bind (`environment.rs:1082-1089`); only their copies do.
    rigid: Set(Int),
    // The annotation names in scope where inference is, and the generics this
    // scope owns: see `Scope`.
    scope: Scope,
    // The type each module constant has in a clause guard once generalized,
    // by module and name: one copy per constant, shared by every guard read
    // of it, as the compiler's stored literal is (see `guard_constant_read`).
    literals: Dict(#(String, String), ty.Type),
  )
}

// The compiler's per-function `Hydrator` name table (`hydrator.rs:30-39`):
// each type-variable name written in an annotation in scope, and the generic
// ids this scope owns. A function's scope starts with its signature's names
// and ids, and the scope is saved and restored around the compiler's five
// boundaries (`scoped`). A read copies every generic it reaches that is not
// owned here (`environment.rs:717-735`), so a generic is rigid only while in
// scope and copied at each read once out of it.
type Scope {
  Scope(names: Dict(String, ty.Type), owned: Set(Int))
}

fn empty_scope() -> Scope {
  Scope(dict.new(), set.new())
}

// A failed inference step: the error, and the state at the point it failed.
// The state holds every unification, id, scope change and literal view made
// before the failure, as the compiler's mutable type cells keep them. A strict
// caller drops it and reports the error. A best-effort group rolls back to a
// state it saved itself and ignores it. A site that recovers in a speculative
// walk, and `speculate` itself, continue from it.
type Failure {
  Failure(error: Error, state: State)
}

// Fail at `st` with `error`.
fn fail(st: State, error: Error) -> Result(a, Failure) {
  Error(Failure(error, st))
}

// A stateless helper's result, its error failing at `st`: the helper changed
// nothing, so the state its caller holds is the state at the failure.
fn stateless(st: State, result: Result(a, Error)) -> Result(a, Failure) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> fail(st, error)
  }
}

// In a speculative walk, a failure resumes with `resume` from the state it
// failed in, at a site the compiler recovers at. Outside one the failure
// stands, and so does `Unsupported` everywhere: it is girard declining syntax,
// not a type error, so it abandons the rest of its argument and stops only at
// the argument itself (`speculate`).
fn recover_with(
  env: Env,
  result: Result(a, Failure),
  resume: fn(State) -> Result(a, Failure),
) -> Result(a, Failure) {
  case result {
    Error(Failure(Unsupported(_), _)) -> result
    Error(Failure(_, failed)) if env.recovering -> resume(failed)
    Ok(_) | Error(_) -> result
  }
}

// A sub-expression the compiler types through `infer` (`expression.rs:1780-
// 1793`): in a speculative walk, a failure is a fresh variable from the
// failed state.
fn recover_fresh(
  env: Env,
  result: Result(#(ty.Type, State), Failure),
) -> Result(#(ty.Type, State), Failure) {
  recover_with(env, result, fn(failed) { Ok(fresh(failed)) })
}

// An expression the compiler types through `infer`: `infer_expr`, its failure
// a fresh variable in a speculative walk (`recover_fresh`).
fn infer_recovering(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(ty.Type, State), Failure) {
  recover_fresh(env, infer_expr(env, st, expr))
}

// A unification the compiler records and moves past: in a speculative walk, a
// failure keeps the links it made before it failed, and the walk goes on with
// the types it already had.
fn recover_unify(
  env: Env,
  st: State,
  left: ty.Type,
  right: ty.Type,
) -> Result(State, Failure) {
  recover_with(env, unify(st, left, right), Ok)
}

// A deferred access awaiting its container's type.
type Pending {
  // `record.label` — the field type goes in `result`.
  PendingField(container: ty.Type, label: String, result: ty.Type)
  // `tuple.index` — the element type goes in `result`.
  PendingIndex(container: ty.Type, index: Int, result: ty.Type)
}

// A reference and what it resolved to, live. The accessed record is an
// inference-side type that later unification may still refine, so it is kept
// as one and `publish_reference` zonks and converts it at the end, exactly as
// `render` does for an annotation. The public `Resolution` cannot be built
// here — it holds the public `Type`, and one module cannot give two types the
// same constructor names.
type Reference {
  Reference(spans: Spans, resolved: Resolved)
}

type Resolved {
  ResolvedField(record: ty.Type, label: String)
  // The scope entry's variant the name was read at, which is what says which
  // member it resolved to and under what name. Published as `ModuleFn`,
  // `ModuleConstant`, `Constructor` or `LocalVariable`, one arm per variant.
  ResolvedValue(variant: ValueVariant)
  // Published as `Unresolved(RecordAccessUnknownType)`.
  ResolvedDeferred
}

// The three spans the compiler records for a reference: the whole access, its
// label and its container (`type_/expression.rs:1362-1379`). For a bare name
// in call position the three coincide.
type Spans {
  Spans(span: glance.Span, label: glance.Span, container: glance.Span)
}

// One scope entry per name, as the compiler's `ValueConstructor`
// (`type_.rs:1490`): the value's scheme and what kind of value it is.
type ValueConstructor {
  ValueConstructor(scheme: ty.Scheme, variant: ValueVariant)
}

// What kind of value a scope entry holds, as the compiler's
// `ValueConstructorVariant` (`type_.rs:720`). A module-level value carries the
// canonical path of the module that declared it and the name it has there, so
// an entry imported under an alias keeps its identity; and the two kinds that
// can take labelled arguments carry their field map, because a constant and a
// local have none and the shape says so. Every variant carries the name the
// value is published under, so a reference needs nothing but the variant.
// Names are prefixed because
// `ModuleFn`, `ModuleConstant`, `Constructor` and `LocalVariable` are already
// the public `Resolution`'s constructors.
type ValueVariant {
  LocalValue(name: String)
  FunctionValue(module: String, name: String, field_map: Option(FieldMap))
  ConstantValue(module: String, name: String, literal: ConstantLiteral)
  ConstructorValue(module: String, name: String, field_map: Option(FieldMap))
}

// A module constant's stored literal, which the compiler keeps beside its
// generalized type (`ValueConstructorVariant::ModuleConstant`,
// `analyse.rs:473-485`) and a clause guard reads instead of instantiating the
// type (`guard.rs:322-324`): the type as inferred, before generalization
// erased its variants, and which of its ids are generics an annotation
// created. A snapshot taken when the constant is inferred: a guard that later
// pins one of its variables in the defining module does not reach an
// importer, where the compiler's literal is one live type.
type ConstantLiteral {
  ConstantLiteral(type_: ty.Type, generics: Set(Int))
}

// The label of each of a callable's positional parameters, `None` where the
// position is unlabelled. Used to reorder labelled and shorthand arguments at
// call and pattern sites.
type FieldMap =
  List(Option(String))

// A callable's field map, or `None` when no position is labelled — the
// compiler's `FieldMap` is optional for the same reason. The one place that
// normalisation happens, so no reader has to ask whether an all-`None` list
// means "no labels".
fn field_map_of(labels: FieldMap) -> Option(FieldMap) {
  use <- bool.guard(when: list.all(labels, fn(l) { l == None }), return: None)
  Some(labels)
}

// The labels a call on this entry may use: the compiler's
// `ValueConstructor::field_map()` (`type_.rs:1611`), which is a projection off
// the variant rather than a table of its own. `None` all the way from where it
// was stored — a callable that labels no position, a value that takes no
// arguments at all, and a call the reader could not attribute to any entry are
// one answer, and the readers turn it into `AmbiguousCall` or an empty list at
// the one place each cares.
fn field_map(variant: ValueVariant) -> Option(FieldMap) {
  case variant {
    FunctionValue(field_map:, ..) | ConstructorValue(field_map:, ..) ->
      field_map
    ConstantValue(..) | LocalValue(..) -> None
  }
}

// A record type's field accessors: the labels every variant declares
// compatibly, and each variant's own, in declaration order. Each map is
// `label -> fn(record) -> field`, generalized over the type's parameters. A
// value known to be one variant reads that variant's map, so it reaches
// fields the other variants do not declare.
type Accessors {
  Accessors(
    shared: Dict(String, ty.Scheme),
    by_variant: List(Dict(String, ty.Scheme)),
  )
}

type Env {
  Env(
    // Value bindings in scope: locals, parameters, top-level functions and
    // custom-type constructors. One entry per name, as the compiler's
    // `Environment.scope` (`environment.rs:61`) keeps it: a name's scheme, its
    // labels and its identity are one thing, so binding a name replaces all of
    // them and cannot leave half of a shadowed binding behind.
    values: Dict(String, ValueConstructor),
    // The subset of `values` that can contribute free type variables to the
    // environment — bindings whose scheme has a type variable not bound by its
    // own quantifier (live monomorphic bindings: locals, parameters, SCC
    // members mid-inference). Fully-generalized and imported schemes quantify
    // every variable in their type, so they contribute nothing regardless of
    // the substitution and are omitted. `env_free_vars` scans only these, which
    // are few, instead of every binding in scope (mostly closed imports).
    // Maintained alongside `values` in `install_entry`, its sole writer.
    open_values: Dict(String, ty.Scheme),
    // Locally-defined type aliases: name -> (parameter names, aliased type
    // AST), expanded during hydration in this module's environment.
    aliases: Dict(String, #(List(String), glance.Type)),
    // Type aliases brought in by unqualified imports, already resolved to a
    // type with the alias's parameters as variables (param ids + body), so
    // they need no re-hydration in this module's environment.
    imported_aliases: Dict(String, #(List(Int), ty.Type)),
    // Record field accessors, by the name of the type they belong to.
    accessors: Dict(String, Accessors),
    // In-scope type names -> (origin module, origin name, arity). Covers types
    // defined in the current module and types brought in by unqualified
    // imports. Used during hydration to resolve a bare type name to its module
    // and to the name it has *there* — an `import x.{type T as U}` is in scope
    // as `U` but must hydrate to `x`'s `T`, not a phantom `x.U`.
    local_types: Dict(String, #(String, String, Int)),
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
    // Every module this one could not load, keyed by its path, with why:
    // imported here directly or recorded by an interface it imported, so the
    // set is already transitive and merging one level per import is enough.
    // `process_imports` is its only writer (see `record_unavailable` for the
    // precedence between a direct failure and an inherited one).
    unavailable: Dict(String, Unavailability),
    // What kind of syntax is being inferred: see `Syntax`.
    syntax: Syntax,
    // Whether this is a speculative walk, where a failure recovers at the
    // site the compiler recovers at instead of failing the walk: see
    // `speculate`. Everything walked within one inherits it, an inner
    // function literal's own speculation and real pass included, because the
    // compiler discards every diagnostic the pass records.
    recovering: Bool,
  )
}

// The compiler parses three kinds of value syntax differently. In a constant
// initializer, or a guard subtree the compiler parses as a constant,
// `name.member` is module access only, as the compiler's constant parser reads
// it. A clause guard is a guard until such a subtree turns it into a constant.
type Syntax {
  ExpressionSyntax
  GuardSyntax
  ConstantSyntax
}

// The public surface of a module, used when importing it elsewhere.
type ModuleInterface {
  ModuleInterface(
    name: String,
    // One entry per public value, as the compiler's `ModuleInterface.values`
    // (`type_.rs:1021`) holds them: an export's scheme, its labels and the
    // identity it was declared under travel together, so an importer reads
    // what the exporting module had in scope rather than a reconstruction of
    // it.
    values: Dict(String, ValueConstructor),
    types: Dict(String, #(String, String, Int)),
    // Public type aliases, resolved to a type with the alias's parameters as
    // variables (param ids + body).
    aliases: Dict(String, #(List(Int), ty.Type)),
    accessors: Dict(String, Accessors),
    // The modules this one imports, so a type it exposes from another module
    // (e.g. a `glance.Span` field) keeps its accessors reachable transitively.
    // Keyed by the alias they are reachable under *here*, which is why a
    // discard-aliased import is absent from it: it has no qualified name.
    modules: Dict(String, ModuleInterface),
    // Everything this module resolved, keyed by real module name — the same
    // graph, addressed the way `accessors_of_module` addresses it. A
    // discard-aliased import is in here, so an importer can still find the
    // accessors of a type this module exposes from one.
    reachable: Dict(String, ModuleInterface),
    // The modules this one could not load while it was inferred, directly or
    // through its own imports: its final `Env.unavailable`. It travels with the
    // interface, so an importer that reuses it from a cache inherits the same
    // set as one that infers it fresh.
    unavailable: Dict(String, Unavailability),
  )
}

fn new_state() -> State {
  State(
    next_id: 0,
    subst: dict.new(),
    annotations: [],
    references: [],
    pending: [],
    rigid: set.new(),
    scope: empty_scope(),
    literals: dict.new(),
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
    current_module: "",
    modules: dict.new(),
    module_index: dict.new(),
    unavailable: dict.new(),
    syntax: ExpressionSyntax,
    recovering: False,
  )
}

// Set the name of the module currently being inferred.
fn set_module(env: Env, name: String) -> Env {
  Env(..env, current_module: name)
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

// The local aliases on a cycle — every alias in a strongly connected component
// of more than one, and an alias that names itself — whose expansion would
// never finish. The compiler rejects a module that declares one, used or not
// (`RecursiveTypeAlias`, from the same toposort over the aliases). girard
// leaves them unregistered instead, so a reference to one hydrates as any name
// girard cannot resolve does, and the module still annotates in finite time.
// An alias that only reaches a cycle is not on it, and stays registered.
fn cyclic_aliases(aliases: List(glance.TypeAlias)) -> Set(String) {
  let names = list.map(aliases, fn(alias) { alias.name })
  let local = set.from_list(names)
  let edges =
    list.fold(aliases, dict.new(), fn(edges, alias) {
      let dependencies =
        list.filter(alias_dependencies(alias.aliased), set.contains(local, _))
      dict.insert(edges, alias.name, dependencies)
    })
  scc.components(names, edges)
  |> list.filter(is_cycle(_, edges))
  |> list.flatten
  |> set.from_list
}

// The unqualified type names `type_` mentions, through named types' arguments,
// tuple elements and function types: the compiler's `get_type_dependencies`. A
// qualified name belongs to another module, so it is never a local alias, but
// its arguments can name one.
fn alias_dependencies(type_: glance.Type) -> List(String) {
  case type_ {
    glance.NamedType(_, name, None, parameters) -> [
      name,
      ..list.flat_map(parameters, alias_dependencies)
    ]
    glance.NamedType(_, _, Some(_), parameters) ->
      list.flat_map(parameters, alias_dependencies)
    glance.TupleType(_, elements) -> list.flat_map(elements, alias_dependencies)
    glance.FunctionType(_, parameters, return) ->
      list.flat_map([return, ..parameters], alias_dependencies)
    glance.VariableType(..) | glance.HoleType(..) -> []
  }
}

// Whether a strongly connected component of the alias graph is a cycle: more
// than one alias, or a single alias that depends on itself.
fn is_cycle(
  component: List(String),
  edges: Dict(String, List(String)),
) -> Bool {
  case component {
    [] -> False
    [name] -> list.contains(result.unwrap(dict.get(edges, name), []), name)
    [_, _, ..] -> True
  }
}

fn fresh_id(st: State) -> #(Int, State) {
  #(st.next_id, State(..st, next_id: st.next_id + 1))
}

fn fresh(st: State) -> #(ty.Type, State) {
  let #(id, st) = fresh_id(st)
  #(ty.Var(id), st)
}

// The id of a type variable. Callers pass freshly-minted `Var`s (custom-type
// parameters, instantiated constructor heads), so a non-`Var` is `Error` rather
// than a fabricated id.
fn var_id(type_: ty.Type) -> Result(Int, Nil) {
  case type_ {
    ty.Var(id) -> Ok(id)
    _ -> Error(Nil)
  }
}

// The prelude value constructors (`True`, `False`, `Nil`, `Ok`, `Error`) as
// named scope entries, with `Ok`'s and `Error`'s type variables minted from
// `st`. Every one of them is a constructor of a prelude type, so the entries
// are built here and one table serves both the initial environment and the
// `gleam` interface — neither has to know how to wrap the other's.
fn prelude_values(st: State) -> #(List(#(String, ValueConstructor)), State) {
  // Ok(a) -> Result(a, e), the prelude's first variant.
  let #(ok_a, st) = fresh_id(st)
  let #(ok_e, st) = fresh_id(st)
  let ok =
    ty.Scheme(
      [ok_a, ok_e],
      ty.Fn(
        [ty.Var(ok_a)],
        stamp(st, prelude_result(ty.Var(ok_a), ty.Var(ok_e)), 0),
      ),
    )

  // Error(e) -> Result(a, e), the second.
  let #(err_a, st) = fresh_id(st)
  let #(err_e, st) = fresh_id(st)
  let error =
    ty.Scheme(
      [err_a, err_e],
      ty.Fn(
        [ty.Var(err_e)],
        stamp(st, prelude_result(ty.Var(err_a), ty.Var(err_e)), 1),
      ),
    )

  let values =
    list.map(
      [
        #("True", ty.Scheme([], prelude_bool())),
        #("False", ty.Scheme([], prelude_bool())),
        #("Nil", ty.Scheme([], prelude_nil())),
        #("Ok", ok),
        #("Error", error),
      ],
      fn(value) {
        let #(name, scheme) = value
        #(
          name,
          ValueConstructor(scheme, ConstructorValue(prelude_module, name, None)),
        )
      },
    )
  #(values, st)
}

// The initial environment and state, seeded with the prelude value
// constructors.
fn prelude() -> #(Env, State) {
  let #(values, st) = prelude_values(new_state())
  let env =
    list.fold(values, new_env(), fn(env, value) {
      install_entry(env, value.0, value.1)
    })
  #(env, st)
}

// The implicit `gleam` prelude module's public interface, used to resolve
// `import gleam` / `import gleam.{Error as Err}`. The prelude has no source
// file; the compiler treats `gleam` as a built-in module exposing the prelude
// types and value constructors. An interface's schemes are instantiated on
// use, so the ids their variables carry here do not matter.
fn prelude_interface() -> ModuleInterface {
  let module = prelude_module
  let #(values, _st) = prelude_values(new_state())
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
    values: dict.from_list(values),
    types: types_,
    aliases: dict.new(),
    accessors: dict.new(),
    modules: dict.new(),
    reachable: dict.new(),
    unavailable: dict.new(),
  )
}

// Install a whole scope entry under a name, replacing whatever it held. The
// only writer of `values`, and with it the only maintainer of `open_values`,
// so the index cannot fall out of step with the table it indexes.
fn install_entry(env: Env, name: String, entry: ValueConstructor) -> Env {
  Env(
    ..env,
    values: dict.insert(env.values, name, entry),
    // Track whether this binding can contribute environment free variables, so
    // `env_free_vars` need not re-walk every closed scheme. A closed scheme
    // shadowing an open one must evict the stale open entry, hence the delete.
    open_values: case scheme_is_closed(entry.scheme) {
      True -> dict.delete(env.open_values, name)
      False -> dict.insert(env.open_values, name, entry.scheme)
    },
  )
}

// Install a name at a scheme and a variant, building the entry for a caller
// that does not already hold one.
fn install(
  env: Env,
  name: String,
  scheme: ty.Scheme,
  variant: ValueVariant,
) -> Env {
  install_entry(env, name, ValueConstructor(scheme, variant))
}

// Bind a local value: a `let`, a parameter, a pattern's binding. Replacing the
// entry is what shadows a module-level name's labels and identity along with
// its type.
fn bind_local(env: Env, name: String, type_: ty.Type) -> Env {
  install(env, name, ty.Scheme([], type_), LocalValue(name))
}

// Whether a scheme can never contribute a free variable to the environment:
// every type variable in its type is bound by its own quantifier. This is
// purely syntactic and so substitution-independent — `scheme_free_vars`
// resolves and collects only variables *not* in `bound`, so a scheme with none
// such yields nothing for any substitution, now or later.
fn scheme_is_closed(scheme: ty.Scheme) -> Bool {
  let bound = set.from_list(scheme.vars)
  all_vars_bound(scheme.type_, bound)
}

fn all_vars_bound(type_: ty.Type, bound: Set(Int)) -> Bool {
  case type_ {
    ty.Var(id) -> set.contains(bound, id)
    ty.Named(_, _, args, _) -> list.all(args, all_vars_bound(_, bound))
    ty.Fn(args, ret) ->
      list.all(args, all_vars_bound(_, bound)) && all_vars_bound(ret, bound)
    ty.Tuple(elements) -> list.all(elements, all_vars_bound(_, bound))
  }
}

// Look up a value's scheme in the environment.
fn lookup(env: Env, name: String) -> Result(ty.Scheme, Nil) {
  dict.get(env.values, name) |> result.map(fn(entry) { entry.scheme })
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

// Install a top-level definition as one scope entry: its scheme, its identity
// and, for a function, the labels its parameters declare. A definition whose
// component fails to type has that component's whole environment discarded, so
// a name it shadowed reverts whole — an unqualified import of the same name
// keeps its scheme, its labels and its origin together, rather than any two of
// the three.
fn define_function(
  env: Env,
  function: glance.Function,
  scheme: ty.Scheme,
) -> Env {
  install(
    env,
    function.name,
    scheme,
    FunctionValue(
      env.current_module,
      function.name,
      field_map_of(list.map(function.parameters, fn(p) { p.label })),
    ),
  )
}

// A constant's entry carries its literal beside its scheme.
fn define_constant(
  env: Env,
  constant: glance.Constant,
  scheme: ty.Scheme,
  literal: ConstantLiteral,
) -> Env {
  install(
    env,
    constant.name,
    scheme,
    ConstantValue(env.current_module, constant.name, literal),
  )
}

fn def_name(def: Def) -> String {
  case def {
    FunctionDef(f) -> f.name
    ConstantDef(c) -> c.name
  }
}

fn def_span(def: Def) -> glance.Span {
  case def {
    FunctionDef(f) -> f.location
    ConstantDef(c) -> c.location
  }
}

// Interfaces resolved so far in this run, keyed by module path. Resolving a
// module is expensive (it infers the whole module), and a deep import graph
// imports the same dependency many times; memoizing keeps each module inferred
// once rather than re-inferring it exponentially.
type InterfaceCache =
  dict.Dict(String, ModuleInterface)

// Everything one module's inference produced. A tuple ran out of room at four
// elements; naming the parts also keeps the three public callers and
// `resolve_uncached` from destructuring positionally past what each needs.
//
// It holds the definitions inference *walked* rather than the module they came
// from, so `render` has no module to look a definition up in and cannot
// publish one that was never walked. That is what the caller's own unfiltered
// module used to let it do.
type Inferred {
  Inferred(
    functions: List(Def),
    constants: List(Def),
    env: Env,
    st: State,
    interface: ModuleInterface,
    cache: InterfaceCache,
    skipped: List(#(String, Error)),
    dropped: List(Dropped),
  )
}

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
) -> Result(Inferred, Error) {
  // Drop definitions and imports compiled only for another target. A pair of
  // target-specific siblings may have different types, so the inactive one
  // must not shadow the active definition.
  let #(module, dropped) = for_target(module, options.target)
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
  //    register aliases and custom-type constructors/accessors. An alias on a
  //    cycle is not registered, since expanding it would never finish. A
  //    function's labels need no early pass: they are installed with its
  //    value, by `register_member` before any body of its group is walked,
  //    and no earlier group can reference it or it would not be earlier.
  let env =
    list.fold(module.custom_types, env, fn(env, d) {
      let ct = d.definition
      declare_type(env, ct.name, list.length(ct.parameters))
    })
  let aliases = list.map(module.type_aliases, fn(d) { d.definition })
  let cyclic = cyclic_aliases(aliases)
  let env =
    aliases
    |> list.filter(fn(alias) { !set.contains(cyclic, alias.name) })
    |> list.fold(env, register_type_alias)
  let #(env, st) =
    list.fold(module.custom_types, #(env, st), fn(acc, d) {
      let #(env, st) = acc
      register_custom_type(env, st, d.definition)
    })

  // 3. Infer definitions in strongly-connected-component order.
  let functions =
    list.map(module.functions, fn(d) { FunctionDef(d.definition) })
  let constants =
    list.map(module.constants, fn(d) { ConstantDef(d.definition) })
  let defs = list.append(functions, constants)
  let order =
    reference.dependency_order(
      list.map(module.functions, fn(d) { d.definition }),
      list.map(module.constants, fn(d) { d.definition }),
    )
  // The names in scope as imported modules, which a best-effort split treats
  // as module access rather than reads of a same-named definition.
  let aliases =
    set.from_list(
      list.filter_map(module.imports, fn(d) { qualified_alias(d.definition) }),
    )
  use #(#(final_env, st), skipped) <- result.try(infer_defs(
    env,
    st,
    order,
    defs,
    aliases,
    best_effort:,
  ))
  // Inference is done: what is left only reads the final state, to export
  // the interface and to publish the results.
  let st = compress_substitution(st)

  let interface =
    build_interface(
      final_env,
      st,
      module_name,
      public_value_names(module),
      public_type_names(module),
      public_accessor_type_names(module),
    )
  Ok(Inferred(
    functions:,
    constants:,
    env: final_env,
    st:,
    interface:,
    cache:,
    skipped:,
    dropped:,
  ))
}

fn infer_defs(
  env: Env,
  st: State,
  order: List(List(String)),
  defs: List(Def),
  aliases: Set(String),
  best_effort best_effort: Bool,
) -> Result(#(#(Env, State), List(#(String, Error))), Error) {
  // Every function is registered before any group is inferred, at the shape
  // its annotations give, as the compiler registers them (`analyse.rs:261-263`).
  // A function the compiler's graph does not order first, read in a
  // `let assert` message its own pattern shadows, is still found.
  let base = env
  let #(#(env, st), items) =
    defs
    |> list.sort(fn(a, b) { int.compare(def_start(a), def_start(b)) })
    |> list.map_fold(#(env, st), fn(acc, def) { register(acc.0, acc.1, def) })
  let by_name = dict.from_list(list.map(items, fn(i) { #(item_name(i), i) }))
  // Each component is a group of mutually recursive definitions, in the
  // compiler's dependency order. Resolve the names back to definitions.
  let groups =
    list.map(order, fn(group) { list.filter_map(group, dict.get(by_name, _)) })
  let initial = Groups(env:, st:, skipped: [])

  // Strict mode stops at the first component that fails to type, returning its
  // error. Best-effort mode keeps the pre-component environment on a failure —
  // discarding that component's partial annotations and substitution — records
  // every definition in it as skipped (with the error), and carries on; a later
  // component referring to a skipped one fails in turn (an unbound variable) and
  // cascades naturally.
  case best_effort {
    False -> {
      use done <- result.map(
        list.try_fold(groups, initial, fn(groups, group) {
          use #(env, st) <- result.map(infer_group(groups, group, base))
          inferred(groups, env, st)
        })
        // The first failure is the module's error; its state is dropped.
        |> result.map_error(fn(failure) { failure.error }),
      )
      #(#(done.env, done.st), [])
    }
    True -> {
      let done =
        list.fold(groups, initial, fn(groups, group) {
          best_effort_group(groups, group, base, aliases)
        })
      Ok(#(#(done.env, done.st), done.skipped))
    }
  }
}

// What inferring a module's groups carries from one group to the next.
type Groups {
  Groups(env: Env, st: State, skipped: List(#(String, Error)))
}

// Adopt a group's result.
fn inferred(groups: Groups, env: Env, st: State) -> Groups {
  Groups(..groups, env:, st:)
}

// One best-effort step over a strongly-connected component: on success adopt
// the new environment; on failure keep the prior one (discarding the
// component's partial work) and skip the component. A component of several
// members is first re-split along the edges the typer really follows, so that
// an edge that only orders two definitions (`reference.strict_edges`) does not
// take an independent one down with a failing one. Code the compiler accepts
// never fails, so the split never changes a result it gives.
fn best_effort_group(
  groups: Groups,
  group: List(GroupItem),
  base: Env,
  aliases: Set(String),
) -> Groups {
  case infer_group(groups, group, base), group {
    Ok(#(env, st)), _ -> inferred(groups, env, st)
    Error(_), [_, _, ..] -> split_group(groups, group, base, aliases)
    Error(Failure(error, _)), _ -> skip_group(groups, group, base, error)
  }
}

// Infer a failed component's strict sub-components in turn, in the order
// Pearce's algorithm gives them over the compiler's member order, skipping
// only those that fail.
fn split_group(
  groups: Groups,
  group: List(GroupItem),
  base: Env,
  aliases: Set(String),
) -> Groups {
  let functions =
    list.filter_map(group, fn(item) {
      case item {
        FunctionItem(function:, ..) -> Ok(function)
        ConstantItem(..) -> Error(Nil)
      }
    })
  let constants =
    list.filter_map(group, fn(item) {
      case item {
        ConstantItem(constant:) -> Ok(constant)
        FunctionItem(..) -> Error(Nil)
      }
    })
  let by_name = dict.from_list(list.map(group, fn(i) { #(item_name(i), i) }))
  let edges = reference.strict_edges(functions, constants, aliases)
  scc.components(list.map(group, item_name), dict.from_list(edges))
  |> list.fold(groups, fn(groups, names) {
    let sub = list.filter_map(names, dict.get(by_name, _))
    case infer_group(groups, sub, base) {
      Ok(#(env, st)) -> inferred(groups, env, st)
      Error(Failure(error, _)) -> skip_group(groups, sub, base, error)
    }
  })
}

// Skip a component: record each member with the error, and take its
// functions' registrations out of scope, giving back whatever the name had
// before registration (an unqualified import, say), so a reader fails as if
// the definition were absent.
fn skip_group(
  groups: Groups,
  group: List(GroupItem),
  base: Env,
  error: Error,
) -> Groups {
  let names = list.map(group, item_name)
  let env =
    list.fold(names, groups.env, fn(env, name) {
      case dict.get(base.values, name) {
        Ok(entry) -> install_entry(env, name, entry)
        Error(_) ->
          Env(
            ..env,
            values: dict.delete(env.values, name),
            open_values: dict.delete(env.open_values, name),
          )
      }
    })
  Groups(
    ..groups,
    env:,
    skipped: list.append(
      groups.skipped,
      list.map(names, fn(name) { #(name, error) }),
    ),
  )
}

// Infer one group of mutually recursive definitions as the compiler does
// (`analyse.rs:297-320`), then generalize each against the environment before
// registration and add it back for later groups.
//
// Every function is already registered (`infer_defs`) at the shape its
// annotations give (`register_value_from_function`, `analyse.rs:1578-1700`):
// its signature variables rigid, each missing part a fresh variable shared by
// every reader until its group is generalized. A constant is not registered:
// the compiler brings it into scope only once it has inferred it. The members
// are inferred in the group's own order. A function's body binds the
// registered parameter types and is checked against the registered return
// (`analyse.rs:553-640`), under a scope seeded with its signature's names and
// generics, as the compiler's per-function hydrator is. Every value read
// copies each generic its scope does not own (`read_value`): the signature
// variables of every other function, which is what lets a function's generic
// reach another one through a shared, unannotated part without pinning it
// there. A constant is inferred under an empty scope, so it owns none.
fn infer_group(
  groups: Groups,
  group: List(GroupItem),
  base: Env,
) -> Result(#(Env, State), Failure) {
  let Groups(env:, st:, ..) = groups
  // Each member's type, in the group's order, to generalize once all are
  // inferred.
  use #(group_env, st, rev_inferred) <- result.try(
    list.try_fold(group, #(env, st, []), fn(acc, item) {
      let #(group_env, st, inferred) = acc
      case item {
        FunctionItem(f, params, return_type, scope) -> {
          // The member's ids stay generics after it, so a later read of its
          // registration copies them; only its scope ends here.
          let st = State(..st, scope:)
          let param_names = list.map(f.parameters, fn(param) { param.name })
          let body_env = bind_params(group_env, param_names, params)
          use st <- result.try(check_body(body_env, st, f, return_type))
          let st = State(..st, scope: empty_scope())
          let member = FunctionMember(f, ty.Fn(params, return_type))
          Ok(#(group_env, st, [member, ..inferred]))
        }
        ConstantItem(c) -> {
          use #(literal, st) <- result.try(infer_constant(group_env, st, c))
          // Until the group is generalized, the constant's literal is its own
          // type, live.
          let scheme = ty.Scheme([], literal.type_)
          let group_env = define_constant(group_env, c, scheme, literal)
          Ok(#(group_env, st, [ConstantMember(c, literal), ..inferred]))
        }
      }
    }),
  )
  // The component's bodies are fully inferred, so any field accesses deferred
  // because their record type was unknown can now be resolved — before we
  // generalize, so the field types are reflected in the schemes.
  use st <- result.try(resolve_pending(group_env, st))
  // Generalized as the compiler's `generalise` does, over every variable still
  // free: against the environment before any registration, so the registered
  // functions of later groups do not hold a variable back.
  // A constant's literal is its type as inferred, before the erasure.
  let env =
    list.fold(list.reverse(rev_inferred), env, fn(env, member) {
      case member {
        FunctionMember(function, type_) ->
          define_function(env, function, generalize(st, base, type_))
        ConstantMember(constant, literal) ->
          define_constant(
            env,
            constant,
            generalize(st, base, literal.type_),
            ConstantLiteral(..literal, type_: zonk(st, literal.type_)),
          )
      }
    })
  Ok(#(env, st))
}

// A member's type as its group inferred it, to generalize once every member
// is inferred: a constant's is its literal's, which also marks the ids its
// annotation made generics.
type Member {
  FunctionMember(function: glance.Function, type_: ty.Type)
  ConstantMember(constant: glance.Constant, literal: ConstantLiteral)
}

// A top-level definition, registered for inference.
type GroupItem {
  // A function, registered at its annotation shape before any group is
  // inferred, with the scope its body starts in: the names its signature
  // wrote and the generics they created, which it owns — rigid in its own
  // body, copied at every read anywhere else.
  FunctionItem(
    function: glance.Function,
    params: List(ty.Type),
    return_type: ty.Type,
    scope: Scope,
  )
  // A constant, in scope only once inferred.
  ConstantItem(constant: glance.Constant)
}

fn item_name(item: GroupItem) -> String {
  case item {
    FunctionItem(function:, ..) -> function.name
    ConstantItem(constant:) -> constant.name
  }
}

fn def_start(def: Def) -> Int {
  case def {
    FunctionDef(f) -> f.location.start
    ConstantDef(c) -> c.location.start
  }
}

// Register a definition: a function at its annotation shape, monomorphic until
// its group is generalized; a constant not at all.
fn register(env: Env, st: State, def: Def) -> #(#(Env, State), GroupItem) {
  case def {
    ConstantDef(c) -> #(#(env, st), ConstantItem(c))
    FunctionDef(f) -> {
      let #(params, return_type, scope, st) = signature_skeleton(env, st, f)
      let env =
        define_function(env, f, ty.Scheme([], ty.Fn(params, return_type)))
      #(#(env, st), FunctionItem(f, params, return_type, scope))
    }
  }
}

// Import resolution
//
// Resolve each import to a `ModuleInterface` — from the run's cache, the
// prelude, or by inferring the imported module's source through the resolver
// — and bring its qualified alias and unqualified items into scope. An import
// that cannot be loaded is skipped and recorded in `Env.unavailable`, beside
// the failures each loaded interface carries from its own imports.

// Imports are met in the order glance stores them, which is the reverse of
// source order: glance prepends each import as it parses it.
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
    use #(resolved, cache) <- result.try(resolve_interface(
      options,
      loading,
      cache,
      path,
      best_effort:,
    ))
    case resolved {
      // Unresolvable or unparsable: best effort, skip (uses of it surface later
      // as unbound variables), but say so.
      Error(reason) -> Ok(#(record_unavailable(env, path, reason), cache))
      Ok(interface) -> {
        let env = import_items(env, import_, interface)
        Ok(#(inherit_unavailable(env, interface), cache))
      }
    }
  })
}

// A direct failure overwrites whatever the path already had, so it wins over
// an entry inherited from an interface met earlier, and `inherit_unavailable`
// never overwrites it when one is met later. The two can disagree only when
// an interface was reused from a cache built against an older source of the
// path, and this import's attempt is the current one.
fn record_unavailable(env: Env, path: String, reason: Unavailability) -> Env {
  Env(..env, unavailable: dict.insert(env.unavailable, path, reason))
}

// Merge an imported interface's failures, inserting only the paths not yet
// recorded: a direct failure keeps its reason, and between two interfaces
// that disagree the one met first wins, which is the import written last (see
// `process_imports`). A path this module imported successfully keeps an entry
// inherited this way too: the interface really was built without it, so its
// exports really lack that module's types. `dict.merge` keeps the second
// dict's entry on a clash, which is what leaves a recorded path alone.
fn inherit_unavailable(env: Env, interface: ModuleInterface) -> Env {
  Env(..env, unavailable: dict.merge(interface.unavailable, env.unavailable))
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
  // (mist's `gleam/http as _ghttp` vs `mist/internal/http`). Its interface is
  // still indexed by real module name: an unqualified constructor taken from it
  // builds a value whose type names that module, and the accessors for that
  // type are found through `module_index`, which is keyed by real name and so
  // cannot shadow anything. The index travels to importers as this module's
  // `reachable`, so the entry is found from further away too.
  let env = case qualified_alias(import_) {
    Ok(alias) -> import_qualified(env, alias, interface)
    Error(_) ->
      Env(..env, module_index: index_interface(env.module_index, interface))
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
) -> Result(#(Result(ModuleInterface, Unavailability), InterfaceCache), Error) {
  // `import gleam` refers to the built-in prelude module, which has no source
  // file; resolve it to a synthetic interface of the prelude's types/values.
  use <- bool.lazy_guard(when: path == prelude_module, return: fn() {
    Ok(#(Ok(prelude_interface()), cache))
  })
  case dict.get(cache, path) {
    // Already inferred in this run: reuse it rather than inferring again.
    Ok(interface) -> Ok(#(Ok(interface), cache))
    Error(_) -> resolve_uncached(options, loading, cache, path, best_effort:)
  }
}

// The inner `Result` says whether the module could be loaded at all; the
// outer one carries a strict-mode inference failure *inside* a module that
// did load. A failure to load is not cached, so the next import of the same
// path asks the resolver again.
fn resolve_uncached(
  options: Options,
  loading: Set(String),
  cache: InterfaceCache,
  path: String,
  best_effort best_effort: Bool,
) -> Result(#(Result(ModuleInterface, Unavailability), InterfaceCache), Error) {
  case options.resolver(path) {
    Error(_) -> Ok(#(Error(NotFound), cache))
    Ok(source) ->
      case glance.module(source) {
        Error(error) -> Ok(#(Error(Unparsable(error)), cache))
        Ok(module) -> {
          // An import's own skipped definitions (best-effort) are irrelevant to
          // the importer; only its public interface, partial or not, matters.
          use inferred <- result.try(infer_module(
            options,
            set.insert(loading, path),
            cache,
            path,
            module,
            best_effort:,
          ))
          Ok(#(
            Ok(inferred.interface),
            dict.insert(inferred.cache, path, inferred.interface),
          ))
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
    // The scope entry each public name holds, verbatim. In best-effort mode a
    // public definition girard declined leaves the entry of whatever it
    // shadowed — an unqualified import, say — and exporting that entry whole
    // is what tells an importer the identity it was actually typed against.
    values: take(env.values, value_names),
    types: take(env.local_types, type_names),
    aliases: resolve_aliases(env, st, type_names),
    // Only non-opaque public types expose their field accessors: an opaque
    // type's fields are private to its defining module.
    accessors: take(env.accessors, accessor_type_names),
    modules: env.modules,
    reachable: env.module_index,
    unavailable: env.unavailable,
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
) -> Dict(String, #(List(Int), ty.Type)) {
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
  body: ty.Type,
  arguments: List(ty.Type),
) -> ty.Type {
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
//
// `reachable` is what carries the transitive half, rather than a walk over
// `modules`: `modules` is keyed by the alias a module was imported under, so a
// discard-aliased import is missing from it and everything only that import
// could reach would be unreachable from here.
fn index_interface(
  index: Dict(String, ModuleInterface),
  interface: ModuleInterface,
) -> Dict(String, ModuleInterface) {
  // Already indexed: stop. Guards the DAG against re-walking shared modules.
  use <- bool.guard(when: dict.has_key(index, interface.name), return: index)
  let index = dict.insert(index, interface.name, interface)
  dict.fold(interface.reachable, index, fn(acc, name, nested) {
    case dict.has_key(acc, name) {
      True -> acc
      False -> dict.insert(acc, name, nested)
    }
  })
}

// Bring a single value (function/constant/constructor) into scope unqualified.
fn import_value(
  env: Env,
  local: String,
  interface: ModuleInterface,
  original: String,
) -> Env {
  // The entry is copied verbatim, so the identity it carries stays the one it
  // was declared under — the exporting module's real path and the name the
  // value has *there*, never the alias it reached this module under. Through
  // `install_entry` rather than a raw insert, so `open_values` is maintained
  // from the entry's own scheme like every other write.
  case dict.get(interface.values, original) {
    Error(_) -> env
    Ok(entry) -> install_entry(env, local, entry)
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
//
// The dropped functions and constants come back with the filtered module, to
// be published: they are the definitions that hold expressions, so they are
// the ones a consumer can find a span inside and no annotation at. A dropped
// import, custom type or alias has no body, so its absence needs no
// explanation and none is reported.
fn for_target(
  module: glance.Module,
  target: Target,
) -> #(glance.Module, List(Dropped)) {
  let #(functions, dropped_functions) =
    list.partition(module.functions, on_target(_, target))
  let #(constants, dropped_constants) =
    list.partition(module.constants, on_target(_, target))
  let module =
    glance.Module(
      imports: list.filter(module.imports, on_target(_, target)),
      custom_types: list.filter(module.custom_types, on_target(_, target)),
      type_aliases: list.filter(module.type_aliases, on_target(_, target)),
      constants:,
      functions:,
    )
  // glance keeps functions and constants in separate lists, so concatenating
  // the two is per-category order; the span sort restores source order, which
  // is what an interleaved pair was written in.
  let dropped =
    list.append(
      list.map(dropped_functions, fn(d) {
        Dropped(d.definition.name, d.definition.location)
      }),
      list.map(dropped_constants, fn(d) {
        Dropped(d.definition.name, d.definition.location)
      }),
    )
  #(module, sort_dropped(dropped))
}

fn on_target(definition: glance.Definition(a), target: Target) -> Bool {
  // The compiler still accepts the deprecated `erl` and `js` shorthands, with a
  // warning, so each target answers to both of its names.
  let names = case target {
    Erlang -> ["erlang", "erl"]
    JavaScript -> ["javascript", "js"]
  }
  list.all(definition.attributes, fn(attr) {
    case attr.name, attr.arguments {
      "target", [glance.Variable(_, name)] -> list.contains(names, name)
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
fn resolve(st: State, type_: ty.Type) -> ty.Type {
  case type_ {
    ty.Var(id) ->
      case dict.get(st.subst, id) {
        Ok(bound) -> resolve(st, bound)
        Error(_) -> type_
      }
    _ -> type_
  }
}

// The substitution with every bound id mapped straight to the end of its
// chain, for publication. The compiler's order links each new variable to the
// next, as the elements of `[[], [], ..]` are, and `unify`'s compression
// re-links only its left variable, as the compiler's does, so a chain can
// still be long, and zonking every recorded type through it would be
// quadratic. Each chain is walked once and every id on it rebound to its end,
// so the whole pass is linear in the substitution's size: an id bound to a
// type is the end of its chain already and is skipped, and an id is rebound
// only where it does not point at the end yet. It is the same substitution
// with its chains shortened: every type zonks the same, and the same ids are
// bound (`literal_links` reads which). It runs once inference is done, never
// on the inference path.
fn compress_substitution(st: State) -> State {
  let subst =
    dict.fold(st.subst, st.subst, fn(subst, id, bound) {
      case bound {
        ty.Var(_) -> {
          let #(chain, end) = chain_end(subst, id, [])
          list.fold(chain, subst, fn(subst, id) { dict.insert(subst, id, end) })
        }
        ty.Named(..) | ty.Fn(..) | ty.Tuple(..) -> subst
      }
    })
  State(..st, subst:)
}

// The ids from `id` along its chain that do not point at its end yet, and the
// end: a type that is no variable, or an unbound variable. A loop, so a long
// chain needs no deep stack.
fn chain_end(
  subst: Dict(Int, ty.Type),
  id: Int,
  chain: List(Int),
) -> #(List(Int), ty.Type) {
  case dict.get(subst, id) {
    Ok(ty.Var(next) as link) ->
      case dict.has_key(subst, next) {
        True -> chain_end(subst, next, [id, ..chain])
        False -> #(chain, link)
      }
    Ok(end) -> #(chain, end)
    Error(Nil) -> #(chain, ty.Var(id))
  }
}

// Fully apply the substitution, leaving only unbound variables as `Var`.
fn zonk(st: State, type_: ty.Type) -> ty.Type {
  case resolve(st, type_) {
    ty.Named(module, name, args, variant) ->
      ty.Named(module, name, list.map(args, zonk(st, _)), variant)
    ty.Fn(args, ret) -> ty.Fn(list.map(args, zonk(st, _)), zonk(st, ret))
    ty.Tuple(elements) -> ty.Tuple(list.map(elements, zonk(st, _)))
    ty.Var(id) -> ty.Var(id)
  }
}

fn free_vars(st: State, type_: ty.Type) -> List(Int) {
  free_vars_loop(zonk(st, type_), [])
}

fn free_vars_loop(type_: ty.Type, acc: List(Int)) -> List(Int) {
  case type_ {
    ty.Var(id) ->
      case list.contains(acc, id) {
        True -> acc
        False -> [id, ..acc]
      }
    ty.Named(_, _, args, _) ->
      list.fold(args, acc, fn(a, t) { free_vars_loop(t, a) })
    ty.Fn(args, ret) ->
      free_vars_loop(
        ret,
        list.fold(args, acc, fn(a, t) { free_vars_loop(t, a) }),
      )
    ty.Tuple(elements) ->
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
  type_: ty.Type,
  bound: List(Int),
  acc: List(Int),
) -> List(Int) {
  case type_ {
    ty.Var(id) ->
      case list.contains(bound, id) {
        True -> acc
        False ->
          case resolve(st, type_) {
            ty.Var(resolved) ->
              case list.contains(acc, resolved) {
                True -> acc
                False -> [resolved, ..acc]
              }
            other -> scheme_free_vars(st, other, bound, acc)
          }
      }
    ty.Named(_, _, args, _) ->
      list.fold(args, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) })
    ty.Fn(args, ret) ->
      scheme_free_vars(
        st,
        ret,
        bound,
        list.fold(args, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) }),
      )
    ty.Tuple(elements) ->
      list.fold(elements, acc, fn(a, t) { scheme_free_vars(st, t, bound, a) })
  }
}

// Inferred variants
//
// The variant a value is known to have been built with, carried on the
// inference-side `Named`. A constructor's return type is stamped with its
// index; binding a type variable to a type erases the variant of what it is
// bound to, and generalizing a top-level definition erases every variant in
// its type. The compiler's `set_custom_type_variant` and
// `generalise_custom_type_variant`.

// Mark a type as known to be its `variant`th constructor. Named types only,
// through a bound variable; functions and tuples carry no variant, so they are
// returned as they are.
fn stamp(st: State, type_: ty.Type, variant: Int) -> ty.Type {
  case resolve(st, type_) {
    ty.Named(module, name, args, _) ->
      ty.Named(module, name, args, Some(variant))
    other -> other
  }
}

// The variant a (resolved) type is known to have been built with.
fn variant_of(type_: ty.Type) -> Option(Int) {
  case type_ {
    ty.Named(_, _, _, variant) -> variant
    _ -> None
  }
}

// Forget which variant a value was built with, as happens when it is bound to
// a type variable. It reaches through functions and tuples but *not* into a
// named type's arguments: a `List(Loud)` still knows its elements are `Loud`.
// No substitution walk is needed — the type arrives resolved, and anything
// reachable through a bound variable below it was itself erased when that
// variable was bound.
fn erase_variant(type_: ty.Type) -> ty.Type {
  case type_ {
    ty.Named(module, name, args, _) -> ty.Named(module, name, args, None)
    ty.Fn(args, ret) -> ty.Fn(list.map(args, erase_variant), erase_variant(ret))
    ty.Tuple(elements) -> ty.Tuple(list.map(elements, erase_variant))
    ty.Var(_) -> type_
  }
}

// Erase every variant at every depth, arguments included. This is the erase a
// top-level definition's generalization performs, where `erase_variant`'s
// shallower reach is the one a variable binding performs.
fn erase_all(type_: ty.Type) -> ty.Type {
  case type_ {
    ty.Named(module, name, args, _) ->
      ty.Named(module, name, list.map(args, erase_all), None)
    ty.Fn(args, ret) -> ty.Fn(list.map(args, erase_all), erase_all(ret))
    ty.Tuple(elements) -> ty.Tuple(list.map(elements, erase_all))
    ty.Var(_) -> type_
  }
}

// Unification
//
// Unify two types, binding flexible variables and rejecting rigid ones, with
// the occurs check that guards against infinite types.
//
// When both sides are unbound variables `unify` binds the left one, as
// 1.19.2's `unify(t1, t2)` links `t1` (`environment.rs:1055-1100`), so every
// call passes its two types in the compiler's order at that site, the
// expected type first where the compiler puts it first. The link directions,
// and the two types a mismatch reports, are then the compiler's; the solution
// is the same either way.
//
// A left argument that is a variable already bound is unified through what it
// is bound to and then, once that succeeds, rebound to the end of its chain,
// as the compiler unifies `t1`'s link and re-links `t1`'s cell to
// `collapse_links` of it (`environment.rs:1103-1117`); bound to a type rather
// than a variable, it is at the end already. The compiler's order
// links each new variable to the next, as the elements of `[[], [], ..]` are,
// and without this every later unification would follow the whole chain from
// its first variable. It rebinds a bound variable to the same type, so the
// substitution means the same and no variable becomes bound that was not; the
// end is what `bind_var` stored, its variant already erased.
fn unify(st: State, left: ty.Type, right: ty.Type) -> Result(State, Failure) {
  case left {
    ty.Var(id) ->
      case dict.get(st.subst, id) {
        // A link to another variable: re-linked to the end once unified.
        Ok(ty.Var(_) as bound) -> {
          use st <- result.map(unify(st, bound, right))
          State(..st, subst: dict.insert(st.subst, id, resolve(st, bound)))
        }
        // Bound to a type: that type is already the end of the chain.
        Ok(bound) -> unify(st, bound, right)
        Error(Nil) -> unify_heads(st, left, resolve(st, right))
      }
    ty.Named(..) | ty.Fn(..) | ty.Tuple(..) ->
      unify_heads(st, left, resolve(st, right))
  }
}

// `unify` on two heads: `left` is no bound variable, and `right` is resolved.
fn unify_heads(
  st: State,
  left: ty.Type,
  right: ty.Type,
) -> Result(State, Failure) {
  case left, right {
    ty.Var(i), ty.Var(j) if i == j -> Ok(st)
    // A rigid variable never binds; a flexible one may bind to it. Two distinct
    // rigid variables, or a rigid variable against a concrete type, mismatch.
    ty.Var(i), ty.Var(j) ->
      case is_rigid(st, i), is_rigid(st, j) {
        True, True -> fail(st, type_mismatch(left, right))
        True, False -> bind_var(st, j, left)
        False, _ -> bind_var(st, i, right)
      }
    ty.Var(i), other ->
      case is_rigid(st, i) {
        True -> fail(st, type_mismatch(left, right))
        False -> bind_var(st, i, other)
      }
    other, ty.Var(j) ->
      case is_rigid(st, j) {
        True -> fail(st, type_mismatch(left, right))
        False -> bind_var(st, j, other)
      }

    // A pair of different lengths fails before any element is unified, as the
    // compiler checks lengths first (`environment.rs:1147, 1163, 1182-1188`):
    // a named type or a tuple with a plain mismatch, a function with the arity
    // reason. Within a pair the elements unify left to right, a function's
    // parameters before its return, and stop at the first failure, whose state
    // keeps the links made before it.
    ty.Named(m1, n1, a1, _), ty.Named(m2, n2, a2, _) if m1 == m2 && n1 == n2 ->
      case same_length(a1, a2) {
        True -> unify_many(st, a1, a2)
        False -> fail(st, type_mismatch(left, right))
      }

    ty.Fn(args1, r1), ty.Fn(args2, r2) ->
      case same_length(args1, args2) {
        True -> {
          use st <- result.try(unify_many(st, args1, args2))
          unify(st, r1, r2)
        }
        False -> fail(st, ArityMismatch)
      }

    ty.Tuple(e1), ty.Tuple(e2) ->
      case same_length(e1, e2) {
        True -> unify_many(st, e1, e2)
        False -> fail(st, type_mismatch(left, right))
      }

    _, _ -> fail(st, type_mismatch(left, right))
  }
}

// Unify two lists of the same length, element by element, left to right.
fn unify_many(
  st: State,
  left: List(ty.Type),
  right: List(ty.Type),
) -> Result(State, Failure) {
  case left, right {
    [x, ..xs], [y, ..ys] -> {
      use st <- result.try(unify(st, x, y))
      unify_many(st, xs, ys)
    }
    // Both lists are empty: every caller checks the lengths first.
    _, _ -> Ok(st)
  }
}

fn same_length(left: List(a), right: List(b)) -> Bool {
  case left, right {
    [], [] -> True
    [_, ..left], [_, ..right] -> same_length(left, right)
    [], [_, ..] | [_, ..], [] -> False
  }
}

fn bind_var(st: State, id: Int, type_: ty.Type) -> Result(State, Failure) {
  use <- bool.lazy_guard(when: occurs(st, id, type_), return: fn() {
    fail(st, recursive_type(id, type_))
  })
  // A value bound to a type variable is no longer known to be any one variant:
  // this is the compiler's erase, in the one place a variable is ever bound.
  Ok(State(..st, subst: dict.insert(st.subst, id, erase_variant(type_))))
}

fn occurs(st: State, id: Int, type_: ty.Type) -> Bool {
  list.contains(free_vars(st, type_), id)
}

// Generalization and instantiation
//
// Generalize a type into a scheme at a definition boundary — quantifying
// variables free in the type but not the environment — and instantiate a
// scheme back to a monotype with fresh variables.

fn generalize(st: State, env: Env, type_: ty.Type) -> ty.Scheme {
  // A generalized definition is used at types its body never saw, so nothing
  // it returns is known to be one variant any more.
  let zonked = erase_all(zonk(st, type_))
  let env_vars = env_free_vars(st, env)
  let quantified =
    list.filter(free_vars(st, zonked), fn(id) { !list.contains(env_vars, id) })
  ty.Scheme(quantified, zonked)
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
fn instantiate(st: State, scheme: ty.Scheme) -> #(ty.Type, State) {
  use <- bool.guard(when: scheme.vars == [], return: #(scheme.type_, st))
  let #(mapping, st) = copy_vars(st, scheme.vars)
  #(substitute(mapping, scheme.type_), st)
}

// A fresh variable for each of `ids`, in order: the mapping from each id to
// its copy.
fn copy_vars(st: State, ids: List(Int)) -> #(Dict(Int, ty.Type), State) {
  list.fold(ids, #(dict.new(), st), fn(acc, id) {
    let #(mapping, st) = acc
    let #(copy, st) = fresh(st)
    #(dict.insert(mapping, id, copy), st)
  })
}

// Read a value: instantiate its scheme, then copy every generic the type
// reaches that the current scope does not own, one fresh variable per id, as
// the compiler's `instantiate` does at every variable read, locals included
// (`expression.rs:3321`, `environment.rs:717-735`). That covers another
// function's signature variables, generalized or not, a body annotation's
// generics once out of scope, and another function's body generics that
// reached this one through a shared, unannotated part. A generic in scope is
// left alone.
//
// The type a read gives is link-free, zonked through the substitution, as the
// compiler's `instantiate` collapses every link it meets
// (`environment.rs:705-715, 758-780`). A binding is stored at the type it was
// matched against, which is often a read's, and the alternatives compare
// bindings raw (`erased_by_later`), so a read must be as raw as the
// compiler's.
fn read_value(st: State, scheme: ty.Scheme) -> #(ty.Type, State) {
  let #(type_, st) = instantiate(st, scheme)
  let zonked = zonk(st, type_)
  // Every read is zonked; one that reaches no unowned generic has nothing to
  // copy.
  use <- bool.guard(when: !reaches_unowned(st, zonked), return: #(zonked, st))
  let unowned = list.filter(free_vars_loop(zonked, []), is_unowned(st, _))
  case unowned {
    [] -> #(zonked, st)
    _ -> instantiate(st, ty.Scheme(unowned, zonked))
  }
}

// A generic the current scope does not own, which a read copies.
fn is_unowned(st: State, id: Int) -> Bool {
  is_rigid(st, id) && !set.contains(st.scope.owned, id)
}

// A read of a value the compiler holds in a local it generated: the piped
// value a pipe step reads (`pipe.rs:97-125, 297-355`), a capture's own
// parameter at its hole, a complex `use` pattern's parameter. The compiler
// reads each the way it reads any local, instantiating it at the read
// (`expression.rs:3321`), so the read copies a generic out of scope; the left
// value of a bare callable step and of `|> echo` is used directly, with no
// read.
fn read_type(st: State, type_: ty.Type) -> #(ty.Type, State) {
  read_value(st, ty.Scheme([], type_))
}

// Whether `type_`, resolved through the substitution, mentions a generic the
// current scope does not own: a walk that allocates nothing, so a read that
// reaches none, which is nearly every read, is its zonked type, with no
// variables collected and nothing copied. Every generic the scope owns is
// rigid, so when it owns them all there is nothing to walk for.
fn reaches_unowned(st: State, type_: ty.Type) -> Bool {
  use <- bool.guard(
    when: set.size(st.rigid) == set.size(st.scope.owned),
    return: False,
  )
  reaches_unowned_loop(st, type_)
}

fn reaches_unowned_loop(st: State, type_: ty.Type) -> Bool {
  case resolve(st, type_) {
    ty.Var(id) -> is_unowned(st, id)
    ty.Named(_, _, args, _) -> list.any(args, reaches_unowned_loop(st, _))
    ty.Fn(args, ret) ->
      list.any(args, reaches_unowned_loop(st, _))
      || reaches_unowned_loop(st, ret)
    ty.Tuple(elements) -> list.any(elements, reaches_unowned_loop(st, _))
  }
}

// A module constant named by a bare variable in a clause guard. The compiler
// takes the constant's stored literal (`infer_clause_guard_variable`,
// `type_/guard.rs:322-324`) rather than instantiating its scheme, so the read
// is not copied, and the literal keeps the variants its value was built with.
// A constant of the current group, or one with no variable to copy, is read at
// its literal as it stands. One already generalized is read at a single copy
// of its literal, made on its first guard read and shared by every later one,
// as the literal's cells are shared: a fresh variable for each variable its
// scheme quantifies, and for each generic one a fresh generic, made here so it
// can never collide with an id of the module that inferred the literal.
fn guard_constant_read(
  st: State,
  scheme: ty.Scheme,
  module: String,
  name: String,
  literal: ConstantLiteral,
) -> #(ty.Type, State) {
  use <- bool.guard(when: scheme.vars == [], return: #(literal.type_, st))
  case dict.get(st.literals, #(module, name)) {
    Ok(view) -> #(view, st)
    Error(_) -> {
      let #(mapping, st) = copy_vars(st, scheme.vars)
      let generics =
        list.filter_map(set.to_list(literal.generics), fn(id) {
          result.try(dict.get(mapping, id), var_id)
        })
      let view = substitute(mapping, literal.type_)
      let st = mark_rigid(st, generics)
      #(
        view,
        State(..st, literals: dict.insert(st.literals, #(module, name), view)),
      )
    }
  }
}

// Read a name in scope as a value: its scope entry, and the type this read
// gets from `read_value`. Every value read goes through here (a variable, a
// callee name, a record-update shorthand, a pattern size), so none can skip
// the copy of a generic out of scope.
fn read_name(
  env: Env,
  st: State,
  name: String,
) -> Result(#(ValueConstructor, ty.Type, State), Failure) {
  case dict.get(env.values, name) {
    Error(_) -> fail(st, UnboundVariable(name))
    Ok(entry) -> {
      let #(type_, st) = read_value(st, entry.scheme)
      Ok(#(entry, type_, st))
    }
  }
}

fn substitute(mapping: Dict(Int, ty.Type), type_: ty.Type) -> ty.Type {
  case type_ {
    ty.Var(id) ->
      case dict.get(mapping, id) {
        Ok(replacement) -> replacement
        Error(_) -> type_
      }
    ty.Named(module, name, args, variant) ->
      ty.Named(module, name, list.map(args, substitute(mapping, _)), variant)
    ty.Fn(args, ret) ->
      ty.Fn(list.map(args, substitute(mapping, _)), substitute(mapping, ret))
    ty.Tuple(elements) -> ty.Tuple(list.map(elements, substitute(mapping, _)))
  }
}

// Top-level definitions
//
// Infer a top-level function or constant and register a custom type's
// constructors and accessors, then resolve the field and tuple accesses
// deferred until inference fixed their container types.

// The type-variable names a function's parameter and return annotations write.
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
// for the body; each unannotated part is a fresh flexible variable, shared by
// the whole group until it is generalized. Returns the parameter types, the
// return type and the scope the body starts in: the name table and the ids
// made rigid, which are also recorded in `State`.
fn signature_skeleton(
  env: Env,
  st: State,
  function: glance.Function,
) -> #(List(ty.Type), ty.Type, Scope, State) {
  // One rigid id per distinct annotation variable name, shared across the whole
  // signature (so a parameter `a` and the return `a` are the same variable).
  let #(names, rigid_ids, st) =
    list.fold(
      list.unique(function_annotation_var_names(function)),
      #(dict.new(), [], st),
      fn(acc, name) {
        let #(names, ids, st) = acc
        let #(id, st) = fresh_id(st)
        #(dict.insert(names, name, ty.Var(id)), [id, ..ids], st)
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
  let scope = Scope(names, set.from_list(rigid_ids))
  #(list.reverse(rev_param_types), return_type, scope, st)
}

// Bind parameters, by their names, to the given types in `env`.
fn bind_params(
  env: Env,
  names: List(glance.AssignmentName),
  types_: List(ty.Type),
) -> Env {
  list.fold(list.zip(names, types_), env, fn(env, pair) {
    case pair.0 {
      glance.Named(name) -> bind_local(env, name, pair.1)
      glance.Discarded(_) -> env
    }
  })
}

// Infer a function's body and check it against its registered return type.
// `@external` functions have no body and pass trivially.
fn check_body(
  env: Env,
  st: State,
  function: glance.Function,
  return_type: ty.Type,
) -> Result(State, Failure) {
  case function.body {
    [] -> Ok(st)
    _ -> {
      use #(body_type, st) <- result.try(infer_statements(
        env,
        st,
        function.body,
      ))
      unify(st, return_type, body_type)
    }
  }
}

// Infer a module constant, returning its literal: its type (an annotation, if
// present, is applied) and the ids its annotation made generics. A constant is
// inferred with a hydrator of its own (`analyse.rs:446-453`), so its scope
// starts empty: every read in it copies every generic, and its annotation's
// names create generics of its own.
fn infer_constant(
  env: Env,
  st: State,
  constant: glance.Constant,
) -> Result(#(ConstantLiteral, State), Failure) {
  use #(value_type, st) <- result.try(infer_expr(
    Env(..env, syntax: ConstantSyntax),
    st,
    constant.value,
  ))
  case constant.annotation {
    Some(ann) -> {
      let #(t, st) = hydrate_scoped(env, st, ann)
      use st <- result.try(unify(st, t, value_type))
      let literal = ConstantLiteral(value_type, st.scope.owned)
      Ok(#(literal, State(..st, scope: empty_scope())))
    }
    None -> Ok(#(ConstantLiteral(value_type, set.new()), st))
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
  let param_vars = list.map(param_ids, ty.Var)
  let names = dict.from_list(list.zip(custom_type.parameters, param_vars))
  let return_type =
    ty.Named(env.current_module, custom_type.name, param_vars, None)

  // Build constructors, keeping each variant's fields in declaration order
  // (label and type per position) so we can later expose accessors for labels
  // shared across all variants.
  let #(env, st, rev_variant_fields) =
    list.index_fold(
      custom_type.variants,
      #(env, st, []),
      fn(acc, variant, index) {
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
        let #(labels, field_types) = list.unzip(fields)
        // A constructor's return type is known to be that constructor, so
        // construction narrows with nothing else having to notice.
        let built = stamp(st, return_type, index)
        let ctor_type = case field_types {
          [] -> built
          _ -> ty.Fn(field_types, built)
        }
        let env =
          install(
            env,
            variant.name,
            ty.Scheme(param_ids, ctor_type),
            ConstructorValue(
              env.current_module,
              variant.name,
              field_map_of(labels),
            ),
          )
        #(env, st, [fields, ..variant_fields])
      },
    )

  // A label is shared iff every variant declares it at the same position with
  // the same type. (Single-variant records are the degenerate case where every
  // label qualifies.) A value known to be one variant reads that variant's own
  // map instead, where every label it declares qualifies.
  let variant_fields = list.reverse(rev_variant_fields)
  let shared = shared_accessors(variant_fields, param_ids, return_type)
  let accessors =
    Accessors(shared:, by_variant: case variant_fields {
      // Every label of a single-variant type is shared, so the two maps are
      // the same one and the type keeps one copy.
      [_] -> [shared]
      _ ->
        list.map(variant_fields, variant_accessors(_, param_ids, return_type))
    })
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
  variants: List(List(#(Option(String), ty.Type))),
  param_ids: List(Int),
  return_type: ty.Type,
) -> Dict(String, ty.Scheme) {
  case variants {
    [] -> dict.new()
    [first, ..rest] ->
      list.index_fold(first, dict.new(), fn(accessors, field, index) {
        let shared =
          list.all(rest, fn(variant) { list_at(variant, index) == Ok(field) })
        case field, shared {
          #(Some(label), field_type), True ->
            dict.insert(
              accessors,
              label,
              ty.Scheme(param_ids, ty.Fn([return_type], field_type)),
            )
          _, _ -> accessors
        }
      })
  }
}

// Accessor schemes for one variant's own labelled fields. This is the
// compiler's `custom_type_accessors`: a value known to be this variant reads
// every label the variant declares, shared with the others or not. The
// argument type is the *unstamped* return type, so a stamped record still
// unifies with it.
fn variant_accessors(
  fields: List(#(Option(String), ty.Type)),
  param_ids: List(Int),
  return_type: ty.Type,
) -> Dict(String, ty.Scheme) {
  list.fold(fields, dict.new(), fn(accessors, field) {
    case field {
      #(Some(label), field_type) ->
        dict.insert(
          accessors,
          label,
          ty.Scheme(param_ids, ty.Fn([return_type], field_type)),
        )
      #(None, _) -> accessors
    }
  })
}

// Look up the accessor scheme for `label` on a (resolved) record type. The
// accessors live with whichever module defined the type — the current module,
// or an imported one identified by the type's origin module.
fn accessor(
  env: Env,
  record: ty.Type,
  label: String,
) -> Result(ty.Scheme, Error) {
  case record {
    ty.Named(module, name, _, variant) -> {
      let accessors = accessors_of_module(env, module)
      case dict.get(accessors, name) {
        Ok(found) ->
          case dict.get(accessors_for_variant(found, variant), label) {
            Ok(scheme) -> Ok(scheme)
            Error(_) -> Error(NoSuchField(name, label))
          }
        Error(_) -> Error(NoSuchField(name, label))
      }
    }
    _ -> Error(NotARecord)
  }
}

// The accessors a record grants: the known variant's own where the value is
// known to be one, else the labels every variant shares. A variant's map is
// the whole answer, not an addition to the shared one, so a value known to be
// a variant that does not declare the label has no accessor for it. An index
// out of range falls back to the shared map, as the compiler's
// `accessors_for_variant` does.
fn accessors_for_variant(
  accessors: Accessors,
  variant: Option(Int),
) -> Dict(String, ty.Scheme) {
  case variant {
    Some(index) ->
      result.unwrap(list_at(accessors.by_variant, index), accessors.shared)
    None -> accessors.shared
  }
}

fn accessors_of_module(env: Env, module: String) -> Dict(String, Accessors) {
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
fn resolve_pending(env: Env, st: State) -> Result(State, Failure) {
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
) -> Result(State, Failure) {
  case pending, fuel <= 0 {
    [], _ -> Ok(st)
    [_, ..], True -> fail(st, NotARecord)
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
        False -> fail(st, NotARecord)
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
) -> Result(#(State, Bool), Failure) {
  case item {
    PendingField(container, label, field) ->
      case resolve(st, container) {
        ty.Named(_, _, _, _) as record -> {
          use scheme <- result.try(stateless(st, accessor(env, record, label)))
          let #(accessor_type, st) = instantiate(st, scheme)
          use st <- result.try(unify(
            st,
            accessor_type,
            ty.Fn([container], field),
          ))
          Ok(#(st, True))
        }
        ty.Var(_) -> Ok(#(st, False))
        _ -> fail(st, NotARecord)
      }
    PendingIndex(container, index, result) ->
      case resolve(st, container) {
        ty.Tuple(elements) ->
          case list_at(elements, index) {
            Ok(element) -> {
              use st <- result.try(unify(st, result, element))
              Ok(#(st, True))
            }
            Error(_) -> fail(st, TupleIndexOutOfRange(index))
          }
        ty.Var(_) -> Ok(#(st, False))
        _ -> fail(st, NotATuple)
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

// `infer_expr` owns recording an ordinary expression's span: it records the
// type `infer_expr_inner` returns, so a helper reached only through it — a
// call, a capture, a pipe — records nothing at the span it was handed, or the
// expression would be published twice. The paths that walk an expression
// without passing through here record it once, explicitly, where they walk
// it: a callee resolved in `infer_callee`, a function literal seeded through
// `infer_seeded` (by `check`, a literal callee or a pipe step), and the call a
// pipe step makes, which `infer_pipe_call` checks against its callee itself.
fn infer_expr(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(ty.Type, State), Failure) {
  // A guard subtree the compiler parses as a constant is typed as one
  // (`type_/guard.rs:164-166`), all the way down.
  let env = case env.syntax == GuardSyntax && reference.guard_constant(expr) {
    True -> Env(..env, syntax: ConstantSyntax)
    False -> env
  }
  use #(type_, st) <- result.try(infer_expr_inner(env, st, expr))
  Ok(#(type_, record(st, span(expr), type_)))
}

fn infer_expr_inner(
  env: Env,
  st: State,
  expr: glance.Expression,
) -> Result(#(ty.Type, State), Failure) {
  case expr {
    glance.Int(..) -> Ok(#(prelude_int(), st))
    glance.Float(..) -> Ok(#(prelude_float(), st))
    glance.String(..) -> Ok(#(prelude_string(), st))

    glance.Variable(_, name) ->
      case env.syntax {
        GuardSyntax -> guard_variable(env, st, name)
        ExpressionSyntax -> read_variable(env, st, name)
        // A name the constant typer cannot find is an invalid constant, a
        // fresh variable, at the name itself (`constant.rs:425-441`).
        ConstantSyntax -> recover_fresh(env, read_variable(env, st, name))
      }

    // An operand, an element and a rest are each a sub-expression the
    // compiler types through `infer`, and each unification is recorded
    // (`expression.rs:937-941, 1005-1010, 1244-1298`).
    glance.NegateInt(_, value) -> {
      use #(t, st) <- result.try(infer_recovering(env, st, value))
      use st <- result.try(recover_unify(env, st, prelude_int(), t))
      Ok(#(prelude_int(), st))
    }

    glance.NegateBool(_, value) -> {
      use #(t, st) <- result.try(infer_recovering(env, st, value))
      use st <- result.try(recover_unify(env, st, prelude_bool(), t))
      Ok(#(prelude_bool(), st))
    }

    glance.Tuple(_, elements) -> {
      use #(elem_types, st) <- result.try(
        infer_each(st, elements, fn(st, element) {
          infer_recovering(env, st, element)
        }),
      )
      Ok(#(ty.Tuple(elem_types), st))
    }

    glance.List(_, elements, rest) -> {
      let #(elem, st) = fresh(st)
      use st <- result.try(
        list.try_fold(elements, st, fn(st, e) {
          use #(t, st) <- result.try(infer_recovering(env, st, e))
          recover_unify(env, st, elem, t)
        }),
      )
      use st <- result.try(case rest {
        Some(r) -> {
          use #(t, st) <- result.try(infer_recovering(env, st, r))
          recover_unify(env, st, prelude_list(elem), t)
        }
        None -> Ok(st)
      })
      Ok(#(prelude_list(elem), st))
    }

    glance.Fn(_, params, return_annotation, body) ->
      // No expected type: each parameter has only its own.
      infer_lambda(env, st, params, return_annotation, body, None)

    glance.Call(_, function, arguments) ->
      infer_call(env, st, function, list.map(arguments, map_field(_, Written)))

    glance.FnCapture(span, label, function, before, after) ->
      infer_capture(env, st, span, label, function, before, after, None)

    glance.BinaryOperator(_, op, left, right) ->
      infer_binop(env, st, op, left, right)

    // A block is a scope of its own (`expression.rs:4178`).
    glance.Block(_, statements) -> {
      use st <- scoped(st)
      infer_statements(env, st, statements)
    }

    glance.Case(_, subjects, clauses) -> infer_case(env, st, subjects, clauses)

    // One of the two places that read `Env.recovering` itself rather than
    // through a recovery helper, because what differs is what succeeds, not
    // how a failure recovers: a speculative guard index reads its child's
    // type as produced, while strict mode resolves it (the other place is
    // `tuple_index`).
    glance.TupleIndex(_, tuple, index) -> {
      use #(t, st) <- result.try(infer_expr(env, st, tuple))
      case env.syntax, env.recovering {
        GuardSyntax, True -> Ok(guard_tuple_index(st, t, index))
        _, _ -> tuple_index(env, st, t, index)
      }
    }

    // `panic` and `todo` are bottom, so the result is a fresh variable that
    // unifies with anything. The message is still walked — and checked against
    // `String`, as the compiler requires — so its subexpressions get annotated.
    // It is checked directly, not through `check_message`, which says why.
    glance.Todo(_, message) | glance.Panic(_, message) ->
      case message {
        Some(m) -> {
          use st <- result.try(check(env, st, m, prelude_string()))
          Ok(fresh(st))
        }
        None -> Ok(fresh(st))
      }

    // The value is typed through `infer`, so its message is walked even
    // after the value failed (`expression.rs:628-648`).
    glance.Echo(_, Some(expression), message) -> {
      use #(type_, st) <- result.try(infer_recovering(env, st, expression))
      use st <- result.try(check_message(env, st, message))
      Ok(#(type_, st))
    }

    // glance builds an `echo` with no expression only as the unit right after
    // `|>`, which `infer_pipe` types as the piped value. It reaches here only
    // when that unit is wrapped, as in `x |> echo(1)` or `x |> echo + 1`, and
    // the compiler rejects both: `Nil` rejects them too, where a fresh
    // variable would accept them with a type.
    glance.Echo(_, None, _message) -> Ok(#(prelude_nil(), st))

    glance.FieldAccess(access, container, label) -> {
      use #(type_, _, st) <- result.try(infer_field_access(
        env,
        st,
        access,
        container,
        label,
      ))
      Ok(#(type_, st))
    }

    glance.RecordUpdate(_, module, constructor, record, fields) -> {
      let update =
        infer_record_update(env, st, module, constructor, record, fields)
      case env.syntax {
        // The constant typer makes a failed record update a fresh invalid
        // constant whole (`constant.rs:275-316, 836-843`).
        ConstantSyntax -> recover_fresh(env, update)
        ExpressionSyntax | GuardSyntax -> update
      }
    }

    // The first segment that fails fails the bit array, and the segments
    // after it are not walked (`expression.rs:1666-1682`). A constant's bit
    // array is still a `BitArray` when it fails (`constant.rs:91-101`).
    glance.BitString(_, segments) -> {
      let walked =
        list.try_fold(segments, st, fn(st, segment) {
          infer_bit_segment(env, st, segment)
        })
      let walked = case env.syntax {
        ConstantSyntax -> recover_with(env, walked, Ok)
        ExpressionSyntax | GuardSyntax -> walked
      }
      use st <- result.try(walked)
      Ok(#(prelude_bit_array(), st))
    }
  }
}

// A bare name in a guard. The compiler's guard-variable lookup
// (`guard.rs:303-324`) accepts a local, read as any value is, and a module
// constant, read as its literal (`guard_constant_read`). It rejects a module
// function or a constructor as if the name were unbound, and a lowercase name
// it rejects, or cannot find, fails: the compiler records the error and the
// name is a fresh variable (`guard.rs:36-46`), as it is in a speculative walk
// here. A bare uppercase name is a constructor the compiler parses as a
// constant (`parse.rs:1912-1932`), which never meets the lookup, so it is read
// as one.
//
// The read is the type the lookup gives, not zonked: a local's read is
// already link-free (`read_value`), a name that cannot be read is a fresh
// variable, and a constant's literal is the one stored, links included, as
// the compiler's guard reads it (`guard.rs:322-324`). A speculative guard
// tuple index inspects it as it stands (`guard_tuple_index`), so a link in
// the stored literal is no tuple there, as in the compiler.
fn guard_variable(
  env: Env,
  st: State,
  name: String,
) -> Result(#(ty.Type, State), Failure) {
  let lowercase = !reference.is_upper(name)
  let read = case dict.get(env.values, name) {
    Ok(ValueConstructor(scheme, ConstantValue(module, name, literal))) ->
      Ok(guard_constant_read(st, scheme, module, name, literal))
    Ok(ValueConstructor(_, FunctionValue(..)))
      | Ok(ValueConstructor(_, ConstructorValue(..)))
      | Error(_)
      if lowercase
    -> fail(st, UnboundVariable(name))
    Ok(_) | Error(_) -> read_variable(env, st, name)
  }
  recover_fresh(env, read)
}

// A name read as an ordinary value, its type alone (`read_name`).
fn read_variable(
  env: Env,
  st: State,
  name: String,
) -> Result(#(ty.Type, State), Failure) {
  use #(_, type_, st) <- result.map(read_name(env, st, name))
  #(type_, st)
}

// A tuple index in a guard, in a speculative walk. The compiler's guard index
// matches the child's type as the child produced it, without following
// links (`guard.rs:49-93`), where an expression index collapses them first
// (`expression.rs:1577-1591`). girard's node is the type unresolved, since a
// variable bound in the substitution is the compiler's linked cell: a tuple
// gives its element as it stands, and anything else — a variable, bound or
// not, included — is the compiler's recovered `NotATuple`, a fresh variable,
// as is an index out of range.
fn guard_tuple_index(
  st: State,
  tuple: ty.Type,
  index: Int,
) -> #(ty.Type, State) {
  case tuple {
    ty.Tuple(elements) ->
      case list_at(elements, index) {
        Ok(element) -> #(element, st)
        Error(_) -> fresh(st)
      }
    ty.Var(_) | ty.Named(..) | ty.Fn(..) -> fresh(st)
  }
}

// A tuple index on a tuple of type `tuple`. One whose tuple type is not known
// yet is deferred until inference fixes it, except in a speculative walk,
// where the compiler fails with `NotATupleUnbound` (`expression.rs:1577-1601`)
// and so never reaches what deferring would walk next. Strict mode keeps the
// deferral, which is why this reads `Env.recovering` itself.
fn tuple_index(
  env: Env,
  st: State,
  tuple: ty.Type,
  index: Int,
) -> Result(#(ty.Type, State), Failure) {
  case resolve(st, tuple), env.recovering {
    ty.Tuple(elements), _ ->
      case list_at(elements, index) {
        Ok(element) -> Ok(#(element, st))
        Error(_) -> fail(st, TupleIndexOutOfRange(index))
      }
    ty.Var(_), False -> {
      let #(element, st) = fresh(st)
      let st =
        State(..st, pending: [PendingIndex(tuple, index, element), ..st.pending])
      Ok(#(element, st))
    }
    ty.Var(_), True | ty.Named(..), _ | ty.Fn(..), _ -> fail(st, NotATuple)
  }
}

// Check one record-update field: its new value (or shorthand variable) must
// match the field's declared type.
//
// In a speculative walk an expression's update recovers each field as the
// compiler does (`expression.rs:2817-2875`): the value through `infer`, then
// an unknown label is skipped and a mismatch recorded, and the next field
// continues. A constant's update recovers only the value: the constant typer
// fails the whole update at its first bad label or mismatch
// (`constant.rs:275-316`). The compiler also skips a label given twice; a
// repeated label is checked again here, which can only differ in a program
// the compiler rejects, since the same update is walked again strictly.
fn update_field(
  env: Env,
  st: State,
  field: glance.RecordUpdateField(glance.Expression),
  label_types: Dict(String, ty.Type),
  type_name: String,
) -> Result(State, Failure) {
  use #(value_type, st) <- result.try(
    recover_fresh(env, case field.item {
      Some(value) -> infer_expr(env, st, value)
      // Shorthand `label:` refers to the variable named `label`.
      None -> {
        use #(_, type_, st) <- result.map(read_name(env, st, field.label))
        #(type_, st)
      }
    }),
  )
  let checked = case dict.get(label_types, field.label) {
    Ok(expected) -> unify(st, value_type, expected)
    Error(_) -> fail(st, NoSuchField(type_name, field.label))
  }
  case env.syntax {
    ConstantSyntax -> checked
    ExpressionSyntax | GuardSyntax -> recover_with(env, checked, Ok)
  }
}

// Check one bit-array segment in the compiler's order (`infer_bit_segment`,
// `expression.rs:1700-1757`): its value is inferred, then its size option is
// checked, then the value is unified with the segment's type.
fn infer_bit_segment(
  env: Env,
  st: State,
  segment: #(
    glance.Expression,
    List(glance.BitStringSegmentOption(glance.Expression)),
  ),
) -> Result(State, Failure) {
  let #(value, options) = segment
  let default = case value {
    glance.String(..) -> prelude_string()
    glance.Float(..) -> prelude_float()
    _ -> prelude_int()
  }
  use #(value_type, st) <- result.try(infer_expr(env, st, value))
  use st <- result.try(
    list.try_fold(options, st, fn(st, option) {
      case option {
        glance.SizeValueOption(size) -> {
          use #(size_type, st) <- result.try(infer_expr(env, st, size))
          unify(st, prelude_int(), size_type)
        }
        _ -> Ok(st)
      }
    }),
  )
  unify(st, segment_value_type(options, default), value_type)
}

// Which branch a `name.label` access took. A call reads it to pick the
// callee's field map, which is a property of the branch, not of the alias, and
// the resolver reads it to record which member the access resolved to.
type Access {
  // A record field: the compiler's `RecordAccess`, which has no field map.
  // Carries the accessed record's nominal type, live — the reference publishes it
  // zonked, so later unification still refines it.
  Field(record: ty.Type)
  // A module export, by what the interface says it is: the variant carries
  // both the labels a call may use and the identity to publish. The scheme the
  // entry also held has been instantiated by the time the branch is read, so
  // the branch does not carry it.
  Export(variant: ValueVariant)
  // Neither yet: the container's type is still a variable and no module of its
  // name exports the label, so a `PendingField` was queued and no member was
  // decided here.
  Deferred
  // Neither: the access failed in a speculative walk and is a fresh variable,
  // as the compiler's `Invalid` expression is. It names no member.
  Invalid
}

// The export `name.label` reaches when `name` is an imported module: the whole
// scope entry, or nothing when there is no such module or no such export. One
// lookup answers every question a caller has about the export, because the
// interface stores what the caller needs as one thing.
fn module_access(
  env: Env,
  name: String,
  label: String,
) -> Option(ValueConstructor) {
  case dict.get(env.modules, name) {
    Error(_) -> None
    Ok(interface) -> option.from_result(dict.get(interface.values, label))
  }
}

// The one resolver for `name.label`, in projection and in call position
// alike. The compiler's rule: a valid record access wins unconditionally, a
// failing one falls through to a same-named module export, and the record
// error is reported only when neither exists. Which fields the record grants
// is the type's business: a value known to be one variant reaches that
// variant's own fields.
//
// A guard decides by the name instead (`guard.rs:96-140`): when the
// guard-variable lookup accepts it — a local or a module constant
// (`guard.rs:303-324`) — the access is a record access and nothing else, and
// only a name it rejects, a function, a constructor or no value at all, is
// tried as a module, where only a constant can be selected.
fn infer_field_access(
  env: Env,
  st: State,
  access: glance.Span,
  container: glance.Expression,
  label: String,
) -> Result(#(ty.Type, Access, State), Failure) {
  let spans = access_spans(access, container, label)
  let access = case container {
    // In a constant, `name.member` is module access only, whatever else
    // `name` is bound to (`parse.rs:3636`).
    glance.Variable(_, name) if env.syntax == ConstantSyntax -> {
      use entry <- result.try(stateless(st, qualified_entry(env, name, label)))
      module_export(st, entry)
    }
    // Only a bare name can also denote a module, so only there is there a
    // module export for a failing record access to fall through to.
    glance.Variable(_, name) -> {
      let export = module_access(env, name, label)
      case env.syntax, dict.get(env.values, name) {
        GuardSyntax, Ok(ValueConstructor(_, LocalValue(..)))
        | GuardSyntax, Ok(ValueConstructor(_, ConstantValue(..)))
        -> value_field(env, st, container, label, None)
        // A guard selects only a module's constant: a function or a
        // constructor is the compiler's `RecordAccessUnknownType`
        // (`guard.rs:386-419`).
        GuardSyntax, _ ->
          case export {
            Some(ValueConstructor(_, ConstantValue(..))) | None ->
              module_or_record(env, st, container, label, export)
            Some(_) -> fail(st, NotARecord)
          }
        _, Ok(_) -> value_field(env, st, container, label, export)
        _, Error(_) -> module_or_record(env, st, container, label, export)
      }
    }
    _ -> module_or_record(env, st, container, label, None)
  }
  // The compiler's field access never fails: whichever branch failed, the
  // container's included, the error is recorded and the access is a fresh
  // variable (`expression.rs:1495-1566`; in a guard `guard.rs:126-139`).
  use #(type_, branch, st) <- result.try(
    recover_with(env, access, fn(failed) {
      let #(type_, failed) = fresh(failed)
      Ok(#(type_, Invalid, failed))
    }),
  )
  Ok(#(type_, branch, record_access(st, spans, label, branch)))
}

// Record the branch the access took, once, wherever it was reached from. A
// deferred access is recorded here too, at the point the deferral is decided:
// the field type it later resolves to is girard's answer, but no member was
// named *at* the access, and a deferral that never resolves fails its whole
// component, whose state — this record included — is discarded with it.
fn record_access(
  st: State,
  spans: Spans,
  label: String,
  access: Access,
) -> State {
  case access {
    Field(record) -> reference(st, spans, ResolvedField(record, label))
    Export(variant) -> reference(st, spans, ResolvedValue(variant))
    Deferred -> reference(st, spans, ResolvedDeferred)
    Invalid -> st
  }
}

// The three spans of a field access. glance builds one as
// `Span(container.start, label_start + byte_size(label))`, so the label is the
// access's last token and its span is exactly the tail of the access.
fn access_spans(
  access: glance.Span,
  container: glance.Expression,
  label: String,
) -> Spans {
  Spans(
    span: access,
    label: glance.Span(access.end - string.byte_size(label), access.end),
    container: span(container),
  )
}

// Instantiate a module export: the branch a record access fell through to.
fn module_export(
  st: State,
  entry: ValueConstructor,
) -> Result(#(ty.Type, Access, State), Failure) {
  let #(type_, st) = instantiate(st, entry.scheme)
  Ok(#(type_, Export(entry.variant), st))
}

// Defer `container.label` until inference fixes the container's type.
fn pending_field(
  st: State,
  container_type: ty.Type,
  label: String,
) -> Result(#(ty.Type, Access, State), Failure) {
  let #(field, st) = fresh(st)
  let st =
    State(..st, pending: [
      PendingField(container_type, label, field),
      ..st.pending
    ])
  Ok(#(field, Deferred, st))
}

// Field access where the container names a bound value: prefer a record field
// when the value's type has it, else a same-named module export.
fn value_field(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
  export: Option(ValueConstructor),
) -> Result(#(ty.Type, Access, State), Failure) {
  use #(container_type, st) <- result.try(infer_expr_inner(env, st, container))
  use #(type_, access, st) <- result.try(case resolve(st, container_type) {
    ty.Named(_, _, _, _) as record ->
      case accessor(env, record, label) {
        Ok(_) -> {
          use #(field, st) <- result.try(field_type(env, st, record, label))
          Ok(#(field, Field(record), st))
        }
        // Not a field of this record; a same-named module may export it.
        Error(field_error) ->
          case export {
            Some(export) -> module_export(st, export)
            None -> fail(st, field_error)
          }
      }
    // The record type is not known yet. Prefer a same-named module export;
    // otherwise defer until inference fixes the type.
    ty.Var(_) ->
      case export {
        Some(export) -> module_export(st, export)
        None -> pending_field(st, container_type, label)
      }
    _ ->
      case export {
        Some(export) -> module_export(st, export)
        None -> fail(st, NotARecord)
      }
  })
  // The container's span is recorded only while the access stays a record
  // access. One that falls through to a module export is a module select in
  // the compiler's typed AST, with no expression at the container's span.
  let st = case access {
    Export(_) | Invalid -> st
    Field(_) | Deferred -> record(st, span(container), container_type)
  }
  Ok(#(type_, access, st))
}

// Field access where the container is not a bound value: a qualified module
// export takes precedence, else it is a record field on the container's value.
fn module_or_record(
  env: Env,
  st: State,
  container: glance.Expression,
  label: String,
  export: Option(ValueConstructor),
) -> Result(#(ty.Type, Access, State), Failure) {
  case export {
    Some(export) -> module_export(st, export)
    None -> {
      use #(container_type, st) <- result.try(infer_expr(env, st, container))
      case resolve(st, container_type) {
        ty.Named(_, _, _, _) as record -> {
          use #(field, st) <- result.try(field_type(env, st, record, label))
          Ok(#(field, Field(record), st))
        }
        ty.Var(_) -> pending_field(st, container_type, label)
        _ -> fail(st, NotARecord)
      }
    }
  }
}

// Resolve `record.label` for a known record type, returning the field type.
fn field_type(
  env: Env,
  st: State,
  record: ty.Type,
  label: String,
) -> Result(#(ty.Type, State), Failure) {
  // Resolve through the substitution: a caller may pass a variable that has
  // since been bound to the record type (e.g. record-update's kept fields).
  use accessor_scheme <- result.try(stateless(
    st,
    accessor(env, resolve(st, record), label),
  ))
  let #(accessor_type, st) = instantiate(st, accessor_scheme)
  // The access is the accessor's own field type (`expression.rs:2670-2679`,
  // `guard.rs:336-362`), as raw as the compiler's where a binding takes it,
  // and as a speculative guard tuple index inspects it (`guard_tuple_index`).
  case accessor_type {
    ty.Fn([parameter], field) -> {
      use st <- result.map(unify(st, parameter, record))
      #(field, st)
    }
    _ -> {
      let #(field, st) = fresh(st)
      use st <- result.map(unify(st, accessor_type, ty.Fn([record], field)))
      #(field, st)
    }
  }
}

fn infer_record_update(
  env: Env,
  st: State,
  module: Option(String),
  constructor: String,
  record: glance.Expression,
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> Result(#(ty.Type, State), Failure) {
  // A record update produces a *fresh* value of the type: updated fields take
  // their new value's type and kept fields are copied from the record. This is
  // what lets an update change a type parameter, as in
  // `Request(..req, body:)` : `fn(Request(a), b) -> Request(b)` — the kept
  // fields tie only the parameters they share, not all of them. The steps are
  // the compiler's, in its order (`infer_record_update`,
  // `expression.rs:2683-3025`): the spread, its variant, the updated fields,
  // then the kept ones.
  use entry <- result.try(stateless(
    st,
    constructor_entry(env, module, constructor),
  ))
  let #(ctor_type, st) = instantiate(st, entry.scheme)
  let #(field_types, return_type) = case ctor_type {
    ty.Fn(arguments, return) -> #(arguments, return)
    other -> #([], other)
  }
  case return_type {
    ty.Named(type_module, type_name, type_parameters, variant) -> {
      let fields_by_position =
        list.zip(positional_labels(entry.variant), field_types)
      let label_types =
        list.fold(fields_by_position, dict.new(), fn(acc, pair) {
          case pair.0 {
            Some(label) -> dict.insert(acc, label, pair.1)
            None -> acc
          }
        })
      let updated = list.map(fields, fn(field) { field.label })

      // Fix the record's head to this type with independent parameters, so its
      // own type variables aren't conflated with the result's.
      let #(record_parameters, st) = fresh_n(st, list.length(type_parameters))
      // The spread is typed through `infer` in an expression; a constant's
      // fails the whole update when it is invalid itself
      // (`infer_constant_spread`).
      use #(record_type, spread_arguments, st) <- result.try(case env.syntax {
        ConstantSyntax -> infer_constant_spread(env, st, record)
        ExpressionSyntax | GuardSyntax -> {
          use #(type_, st) <- result.map(recover_fresh(
            env,
            infer_expr(env, st, record),
          ))
          #(type_, [], st)
        }
      })
      use st <- result.try(unify(
        st,
        record_type,
        ty.Named(type_module, type_name, record_parameters, variant),
      ))
      use st <- result.try(check_update_variant(
        env,
        st,
        record_type,
        return_type,
      ))
      use bases <- result.try(copy_bases(
        env,
        st,
        record,
        spread_arguments,
        list.length(field_types),
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
      // fields not shared by every variant of a multi-variant type. Every field
      // the update does not name is kept, an unlabelled one included, by
      // position in declaration order (`expression.rs:2899-3025`). A
      // constant's inline spread gives a field its own argument's type
      // instead (`copy_bases`).
      let to_record_params =
        dict.from_list(list.zip(
          list.filter_map(type_parameters, var_id),
          record_parameters,
        ))
      let kept =
        list.filter(list.zip(fields_by_position, bases), fn(pair) {
          case pair.0.0 {
            Some(label) -> !list.contains(updated, label)
            None -> True
          }
        })
      use st <- result.try(
        list.try_fold(kept, st, fn(st, pair) {
          let #(#(_, field), base) = pair
          let base =
            option.lazy_unwrap(base, fn() {
              substitute(to_record_params, field)
            })
          // The result's field first, as the compiler unifies it
          // (`constant.rs:353-363`): its fresh variable is bound to the base,
          // never the base's, a live literal's for a constant spread, to it.
          unify(st, field, base)
        }),
      )

      Ok(#(return_type, st))
    }
    _ -> fail(st, NotARecord)
  }
}

// A constant update's spread, typed so that a failure of its own fails the
// update: the constant typer needs the spread to be a record, and an invalid
// one is not (`constant.rs:186-232`). So a name or a module select that
// cannot be read, a constructor that cannot be found and a nested update that
// failed each fail the update whole, where elsewhere in a constant they would
// be fresh. What the spread holds recovers as anywhere else: a constructor's
// arguments, a nested update's fields. The spread's span is recorded once, as
// `infer_expr` records it. A constructor call also gives each of its
// arguments' own types, in the order they were placed, which the update
// copies its fields from (`copy_bases`); any other spread gives none.
fn infer_constant_spread(
  env: Env,
  st: State,
  spread: glance.Expression,
) -> Result(#(ty.Type, List(Option(ty.Type)), State), Failure) {
  let strict = Env(..env, recovering: False)
  let no_arguments = fn(typed) {
    result.map(typed, fn(typed: #(ty.Type, State)) { #(typed.0, [], typed.1) })
  }
  let typed = case spread {
    glance.Variable(..) | glance.FieldAccess(..) ->
      no_arguments(infer_expr_inner(strict, st, spread))
    glance.RecordUpdate(_, module, constructor, inner, fields) ->
      no_arguments(infer_record_update(
        env,
        st,
        module,
        constructor,
        inner,
        fields,
      ))
    glance.Call(_, function, arguments) -> {
      use #(fn_type, labels, st) <- result.try(infer_callee(
        strict,
        st,
        function,
      ))
      place_constant_arguments(
        env,
        st,
        fn_type,
        labels,
        list.map(arguments, map_field(_, Written)),
      )
    }
    _ -> no_arguments(infer_expr_inner(env, st, spread))
  }
  use #(type_, arguments, st) <- result.map(typed)
  #(type_, arguments, record(st, span(spread), type_))
}

// The type a record update copies each field from, where it is not the
// spread constructor's field type: in a constant whose spread is an inline
// constructor call, each field the call's own argument for it, as the
// constant typer copies the base record's arguments (`constant.rs:212-230,
// 353-390`).
// It differs from the field type only where the argument recovered a
// mismatch, so only in a speculative walk. Each argument's type is the one
// its own walk inferred, before the unification with its field, passed out of
// the spread's walk (`spread_arguments`, from `place_constant_arguments`), so
// nothing is walked twice or looked up; one that failed is the fresh variable
// it recovered to, which that unification bound to the field. A spread whose
// argument count is not the constructor's fails the update, as the constant
// typer checks before any updated field is walked (`constant.rs:257-273`).
fn copy_bases(
  env: Env,
  st: State,
  record: glance.Expression,
  spread_arguments: List(Option(ty.Type)),
  fields: Int,
) -> Result(List(Option(ty.Type)), Failure) {
  let by_field = fn() { Ok(list.repeat(None, fields)) }
  use <- bool.lazy_guard(when: env.syntax != ConstantSyntax, return: by_field)
  case inline_spread(env, record) {
    Ok(arguments) -> {
      use <- bool.lazy_guard(
        when: list.length(arguments) != fields,
        return: fn() { fail(st, ArityMismatch) },
      )
      let missing = fields - list.length(spread_arguments)
      Ok(list.append(spread_arguments, list.repeat(None, missing)))
    }
    Error(Nil) -> by_field()
  }
}

// A record update's spread that is a constructor call: its arguments in the
// constructor's field order, placed as `place_arguments` placed them.
fn inline_spread(
  env: Env,
  record: glance.Expression,
) -> Result(List(CallArg), Nil) {
  use #(entry, arguments) <- result.try(case record {
    glance.Call(_, glance.Variable(_, name), arguments) ->
      dict.get(env.values, name)
      |> result.map(fn(entry) { #(entry, arguments) })
    glance.Call(
      _,
      glance.FieldAccess(_, glance.Variable(_, alias), name),
      arguments,
    ) ->
      qualified_entry(env, alias, name)
      |> result.replace_error(Nil)
      |> result.map(fn(entry) { #(entry, arguments) })
    _ -> Error(Nil)
  })
  case entry.variant {
    ConstructorValue(field_map: labels, ..) -> {
      let arguments = list.map(arguments, map_field(_, Written))
      order_fields(labels, arguments, fn(label, location) {
        Written(glance.Variable(location, label))
      })
      |> result.lazy_unwrap(fn() { call_order(labels, arguments) })
      |> Ok
    }
    LocalValue(..) | FunctionValue(..) | ConstantValue(..) -> Error(Nil)
  }
}

// A record update of a type with several variants needs the spread to be
// known to be the constructor's own variant (`infer_record_update_variant`,
// `expression.rs:3096-3170`): a spread known to be another variant, or not
// known to be any, is the compiler's unsafe update. A constant's update is
// not checked here: the compiler's constant typer compares the variant of the
// constant the spread names, through its stored literal
// (`constant.rs:164-245`), which the spread's generalized type no longer
// carries.
fn check_update_variant(
  env: Env,
  st: State,
  record_type: ty.Type,
  return_type: ty.Type,
) -> Result(State, Failure) {
  case env.syntax, return_type {
    ExpressionSyntax, ty.Named(module, name, _, Some(index))
    | GuardSyntax, ty.Named(module, name, _, Some(index))
    -> {
      let record_type = resolve(st, record_type)
      case
        dict.get(accessors_of_module(env, module), name),
        variant_of(record_type) == Some(index)
      {
        Ok(Accessors(by_variant: [_, _, ..], ..)), False ->
          fail(st, type_mismatch(record_type, return_type))
        _, _ -> Ok(st)
      }
    }
    _, _ -> Ok(st)
  }
}

// The per-position labels a callable declares, as a list: the positions of a
// callable with no labelled position at all, which is the empty list because
// there is nothing to reorder against.
fn positional_labels(variant: ValueVariant) -> FieldMap {
  option.unwrap(field_map(variant), [])
}

// Infer each item in order, threading the state, and return the types in the
// same order.
fn infer_each(
  st: State,
  items: List(a),
  infer: fn(State, a) -> Result(#(ty.Type, State), Failure),
) -> Result(#(List(ty.Type), State), Failure) {
  use #(rev, st) <- result.try(
    list.try_fold(items, #([], st), fn(acc, item) {
      let #(types_, st) = acc
      use #(t, st) <- result.map(infer(st, item))
      #([t, ..types_], st)
    }),
  )
  Ok(#(list.reverse(rev), st))
}

// The two function literals a known type can be pushed into before their
// bodies are walked. A capture is one: the compiler parses `f(a, _, b)` as
// `fn(_capture) { f(a, _capture, b) }` (`parse.rs:5376-5417`), so wherever a
// lambda is seeded, called or piped into, a capture is too.
type FnLiteral {
  Lambda(
    span: glance.Span,
    params: List(glance.FnParameter),
    return_annotation: Option(glance.Type),
    body: List(glance.Statement),
  )
  Capture(
    span: glance.Span,
    label: Option(String),
    function: glance.Expression,
    before: List(glance.Field(glance.Expression)),
    after: List(glance.Field(glance.Expression)),
  )
}

fn as_fn_literal(expr: glance.Expression) -> Result(FnLiteral, Nil) {
  case expr {
    glance.Fn(span, params, return_annotation, body) ->
      Ok(Lambda(span, params, return_annotation, body))
    glance.FnCapture(span, label, function, before, after) ->
      Ok(Capture(span, label, function, before, after))
    _ -> Error(Nil)
  }
}

fn fn_literal_arity(literal: FnLiteral) -> Int {
  case literal {
    Lambda(params:, ..) -> list.length(params)
    Capture(..) -> 1
  }
}

// `expr` as a function literal taking `arity` parameters: the one callee or
// pipe step that can be called at the types its arguments have.
fn fn_literal_of_arity(
  expr: glance.Expression,
  arity: Int,
) -> Result(FnLiteral, Nil) {
  use literal <- result.try(as_fn_literal(expr))
  case fn_literal_arity(literal) == arity {
    True -> Ok(literal)
    False -> Error(Nil)
  }
}

// Infer a function literal whose parameters are seeded from the types it will
// be called at, and record its span — which `infer_expr`'s wrapper does for a
// literal reached the ordinary way, and which every seeding caller bypasses.
// Its return is checked by the caller, which knows the whole function type.
fn infer_seeded(
  env: Env,
  st: State,
  literal: FnLiteral,
  seeds: List(ty.Type),
) -> Result(#(ty.Type, State), Failure) {
  use #(fn_type, st) <- result.try(case literal {
    Lambda(_, params, return_annotation, body) ->
      infer_lambda(env, st, params, return_annotation, body, Some(seeds))
    Capture(span, label, function, before, after) ->
      infer_capture(env, st, span, label, function, before, after, Some(seeds))
  })
  Ok(#(fn_type, record(st, literal.span, fn_type)))
}

// Infer a lambda whose parameters are seeded with `seeds`, the types it will
// be called at, when known (`parameter_types`).
//
// The parameter annotations, then the return annotation, are hydrated in the
// enclosing scope, before the body's opens, as `do_infer_fn` hydrates them
// (`expression.rs:4041-4060`): a name they create is visible after the lambda
// as long as the enclosing scope lasts. The body, with the return check, is a
// scope of its own (`infer_fn_with_known_types`, `expression.rs:4082`).
fn infer_lambda(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
  seeds: Option(List(ty.Type)),
) -> Result(#(ty.Type, State), Failure) {
  let annotations = list.map(params, fn(param) { param.type_ })
  case parameter_types(env, st, annotations, seeds) {
    Ok(#(param_types, st)) ->
      lambda_body(env, st, params, param_types, return_annotation, body)
    // A parameter whose seed does not unify stops the header, and the lambda
    // is a fresh variable (`expression.rs:1099-1110, 4041-4060`). The names
    // hydrated before it, its own included, stay in the failed state.
    Error(failure) -> recover_fresh(env, Error(failure))
  }
}

// A lambda once its parameters are typed: the return annotation, hydrated in
// the enclosing scope, then the body, with the return check, in a scope of
// its own. A failed return check is recorded and the lambda's return is a
// fresh variable (`expression.rs:4141-4170`).
fn lambda_body(
  env: Env,
  st: State,
  params: List(glance.FnParameter),
  param_types: List(ty.Type),
  return_annotation: Option(glance.Type),
  body: List(glance.Statement),
) -> Result(#(ty.Type, State), Failure) {
  let #(return_type, st) = case return_annotation {
    Some(ann) -> {
      let #(t, st) = hydrate_scoped(env, st, ann)
      #(Some(t), st)
    }
    None -> #(None, st)
  }
  let param_names = list.map(params, fn(param) { param.name })
  let body_env = bind_params(env, param_names, param_types)
  use #(body_type, st) <- result.try({
    use st <- scoped(st)
    use #(body_type, st) <- result.try(infer_statements(body_env, st, body))
    case return_type {
      Some(t) ->
        recover_fresh(
          env,
          result.map(unify(st, t, body_type), fn(st) { #(body_type, st) }),
        )
      None -> Ok(#(body_type, st))
    }
  })
  Ok(#(ty.Fn(param_types, body_type), st))
}

// A function literal's parameter types, in order. Each parameter takes its own
// type — its annotation, or a fresh variable — and that type is unified with
// its seed, the type it is called at where that is known, as the compiler's
// `infer_arg` does (`expression.rs:1133-1173`). Using the seed itself would
// keep a variant the seed was stamped with; binding the parameter's own
// variable to it erases that, as the compiler's link does.
fn parameter_types(
  env: Env,
  st: State,
  annotations: List(Option(glance.Type)),
  seeds: Option(List(ty.Type)),
) -> Result(#(List(ty.Type), State), Failure) {
  let seeds = case seeds {
    Some(seeds) -> list.map(seeds, Some)
    None -> list.repeat(None, list.length(annotations))
  }
  infer_each(st, list.zip(annotations, seeds), fn(st, pair) {
    let #(annotation, seed) = pair
    let #(own, st) = case annotation {
      Some(ann) -> hydrate_scoped(env, st, ann)
      None -> fresh(st)
    }
    use st <- result.map(unify_seed(st, seed, own))
    #(own, st)
  })
}

// Unify a parameter's own type with the type it is called at, where that is
// known: the expected type first, as `infer_arg` unifies them.
fn unify_seed(
  st: State,
  seed: Option(ty.Type),
  own: ty.Type,
) -> Result(State, Failure) {
  case seed {
    Some(seed) -> unify(st, seed, own)
    None -> Ok(st)
  }
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
) -> Result(#(ty.Type, Option(FieldMap), State), Failure) {
  // A callee the compiler cannot type is recorded and is an invalid
  // expression, a fresh variable with no field map (`expression.rs:3550-3640`).
  use failed <- recover_with(env, resolve_callee(env, st, function))
  let #(type_, failed) = fresh(failed)
  Ok(#(type_, None, failed))
}

fn resolve_callee(
  env: Env,
  st: State,
  function: glance.Expression,
) -> Result(#(ty.Type, Option(FieldMap), State), Failure) {
  case function {
    // Resolved here rather than through `infer_expr`, which would drop the
    // branch; the callee's span is recorded once, as `infer_expr` would.
    glance.FieldAccess(access_span, container, label) -> {
      use #(type_, access, st) <- result.try(infer_field_access(
        env,
        st,
        access_span,
        container,
        label,
      ))
      let labels = case access {
        Export(variant) -> field_map(variant)
        Field(_) | Deferred | Invalid -> None
      }
      Ok(#(type_, labels, record(st, span(function), type_)))
    }
    // A bare name, resolved here for the same reason: `infer_expr` would
    // instantiate the scheme and drop the entry it came from, and the entry is
    // what says which member this call resolved to and what labels it may use.
    // Reading it once is also what makes an unbound name one answer — the
    // error — rather than an answer here and an error there. All three of the
    // reference's spans are the variable's.
    glance.Variable(name_span, name) -> {
      use #(entry, type_, st) <- result.map(read_name(env, st, name))
      let st = record(st, name_span, type_)
      let spans = Spans(name_span, name_span, name_span)
      #(
        type_,
        field_map(entry.variant),
        reference(st, spans, ResolvedValue(entry.variant)),
      )
    }
    // A lambda, another call's result: neither a name nor a reference, and no
    // labels to call it with.
    _ -> {
      use #(type_, st) <- result.try(infer_expr(env, st, function))
      Ok(#(type_, None, st))
    }
  }
}

// A call of `function` on `arguments`: the callee as `infer_called`
// dispatches it, then every argument checked against the parameter the
// callee's field map places it at.
fn infer_call(
  env: Env,
  st: State,
  function: glance.Expression,
  arguments: List(glance.Field(CallArg)),
) -> Result(#(ty.Type, State), Failure) {
  use #(fn_type, labels, st) <- result.try(infer_called(
    env,
    st,
    function,
    arguments,
  ))
  place_arguments(env, st, fn_type, labels, arguments)
}

// Place a call's arguments against the callee's parameters and check each one:
// reorder the arguments through the callee's field map, fix the callee's
// function shape *before* any argument is walked, then check each argument
// against the parameter the reorder placed it at. Returns the call's result.
//
// Fixing the shape first is what lets an argument's body see the types it will
// be called with — a lambda argument's parameters in `list.map(rows, fn(row) {
// row.field })`, and every seeded position this module has. Walking the
// arguments in declared order is the other half: types flowing from an earlier
// argument constrain a later one, and an argument declared after another is
// inferred after it however the two were written. A shorthand `label:` is the
// in-scope `label`, whatever the call's shape.
fn place_arguments(
  env: Env,
  st: State,
  fn_type: ty.Type,
  labels: Option(FieldMap),
  arguments: List(glance.Field(CallArg)),
) -> Result(#(ty.Type, State), Failure) {
  use ordered <- result.try(ordered_arguments(env, st, labels, arguments))
  let #(holes, st) = fresh_n(st, list.length(ordered))
  let #(result, st) = fresh(st)
  case unify(st, fn_type, ty.Fn(holes, result)) {
    Ok(st) -> {
      use st <- result.map(check_each(env, st, ordered, holes))
      // The call's value is the callee's own return type, not the hole
      // unified against it: the two are the same type, but only the callee's
      // carries the variant a constructor's return was built with.
      #(call_return(st, fn_type, result), st)
    }
    Error(failure) ->
      recover_with(env, Error(failure), fn(failed) {
        misshapen_call(env, failed, fn_type, labels, arguments, ordered)
      })
  }
}

// A call's arguments in the order its field map places them. In a speculative
// walk a reorder that fails leaves the arguments as the compiler's
// `FieldMap::reorder` leaves them (`call_order`).
fn ordered_arguments(
  env: Env,
  st: State,
  labels: Option(FieldMap),
  arguments: List(glance.Field(CallArg)),
) -> Result(List(CallArg), Failure) {
  let reordered =
    order_fields(labels, arguments, fn(label, location) {
      Written(glance.Variable(location, label))
    })
  case reordered {
    Ok(ordered) -> Ok(ordered)
    Error(error) ->
      recover_with(env, fail(st, error), fn(_) {
        Ok(call_order(labels, arguments))
      })
  }
}

// A constant's constructor call, placed as `place_arguments` places a call,
// also giving each argument's own type in the order it was placed: the type
// it was inferred at, before the unification with its parameter, which a
// recovered mismatch leaves apart. A constant update copies its fields from
// them (`copy_bases`). A constant holds no function literal, so each written
// argument is inferred through `infer` and unified with its parameter, as
// `check` checks one. A call of another arity gives no types: its argument
// count fails the update before any is read.
fn place_constant_arguments(
  env: Env,
  st: State,
  fn_type: ty.Type,
  labels: Option(FieldMap),
  arguments: List(glance.Field(CallArg)),
) -> Result(#(ty.Type, List(Option(ty.Type)), State), Failure) {
  use ordered <- result.try(ordered_arguments(env, st, labels, arguments))
  let #(holes, st) = fresh_n(st, list.length(ordered))
  let #(result, st) = fresh(st)
  case unify(st, fn_type, ty.Fn(holes, result)) {
    Ok(st) -> {
      use #(types, st) <- result.map(check_constant_arguments(
        env,
        st,
        ordered,
        holes,
      ))
      #(call_return(st, fn_type, result), types, st)
    }
    Error(failure) ->
      recover_with(env, Error(failure), fn(failed) {
        use #(return, st) <- result.map(misshapen_call(
          env,
          failed,
          fn_type,
          labels,
          arguments,
          ordered,
        ))
        #(return, [], st)
      })
  }
}

// Check a constant call's arguments against their parameters, giving each
// written one's own type.
fn check_constant_arguments(
  env: Env,
  st: State,
  arguments: List(CallArg),
  parameters: List(ty.Type),
) -> Result(#(List(Option(ty.Type)), State), Failure) {
  use #(rev_types, st) <- result.map(
    list.try_fold(list.zip(arguments, parameters), #([], st), fn(acc, pair) {
      let #(types, st) = acc
      case pair.0 {
        Written(expression) -> {
          use #(type_, st) <- result.try(infer_recovering(env, st, expression))
          use st <- result.map(recover_unify(env, st, pair.1, type_))
          #([Some(type_), ..types], st)
        }
        Read(..) | Callback(..) -> {
          use st <- result.map(check_argument(env, st, pair.0, pair.1))
          #([None, ..types], st)
        }
      }
    }),
  )
  #(list.reverse(rev_types), st)
}

// A call whose callee is no function of its arity, in a speculative walk. The
// callee's resolved type decides which parameters the arguments are checked
// against, as the compiler's `fault_tolerant_match_function_type` does
// (`expression.rs:4346-4440`): a function of another arity keeps its own
// parameters and return, and the arguments are checked against the common
// prefix — against the parameters before the first labelled argument when the
// field map rejected the arity, and with a `use` call's placeholders; a
// generic or any other type is not a function, so no argument is walked and
// the call is a fresh variable. (An unbound variable is a function of the
// call's arity, so it never reaches here.)
fn misshapen_call(
  env: Env,
  st: State,
  fn_type: ty.Type,
  labels: Option(FieldMap),
  arguments: List(glance.Field(CallArg)),
  ordered: List(CallArg),
) -> Result(#(ty.Type, State), Failure) {
  case resolve(st, fn_type) {
    ty.Fn(params, return) -> {
      let kept = case arity_rejected(labels, arguments) {
        True -> list.take(params, positional_prefix(arguments))
        False -> params
      }
      let ordered =
        use_placeholders(
          arguments,
          ordered,
          list.length(params) - list.length(ordered),
        )
      use st <- result.map(check_each(env, st, ordered, kept))
      #(return, st)
    }
    ty.Var(_) | ty.Named(..) | ty.Tuple(..) -> Ok(fresh(st))
  }
}

// Check each argument against the parameter beside it, as far as both lists
// go.
fn check_each(
  env: Env,
  st: State,
  arguments: List(CallArg),
  parameters: List(ty.Type),
) -> Result(State, Failure) {
  list.try_fold(list.zip(arguments, parameters), st, fn(st, pair) {
    check_argument(env, st, pair.0, pair.1)
  })
}

// How many arguments come before the first labelled one.
fn positional_prefix(arguments: List(glance.Field(CallArg))) -> Int {
  list.length(list.take_while(arguments, is_unlabelled))
}

// A `use` call short of arguments gets a placeholder for each missing one
// before its last argument, so the callback reaches its own parameter
// (`expression.rs:3760-3787`). A placeholder is the compiler's: a bare
// `panic`, which types as a fresh variable.
fn use_placeholders(
  arguments: List(glance.Field(CallArg)),
  ordered: List(CallArg),
  missing: Int,
) -> List(CallArg) {
  let is_use =
    list.any(arguments, fn(field) {
      case field_argument(field) {
        Callback(..) -> True
        Written(..) | Read(..) -> False
      }
    })
  case is_use && missing > 0, list.reverse(ordered) {
    True, [last, ..rest] -> {
      let placeholder = Written(glance.Panic(glance.Span(0, 0), None))
      list.flatten([
        list.reverse(rest),
        list.repeat(placeholder, missing),
        [last],
      ])
    }
    _, _ -> ordered
  }
}

// The arguments in the order the compiler's `FieldMap::reorder` leaves them,
// errors included (`fields.rs:48-150`):
// - a callee with no field map leaves them in source order, labels and all;
// - a wrong number of arguments, or a positional one after a labelled one,
//   leaves them in source order;
// - a label met twice ends the reorder there, the labelled arguments already
//   taken from the end gone;
// - otherwise each known label goes to its position, and an unknown one stays
//   among the rest.
// A `use` callback is implicit, so it may follow a labelled argument.
fn call_order(
  labels: Option(FieldMap),
  fields: List(glance.Field(CallArg)),
) -> List(CallArg) {
  case labels {
    None -> list.map(fields, field_argument)
    Some(labels) ->
      case same_length(fields, labels), positional_after_labelled(fields) {
        True, False -> reorder_labelled(fields, labels)
        False, _ | True, True -> list.map(fields, field_argument)
      }
  }
}

// Whether the callee's field map rejects the number of arguments
// (`fields.rs:59-67`).
fn arity_rejected(
  labels: Option(FieldMap),
  fields: List(glance.Field(CallArg)),
) -> Bool {
  case labels {
    Some(labels) -> !same_length(fields, labels)
    None -> False
  }
}

fn positional_after_labelled(fields: List(glance.Field(CallArg))) -> Bool {
  list.drop_while(fields, is_unlabelled)
  |> list.any(fn(field) {
    case field {
      glance.UnlabelledField(Callback(..)) -> False
      glance.UnlabelledField(_) -> True
      glance.LabelledField(..) | glance.ShorthandField(..) -> False
    }
  })
}

// `FieldMap::reorder`'s walk from the last argument to the first: a known
// label is taken out to its position, until a label repeats. Each label has a
// position of its own, so a repeated label is a position already taken.
fn reorder_labelled(
  fields: List(glance.Field(CallArg)),
  labels: FieldMap,
) -> List(CallArg) {
  let index_of = label_indices(labels)
  let indexed = list.index_map(fields, fn(field, index) { #(index, field) })
  // Each position taken, with the index of the argument that took it.
  let #(placed, repeated) =
    list.fold(list.reverse(indexed), #(dict.new(), False), fn(acc, pair) {
      let #(placed, repeated) = acc
      let #(index, field) = pair
      case repeated, result.try(field_label(field), dict.get(index_of, _)) {
        False, Ok(position) ->
          case dict.has_key(placed, position) {
            True -> #(placed, True)
            False -> #(dict.insert(placed, position, #(index, field)), False)
          }
        _, _ -> acc
      }
    })
  let taken =
    dict.fold(placed, set.new(), fn(taken, _, by) { set.insert(taken, by.0) })
  let rest =
    list.filter_map(indexed, fn(pair) {
      case set.contains(taken, pair.0) {
        True -> Error(Nil)
        False -> Ok(field_argument(pair.1))
      }
    })
  use <- bool.guard(when: repeated, return: rest)
  let arguments = dict.map_values(placed, fn(_, by) { field_argument(by.1) })
  fill_positions(arguments, rest, 0, list.length(fields))
}

fn field_label(field: glance.Field(a)) -> Result(String, Nil) {
  case field {
    glance.LabelledField(label, ..) | glance.ShorthandField(label, ..) ->
      Ok(label)
    glance.UnlabelledField(..) -> Error(Nil)
  }
}

// Positions `from` to `count - 1`: the argument placed at each, or else the
// next of `rest`.
fn fill_positions(
  placed: Dict(Int, CallArg),
  rest: List(CallArg),
  from: Int,
  count: Int,
) -> List(CallArg) {
  use <- bool.guard(when: from >= count, return: rest)
  case dict.get(placed, from), rest {
    Ok(argument), _ -> [
      argument,
      ..fill_positions(placed, rest, from + 1, count)
    ]
    Error(_), [next, ..rest] -> [
      next,
      ..fill_positions(placed, rest, from + 1, count)
    ]
    Error(_), [] -> fill_positions(placed, [], from + 1, count)
  }
}

// Infer the callee of a call on `arguments`, as the compiler's `do_infer_call`
// dispatches it (`expression.rs:3543-3582`). A function literal in callee
// position has no signature its parameter types can be read from, so where it
// takes as many parameters as the call passes, they are learned from the
// call's own arguments, speculated in source order — the compiler's
// `infer_fn_with_call_context`. A capture is a lambda of one parameter, so it
// is speculated the same way. At any other arity the call is an error, and
// pairing the arguments off against the parameters would be pairing the wrong
// ones. Any other callee is resolved by `infer_callee`.
//
// A literal has no field map, so the call accepts no labelled argument. The
// caller goes on to infer the arguments again, for real, against the
// parameters this seeded: the speculative pass exists only to learn the types.
fn infer_called(
  env: Env,
  st: State,
  function: glance.Expression,
  arguments: List(glance.Field(CallArg)),
) -> Result(#(ty.Type, Option(FieldMap), State), Failure) {
  case fn_literal_of_arity(function, list.length(arguments)) {
    Ok(literal) -> {
      let #(seeds, st) = speculate(env, st, list.map(arguments, field_argument))
      use #(fn_type, st) <- result.try(infer_seeded(env, st, literal, seeds))
      Ok(#(fn_type, None, st))
    }
    Error(Nil) -> infer_callee(env, st, function)
  }
}

// One argument of a call girard checks. Besides a written expression, the
// compiler passes two arguments it generated: a read of a local it holds a
// type in — the piped value, a capture's own parameter at its hole — and a
// `use` callback, the rest of the block under the `use`'s patterns. Each
// reaches the callee's parameters through the same reorder as the written
// ones, so a field map may place it anywhere among them.
type CallArg {
  Written(expression: glance.Expression)
  Read(type_: ty.Type)
  Callback(patterns: List(glance.UsePattern), body: List(glance.Statement))
}

// A field's argument, a shorthand `label:` being the in-scope `label`.
fn field_argument(field: glance.Field(CallArg)) -> CallArg {
  case field {
    glance.UnlabelledField(argument) -> argument
    glance.LabelledField(_, _, argument) -> argument
    glance.ShorthandField(label, location) ->
      Written(glance.Variable(location, label))
  }
}

// Check one argument against the parameter it was placed at. A generated read
// is checked as the compiler checks a variable argument: read, then unified
// with the parameter (`infer_call_argument`, `expression.rs:3942-3985`).
fn check_argument(
  env: Env,
  st: State,
  argument: CallArg,
  expected: ty.Type,
) -> Result(State, Failure) {
  case argument {
    Written(expression) -> check(env, st, expression, expected)
    Read(type_) -> {
      let #(read, st) = read_type(st, type_)
      recover_unify(env, st, expected, read)
    }
    Callback(patterns, body) ->
      check_callback(env, st, patterns, body, expected)
  }
}

// Infer one argument to learn its type, as the speculative pass does. A `use`
// callback is inferred as a lambda with no expected type (`infer`'s `Fn` arm,
// `expression.rs:483-489`): its parameter types are what the pass learns.
fn speculate_argument(
  env: Env,
  st: State,
  argument: CallArg,
) -> Result(#(ty.Type, State), Failure) {
  case argument {
    Written(expression) -> infer_expr(env, st, expression)
    Read(type_) -> Ok(read_type(st, type_))
    Callback(patterns, body) -> {
      let #(callback, st) = fresh(st)
      use st <- result.try(check_callback(env, st, patterns, body, callback))
      Ok(#(callback, st))
    }
  }
}

// Infer each argument only to learn its type, keeping what unification learned
// and putting back everything the pass *reported*. The compiler does the same
// in `infer_fn_with_call_context` (`expression.rs:3642-3690`), where the
// restore is of the diagnostics the speculative pass recorded rather than of
// the substitution. The pass keeps every effect it had, some of which the
// real pass would not make — it can read, and pin, an outer name that the
// real pass finds bound by a pattern the speculative walk skipped — and
// keeping them is what gives the compiler's answer.
//
// Restoring the three lists is what keeps the pass invisible: no span is
// annotated twice, no reference recorded twice, and no deferral is left behind
// holding a result variable nothing will ever read.
//
// The pass is a speculative walk (`Env.recovering`): inside an argument, each
// site the compiler recovers at recovers as it does, keeping every effect so
// far. An argument that still fails is a fresh variable, its effects kept,
// and the next argument continues from there (`expression.rs:3665-3671`), so
// the pass itself never fails: the real pass walks every argument again,
// strictly, and only it rejects. The effects this pass keeps can still decide
// what the real pass accepts: a binding it made can be what lets the real
// pass type an argument (`speculated_unification_keeps_its_prefix_test`).
// `Unsupported` stops here too, so the real pass reports whatever it meets
// first. Nothing rewinds, the
// id counter included: an id a failed argument spent may be reachable from a
// link it kept.
fn speculate(
  env: Env,
  st: State,
  arguments: List(CallArg),
) -> #(List(ty.Type), State) {
  let env = Env(..env, recovering: True)
  let #(rev, spent) =
    list.fold(arguments, #([], st), fn(acc, argument) {
      let #(types_, st) = acc
      case speculate_argument(env, st, argument) {
        Ok(#(type_, st)) -> #([type_, ..types_], st)
        Error(Failure(_, failed)) -> {
          let #(type_, failed) = fresh(failed)
          #([type_, ..types_], failed)
        }
      }
    })
  #(
    list.reverse(rev),
    State(
      ..spent,
      annotations: st.annotations,
      references: st.references,
      pending: st.pending,
    ),
  )
}

// A call's result: the callee's own return where the callee is known to be a
// function, else the hole the call was unified against.
fn call_return(st: State, callee: ty.Type, hole: ty.Type) -> ty.Type {
  case resolve(st, callee) {
    ty.Fn(_, return) -> return
    _ -> hole
  }
}

fn fresh_n(st: State, n: Int) -> #(List(ty.Type), State) {
  use <- bool.guard(when: n <= 0, return: #([], st))
  let #(t, st) = fresh(st)
  let #(rest, st) = fresh_n(st, n - 1)
  #([t, ..rest], st)
}

// Re-wrap a field's item, keeping the label the reorder places it by. A
// shorthand field carries no item to wrap and is left as one, for
// `order_fields`' materializer to resolve to the in-scope name.
fn map_field(field: glance.Field(a), wrap: fn(a) -> b) -> glance.Field(b) {
  case field {
    glance.UnlabelledField(item) -> glance.UnlabelledField(wrap(item))
    glance.LabelledField(label, location, item) ->
      glance.LabelledField(label, location, wrap(item))
    glance.ShorthandField(label, location) ->
      glance.ShorthandField(label, location)
  }
}

// Reorder labelled/shorthand call or pattern arguments into positional order
// using the callee's field map. If every argument is positional we don't need
// the field map (this also covers calls to anonymous functions).
fn order_fields(
  labels: Option(FieldMap),
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
    Some(labels) -> reorder(fields, labels, shorthand)
    None -> Error(AmbiguousCall)
  }
}

fn label_indices(labels: FieldMap) -> Dict(String, Int) {
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
  labels: FieldMap,
  shorthand: fn(String, glance.Span) -> t,
) -> Result(List(t), Error) {
  // More arguments than the callee declares is the compiler's arity error
  // (`fields.rs:59-67`), and it leaves the arguments in source order.
  use <- bool.guard(
    when: list.length(fields) > list.length(labels),
    return: Error(ArityMismatch),
  )
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

fn infer_capture(
  env: Env,
  st: State,
  span: glance.Span,
  label: Option(String),
  function: glance.Expression,
  before: List(glance.Field(glance.Expression)),
  after: List(glance.Field(glance.Expression)),
  seeds: Option(List(ty.Type)),
) -> Result(#(ty.Type, State), Failure) {
  // `f(a, _, b)` is `fn(_capture) { f(a, _capture, b) }` (`parse.rs:5376-5417`),
  // and it is inferred as that lambda. Its one parameter takes its own type,
  // unified with the type it is called at where that is known, as a lambda
  // parameter is (`infer_arg`). Its body, the call, is a function body's
  // scope, callee and explicit arguments included.
  let #(hole, st) = fresh(st)
  let seed = case seeds {
    Some([seed, ..]) -> Some(seed)
    _ -> None
  }
  use st <- result.try(unify_seed(st, seed, hole))
  // The body is an ordinary call. Its arguments are built in source order —
  // the hole a read of the parameter, under its own label where it has one,
  // `value: _` — so a literal callee speculates them in that order, and the
  // field map's reorder aligns the hole and every argument into declared order
  // as it would a direct call's.
  let hole_field = case label {
    Some(name) -> glance.LabelledField(name, span, Read(hole))
    None -> glance.UnlabelledField(Read(hole))
  }
  let arguments =
    list.flatten([
      list.map(before, map_field(_, Written)),
      [hole_field],
      list.map(after, map_field(_, Written)),
    ])
  use #(return, st) <- result.try({
    use st <- scoped(st)
    infer_call(env, st, function, arguments)
  })
  // A capture is a lambda whose body is the call, so its return is the
  // callee's own — `Loud(_)` returns a value known to be `Loud`.
  Ok(#(ty.Fn([hole], return), st))
}

fn infer_binop(
  env: Env,
  st: State,
  op: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(ty.Type, State), Failure) {
  case op {
    glance.Pipe -> infer_pipe(env, st, left, right)

    glance.And | glance.Or ->
      infer_operator(env, st, left, right, prelude_bool(), prelude_bool())

    glance.Eq | glance.NotEq -> {
      use #(lt, st) <- result.try(infer_recovering(env, st, left))
      use #(rt, st) <- result.try(infer_recovering(env, st, right))
      use st <- result.try(recover_unify(env, st, lt, rt))
      Ok(#(prelude_bool(), st))
    }

    // The constant typer types `<>` one operand at a time, the left first
    // (`constant.rs:557-584`).
    glance.Concatenate ->
      case env.syntax {
        ConstantSyntax -> infer_constant_concatenation(env, st, left, right)
        ExpressionSyntax | GuardSyntax ->
          infer_operator(
            env,
            st,
            left,
            right,
            prelude_string(),
            prelude_string(),
          )
      }

    glance.AddInt
    | glance.SubInt
    | glance.MultInt
    | glance.DivInt
    | glance.RemainderInt ->
      infer_operator(env, st, left, right, prelude_int(), prelude_int())

    glance.AddFloat | glance.SubFloat | glance.MultFloat | glance.DivFloat ->
      infer_operator(env, st, left, right, prelude_float(), prelude_float())

    glance.LtInt | glance.LtEqInt | glance.GtInt | glance.GtEqInt ->
      infer_operator(env, st, left, right, prelude_int(), prelude_bool())

    glance.LtFloat | glance.LtEqFloat | glance.GtFloat | glance.GtEqFloat ->
      infer_operator(env, st, left, right, prelude_float(), prelude_bool())
  }
}

// An operator other than `==`, `!=`, `|>` and a constant's `<>`, in the
// compiler's order (`infer_binop`, `expression.rs:1865-1868`): both operands
// are inferred, then each is unified with the operator's operand type, left
// first. Its type is the operator's result type. Each operand is typed
// through `infer` and each unification is recorded.
fn infer_operator(
  env: Env,
  st: State,
  left: glance.Expression,
  right: glance.Expression,
  operand: ty.Type,
  result: ty.Type,
) -> Result(#(ty.Type, State), Failure) {
  use #(left_type, st) <- result.try(infer_recovering(env, st, left))
  use #(right_type, st) <- result.try(infer_recovering(env, st, right))
  use st <- result.try(recover_unify(env, st, operand, left_type))
  use st <- result.try(recover_unify(env, st, operand, right_type))
  Ok(#(result, st))
}

// A constant's `<>`, in the constant typer's order
// (`infer_string_concatenation`, `constant.rs:557-584`): the left operand is
// inferred and unified with `String`, then the right one. Each operand is
// typed through `infer` and each unification is recorded.
fn infer_constant_concatenation(
  env: Env,
  st: State,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(ty.Type, State), Failure) {
  use #(left_type, st) <- result.try(infer_recovering(env, st, left))
  use st <- result.try(recover_unify(env, st, prelude_string(), left_type))
  use #(right_type, st) <- result.try(infer_recovering(env, st, right))
  use st <- result.try(recover_unify(env, st, prelude_string(), right_type))
  Ok(#(prelude_string(), st))
}

fn infer_pipe(
  env: Env,
  st: State,
  left: glance.Expression,
  right: glance.Expression,
) -> Result(#(ty.Type, State), Failure) {
  case right {
    // `left |> echo` is `echo left`: it prints the piped value and returns it,
    // so the `echo` and the pipe both have its type, as the compiler's pipeline
    // typer gives them. Inferred as that `echo`, through `infer_expr`, it
    // records its span like any expression and names nothing to resolve.
    glance.Echo(echo_span, None, message) ->
      infer_expr(env, st, glance.Echo(echo_span, Some(left), message))
    // Every other step is typed after the left side (`pipe.rs:43-63`), against
    // a local the compiler generates to hold the left value's type. A lambda
    // or capture step is a call of the literal on a read of that local
    // (`pipe.rs:97-125`), so it goes the way of a literal callee: the
    // speculative pass reads the left value to seed the parameter, and the
    // real pass reads it again as the argument.
    _ -> {
      // The first value is typed through `infer` (`pipe.rs:56-65`).
      use #(left_type, st) <- result.try(infer_recovering(env, st, left))
      case right, fn_literal_of_arity(right, 1) {
        glance.Call(call_span, function, arguments), _ ->
          infer_pipe_call(env, st, left_type, call_span, function, arguments)
        _, Ok(_) ->
          infer_call(env, st, right, [glance.UnlabelledField(Read(left_type))])
        _, Error(Nil) -> infer_pipe_apply(env, st, left_type, right)
      }
    }
  }
}

// `left |> f(args)`. The callee is typed once, as the compiler's
// `infer_called` types it (`pipe.rs:130-167, 404-430`): a function literal
// there has no call context, so its explicit arguments are not speculated.
// Then its arity decides the shape, and both shapes check their arguments
// against the known callee (`do_infer_call_with_known_fun`).
fn infer_pipe_call(
  env: Env,
  st: State,
  left_type: ty.Type,
  call_span: glance.Span,
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> Result(#(ty.Type, State), Failure) {
  use #(fn_type, labels, st) <- result.try(infer_callee(env, st, function))
  let left = Read(left_type)
  let written = list.map(arguments, map_field(_, Written))
  case expected_fn(st, fn_type, list.length(arguments)) {
    // `f(args)` is already a saturated call, which returns a function: the
    // pipe applies it to the left value, `f(args)(left)`
    // (`infer_apply_to_call_pipe`, `pipe.rs:297-330`). The call `f(args)` is
    // recorded at the step's span, as `infer_expr` would record it.
    Ok(_) -> {
      use #(call_type, st) <- result.try(place_arguments(
        env,
        st,
        fn_type,
        labels,
        written,
      ))
      let st = record(st, call_span, call_type)
      place_arguments(env, st, call_type, None, [glance.UnlabelledField(left)])
    }
    // `f(left, args)` (`infer_insert_pipe`, `pipe.rs:335-355`): the left value
    // is the first argument in source order, read where the reorder places it,
    // so a labelled argument placed before it is inferred first
    // (`fields.rs:128-137`). The call has no node of its own, so its span is
    // recorded here, once; the whole pipe's span is `infer_expr`'s.
    Error(Nil) -> {
      use #(call_type, st) <- result.try(
        place_arguments(env, st, fn_type, labels, [
          glance.UnlabelledField(left),
          ..written
        ]),
      )
      Ok(#(call_type, record(st, call_span, call_type)))
    }
  }
}

// `left |> f` for any other `f`: the step is unified with a function of the
// left value's own type, with no read of it (`infer_apply_pipe`,
// `pipe.rs:367-399`). It resolves through `infer_callee` — `infer_expr` plus a
// field-map lookup this shape has no arguments to use — which is also what
// records a bare name's reference.
fn infer_pipe_apply(
  env: Env,
  st: State,
  left_type: ty.Type,
  right: glance.Expression,
) -> Result(#(ty.Type, State), Failure) {
  use #(function_type, _labels, st) <- result.try(infer_callee(env, st, right))
  let #(result, st) = fresh(st)
  use st <- result.try(recover_unify(
    env,
    st,
    function_type,
    ty.Fn([left_type], result),
  ))
  Ok(#(result, st))
}

// Infer an expression and unify it against an expected type. A function
// literal — a lambda or a capture — is checked against the expected type so
// its parameters are seeded from the expected argument types before its body
// is inferred (`infer_call_argument`, `expression.rs:3942-3985`). Any other
// expression is typed through `infer`, and the unification is recorded, as
// the compiler checks a call argument, a message and a guard.
fn check(
  env: Env,
  st: State,
  expr: glance.Expression,
  expected: ty.Type,
) -> Result(State, Failure) {
  let seeded = {
    use literal <- result.try(as_fn_literal(expr))
    use #(seeds, _return) <- result.map(expected_fn(
      st,
      expected,
      fn_literal_arity(literal),
    ))
    #(literal, seeds)
  }
  case seeded {
    Ok(#(literal, seeds)) -> {
      use #(fn_type, st) <- result.try(infer_seeded(env, st, literal, seeds))
      recover_unify(env, st, expected, fn_type)
    }
    Error(Nil) -> {
      use #(t, st) <- result.try(infer_recovering(env, st, expr))
      recover_unify(env, st, expected, t)
    }
  }
}

// Check the `as` message of an `echo`, an `assert` or a `let assert` against
// `String`, as the compiler does.
//
// The compiler reads a message as one expression unit. glance reads a whole
// expression, so an operator after the message lands inside it: the compiler
// reads `x |> echo as "m" |> f` as `(x |> echo as "m") |> f`, glance as a
// message `"m" |> f`. After an assertion, a next statement starting with a
// minus is read into the message the same way, the rest of that statement with
// it. A unit is never a bare binary operator (a grouped one is a block), so a
// message glance hands over as one is a reading the compiler never made.
// Typing it would give a false error or a wrong signature, so it is declined.
//
// `todo` and `panic` check their message without this guard: girard has typed
// their messages as glance reads them all along, and published code holds
// messages such as `panic as "x: " <> y`, which the guard would decline. Once
// glance parses a message as a unit, the guard can never match and goes.
fn check_message(
  env: Env,
  st: State,
  message: Option(glance.Expression),
) -> Result(State, Failure) {
  case message {
    Some(glance.BinaryOperator(..)) ->
      fail(st, Unsupported("an operator after an `as` message"))
    Some(message) -> check(env, st, message, prelude_string())
    None -> Ok(st)
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
) -> Result(#(ty.Type, State), Failure) {
  case statements {
    // No statement is the compiler's implicit `todo`, a fresh type: the parser
    // puts one in an empty block, at the block's own span
    // (`TodoKind::EmptyBlock`, `parse.rs:1310-1320`), and in an empty function
    // body (`TodoKind::EmptyFunction`, `parse.rs:2294-2310`), and the typer
    // ends a `use` with nothing after it with one, after the callback's
    // generated assignments (`TodoKind::IncompleteUse`,
    // `expression.rs:815-822`). A block records its span once, as the block.
    // The other two record none: an empty function body's `todo` spans from
    // after its `{`, which glance does not keep, and girard records no
    // expression at a `use` statement's span, where the compiler records the
    // call, the callback and this `todo` together.
    [] -> Ok(fresh(st))
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

// Desugar `use a, b <- rhs(args)` followed by `rest` into
// `rhs(args, fn(a, b) { rest })` and infer the resulting call.
//
// The callee comes first, as it does for every other call, so the callback's
// parameter types are known before the rest of the block is walked: a field
// access on a `use` binding then resolves at the access instead of waiting for
// unification to fix the receiver. The callback is pushed *unlabelled* and the
// complete argument list is reordered through the callee's field map, so a
// labelled explicit argument can leave the callback an earlier slot than the
// last — and the slots are then walked in declared order, so an explicit
// argument declared after the callback is inferred after it.
//
// The desugared call is an ordinary call (`expression.rs:802-888`), so a
// literal callee speculates its arguments first: the explicit ones in source
// order, then the callback, which has no expected type yet.
fn infer_use(
  env: Env,
  st: State,
  use_patterns: List(glance.UsePattern),
  function: glance.Expression,
  rest: List(glance.Statement),
) -> Result(#(ty.Type, State), Failure) {
  let #(callee, arguments) = case function {
    glance.Call(_, callee, arguments) -> #(callee, arguments)
    // A `use` callee with no argument list is still a callee: the callback is
    // its only argument.
    other -> #(other, [])
  }
  let arguments =
    list.append(list.map(arguments, map_field(_, Written)), [
      glance.UnlabelledField(Callback(use_patterns, rest)),
    ])
  infer_call(env, st, callee, arguments)
}

// Check a `use` callback against the parameter type its slot was given, the way
// `check` checks a lambda against a known function type. A callback is not a
// `glance.Fn` — its parameters are patterns and its body is the rest of the
// block — so it cannot go through `check` itself, but the seeding rule is the
// same: where the expected type is a function of the patterns' arity, each
// pattern is inferred against its expected parameter type, so a field access on
// a `use` binding sees the type it was bound at.
//
// The callback is the lambda the compiler desugars it to
// (`UseAssignments::from_use_expression`, `expression.rs:4849-4909`). A
// variable or discard pattern is a parameter, its annotation the parameter's.
// Any other pattern is a generated parameter with no annotation, and the
// pattern with its annotation is the assignment `let pattern: ann = _use<n>`
// at the head of the body.
fn check_callback(
  env: Env,
  st: State,
  use_patterns: List(glance.UsePattern),
  rest: List(glance.Statement),
  expected: ty.Type,
) -> Result(State, Failure) {
  let seeds = case expected_fn(st, expected, list.length(use_patterns)) {
    Ok(#(params, _return)) -> Some(params)
    Error(_) -> None
  }
  // A simple pattern's annotation is its parameter's, hydrated here, in the
  // enclosing scope, as a lambda parameter's is; a complex pattern's
  // parameter has none.
  let annotations =
    list.map(use_patterns, fn(use_pattern) {
      case simple_use_pattern(use_pattern) {
        True -> use_pattern.annotation
        False -> None
      }
    })
  case parameter_types(env, st, annotations, seeds) {
    Ok(#(param_types, st)) ->
      callback_body(env, st, use_patterns, param_types, rest, expected)
    // As a lambda's: the callback is a fresh variable, checked against the
    // parameter as any argument is.
    Error(failure) -> {
      use #(callback, st) <- result.try(recover_fresh(env, Error(failure)))
      recover_unify(env, st, expected, callback)
    }
  }
}

// A `use` callback once its parameters are typed.
fn callback_body(
  env: Env,
  st: State,
  use_patterns: List(glance.UsePattern),
  param_types: List(ty.Type),
  rest: List(glance.Statement),
  expected: ty.Type,
) -> Result(State, Failure) {
  // The body, a scope of its own: the simple patterns bound as parameters,
  // then each generated assignment in order — a read of its parameter, the
  // pattern against what was read, then the annotation, hydrated in the body's
  // scope, as a `let` is typed.
  let #(simple, complex) =
    list.zip(use_patterns, param_types)
    |> list.partition(fn(param) { simple_use_pattern(param.0) })
  use #(body_env, st) <- result.try(
    list.try_fold(simple, #(env, st), fn(acc, param) {
      let #(env, st) = acc
      let #(use_pattern, type_) = param
      use #(env, _, st) <- result.map(infer_pattern(
        env,
        st,
        use_pattern.pattern,
        type_,
        None,
      ))
      #(env, st)
    }),
  )
  use #(body_type, st) <- result.try({
    use st <- scoped(st)
    use #(body_env, st) <- result.try(
      list.try_fold(complex, #(body_env, st), fn(acc, param) {
        let #(env, st) = acc
        use_assignment(env, st, param.0, param.1)
      }),
    )
    infer_statements(body_env, st, rest)
  })
  recover_unify(env, st, expected, ty.Fn(param_types, body_type))
}

// The assignment the compiler generates at the head of a `use` callback's
// body for a pattern that is not a parameter, `let pattern: ann = _use<n>`,
// typed as any `let` is: a read of the parameter, the pattern against what
// was read, then the annotation.
fn use_assignment(
  env: Env,
  st: State,
  use_pattern: glance.UsePattern,
  param_type: ty.Type,
) -> Result(#(Env, State), Failure) {
  let #(read, st) = read_type(st, param_type)
  use #(env, _, st) <- result.try(infer_pattern(
    env,
    st,
    use_pattern.pattern,
    read,
    None,
  ))
  use st <- result.map(case use_pattern.annotation {
    Some(ann) -> {
      let #(annotated, st) = hydrate_scoped(env, st, ann)
      recover_unify(env, st, annotated, read)
    }
    None -> Ok(st)
  })
  #(env, st)
}

// Whether a `use` pattern is a parameter of the callback the compiler
// desugars, rather than an assignment in its body: a variable or a discard.
fn simple_use_pattern(use_pattern: glance.UsePattern) -> Bool {
  case use_pattern.pattern {
    glance.PatternVariable(..) | glance.PatternDiscard(..) -> True
    _ -> False
  }
}

// When a lambda of `arity` parameters may be seeded from `expected`: its
// parameter types and its return, where the expected type is already known to
// be a function of that arity. This is the rule the whole seeding mechanism
// turns on, so `check` and `check_callback` read it from one place.
fn expected_fn(
  st: State,
  expected: ty.Type,
  arity: Int,
) -> Result(#(List(ty.Type), ty.Type), Nil) {
  case resolve(st, expected) {
    ty.Fn(params, return) ->
      case list.length(params) == arity {
        True -> Ok(#(params, return))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// Infer one statement, returning its type and the (possibly extended)
// environment to thread to following statements.
fn infer_statement(
  env: Env,
  st: State,
  statement: glance.Statement,
) -> Result(#(ty.Type, Env, State), Failure) {
  case statement {
    // Typed through `infer`, so the next statement continues after a failure
    // (`expression.rs:763-799`).
    glance.Expression(expr) -> {
      use #(t, st) <- result.try(infer_recovering(env, st, expr))
      Ok(#(t, env, st))
    }

    glance.Assignment(_, kind, pattern, annotation, value) ->
      infer_expr_assignment(env, st, kind, pattern, annotation, value)

    glance.Assert(_, expression, message) -> {
      use st <- result.try(check(env, st, expression, prelude_bool()))
      use st <- result.try(check_message(env, st, message))
      Ok(#(prelude_nil(), env, st))
    }

    // `use` is handled by infer_statements before reaching here.
    glance.Use(..) -> fail(st, Unsupported("use in non-tail position"))
  }
}

// `let pattern = value`, in the compiler's order (`infer_assignment`,
// `expression.rs:2085-2114`): infer the value in a scope of its own, check a
// `let assert`'s message, bind the pattern monomorphically, then check the
// value against the binding's annotation, hydrated in the statement's scope,
// so a name it creates is visible to the rest of the block. The message is
// checked under the incoming `env`, before the pattern binds: it sees neither
// the pattern's names nor what the pattern constrains.
//
// A let-bound annotated lambda is polymorphic with no generalization step:
// its annotations' generics leave scope with the value, so each read of the
// binding copies them.
fn infer_expr_assignment(
  env: Env,
  st: State,
  kind: glance.AssignmentKind,
  pattern: glance.Pattern,
  annotation: Option(glance.Type),
  value: glance.Expression,
) -> Result(#(ty.Type, Env, State), Failure) {
  use #(value_type, st) <- result.try({
    use st <- scoped(st)
    infer_recovering(env, st, value)
  })
  let message = reference.assignment_message(kind)
  use st <- result.try(check_message(env, st, message))
  // `let assert Ctor(..) = x` narrows `x` itself, for the rest of the block.
  use #(pattern_env, _, st) <- result.try(infer_pattern(
    env,
    st,
    pattern,
    value_type,
    subject_of(value),
  ))
  use st <- result.try(case annotation {
    Some(ann) -> {
      let #(t, st) = hydrate_scoped(env, st, ann)
      recover_unify(env, st, t, value_type)
    }
    None -> Ok(st)
  })
  Ok(#(value_type, pattern_env, st))
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
) -> Result(#(ty.Type, State), Failure) {
  // Each subject is a scope of its own, as the compiler's `infer_case` scopes
  // it (`expression.rs:2285`).
  use #(subject_types, st) <- result.try(
    infer_each(st, subjects, fn(st, subject) {
      use st <- scoped(st)
      infer_recovering(env, st, subject)
    }),
  )
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
  subject_types: List(ty.Type),
  result: ty.Type,
) -> Result(State, Failure) {
  // A clause is a scope of its own (`expression.rs:2387`).
  use st <- scoped_state(st)
  // Each clause may have several alternative pattern lists (`a | b ->`); each
  // binds the same variables and is checked against the subject types. The
  // first alternative binds in the clause's environment, and its bindings are
  // installed before any later alternative is typed, as the compiler's
  // `infer_clause` installs them (`expression.rs:2404-2428`): a later
  // alternative starts from the clause's environment plus those bindings, and
  // each of its own bindings of a name is unified with the first's as it is
  // made. The guard and body are checked once, under the first alternative's
  // bindings, less the narrowings the alternatives disagree on.
  case clause.patterns {
    // A clause glance parsed always has a pattern list; one with none binds
    // nothing to check a body under.
    [] -> Ok(st)
    [first_patterns, ..later] -> {
      use #(first, st) <- result.try(bind_alternative(
        env,
        None,
        st,
        first_patterns,
        subjects,
        subject_types,
      ))
      use #(others, st) <- result.try(bind_later_alternatives(
        env,
        first.bound,
        st,
        later,
        subjects,
        subject_types,
      ))
      let clause_env = case others {
        // One alternative agrees with itself, which is every clause that does
        // not spell `|`.
        [] -> first.env
        _ ->
          // The bindings' agreement compares the types the walks stored for
          // them, which unifying the bindings cannot have changed.
          agree_subjects(st, first, others)
          |> agree_bindings(st, _, first.bound, others)
      }
      infer_clause_body(clause_env, st, clause, result)
    }
  }
}

// Bind a clause's later alternatives, each from the clause's environment
// plus the bindings the first alternative made (`bound`).
fn bind_later_alternatives(
  env: Env,
  bound: Dict(String, ValueConstructor),
  st: State,
  later: List(List(glance.Pattern)),
  subjects: List(glance.Expression),
  subject_types: List(ty.Type),
) -> Result(#(List(PatternWalk), State), Failure) {
  use <- bool.guard(when: later == [], return: Ok(#([], st)))
  let start = dict.fold(bound, env, install_entry)
  use #(rev_others, st) <- result.map(
    list.try_fold(later, #([], st), fn(acc, patterns) {
      let #(others, st) = acc
      use #(other, st) <- result.map(bind_alternative(
        start,
        Some(bound),
        st,
        patterns,
        subjects,
        subject_types,
      ))
      #([other, ..others], st)
    }),
  )
  #(list.reverse(rev_others), st)
}

// Check a clause's guard, if it has one, and unify its body with the `case`'s
// result, under the bindings its patterns introduced.
fn infer_clause_body(
  env: Env,
  st: State,
  clause: glance.Clause,
  result: ty.Type,
) -> Result(State, Failure) {
  use st <- result.try(case clause.guard {
    Some(guard) ->
      check(Env(..env, syntax: GuardSyntax), st, guard, prelude_bool())
    None -> Ok(st)
  })
  use #(body_type, st) <- result.try(infer_recovering(env, st, clause.body))
  recover_unify(env, st, result, body_type)
}

// Bind one alternative's patterns against the subjects, narrowing any bare
// subject variable a variant pattern matches. `first` is `None` for a
// clause's first alternative, and the bindings the first alternative made for
// a later one. Returns the walk, which holds the environment, the bindings
// the alternative made and the narrowings, and the state.
fn bind_alternative(
  env: Env,
  first: Option(Dict(String, ValueConstructor)),
  st: State,
  patterns: List(glance.Pattern),
  subjects: List(glance.Expression),
  subject_types: List(ty.Type),
) -> Result(#(PatternWalk, State), Failure) {
  let walk =
    PatternWalk(
      env:,
      start: env.values,
      first:,
      bound: dict.new(),
      narrowed: dict.new(),
    )
  use #(walk, st) <- result.map(
    list.try_fold(
      list.zip(patterns, list.zip(subjects, subject_types)),
      #(walk, st),
      fn(acc, pair) {
        let #(walk, st) = acc
        let #(pattern, #(subject, subject_type)) = pair
        use #(walk, _, st) <- result.map(walk_pattern(
          walk,
          st,
          pattern,
          subject_type,
          subject_of(subject),
        ))
        #(walk, st)
      },
    ),
  )
  #(walk, st)
}

// A subject variable's variant across alternatives, the compiler's
// `set_subject_variable_variant` in alternative mode (`pattern.rs:236-257`):
// the **first** alternative is the only one that may set it, and a later
// alternative can only take it away, by narrowing it to a different variant.
// One that narrows it to none leaves it alone, and so does every later
// alternative for a subject the first did not narrow, so a variant the subject
// had before the `case` is kept.
//
// So the rule is order-sensitive, and measured to be: `Loud(..) | _` keeps the
// narrowing and reads the field, while `_ | Loud(..)` is rejected — the first
// alternative narrows nothing, and the second is not allowed to. It is decided
// from the narrowings each alternative's own patterns made, not from the
// variants its environment holds, which include the inherited ones. A later
// alternative that narrows to another variant erases it for good, as the
// compiler drops the subject from the first alternative's narrowings, so one
// after it naming the first's variant again does not bring it back. The answer
// is applied to `first`'s environment alone: the guard and body are checked
// under it, so it is the env that must bind the subject at the variant the
// compiler ends up with.
fn agree_subjects(
  st: State,
  first: PatternWalk,
  others: List(PatternWalk),
) -> Env {
  // Each later narrowing is compared once, with the variant the first
  // alternative holds.
  list.fold(others, set.new(), fn(erased, other) {
    dict.fold(other.narrowed, erased, fn(erased, name, variants) {
      case disagrees(first.narrowed, name, variants) {
        True -> set.insert(erased, name)
        False -> erased
      }
    })
  })
  |> set.fold(first.env, fn(env, name) { erase_binding(st, env, name) })
}

// Whether a later alternative narrowed `name` to a variant other than the one
// the first alternative holds, its latest narrowing of it. A subject the first
// did not narrow is never in disagreement.
fn disagrees(
  first: Dict(String, List(Int)),
  name: String,
  variants: List(Int),
) -> Bool {
  case dict.get(first, name) {
    Ok([held, ..]) -> list.any(variants, fn(variant) { variant != held })
    Ok([]) | Error(Nil) -> False
  }
}

// A name the patterns *bind* is a different rule, and not the one above: the
// compiler unifies the alternatives' bindings through
// `unify_constructor_variants` (`pattern.rs:163-185, 1654-1668`), which
// erases the first alternative's variant where a later alternative binds the
// name at another one. Measured: `Loud(..) as io | _ as io` is rejected,
// where the subject form `Loud(..) | _` is accepted, so the two classes
// genuinely disagree and cannot share a pass. Equal and unstamped is
// agreement too. As above, the answer is applied to `first`.
//
// The bindings are the ones the walks made (`bound`), so a name in a
// sub-pattern a speculative walk skipped is no binding. Each binding's stored
// type is compared raw, as the compiler compares them: both must be named
// types, so a binding at a type variable, which is the compiler's link
// whether the substitution binds it or not, leaves the first's variant alone.
// That relies on girard's types being as raw as the compiler's: a read is
// link-free (`read_value`), a field access is the accessor's own field type
// (`field_type`), and a list pattern's element is the list type's argument
// (`list_element`).
//
// Only a binding's outer type is compared, as `unify_constructor_variants`
// compares it: a variant inside a tuple binding is not cleared where the
// alternatives differ, so `#(Loud(..), _) as p | #(Quiet(..), _) as p` keeps
// the first alternative's `p.0` narrowed, which the compiler accepts too.
fn agree_bindings(
  st: State,
  first: Env,
  bound: Dict(String, ValueConstructor),
  others: List(PatternWalk),
) -> Env {
  dict.fold(bound, first, fn(env, name, entry) {
    case erased_by_later(entry, name, others) {
      True -> erase_binding(st, env, name)
      False -> env
    }
  })
}

// Whether a later alternative binds `name` at a named type whose variant is
// not the first alternative's, which must be a named type with a variant.
fn erased_by_later(
  entry: ValueConstructor,
  name: String,
  others: List(PatternWalk),
) -> Bool {
  case bound_variant(entry) {
    Ok(Some(_) as variant) ->
      list.any(others, fn(other) {
        case result.try(dict.get(other.bound, name), bound_variant) {
          Ok(later) -> later != variant
          Error(Nil) -> False
        }
      })
    Ok(None) | Error(Nil) -> False
  }
}

// The variant a binding's stored type carries, read raw: an error unless the
// type is a named one, without following the substitution.
fn bound_variant(entry: ValueConstructor) -> Result(Option(Int), Nil) {
  case entry.scheme.type_ {
    ty.Named(variant:, ..) -> Ok(variant)
    ty.Var(_) | ty.Fn(..) | ty.Tuple(..) -> Error(Nil)
  }
}

// Rebind `name` to its own type with the variant forgotten: the same binding,
// less what the alternatives disagreed on.
fn erase_binding(st: State, env: Env, name: String) -> Env {
  case dict.get(env.values, name) {
    Ok(ValueConstructor(ty.Scheme(vars, type_), variant)) ->
      install(
        env,
        name,
        ty.Scheme(vars, erase_variant(resolve(st, type_))),
        variant,
      )
    Error(_) -> env
  }
}

// Patterns
//
// Infer a pattern against its expected type, binding the variables it
// introduces — constructor, list, tuple, string-prefix and bit-array
// patterns included, and narrowing the bare variable the pattern is matched
// against when there is one.

// The bare variable a pattern is matched against, if the pattern is matched
// against one. A constructor names a record rather than a local variable, and
// `echo` is transparent, so `case echo io { .. }` narrows `io`.
fn subject_of(expr: glance.Expression) -> Option(String) {
  case expr {
    glance.Variable(_, name) ->
      case reference.is_upper(name) {
        True -> None
        False -> Some(name)
      }
    glance.Echo(_, Some(inner), _) -> subject_of(inner)
    _ -> None
  }
}

// Rebind `name` to its type narrowed to `variant`. The compiler sets the
// variant on a link-collapsed copy so the outer scope keeps its type; here the
// rebinding is the copy, and it lives only as long as the environment it is
// made in.
//
// The scheme's quantifiers are kept rather than instantiated away. A module
// constant is generalized like a function, so `const box = Empty` is bound at
// `Box(a)`, and monomorphizing it here would reject a clause that uses it at
// two instantiations — which the compiler accepts. Stamping under the
// quantifier narrows every instantiation instead, and `substitute` carries the
// variant through. Only a record is narrowed: a name whose type is a function
// or a tuple stamps to itself and is left alone, which is what excludes a
// top-level function used as a subject.
fn narrow(env: Env, st: State, name: String, variant: Int) -> Env {
  case dict.get(env.values, name) {
    Ok(ValueConstructor(ty.Scheme(vars, type_), value)) ->
      case stamp(st, type_, variant) {
        ty.Named(..) as stamped ->
          install(env, name, ty.Scheme(vars, stamped), value)
        _ -> env
      }
    Error(_) -> env
  }
}

// Infer a pattern, returning the environment it extends, **its own type**, and
// the state. The type is the compiler's `Pattern::type_()` rather than the
// expected type it was matched against: the two differ exactly where a pattern
// is more specific than what it matched, which is what an enclosing `as` has to
// bind at. A constructor pattern's own type carries the variant it matched, and
// a tuple pattern's is rebuilt from its elements' own types, so
// `#(Loud(..), _) as pair` binds `pair` at `#(Logger[Loud], Int)` and
// `pair.0.println` is in reach.
//
// Measured against 1.18.0: the rebuild is recursive (a tuple in a tuple keeps
// the stamp) and it stops at a constructor's arguments — `Box(Loud(..)) as b`
// leaves `b.value` un-narrowed, because a constructor pattern's type is its
// return, whose arguments were erased when the type variable was bound.
fn infer_pattern(
  env: Env,
  st: State,
  pattern: glance.Pattern,
  expected: ty.Type,
  subject: Option(String),
) -> Result(#(Env, ty.Type, State), Failure) {
  let walk =
    PatternWalk(
      env:,
      start: env.values,
      first: None,
      bound: dict.new(),
      narrowed: dict.new(),
    )
  use #(walk, type_, st) <- result.map(walk_pattern(
    walk,
    st,
    pattern,
    expected,
    subject,
  ))
  #(walk.env, type_, st)
}

// A pattern walk: the environment its bindings extend, and what the
// compiler's pattern typer keeps beside it (`pattern.rs:100-193`).
type PatternWalk {
  PatternWalk(
    env: Env,
    // The names in scope where the pattern started: the clause's, and for a
    // later alternative the first alternative's bindings too. A bit-array
    // size reads a name from here unless an earlier segment of its own bit
    // array bound it: every other part of the pattern is out of its reach
    // (`pattern.rs:419-428, 1405-1423`).
    start: Dict(String, ValueConstructor),
    // For a later alternative, the bindings the first alternative made;
    // `None` for a first or only alternative.
    first: Option(Dict(String, ValueConstructor)),
    // The bindings this walk has made so far.
    bound: Dict(String, ValueConstructor),
    // The subject variables this walk has narrowed, each with every variant
    // it narrowed it to, latest first. The latest is the one a first
    // alternative holds, as the compiler's `inferred_variant_variables` keeps
    // it; any one of a later alternative's that differs takes it away
    // (`pattern.rs:197-257`).
    narrowed: Dict(String, List(Int)),
  )
}

fn walk_pattern(
  walk: PatternWalk,
  st: State,
  pattern: glance.Pattern,
  expected: ty.Type,
  subject: Option(String),
) -> Result(#(PatternWalk, ty.Type, State), Failure) {
  case pattern {
    glance.PatternInt(..) ->
      typed(
        walk,
        prelude_int(),
        recover_unify(walk.env, st, expected, prelude_int()),
      )
    glance.PatternFloat(..) ->
      typed(
        walk,
        prelude_float(),
        recover_unify(walk.env, st, expected, prelude_float()),
      )
    glance.PatternString(..) ->
      typed(
        walk,
        prelude_string(),
        recover_unify(walk.env, st, expected, prelude_string()),
      )
    glance.PatternDiscard(..) -> Ok(#(walk, expected, st))

    glance.PatternVariable(_, name) -> {
      use #(walk, st) <- result.map(bind_pattern_name(walk, st, name, expected))
      #(walk, expected, st)
    }

    glance.PatternTuple(_, elements) -> {
      // Destructure a tuple the expected type already is, element by element,
      // rather than through fresh element variables: a variable binding erases
      // what the element was built with, and the compiler destructures. The
      // tuple's own type is then rebuilt from what the elements matched, which
      // is where an element's variant survives to an enclosing `as`.
      use #(elem_types, st) <- result.try(tuple_elements(
        walk.env,
        st,
        expected,
        list.length(elements),
      ))
      // A tuple pattern against a type that is no tuple of its width walks
      // no element in a speculative walk, and is the type it was matched
      // against (`pattern.rs:932-979`).
      use elem_types <- skip_pattern(elem_types, #(walk, expected, st))
      use #(walk, rev_types, st) <- result.try(
        list.try_fold(
          list.zip(elements, elem_types),
          #(walk, [], st),
          fn(acc, pair) {
            let #(walk, types_, st) = acc
            let #(pattern, t) = pair
            use #(walk, t, st) <- result.map(walk_pattern(
              walk,
              st,
              pattern,
              t,
              None,
            ))
            #(walk, [t, ..types_], st)
          },
        ),
      )
      Ok(#(walk, ty.Tuple(list.reverse(rev_types)), st))
    }

    glance.PatternList(_, elements, tail) -> {
      // A list pattern against a type that is no list walks no element in a
      // speculative walk, and is the type it was matched against
      // (`pattern.rs:880-929`).
      use #(shape, st) <- result.try(list_element(walk.env, st, expected))
      use elem <- skip_pattern(shape, #(walk, expected, st))
      use #(walk, st) <- result.try(
        list.try_fold(elements, #(walk, st), fn(acc, p) {
          let #(walk, st) = acc
          use #(walk, _, st) <- result.map(walk_pattern(walk, st, p, elem, None))
          #(walk, st)
        }),
      )
      use #(walk, st) <- result.try(case tail {
        Some(t) -> {
          use #(walk, _, st) <- result.map(walk_pattern(
            walk,
            st,
            t,
            prelude_list(elem),
            None,
          ))
          #(walk, st)
        }
        None -> Ok(#(walk, st))
      })
      Ok(#(walk, prelude_list(elem), st))
    }

    // `Ctor(..) as name` hands the subject on to the pattern inside it, which
    // narrows the subject as it would on its own; the `as` name then takes the
    // pattern's own type, and so is itself that pattern's type. The pattern is
    // inferred first so its narrowing cannot overwrite this binding.
    glance.PatternAssignment(_, pattern, name) -> {
      use #(walk, type_, st) <- result.try(walk_pattern(
        walk,
        st,
        pattern,
        expected,
        subject,
      ))
      use #(walk, st) <- result.map(bind_pattern_name(walk, st, name, type_))
      #(walk, type_, st)
    }

    glance.PatternConcatenate(..) -> {
      use st <- result.try(recover_unify(
        walk.env,
        st,
        expected,
        prelude_string(),
      ))
      // Both the matched prefix (`"a" as c <> rest`) and the remainder bind to
      // String. The prefix binding is optional (`<> rest` with no `as`).
      use #(walk, st) <- result.map(
        list.try_fold(
          reference.pattern_names(pattern),
          #(walk, st),
          fn(acc, name) {
            bind_pattern_name(acc.0, acc.1, name, prelude_string())
          },
        ),
      )
      #(walk, prelude_string(), st)
    }

    glance.PatternVariant(_, module, constructor, arguments, _spread) -> {
      use entry <- result.try(stateless(
        st,
        constructor_entry(walk.env, module, constructor),
      ))
      let #(ctor_type, st) = instantiate(st, entry.scheme)
      // A constructor with fields is a function; one without is the value.
      let #(field_types, ret) = case ctor_type {
        ty.Fn(args, ret) -> #(args, ret)
        other -> #([], other)
      }
      // A mismatch with the subject is recorded, and the field patterns are
      // still walked at the constructor's field types (`pattern.rs:1232-1262`).
      use st <- result.try(recover_unify(walk.env, st, expected, ret))
      // Matching a bare subject variable against this constructor narrows that
      // variable to it, in this scope only: `env` is a value, so the scope the
      // pattern opens carries the rebinding and the caller's does not.
      let walk = case subject, variant_of(ret) {
        Some(name), Some(index) -> narrow_subject(walk, st, name, index)
        _, _ -> walk
      }
      use arg_patterns <- result.try(stateless(
        st,
        order_pattern_args(
          positional_labels(entry.variant),
          arguments,
          list.length(field_types),
        ),
      ))
      use #(walk, st) <- result.try(
        list.try_fold(
          list.zip(arg_patterns, field_types),
          #(walk, st),
          fn(acc, pair) {
            let #(walk, st) = acc
            let #(pattern, t) = pair
            use #(walk, _, st) <- result.map(walk_pattern(
              walk,
              st,
              pattern,
              t,
              None,
            ))
            #(walk, st)
          },
        ),
      )
      // The constructor's own return, stamped: the arguments matched above do
      // not re-stamp it, which is the compiler's shape.
      Ok(#(walk, ret, st))
    }

    glance.PatternBitString(_, segments) -> {
      use st <- result.try(recover_unify(
        walk.env,
        st,
        expected,
        prelude_bit_array(),
      ))
      // A size reads the names the pattern started with, plus those bound by
      // earlier segments of this bit array.
      use #(walk, _sizes, st) <- result.try(
        list.try_fold(segments, #(walk, walk.start, st), fn(acc, segment) {
          let #(walk, sizes, st) = acc
          infer_bit_pattern_segment(walk, sizes, st, segment)
        }),
      )
      Ok(#(walk, prelude_bit_array(), st))
    }
  }
}

// Bind a name the pattern introduces, as the compiler's `insert_variable`
// does (`pattern.rs:124-193`). A later alternative's binding of a name the
// first alternative bound is unified with the first's binding as it is made;
// one of a name the first did not bind is the compiler's
// `ExtraVarInAlternativePattern`, reported here as the name being unbound. In
// a speculative walk it is recorded and the name is bound nowhere: neither in
// the environment nor for a later size to read.
fn bind_pattern_name(
  walk: PatternWalk,
  st: State,
  name: String,
  type_: ty.Type,
) -> Result(#(PatternWalk, State), Failure) {
  case walk.first {
    None -> Ok(#(bound_name(walk, name, type_), st))
    Some(first) ->
      case dict.get(first, name) {
        Ok(initial) -> {
          use st <- result.map(recover_unify(
            walk.env,
            st,
            initial.scheme.type_,
            type_,
          ))
          #(bound_name(walk, name, type_), st)
        }
        Error(_) ->
          recover_with(walk.env, fail(st, UnboundVariable(name)), fn(failed) {
            Ok(#(walk, failed))
          })
      }
  }
}

// `walk` with `name` bound at `type_`. A first or only alternative's binding
// of a subject it narrowed takes the narrowing out of `narrowed`, as the
// compiler's `insert_variable` takes it out of `inferred_variant_variables`
// (`pattern.rs:133-150`): the name is now the pattern's own value, which a
// later alternative cannot erase a variant of. A later alternative's binding
// leaves its narrowings alone, as the compiler's does.
fn bound_name(walk: PatternWalk, name: String, type_: ty.Type) -> PatternWalk {
  let entry = ValueConstructor(ty.Scheme([], type_), LocalValue(name))
  let narrowed = case walk.first {
    None -> dict.delete(walk.narrowed, name)
    Some(_) -> walk.narrowed
  }
  PatternWalk(
    ..walk,
    env: install_entry(walk.env, name, entry),
    bound: dict.insert(walk.bound, name, entry),
    narrowed:,
  )
}

// Narrow the subject variable `name` to `variant` for the rest of the walk,
// unless the walk has already bound `name` itself (`pattern.rs:197-205`). A
// pattern's own binding is a different value. One made before the narrowing
// blocks it; one made after it replaces the narrowed entry (`bound_name`). So
// which wins depends on the walk order and on what was actually bound, and a
// sub-pattern a speculative walk skips binds nothing: in
// `case t, r.field { B, #(t) -> .. }` with `r.field` no tuple, `t` is narrowed.
fn narrow_subject(
  walk: PatternWalk,
  st: State,
  name: String,
  variant: Int,
) -> PatternWalk {
  use <- bool.guard(when: dict.has_key(walk.bound, name), return: walk)
  PatternWalk(
    ..walk,
    env: narrow(walk.env, st, name, variant),
    narrowed: dict.upsert(walk.narrowed, name, fn(earlier) {
      [variant, ..option.unwrap(earlier, [])]
    }),
  )
}

// The type a list pattern matches its elements against: the expected type's
// own argument where it already is a list, as the compiler's
// `named_type_arguments` reads it (`pattern.rs:880-896`, `type_.rs:421-470`),
// so an element binds at that type as it stands; otherwise a fresh element
// variable the expected type is unified with. `None` where the expected type
// is no list, which a speculative walk skips (`shape`).
fn list_element(
  env: Env,
  st: State,
  expected: ty.Type,
) -> Result(#(Option(ty.Type), State), Failure) {
  case resolve(st, expected) {
    ty.Named(module, "List", [element], _) if module == prelude_module ->
      Ok(#(Some(element), st))
    _ -> {
      let #(element, st) = fresh(st)
      shape(env, unify(st, expected, prelude_list(element)), element)
    }
  }
}

// A pattern arm's result where the pattern's own type is already known.
fn typed(
  walk: PatternWalk,
  type_: ty.Type,
  st: Result(State, Failure),
) -> Result(#(PatternWalk, ty.Type, State), Failure) {
  result.map(st, fn(st) { #(walk, type_, st) })
}

// A tuple pattern's element types: the expected type's own elements where it
// already is a tuple of the right width, else fresh variables unified against
// it. Destructuring is what keeps an element's variant, which binding it to a
// fresh variable would erase; the fresh-variable path is also where an arity
// mismatch is still reported. In a speculative walk, `None` where the
// expected type is a concrete type that is no tuple of this width, whose
// elements the compiler does not walk; against a variable, rigid ones
// included, the shape's unification is recorded and the elements are walked
// (`pattern.rs:932-979`).
fn tuple_elements(
  env: Env,
  st: State,
  expected: ty.Type,
  arity: Int,
) -> Result(#(Option(List(ty.Type)), State), Failure) {
  let resolved = resolve(st, expected)
  let destructured = case resolved {
    ty.Tuple(elements) ->
      case list.length(elements) == arity {
        True -> Ok(elements)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case destructured, resolved {
    Ok(elements), _ -> Ok(#(Some(elements), st))
    Error(_), ty.Var(_) -> {
      let #(elem_types, st) = fresh_n(st, arity)
      use st <- result.map(recover_unify(
        env,
        st,
        ty.Tuple(elem_types),
        expected,
      ))
      #(Some(elem_types), st)
    }
    Error(_), ty.Tuple(..) | Error(_), ty.Named(..) | Error(_), ty.Fn(..) -> {
      let #(elem_types, st) = fresh_n(st, arity)
      shape(env, unify(st, expected, ty.Tuple(elem_types)), elem_types)
    }
  }
}

// A pattern's shape unified: `Some(value)` and the state, or in a speculative
// walk `None` and the failed state, where the pattern walks none of its
// children.
fn shape(
  env: Env,
  unified: Result(State, Failure),
  value: a,
) -> Result(#(Option(a), State), Failure) {
  unified
  |> result.map(fn(st) { #(Some(value), st) })
  |> recover_with(env, _, fn(failed) { Ok(#(None, failed)) })
}

// Continue a pattern arm with `shape`'s value, or end it with `skipped` where
// a speculative walk walks none of its children.
fn skip_pattern(
  shape: Option(a),
  skipped: b,
  continue: fn(a) -> Result(b, Failure),
) -> Result(b, Failure) {
  case shape {
    Some(value) -> continue(value)
    None -> Ok(skipped)
  }
}

// Check one bit-array *pattern* segment in the compiler's order
// (`infer_pattern_segment`, `pattern.rs:489-514, 609`): its size option is
// typed first, reading `sizes`, and then the segment's pattern binds. Returns
// `sizes` with what the segment bound added, for the segments after it.
fn infer_bit_pattern_segment(
  walk: PatternWalk,
  sizes: Dict(String, ValueConstructor),
  st: State,
  segment: #(
    glance.Pattern,
    List(glance.BitStringSegmentOption(glance.BitArraySize)),
  ),
) -> Result(#(PatternWalk, Dict(String, ValueConstructor), State), Failure) {
  let #(pattern, options) = segment
  let default = case pattern {
    glance.PatternString(..) -> prelude_string()
    glance.PatternFloat(..) -> prelude_float()
    _ -> prelude_int()
  }
  // A size that fails is recorded and the walk goes on (`pattern.rs:726-735`).
  use st <- result.try(
    list.try_fold(options, st, fn(st, option) {
      case option {
        glance.SizeValueOption(size) -> {
          // Read-only: a size lookup reads `values` and nothing else.
          let size_env = Env(..walk.env, values: sizes)
          recover_with(size_env, check_bit_array_size(size_env, st, size), Ok)
        }
        _ -> Ok(st)
      }
    }),
  )
  // The segment is walked with no binding of its own yet, so what its walk
  // holds after is exactly what it bound, and a segment costs only what it
  // binds; the walk's earlier bindings are merged back in after it.
  use #(after, _, st) <- result.try(walk_pattern(
    PatternWalk(..walk, bound: dict.new()),
    st,
    pattern,
    segment_value_type(options, default),
    None,
  ))
  let made = after.bound
  let after = PatternWalk(..after, bound: dict.merge(walk.bound, made))
  // In a later alternative a binding of a name the first alternative bound
  // is unified with the first's, and the compiler adds no variable of its
  // own (`pattern.rs:163-184, 394-415`): a size after it reads the first's
  // entry (`pattern.rs:1405-1419`).
  let for_sizes = case walk.first {
    None -> made
    Some(first) ->
      dict.map_values(made, fn(name, entry) {
        result.unwrap(dict.get(first, name), entry)
      })
  }
  Ok(#(after, dict.merge(sizes, for_sizes), st))
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
) -> Result(State, Failure) {
  case size {
    glance.BitArraySizeInt(..) -> Ok(st)
    glance.BitArraySizeVariable(_, name) -> {
      use #(_, type_, st) <- result.try(read_name(env, st, name))
      recover_unify(env, st, prelude_int(), type_)
    }
    glance.BitArraySizeBinaryOperator(_, _, left, right) -> {
      use st <- result.try(check_bit_array_size(env, st, left))
      check_bit_array_size(env, st, right)
    }
    glance.BitArraySizeBlock(_, inner) -> check_bit_array_size(env, st, inner)
  }
}

// Resolve a constructor name (optionally module-qualified) to its scope entry.
// The whole entry, because every caller wants the scheme *and* the labels, and
// resolving the name once is what keeps the two answers about the same
// constructor: a second lookup for the labels would have to re-decide which
// module the name came from, and could only disagree.
fn constructor_entry(
  env: Env,
  module: Option(String),
  constructor: String,
) -> Result(ValueConstructor, Error) {
  case module {
    Some(alias) -> qualified_entry(env, alias, constructor)
    None ->
      dict.get(env.values, constructor)
      |> result.replace_error(UnknownConstructor(constructor))
  }
}

// The export `alias.name` names: the imported module's scope entry, or why
// there is none.
fn qualified_entry(
  env: Env,
  alias: String,
  name: String,
) -> Result(ValueConstructor, Error) {
  case dict.get(env.modules, alias) {
    Ok(interface) ->
      dict.get(interface.values, name)
      |> result.replace_error(NoSuchExport(alias, name))
    Error(_) -> Error(UnknownModule(alias))
  }
}

// The value type of a bit-array segment given its options and the default to
// use when no type option is present (`Int` for numeric segments, `String`
// for string-literal segments, etc.).
fn segment_value_type(
  options: List(glance.BitStringSegmentOption(t)),
  default: ty.Type,
) -> ty.Type {
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
  labels: FieldMap,
  arguments: List(glance.Field(glance.Pattern)),
  arity: Int,
) -> Result(List(glance.Pattern), Error) {
  let index_of = label_indices(labels)
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
// a type variable is the one its name table holds, or a new one. An
// unresolved unqualified name is attributed to the prelude; an unresolved
// qualified name keeps its written module alias.

// Hydrate an annotation inside a function or a constant, as the compiler's
// `type_from_ast` does with new type variables permitted
// (`hydrator.rs:288-330`): a name already in scope is that type, and a new
// name is a generic the scope owns from here on, in scope until the boundary
// it was created inside closes. A hole is a flexible variable.
fn hydrate_scoped(env: Env, st: State, ast: glance.Type) -> #(ty.Type, State) {
  let before = st.scope.names
  let #(#(type_, st), names) = hydrate_with(env, before, st, ast)
  // `hydrate_with` only adds the names it does not find, so a table of the
  // same size means no name was created.
  use <- bool.guard(when: dict.size(names) == dict.size(before), return: #(
    type_,
    st,
  ))
  // `hydrate_with` minted each new name as a fresh variable nothing has
  // unified yet, so marking it a generic now is the same as minting one.
  let created =
    dict.drop(names, dict.keys(before))
    |> dict.values
    |> list.filter_map(var_id)
  let st = mark_rigid(st, created)
  let owned = list.fold(created, st.scope.owned, set.insert)
  #(type_, State(..st, scope: Scope(names:, owned:)))
}

// Run `infer` inside a new annotation scope, as the compiler's `scoped`
// (`expression.rs:381-393`) saves the hydrator's names around a `let` value,
// each `case` subject, a `case` clause, a function body and a block: a name
// created inside leaves scope when the boundary closes, though its generic
// stays rigid, so every later read copies it. The compiler's closure returns a
// value even where something inside it failed, so the boundary closes on a
// failure too: the failure's state leaves the scope as a success's does.
fn scoped(
  st: State,
  infer: fn(State) -> Result(#(a, State), Failure),
) -> Result(#(a, State), Failure) {
  let scope = st.scope
  case infer(st) {
    Ok(#(value, st)) -> Ok(#(value, State(..st, scope:)))
    Error(Failure(error, failed)) ->
      Error(Failure(error, State(..failed, scope:)))
  }
}

// `scoped` for a walk that returns only the state.
fn scoped_state(
  st: State,
  infer: fn(State) -> Result(State, Failure),
) -> Result(State, Failure) {
  use #(Nil, st) <- result.map(
    scoped(st, fn(st) { result.map(infer(st), fn(st) { #(Nil, st) }) }),
  )
  st
}

// Resolve a (possibly qualified) type name applied to `arg_types` to a concrete
// `Type`, expanding aliases (local, unqualified-imported, or qualified) and
// attributing a named type to its origin module.
fn resolve_named_type(
  env: Env,
  st: State,
  module: Option(String),
  name: String,
  arg_types: List(ty.Type),
) -> #(ty.Type, State) {
  case module {
    None -> resolve_unqualified_type(env, st, name, arg_types)
    Some(alias) -> resolve_qualified_type(env, st, alias, name, arg_types)
  }
}

fn resolve_unqualified_type(
  env: Env,
  st: State,
  name: String,
  arg_types: List(ty.Type),
) -> #(ty.Type, State) {
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
fn resolve_named_origin(
  env: Env,
  name: String,
  arg_types: List(ty.Type),
) -> ty.Type {
  case dict.get(env.imported_aliases, name) {
    Ok(#(params, body)) -> instantiate_alias(params, body, arg_types)
    Error(_) ->
      case dict.get(env.local_types, name) {
        Ok(#(origin, origin_name, _arity)) ->
          ty.Named(origin, origin_name, arg_types, None)
        Error(_) -> ty.Named(prelude_module, name, arg_types, None)
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
  arg_types: List(ty.Type),
) -> #(ty.Type, State) {
  case dict.get(env.modules, alias) {
    Error(_) -> #(ty.Named(alias, name, arg_types, None), st)
    Ok(interface) ->
      case dict.get(interface.aliases, name) {
        Ok(#(params, body)) -> #(instantiate_alias(params, body, arg_types), st)
        Error(_) -> {
          let origin = case dict.get(interface.types, name) {
            Ok(#(origin, _origin_name, _arity)) -> origin
            Error(_) -> alias
          }
          #(ty.Named(origin, name, arg_types, None), st)
        }
      }
  }
}

fn hydrate_with(
  env: Env,
  names: Dict(String, ty.Type),
  st: State,
  ast: glance.Type,
) -> #(#(ty.Type, State), Dict(String, ty.Type)) {
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
      #(#(ty.Tuple(list.reverse(elem_types)), st), names)
    }

    glance.FunctionType(_, parameters, return) -> {
      let #(param_types, st, names) =
        list.fold(parameters, #([], st, names), fn(acc, p) {
          let #(types_, st, names) = acc
          let #(#(t, st), names) = hydrate_with(env, names, st, p)
          #([t, ..types_], st, names)
        })
      let #(#(ret, st), names) = hydrate_with(env, names, st, return)
      #(#(ty.Fn(list.reverse(param_types), ret), st), names)
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
  names: Dict(String, ty.Type),
  st: State,
  ast: glance.Type,
) -> #(ty.Type, State) {
  hydrate_with(env, names, st, ast).0
}

// Building the annotated module
//
// Assemble the final `AnnotatedModule` from the inferred environment and
// state: each definition's generalized scheme and every recorded expression
// type, zonked and sorted by span. This section is the only place an
// inference-side type becomes a public one, whether in a result or in an
// `Error` that carries a type.

// `Inferred.functions` and `Inferred.constants` are the definitions inference
// walked, so a definition dropped for the other target is not looked up here
// at all. Rendering the caller's unfiltered module — as this used to —
// publishes a target sibling twice, since both names find the surviving
// definition's scheme, and publishes a dropped definition under the scheme of
// a same-named unqualified import.
fn render(inferred: Inferred) -> AnnotatedModule {
  let Inferred(functions:, constants:, env:, st:, skipped:, dropped:, ..) =
    inferred
  let declined = set.from_list(list.map(skipped, fn(entry) { entry.0 }))

  // `st.annotations` is in reverse discovery order. Restore discovery order
  // before the stable span sort, so annotations sharing a span retain the order
  // in which inference recorded them.
  let expressions =
    list.map(list.reverse(st.annotations), fn(entry) {
      let #(span, type_) = entry
      Annotation(span, to_public(zonk(st, type_)))
    })

  // `Env.unavailable` is keyed by module path, so there is one entry per
  // module already; only the order is left to decide.
  let unavailable =
    list.map(dict.to_list(env.unavailable), fn(entry) {
      let #(module, reason) = entry
      UnavailableModule(module, reason)
    })

  AnnotatedModule(
    functions: collect_schemes(functions, env, declined),
    constants: collect_schemes(constants, env, declined),
    expressions: sort_by_span(expressions),
    resolutions: publish_references(st),
    dropped:,
    unavailable: sort_unavailable(unavailable),
  )
}

// Publish the references recorded during inference: keep one per span, zonk
// each accessed record through the final substitution and convert it, then sort by
// span as annotations are sorted.
fn publish_references(st: State) -> List(ResolvedReference) {
  st.references
  |> one_per_span
  |> list.map(publish_reference(st, _))
  |> sort_references
}

// `AnnotatedModule.resolutions` promises one entry per span, so this is where
// that promise is kept, whoever produces a duplicate. No path does today
// — `infer_pipe`'s arity probe used to, and now runs on a state it throws away
// — but the guarantee is the API's, not one walk's, so it is enforced rather
// than assumed. The survivor is the **last recorded**: `st.references` is in
// reverse discovery order, where the last recorded is the first met.
//
// Two *different* references never share a whole span: a bare callee's is its
// variable, and a field access's includes its container.
fn one_per_span(references: List(Reference)) -> List(Reference) {
  list.fold(references, #([], set.new()), fn(acc, reference) {
    let #(kept, seen) = acc
    case set.contains(seen, reference.spans.span) {
      True -> acc
      False -> #([reference, ..kept], set.insert(seen, reference.spans.span))
    }
  }).0
}

fn publish_reference(st: State, reference: Reference) -> ResolvedReference {
  ResolvedReference(
    span: reference.spans.span,
    label_span: reference.spans.label,
    container_span: reference.spans.container,
    resolution: publish_resolution(st, reference.resolved),
  )
}

fn publish_resolution(st: State, resolved: Resolved) -> Resolution {
  case resolved {
    ResolvedField(receiver, label) ->
      RecordField(to_public(zonk(st, receiver)), label)
    // The declaring module's canonical path and the name the value has
    // *there*, never the alias it was read under: an
    // `import kinds.{Near as Close}` publishes `Constructor("kinds", "Near")`.
    ResolvedValue(FunctionValue(module:, name:, ..)) -> ModuleFn(module, name)
    ResolvedValue(ConstantValue(module:, name:, ..)) ->
      ModuleConstant(module, name)
    ResolvedValue(ConstructorValue(module:, name:, ..)) ->
      Constructor(module, name)
    ResolvedValue(LocalValue(name:)) -> LocalVariable(name)
    ResolvedDeferred -> Unresolved(RecordAccessUnknownType)
  }
}

fn sort_references(
  references: List(ResolvedReference),
) -> List(ResolvedReference) {
  list.sort(references, fn(a, b) { compare_spans(a.span, b.span) })
}

// Called from `for_target`, which is where a dropped definition is found, but
// defined here beside the other sorts so every published ordering is decided
// in one place.
fn sort_dropped(dropped: List(Dropped)) -> List(Dropped) {
  list.sort(dropped, fn(a, b) { compare_spans(a.span, b.span) })
}

// A module girard could not load has no span in the module being annotated,
// so its entries are sorted by path instead.
fn sort_unavailable(
  unavailable: List(UnavailableModule),
) -> List(UnavailableModule) {
  list.sort(unavailable, fn(a, b) { string.compare(a.module, b.module) })
}

// The inferred (generalized) scheme of each definition, in source order.
// glance accumulates a module's definitions newest-first, so the span sort is
// what puts them in the order the fields promise rather than its reverse.
//
// Best-effort inference leaves a skipped definition unbound, so a lookup is
// usually enough to omit it — but its name is only unbound if nothing *else*
// binds it. One that shadows a same-named unqualified import falls back to
// the import's entry, so it would be published under the import's scheme,
// which is the same mistake `render` avoids for a dropped definition. The
// names inference declined are therefore dropped by name.
fn collect_schemes(
  defs: List(Def),
  env: Env,
  declined: Set(String),
) -> List(#(String, Scheme)) {
  defs
  |> list.sort(fn(a, b) { compare_spans(def_span(a), def_span(b)) })
  |> list.filter_map(fn(def) {
    let name = def_name(def)
    case set.contains(declined, name) {
      True -> Error(Nil)
      False ->
        case lookup(env, name) {
          Ok(scheme) -> Ok(#(name, scheme_to_public(scheme)))
          Error(_) -> Error(Nil)
        }
    }
  })
}

// Publish an inference-side type as the public `Type`. The variant a value
// was narrowed to is inference state, not part of the type consumers see.
fn to_public(type_: ty.Type) -> Type {
  case type_ {
    ty.Named(module, name, args, _) ->
      Named(module, name, list.map(args, to_public))
    ty.Fn(args, ret) -> Fn(list.map(args, to_public), to_public(ret))
    ty.Var(id) -> Var(id)
    ty.Tuple(elements) -> Tuple(list.map(elements, to_public))
  }
}

fn scheme_to_public(scheme: ty.Scheme) -> Scheme {
  Scheme(scheme.vars, to_public(scheme.type_))
}

// The two errors that carry a type, published from their inference-side
// operands.
fn type_mismatch(left: ty.Type, right: ty.Type) -> Error {
  TypeMismatch(to_public(left), to_public(right))
}

fn recursive_type(id: Int, type_: ty.Type) -> Error {
  RecursiveType(id, to_public(type_))
}

fn sort_by_span(annotations: List(Annotation)) -> List(Annotation) {
  list.sort(annotations, fn(a, b) { compare_spans(a.span, b.span) })
}

// The order every published list carries: by where a span starts, then by
// where it ends. One comparator, so "sorted by span" cannot come to mean two
// things.
fn compare_spans(a: glance.Span, b: glance.Span) -> order.Order {
  int.compare(a.start, b.start)
  |> order.break_tie(int.compare(a.end, b.end))
}

// Small helpers
//
// Record an expression's type by span, recover an expression's span, and
// index into a list.

fn record(st: State, span: glance.Span, type_: ty.Type) -> State {
  State(..st, annotations: [#(span, type_), ..st.annotations])
}

// Record which member a reference resolved to.
fn reference(st: State, spans: Spans, resolved: Resolved) -> State {
  State(..st, references: [Reference(spans, resolved), ..st.references])
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

fn prelude_bit_array() -> ty.Type {
  ty.Named(prelude_module, "BitArray", [], None)
}

fn prelude_bool() -> ty.Type {
  ty.Named(prelude_module, "Bool", [], None)
}

fn prelude_float() -> ty.Type {
  ty.Named(prelude_module, "Float", [], None)
}

fn prelude_int() -> ty.Type {
  ty.Named(prelude_module, "Int", [], None)
}

fn prelude_list(element: ty.Type) -> ty.Type {
  ty.Named(prelude_module, "List", [element], None)
}

fn prelude_nil() -> ty.Type {
  ty.Named(prelude_module, "Nil", [], None)
}

fn prelude_result(ok: ty.Type, error: ty.Type) -> ty.Type {
  ty.Named(prelude_module, "Result", [ok, error], None)
}

fn prelude_string() -> ty.Type {
  ty.Named(prelude_module, "String", [], None)
}

fn prelude_utf_codepoint() -> ty.Type {
  ty.Named(prelude_module, "UtfCodepoint", [], None)
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
