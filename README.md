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

## Why?

The Gleam compiler infers a type for every expression, but it does not expose
that information as a library: there is no API a tool can call to ask "what is
the type of the expression at this span?". girard exists to answer exactly
that question.

That makes it a building block for language tooling written in Gleam:

- **Editor tooling and language servers** — code actions, hovers, and
  completions that need the type of the expression under the cursor. For
  example, a "wrap this element" refactor only makes sense when it knows the
  expression already has the element type it is wrapping.
- **Linters and analyzers** — rules that depend on types rather than syntax
  alone, and on which member a call resolves to, without reimplementing
  inference.
- **Code generation and refactoring tools** — codemods that must know a
  binding's signature to rewrite call sites safely.

Because girard consumes [`glance`](https://hexdocs.pm/glance/) ASTs and keys
its annotations by source span, a tool that already parses with glance can join
inferred types directly back onto its own AST — no compiler invocation, no AST
fork, no parsing twice.

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
`expressions`). These are structured [`girard`](src/girard.gleam) values —
pattern-match on `Named`/`Fn`/`Var`/`Tuple`, or render one with
`girard.type_to_string`. `girard.analyse` returns the same annotations plus
what every reference resolved to — see [Resolving
references](#resolving-references).

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
import girard.{type Type, Fn, Named}
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

### Resolving references

`girard.analyse` — and `analyse_module`, `analyse_with_cache` and
`analyse_package`, the twins of the four `annotate*` functions — reports
everything `annotate` does *and* which member each reference resolved to. This
is the question a linter or a rename asks: given `printer.println(…)`, is
`printer` a record in scope or the module the import bound?

```gleam
import gleam/io as printer

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn run(l: Logger) {
  case l {
    Loud(..) as printer -> printer.println("hi")   // RecordField(Logger, "println")
    Quiet(..) -> printer.println("quiet")          // ModuleFunction("gleam/io", "println")
  }
}
```

Each `ResolvedReference` carries the access's span — the same span the
`Annotation` for it carries — the label's, the receiver's, and a `Resolution`:

```gleam
import girard
import gleam/list

pub fn members(source: String) -> List(String) {
  let assert Ok(analysis) = girard.analyse(source, girard.default_options())
  list.map(analysis.resolutions, fn(reference) {
    case reference.resolution {
      girard.RecordField(receiver, label) ->
        girard.type_to_string(receiver) <> "." <> label
      girard.ModuleFunction(module, name) -> module <> "." <> name <> "()"
      girard.ModuleConstant(module, name) -> module <> "." <> name
      girard.Constructor(module, name) -> module <> "." <> name <> "{}"
      girard.LocalValue(name) -> name
      girard.Unresolved(_) -> "?"
    }
  })
}
```

A module is always named by its canonical path, never the alias it was imported
under, and a constructor by the name it is declared with — `Near`, even where it
was imported `as Close`.

The contract is exact: an entry is recorded for **every field access**, wherever
it sits, and for **every bare name in call position** — the callee of a call, a
capture or a `use`, and a bare pipe target. Nothing else, so a name read outside
call position (`let g = greet`), the constructor of a record update or of a
pattern, and a tuple index have no entry. A span with no entry was therefore
either not a recorded position or never walked: a definition `analyse_package`
reports as `skipped` contributes none, and neither does one dropped for the
other build target.

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

### Reusing imported interfaces

An editor or package-walking tool can carry a `Cache` between annotations so
shared imports are parsed and inferred once:

```gleam
let options = girard.default_options()
let cache = girard.new_cache()

let #(first_result, cache) =
  girard.annotate_with_cache(first_source, options, cache)
let #(second_result, cache) =
  girard.annotate_with_cache(second_source, options, cache)
```

A cache assumes the same resolver and target for its whole lifetime. When an
imported module changes, invalidate its module path before the next call:

```gleam
let cache = girard.invalidate(cache, "my_app/shared")
```

`invalidate` removes only that module. If its public interface changed, also
invalidate cached importers, or start again from `new_cache()`.

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

The resolver must be able to load package-local imports as well as external
dependencies. Supplying a module in `modules` gives girard its AST to annotate;
it does not implicitly add that source to the resolver. An in-memory package can
provide both views from one source table:

```gleam
import girard
import glance
import gleam/dict
import gleam/list

let sources =
  dict.from_list([
    #("my_app/a", "pub fn answer() { 42 }"),
    #(
      "my_app/b",
      "import my_app/a\npub fn answer() { a.answer() }",
    ),
  ])

let resolver = fn(path) { dict.get(sources, path) }
let modules =
  sources
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(path, source) = entry
    let assert Ok(module) = glance.module(source)
    #(path, module)
  })

let options =
  girard.default_options()
  |> girard.with_resolver(resolver)
let results = girard.annotate_package(modules, options)
```

## Limitations

- **Parsing is bounded by `glance`.** girard does not parse Gleam itself, so
  source that [`glance`](https://hexdocs.pm/glance/) cannot parse, girard cannot
  annotate. Since imports are resolved by parsing, an unparseable module also
  makes its dependents fail with `unbound variable`. Such failures are `glance`
  limitations, not girard inference errors.

- **Inferred types, not diagnostics.** girard reproduces the types the compiler
  infers, but it is not a full type checker: when a module cannot be typed it
  returns a single `Error` for the first problem found, not the compiler's full
  set of diagnostics.

- **Scoped to compilable code.** Inference is validated against programs the real
  compiler accepts; packages that do not compile with current tooling are out of
  scope, since the compiler cannot type them either.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development workflow,
differential testing, and code and commit conventions. See
[`AGENTS.md`](AGENTS.md) for the architecture, inference pipeline, state model,
and design decisions.

API documentation is available at <https://hexdocs.pm/girard>.
