# girard

[![Package Version](https://img.shields.io/hexpm/v/girard)](https://hex.pm/packages/girard)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/girard/)
[![CI](https://github.com/alvivi/girard/actions/workflows/test.yml/badge.svg)](https://github.com/alvivi/girard/actions/workflows/test.yml)

A Gleam source type annotator, in Gleam!

Runs type inference over Gleam source — replicating the real Gleam compiler — and
reports the inferred type of every expression (by source span) together with each
top-level definition's signature. Parsing is delegated to
[`glance`](https://hexdocs.pm/glance/).

The project is stable: its inferred types are validated differentially against
the real compiler across the hex ecosystem (see [`PACKAGES.md`](PACKAGES.md)).

## Usage

Add the package to your Gleam project:

```sh
gleam add girard
```

Then annotate some source:

```gleam
import girard
import gleam/io

const code = "pub fn double(x) { x + x }"

pub fn main() {
  io.println(girard.report(code))
}
```

This program outputs the following to the console:

```text
double: fn(Int) -> Int
19-20: Int
19-24: Int
23-24: Int
```

`report` is the quick, human-readable rendering. For programmatic use,
`girard.annotate(code, girard.default_options())` returns a structured
`AnnotatedModule`: each top-level definition's `Scheme` (in `functions` /
`constants`) and every expression's `Type` keyed by its source span (in
`expressions`). These are structured [`girard/types`](src/girard/types.gleam)
values — pattern-match on `Named`/`Fn`/`Var`/`Tuple`, or render one with
`girard.type_to_string`.

### Command line

```sh
gleam run -- path/to/file.gleam   # annotate a file
gleam run -- -                    # annotate stdin
cat file.gleam | gleam run        # annotate stdin
gleam run -- --help               # usage
```

Imports are resolved from `src/` and `build/packages` (so `import gleam/list`
works); ill-typed input prints a single `// error: …` line.

### Annotating a `glance` AST you already parsed

If you have already parsed the source with
[`glance`](https://hexdocs.pm/glance/), hand the `glance.Module` to
`girard.annotate_module` instead of a source string, so the source is parsed
once, not twice. Each expression `Annotation` carries a `glance.Span` — the same
span glance puts on every AST node — so you join the inferred types onto your own
tree by span, and inspect them as structured values.

```gleam
import girard
import girard/types.{type Type, Fn, Named}
import glance
import gleam/dict.{type Dict}
import gleam/list

/// Parse once with glance, then annotate that AST. Returns each expression's
/// inferred type keyed by its glance span, to join onto your own AST nodes.
pub fn types_by_span(source: String) -> Dict(#(Int, Int), Type) {
  let assert Ok(module) = glance.module(source)
  let assert Ok(annotated) =
    girard.annotate_module(module, girard.default_options())
  list.fold(annotated.expressions, dict.new(), fn(acc, a) {
    dict.insert(acc, #(a.span.start, a.span.end), a.type_)
  })
}

/// A definition's generalized signature is a structured `Scheme` (`.type_` is
/// the type, `.vars` are its quantified type-variable ids) you can pattern-match.
pub fn return_kind(source: String, name: String) -> String {
  let assert Ok(module) = glance.module(source)
  let assert Ok(annotated) =
    girard.annotate_module(module, girard.default_options())
  case list.key_find(annotated.functions, name) {
    Ok(scheme) ->
      case scheme.type_ {
        Fn(_args, Named("gleam", "Int", [])) -> "returns Int"
        Fn(_args, Named("gleam", "List", [_])) -> "returns a List"
        Fn(_args, other) -> girard.type_to_string(other)
        other -> girard.type_to_string(other)
      }
    Error(_) -> "no such function"
  }
}
```

(Imported modules are still parsed internally, via the resolver — only the
module you pass is taken pre-parsed.)

### Options: resolver and target

`annotate`, `annotate_module`, and `annotate_package` all take an `Options`
value. Build it from `girard.default_options()` (disk resolver, `Erlang` target)
and customize it with the `with_*` setters:

```gleam
girard.default_options()
|> girard.with_target(girard.JavaScript)        // type for the JS target
|> girard.with_resolver(fn(_) { Error(Nil) })   // resolve no imports
```

The resolver is `fn(module_path) -> Result(source, Nil)`; inject your own to
resolve imports from anywhere (an in-memory map, a build tree, …).

### Annotating a whole package

`girard.annotate_package(modules, options)` annotates many modules in one pass,
inferring a shared import only once across the whole run. `modules` is a list of
`#(module_path, glance.Module)`; the result maps each path to a `ModuleResult`
(`.annotated` plus `.skipped`).

Unlike `annotate`/`annotate_module`, it is **best-effort per definition**: a
top-level function or constant that does not type — along with anything that
depends on it — is listed in that module's `.skipped` (with the error that
declined it) rather than failing the module, and every other definition is still
annotated. A strict check is just `result.skipped == []`.

## Limitations

- **Parsing is bounded by `glance`.** girard does not parse Gleam itself, so
  source that [`glance`](https://hexdocs.pm/glance/) cannot parse, girard cannot
  annotate. Since imports are resolved by parsing, an unparseable module also
  makes its dependents fail with `unbound variable`. The gaps the sweep surfaces
  are all in bit-array syntax — chiefly arithmetic in a bit-array *pattern*
  segment size, e.g. `<<value:size(len - 1)>>` (the construction side parses, the
  pattern side does not). These are `glance` limitations, not girard inference
  errors.

- **Inferred types, not diagnostics.** girard reproduces the types the compiler
  infers, but it is not a full type checker: when a module cannot be typed it
  returns a single `Error` for the first problem found, not the compiler's full
  set of diagnostics.

- **Scoped to compilable code.** Inference is validated against programs the real
  compiler accepts; packages that do not compile with current tooling are out of
  scope, since the compiler cannot type them either.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development workflow,
differential testing against the real compiler, and an overview of the
architecture.

API documentation is available at <https://hexdocs.pm/girard>.
