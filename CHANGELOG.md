# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[1.1.0]: https://github.com/alvivi/girard/releases/tag/v1.1.0
[1.0.0]: https://github.com/alvivi/girard/releases/tag/v1.0.0
