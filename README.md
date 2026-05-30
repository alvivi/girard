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

`girard.annotate(source)` returns a structured `Annotated` value
(`functions: List(#(name, signature))` and `expressions: List(Annotation)`);
`girard.format(source)` renders the report above.

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

## Roadmap

The goal is to annotate **any** well-typed Gleam module with the same types the
official compiler infers. We get there in milestones.

### ✅ Milestone 0 — Bootstrap
- Gleam project, `glance` dependency, pinned toolchain, test harness.

### ✅ Milestone 1 — Single-module HM core
- `Type` model + prelude constructors; unification with occurs check; let-style
  generalization/instantiation; the substitution-backed `State`.
- Inference for: literals, variables, `fn` definitions and calls, function
  captures (`f(1, _)`), `let` bindings, blocks, all binary operators
  (Int/Float/comparison/concat/boolean/pipe), `case` with patterns (int, float,
  string, variable, discard, tuple, list, assignment, string-prefix, variant),
  lists, tuples, tuple indexing, negation, `todo`/`panic`, `echo`.
- Local custom types (generic and enums) and their constructors; prelude value
  constructors (`True`, `False`, `Nil`, `Ok`, `Error`).
- Per-expression span→type output plus generalized function signatures.

### ✅ Milestone 2 — Correct module-level polymorphism
- Build a call graph between top-level definitions, compute strongly-connected
  components, and infer in dependency order, generalizing after each SCC
  (mirrors the compiler's `call_graph` + `dep_tree`).
- A generic helper is now generalized before its callers, so it can be used at
  several types within one module; mutually recursive functions are inferred
  together.

### ✅ Milestone 3 — Full single-module surface
- Module constants and `type` aliases (including parametric aliases), expanded
  during hydration; constants join functions in the dependency graph.
- Record field access (`record.field`) and record update (`Foo(..r, x: 1)`)
  via per-type accessors, including labels shared across all variants of a
  multi-variant type (with a consistent field type).
- **Labelled arguments**: field maps for functions and constructors, with
  argument and pattern reordering plus `..` spread in patterns.
- `use` expressions (desugaring to a callback-passing call).
- Bit array expressions and patterns with segment options.
- Type-variable sharing within a single signature (a written `fn(a) -> a` ties
  the occurrences of `a` together).

### ✅ Milestone 4 — Imports, prelude & standard library
- Resolve `import` statements (qualified, aliased, and unqualified value/type
  imports) through a `Resolver`; the default resolver reads `src/` and
  `build/packages/*/src` from disk, and `annotate_with` accepts a custom one.
- Imported modules are inferred to a public `ModuleInterface`; cyclic imports
  are broken with a loading set. Types carry their origin module so cross-module
  identity is correct, including qualified type annotations (`opt.Maybe`).
- Qualified calls (`list.map`), qualified constructor patterns (`order.Gt`),
  unqualified imported values/types/constructors, and `@external` functions.
- Verified end-to-end against the real `gleam_stdlib`: e.g. `list.map` infers
  `fn(List(Int)) -> List(Int)` and `result.map` preserves the polymorphic error
  type `fn(Result(Int, a)) -> Result(Int, a)`.

### ⏳ Milestone 5 — Fidelity & ergonomics
- Match the compiler's `inferred_variant` tracking and variant-aware inference.
- Match its type-variable naming and module-qualified printing exactly, so our
  output is byte-for-byte comparable to the compiler's (e.g. against language
  server hover types) for differential testing against `../gleam`.
- A CLI: `gleam run -- path/to/file.gleam` (and stdin) producing the report.
- Annotate patterns and other non-expression nodes; emit a machine-readable
  (e.g. JSON) form alongside the text report.

### 🎯 Final goal
Given any module the official compiler accepts, `girard` reproduces the inferred
type of every expression and definition, validated by a differential test
harness that compares our output against types extracted from the real Gleam
compiler at `../gleam`.
