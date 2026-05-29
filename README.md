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

## Development

```sh
gleam test               # run the test suite (the primary workflow for now)
gleam run -m glinter     # lint src/ (config under [tools.glinter] in gleam.toml)
bash scripts/gen-oracle.sh  # regenerate the differential-testing fixtures
```

Toolchain is pinned in `.tool-versions` (gleam 1.16.0, erlang 28.4.2).

### Differential testing against the real compiler

`test/oracle_test.gleam` checks girard's inferred top-level signatures against
the *actual* Gleam compiler. For each `test/oracle/<name>.gleam`, `gleam export
package-interface` produces a JSON of the compiler's inferred public interface
(committed as `<name>.interface.json`); the test decodes that JSON into girard's
own `Type`, renders it with girard's printer, and compares — modulo a canonical
type-variable renaming. Regenerate the fixtures with `scripts/gen-oracle.sh`.
This is the seed of the M5 fidelity harness (signature level today;
per-expression once the compiler is patched to emit span→type).

## Architecture

| Module                  | Responsibility                                                              |
| ----------------------- | --------------------------------------------------------------------------- |
| `girard/types`          | The internal `Type` model (`Named`/`Fn`/`Var`/`Tuple`), prelude constructors, `Scheme` |
| `girard/infer`          | Threaded `State` (substitution + fresh-var counter + span→type map), unification, generalize/instantiate, inference of expressions/statements/patterns, hydration, module interfaces & imports |
| `girard/scc`            | Tarjan strongly-connected components, for dependency-ordered inference       |
| `girard/references`     | Collect the names a definition refers to, to build the call graph            |
| `girard/printer`        | Rendering a `Type` back to Gleam syntax with `a, b, c …` variable naming     |
| `girard`                | The driver: parse → resolve imports → register types → infer in SCC order → emit annotations |

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
  via per-type accessors (single-variant records for now; shared fields across
  variants remain a refinement).
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
