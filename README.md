# girard

A **type annotator for Gleam, written in Gleam**. Given Gleam source, `girard`
runs Hindley-Milner type inference and reports the inferred type of every
expression (by source span) together with each top-level definition's
signature.

It deliberately replicates the inference performed by the real Gleam compiler
(the Rust `compiler-core/src/type_/` crate) rather than inventing its own type
system. It is **not** a full type checker: it does not aim for rich diagnostics.
Inference is total — `annotate` returns `Result(Annotated, Error)`, where
`Error` explains why a module could not be typed (type mismatch, unbound
variable, unknown field, …) rather than crashing.

Parsing is delegated to [`glance`](https://hexdocs.pm/glance/), a pure-Gleam
Gleam parser, so `girard` only implements the inference layer.

**Status:** girard reproduces the compiler's per-expression types, validated
differentially across the hex ecosystem (1378 packages swept; see
[`PACKAGES.md`](PACKAGES.md)). The remaining mismatches are upstream `glance`
parser gaps or oracle-export artifacts, not inference bugs.

## Example

```gleam
import girard

pub fn main() {
  girard.format("pub fn double(x) { x + x }")
}
```

```
double: fn(Int) -> Int
19-20: Int
19-24: Int
23-24: Int
```

`girard.annotate(source, girard.default_options())` returns a structured
`Annotated` value. Top-level
definitions carry a `Scheme` (`functions`/`constants: List(#(name, Scheme))` —
its `.type_` plus `.vars`, the ids of the quantified/generic `Var`s); each
expression carries a monomorphic `Type` (`expressions: List(Annotation)`). All
are structured [`girard/types`](src/girard/types.gleam) values — pattern-match on
`Named`/`Fn`/`Var`/`Tuple` to inspect or transform them — not strings. Render a
type with `girard.type_to_string(type_)`; `girard.format(source)` renders the
whole report above.

### Annotating a `glance` AST you already parsed

If you have already parsed the source with [`glance`](https://hexdocs.pm/glance/),
hand the `glance.Module` to `girard.annotate_module` instead of a source string,
so the source is parsed once, not twice. Each expression `Annotation` carries a
`glance.Span` — the same span glance puts on every AST node — so you join the
inferred types onto your own tree by span, and inspect them as structured values.

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
        Fn(_args, other) -> girard.type_to_string(other) // render to text
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
value. Build it from `girard.default_options()` (disk resolver, `Erlang`
target) with the `with_*` setters:

```gleam
girard.default_options()
|> girard.with_target(girard.JavaScript)        // type for the JS target
|> girard.with_resolver(fn(_) { Error(Nil) })   // resolve no imports
```

The resolver is `fn(module_path) -> Result(source, Nil)`; inject your own to
resolve imports from anywhere (an in-memory map, a build tree, …).

### Annotating a whole package (best-effort)

`girard.annotate_package(modules, options)` annotates many modules in one pass,
inferring a shared import only once across the whole run. `modules` is a list of
`#(module_path, glance.Module)`; the result maps each path to a `ModuleResult`
(`.annotated` plus `.skipped`).

Unlike `annotate`/`annotate_module`, it is **best-effort per definition**: a
top-level function or constant that does not type — along with anything that
depends on it — is listed in that module's `.skipped` (with the error that
declined it) rather than failing the module, and every other definition is
still annotated. A strict check is just `result.skipped == []`.

## Command line

```sh
gleam run -- path/to/file.gleam   # annotate a file
gleam run -- -                    # annotate stdin
cat file.gleam | gleam run        # annotate stdin
gleam run -- --help               # usage
```

Imports are resolved from `src/` and `build/packages` (so `import gleam/list`
works); ill-typed input prints a single `// error: …` line.

## Development

```sh
gleam test                  # run the test suite (the primary workflow for now)
gleam run -m glinter        # lint src/ (config under [tools.glinter] in gleam.toml)
gleam run -m girard/sweep   # run girard over every gleam_stdlib module
bash scripts/gen-oracle.sh  # regenerate the differential-testing fixtures
```

The **package sweep** (`gleam run -m girard/sweep [package]`) runs girard over
every module of an installed dependency and buckets each as fully typed or by
error reason — a coverage report and a prioritised backlog of inference gaps.
girard fully types every module of gleam_stdlib and of every other package swept so far (glance, glexer, gleam_json, tom, simplifile, filepath, gleam_time, gleeunit, glinter, ...).

Toolchain is pinned in `.tool-versions` (gleam 1.16.0, erlang 28.4.2).

### Differential testing against the real compiler

`test/oracle_test.gleam` checks girard's inferred top-level signatures against
the *actual* Gleam compiler. For each `test/oracle/<name>.gleam`, `gleam export
package-interface` produces a JSON of the compiler's inferred public interface
(committed as `<name>.interface.json`); the test decodes that JSON into girard's
own `Type`, renders it with girard's printer, and compares — modulo a canonical
type-variable renaming. Regenerate the fixtures with `scripts/gen-oracle.sh`.

For full breadth, `scripts/sweep.sh <package>` checks girard's **per-expression**
output against a patched compiler's `gleam export expression-types` over a
package's whole hex-resolved dependency closure; `scripts/batch_sweep.sh` runs it
across many packages. Results across the hex ecosystem are tracked in
[`PACKAGES.md`](PACKAGES.md).

**What CI covers.** CI runs only `gleam test` (the unit suite plus the committed
oracle fixtures) and `gleam format --check`. The per-expression hex sweep is a
manual safety net — it needs the patched compiler and network access to hex — so
it is run locally, not in CI; `PACKAGES.md` is the record of that coverage.

## Architecture

The public API is two modules — `girard` (the driver) and `girard/types` (the
`Type` and `Error` vocabulary it reports). Everything else is implementation
detail under `girard/internal/` (not part of the documented/stable API).

| Module                     | Responsibility                                                              |
| -------------------------- | --------------------------------------------------------------------------- |
| `girard`                   | **Public.** The driver: parse → resolve imports → register types → infer in SCC order → emit annotations |
| `girard/types`             | **Public.** The `Type` model (`Named`/`Fn`/`Var`/`Tuple`) and the `Error` reported when a module can't be typed |
| `girard/internal/infer`    | Threaded `State` (substitution + fresh-var counter + span→type map), `Scheme`, unification, generalize/instantiate, inference of expressions/statements/patterns, hydration, module interfaces & imports |
| `girard/internal/prelude`  | Constructors for the built-in prelude types (`Int`, `List`, …)              |
| `girard/internal/scc`      | Tarjan strongly-connected components, for dependency-ordered inference       |
| `girard/internal/reference`| Collect the names a definition refers to, to build the call graph            |
| `girard/internal/printer`  | Rendering a `Type` back to Gleam syntax with `a, b, c …` variable naming     |

**Mutability model.** The real compiler mutates type variables in place via
`Arc<RefCell<TypeVar>>`. Since Gleam-the-language is pure, a `Var(id)` instead
carries an integer id that is resolved through a substitution `Dict(Int, Type)`
threaded in the inference `State` (absent = unbound, present = bound). Like the
real compiler, generalization happens only at module-level definition
boundaries; local `let` bindings stay monomorphic.
