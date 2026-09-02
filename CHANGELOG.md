# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Calling a field on a value a pattern has narrowed — `Loud(..) as io ->
  io.println("hi")` — now calls the field even when a module named `io` is
  in scope. Previously the module function won, unlike the compiler.
  Reading and calling a field now resolve the same way.
- `Loud(..) as io | Quiet(..) as io` no longer narrows `io` to either
  variant, matching the compiler.
- `Close(..) as io | kinds.Near(..) as io`, with `Near` imported as `Close`,
  keeps its narrowing: the two spellings are recognised as one constructor.
- A field is only accessible on the whole type when every variant declares it
  at the same position with the same type. `y` in `A(x: Int, y: String)` /
  `B(y: String)` is no longer an accessor, matching the compiler.
- Passing a labelled argument to a function stored in a record field is now an
  error, as in the compiler. Previously the labels of an unrelated function
  with the same name were used to reorder the arguments.
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

[2.1.1]: https://github.com/alvivi/girard/releases/tag/v2.1.1
[2.1.0]: https://github.com/alvivi/girard/releases/tag/v2.1.0
[2.0.0]: https://github.com/alvivi/girard/releases/tag/v2.0.0
[1.1.1]: https://github.com/alvivi/girard/releases/tag/v1.1.1
[1.1.0]: https://github.com/alvivi/girard/releases/tag/v1.1.0
[1.0.0]: https://github.com/alvivi/girard/releases/tag/v1.0.0
