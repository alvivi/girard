# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `AnnotatedModule.dropped`: the name and span of every top-level function or
  constant left out for the other build `Target`. A span with no annotation
  and no resolution is now one of three things a consumer can tell apart: not
  a recorded position, inside a definition `skipped` with its error, or inside
  one `dropped` for the target.

### Changed

- `annotate`, `annotate_module`, `annotate_with_cache` and `annotate_package`
  now return the resolutions 2.2.0 introduced: `AnnotatedModule` has a
  `resolutions` field. Their signatures are otherwise unchanged, so a consumer
  that only reads fields off the result is unaffected; constructing or fully
  destructuring `AnnotatedModule` must name the two new fields, `resolutions`
  and the `dropped` above.
- `Resolution`'s `RecordField` names the accessed value's type `receiver`
  rather than `record`. Positional matches (`RecordField(type_, label)`) are
  unaffected; only a labelled access or update needs the new name. The variant
  holds a type, not the accessed expression the compiler's own `record` field
  holds, and `record` otherwise had to name both the whole access and one half
  of it.

### Removed

- `analyse`, `analyse_module`, `analyse_with_cache` and `analyse_package`, and
  the `Analysis` type they returned. There is no deprecation period and no
  alias: 2.2.0 released the resolution API additively so 2.x consumers could
  stay on 2.x, and 3.0.0 is where it becomes the only API. Every `analyse*`
  call becomes the `annotate*` of the same name, reading one record instead of
  two:

  ```gleam
  // Before
  let assert Ok(analysis) = girard.analyse(source, options)
  analysis.annotated.expressions
  analysis.resolutions

  // After
  let assert Ok(annotated) = girard.annotate(source, options)
  annotated.expressions
  annotated.resolutions
  ```

### Fixed

- A `@target` sibling pair is listed once in `functions` / `constants`, under
  the active target's signature; the inactive one was listed too, with the
  active one's signature. A definition dropped for the target no longer
  appears under a same-named unqualified import's signature either.
- A definition in a `ModuleResult`'s `skipped` no longer appears in
  `annotated.functions` under the signature of the unqualified import it
  shadows. `import imported.{g}` with a local `pub fn g` that does not type
  listed `g` in both `skipped` and `functions`, holding `imported`'s scheme,
  against `ModuleResult`'s own promise that a skipped definition is absent from
  `annotated`. The names inference declined are dropped by name now, rather
  than by a lookup that only fails when nothing else binds the name.
- `AnnotatedModule.functions` and `constants` are in the source order their
  fields have always documented. `glance` accumulates a module's definitions
  newest-first and both lists were published as they came, so they were
  reversed; they are sorted by span like every other published list now. A
  consumer that reads a definition by name is unaffected; one that walked
  either list in order was walking the module backwards. `girard.report`
  renders definitions in the same new order.
- A skipped definition no longer breaks calls to the import it shadows. In
  best-effort mode the skipped definition's argument labels outlived it, so a
  later call using the import's own labels was wrongly rejected with
  `UnknownLabel` or `AmbiguousCall`. Those calls now type.
- A resolution now names the module a call was typed against. Where `a`'s own
  `g` was skipped and shadowed an `import imported.{g}`, an importer calling
  `a.g` was told it had called `a.g` rather than `imported.g`.
- A lambda that is piped into, called directly, given as a `use` callback or
  passed to a capture now sees its parameter types before its body is
  inferred, as the compiler does. A field access on such a parameter resolves
  at the access instead of being deferred and published as `Unresolved`. With
  a module of the parameter's name in scope it now reads the field where it
  previously took the module's export, which changes the inferred type when
  the two differ.
- A `use`'s callback and a capture's hole are placed by the same reorder as
  the arguments around them, so a labelled argument taking a later declared
  slot no longer leaves either in the wrong one, and an argument written out
  of declared order is checked against the parameter it was placed against.
- A lambda checked against a known function type shares the type-variable
  names its own annotations write, as one inferred without a known type
  already did: in `fn(m: Msg(a)) -> Next(Msg(a))` the two `a`s are one type
  wherever the lambda is checked.

## [2.2.0] - 2026-09-04

### Added

- `analyse`, `analyse_module`, `analyse_with_cache` and `analyse_package`:
  the `annotate*` results plus, for every field access and every bare name in
  call position, what it resolved to. Each `ResolvedReference` gives the spans
  of the access, its label and the accessed value, and a `Resolution`: a
  record field and the record's type, a module function, constant or
  constructor under the module's canonical path (not the import alias), a local
  variable, or `Unresolved`. The variants are named after the compiler's
  `ValueConstructorVariant`. `annotate*` keep their signatures — they are these
  functions with the resolutions dropped.

### Fixed

- A piped call's callee is no longer annotated twice. `left |> f(args)` infers
  `f` once to measure its arity and once as part of the call; the arity probe
  now runs on a state that is thrown away, so `expressions` has a single entry
  for the callee's span, holding the type the call gave it.
- Variant narrowing now follows the value, not the name it was bound under.
  After `let assert Loud(..) = l`, `let io = l` still reads `io.println` as the
  field, and so do a tuple pattern, a closure's return, a record update, a
  `use` value and a generic constant. It is dropped where the compiler drops
  it: through a type variable, out of a `case` result, into a bare constructor,
  and at a top-level definition's generalized type.
- Calling a field on a value a pattern has narrowed — `Loud(..) as io ->
  io.println("hi")` — now calls the field even when a module named `io` is
  in scope. Previously the module function won, unlike the compiler.
  Reading and calling a field now resolve the same way.
- `Loud(..) as io | Quiet(..) as io` no longer narrows `io` to either
  variant, matching the compiler. A `case` subject follows the compiler's
  other rule: only the first alternative may narrow it, so
  `case io { Loud(..) | _ -> ... }` keeps the narrowing and `_ | Loud(..)`
  does not.
- A record type imported under a discarded alias (`import kinds.{Box} as _k`)
  keeps its field accessors, in the importing module and downstream.
- `Close(..) as io | kinds.Near(..) as io`, with `Near` imported as `Close`,
  keeps its narrowing: the two spellings are recognised as one constructor.
- A field is only accessible on the whole type when every variant declares it
  at the same position with the same type. `y` in `A(x: Int, y: String)` /
  `B(y: String)` is no longer an accessor, matching the compiler.
- Passing a labelled argument to a function stored in a record field is now an
  error, as in the compiler. Previously the labels of an unrelated function
  with the same name were used to reorder the arguments.
- A local binding now shadows a callable's labels as well as its type. After
  `let greet = fn(who: String) -> String { who }`, calling `greet(name: "hi")`
  is an error rather than being reordered by the top-level `greet`'s labels,
  as in the compiler. A parameter and a shadowed unqualified import behave the
  same way.
- A top-level definition replaces the labels of the unqualified import it
  shadows. `import imported.{greet}` followed by an unlabelled
  `pub fn greet(who: String)` no longer lets `greet(name: "hi")` borrow the
  import's `name:`; a constant and a record constructor clear the shadowed
  name's labels the same way.
- Expressions inside a `panic as` / `todo as` message are now annotated.
  Previously nothing in the message got a type — `name` in
  `panic as { "no such user: " <> name }` had no annotation at all. The message
  is now inferred like any other expression and checked against `String`, so an
  ill-typed message is reported instead of ignored. `panic` and `todo` still
  unify with anything, and the message-less forms are unchanged.

## [2.1.1] - 2026-08-24

### Fixed

- The shipped `.graded` spec is updated to the current spec format.

## [2.1.0] - 2026-08-05

### Changed

- Building a disk resolver or default options no longer touches the filesystem;
  I/O happens on first resolution. `disk_resolver()` and `default_options()` are
  now pure: they scan `build/packages` and read module sources only when the
  resolver is actually invoked during annotation, rather than eagerly at
  construction. Behaviour is otherwise unchanged, including that a missing
  `build/packages` or an unreadable source surfaces as `Error(Nil)` — now at
  resolution time instead of construction.

## [2.0.0] - 2026-07-16

### Changed

- Consolidated the public API into a single `girard` module. The `Type`,
  `Scheme`, and `Error` types and their constructors, previously exposed from
  `girard/types`, now live in `girard`, and the `girard/types` module has been
  removed. This is a breaking change to the import path; update imports:

  ```gleam
  // Before
  import girard
  import girard/types.{type Type, Fn, Named}

  // After
  import girard.{type Type, Fn, Named}
  ```

- Updated `glance` to 7.0.0, which parses arithmetic in bit-array pattern
  segment sizes (e.g. `<<_:size(n - 1)-bytes, tail:bytes>>`). Modules using
  that form now annotate instead of failing to parse, values referenced in
  segment sizes are typed as `Int`, and a top-level constant used only as a
  segment size now counts as a dependency of the definition using it. Because
  the public API accepts and annotates `glance` ASTs, this is a breaking
  dependency bump: callers passing pre-parsed modules must move to glance 7.

## [1.1.1] - 2026-06-20

### Changed

- Updated `glance` to 6.1.0, which parses string-prefix patterns that discard
  the rest (e.g. `"a" <> _`). Modules using that form now annotate instead of
  failing to parse.

## [1.1.0] - 2026-06-07

### Added

- A reusable interface cache. Annotate a module or walk a package while reusing
  the work done for shared imports across calls, then drop a single module's
  cached interface when its source changes.

### Changed

- Faster annotation, most noticeably when typing many modules or re-annotating
  the same module as it changes.
- Now requires Gleam 1.15.0 or newer.

## [1.0.0] - 2026-06-02

### Added

- Annotate a single Gleam module or a whole package, reporting the inferred type
  of every expression — keyed by its source span — and the signature of every
  top-level function and constant.
- Accepts either source text or a `glance` AST you have already parsed.
- Choose the build target (Erlang or JavaScript) and supply your own resolver
  for imported modules, with a default resolver that reads them from disk.
- Best-effort package annotation: definitions that cannot be typed are reported
  individually, and every other definition in the module is still annotated.
- Render any inferred type to Gleam syntax, produce a human-readable report, and
  describe why a module could not be typed.
- A command-line interface that annotates a file or standard input.

[2.2.0]: https://github.com/alvivi/girard/releases/tag/v2.2.0
[2.1.1]: https://github.com/alvivi/girard/releases/tag/v2.1.1
[2.1.0]: https://github.com/alvivi/girard/releases/tag/v2.1.0
[2.0.0]: https://github.com/alvivi/girard/releases/tag/v2.0.0
[1.1.1]: https://github.com/alvivi/girard/releases/tag/v1.1.1
[1.1.0]: https://github.com/alvivi/girard/releases/tag/v1.1.0
[1.0.0]: https://github.com/alvivi/girard/releases/tag/v1.0.0
