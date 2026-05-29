# girard

A **type annotator for Gleam, written in Gleam**. Given Gleam source, `girard`
runs Hindley-Milner type inference and reports the inferred type of every
expression (by source span) together with each top-level definition's
signature.

It deliberately replicates the inference performed by the real Gleam compiler
(the Rust `compiler-core/src/type_/` crate) rather than inventing its own type
system. It is **not** a full type checker: it does not produce diagnostics. If
the input is invalid or uses an unsupported construct, it simply `panic`s.

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
gleam test   # run the test suite (the primary workflow for now)
```

Toolchain is pinned in `.tool-versions` (gleam 1.16.0, erlang 28.4.2).

## Architecture

| Module                  | Responsibility                                                              |
| ----------------------- | --------------------------------------------------------------------------- |
| `girard/types`          | The internal `Type` model (`Named`/`Fn`/`Var`/`Tuple`), prelude constructors, `Scheme` |
| `girard/infer`          | Threaded `State` (substitution + fresh-var counter + span→type map), unification, generalize/instantiate, inference of expressions/statements/patterns, annotation hydration |
| `girard/printer`        | Rendering a `Type` back to Gleam syntax with `a, b, c …` variable naming     |
| `girard`                | The driver: parse → register types → infer → generalize → emit annotations   |

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

### ⏳ Milestone 2 — Correct module-level polymorphism
- Build a call graph between top-level definitions, compute strongly-connected
  components, and infer in dependency order, generalizing after each SCC
  (mirrors the compiler's `call_graph` + `dep_tree`).
- Without this, a generic helper used at two different types within one module
  is wrongly monomorphized. This is the current top priority.

### ⏳ Milestone 3 — Full single-module surface
- Module constants and `type` aliases (with hydration into the environment).
- Record field access (`record.field`) and record update (`Foo(..r, x: 1)`),
  including accessor maps for shared labels across variants.
- **Labelled arguments**: field maps for functions and constructors, with
  argument reordering — currently calls are treated positionally.
- `use` expressions (desugaring to a callback-passing call).
- Bit array expressions and patterns with segment options.
- Guards in `case` clauses with their full operator set.
- Annotated-variable sharing within a single signature (so `fn(a) -> a` written
  by the user is honoured, not just inferred).

### ⏳ Milestone 4 — Imports, prelude & standard library
- Resolve `import` statements (qualified, aliased, and unqualified imports).
- Read module interfaces so external functions/types/constructors get correct
  types — starting with `gleam_stdlib`, by loading published package interfaces
  or by inferring dependency modules ourselves.
- Qualified calls (`list.map`), unqualified imported constructors, module-level
  type references across files.

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
