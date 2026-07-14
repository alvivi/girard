# AGENTS.md

This file provides guidance to coding agents when working with code in this
repository.

## Project Overview

**girard** is a type annotator for Gleam, written in Gleam. It runs
Hindley-Milner inference over a `glance` AST, mirroring the real Gleam compiler,
and reports the inferred type of every expression by source span together with
each top-level definition's signature.

The public API accepts source text, a pre-parsed `glance.Module`, or a whole
package. Imported modules are resolved through an injectable resolver. Package
annotation is best-effort per definition: definitions that cannot be typed and
their dependants are reported as skipped while independent definitions are
still annotated.

## Build and Test

```sh
gleam format --check src/ test/ dev/  # check formatting
gleam build --warnings-as-errors      # compile; no warnings allowed
gleam test                            # run the full test suite
gleam run -m glinter                  # lint src/
gleam run -m girard/sweep [package]   # sweep an installed dependency
bash scripts/gen-oracle.sh            # regenerate compiler oracle fixtures
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local dev loop, differential
testing workflow, and code/changelog/commit conventions.

Tests use **gleeunit**. `test/girard_test.gleam` covers inference and the public
API directly. `test/oracle_test.gleam` compares inferred public signatures with
committed JSON interfaces exported by the real Gleam compiler for sources under
`oracle/`.

## Architecture

The public API is a single module, `girard`. Everything under
`src/girard/internal/` is an implementation detail rather than documented/stable
API.

| File | Responsibility |
|---|---|
| `src/girard.gleam` | The whole public API and inference engine, in public-then-private (`// ===`) sections: source/AST/package entry points and CLI; the public `Type`, `Scheme`, and inference `Error` vocabulary; Hindley-Milner inference (state, substitutions, environments and schemes, unification, generalization/instantiation, expression/pattern/statement inference, type hydration, module interfaces); the built-in prelude type constructors; and the type printer |
| `src/girard/internal/scc.gleam` | Tarjan strongly-connected components for dependency-ordered inference |
| `src/girard/internal/reference.gleam` | Lexically scoped reference collection for the top-level definition graph |

Development-only modules under `dev/girard/` provide package sweeps,
per-expression compiler diffs, and benchmarks. Shell scripts under `scripts/`
stage packages and compiler output for those tools.

## Inference Pipeline

For a module, girard:

1. Parses source with `glance` unless it receives an existing AST.
2. Resolves imports and builds public interfaces for imported modules.
3. Registers custom types, constructors, aliases, and external definitions.
4. Collects top-level value references and orders definitions by strongly
   connected component.
5. Infers each component, unifies constraints, then generalizes at the
   top-level definition boundary.
6. Zonks substitutions through signatures and expression annotations before
   returning structured public types.

Package annotation caches imported interfaces and infers shared imports once.
It is deliberately best-effort: a failed definition and its dependants are
skipped without discarding unrelated inferred definitions.

## Type and State Model

The real compiler mutates type variables in place through
`Arc<RefCell<TypeVar>>`. Gleam-the-language is pure, so girard represents a type
variable as `Var(id)` and carries a `Dict(Int, Type)` substitution in the
threaded inference `State`. An absent id is unbound; a present id is bound.

Generalization happens only at module-level definition boundaries. Local `let`
bindings remain monomorphic, matching Gleam. Explicitly annotated type
variables are rigid within the definition being checked. Pending field and
tuple accesses are revisited after inference fixes their container types.

The public `Type` model has four variants:

- `Named(module, name, arguments)` for nominal and prelude types.
- `Fn(arguments, return)` for functions.
- `Var(id)` for type variables.
- `Tuple(elements)` for tuples.

## Import Resolution and Caching

`Options` holds the target, resolver, and optional reusable interface cache.
The default disk resolver searches project sources and installed packages under
`build/packages`. Callers can inject an in-memory or otherwise custom resolver.

An interface contains only the public types required by importing modules. The
reusable cache avoids parsing and inferring a shared import more than once and
can invalidate a single module when its source changes.

## Differential Testing

There are three levels of compiler comparison:

- `test/oracle_test.gleam` compares top-level public signatures against
  committed `gleam export package-interface` JSON fixtures. Regenerate them
  with `scripts/gen-oracle.sh`.
- `scripts/sweep.sh <package>` compares per-expression types with a patched
  compiler's `gleam export expression-types` over a package's resolved
  dependency closure.
- `scripts/batch_sweep.sh` repeats the per-expression sweep across many Hex
  packages. [PACKAGES.md](PACKAGES.md) records the resulting ecosystem
  coverage.

The broad per-expression sweep needs the patched compiler and network access,
so it is a manual safety net rather than a CI gate.

## Key Design Decisions

- **Mirror the compiler's inference, not its diagnostics.** girard reproduces
  accepted programs' inferred types but returns one structured error rather
  than acting as a full compiler diagnostic engine.
- **Use `glance` as the syntax boundary.** girard accepts and annotates glance
  ASTs; syntax that glance cannot parse is outside girard's reach.
- **Expose structured types.** Consumers pattern-match on `Type` and `Scheme`;
  rendering is a convenience rather than the primary representation.
- **Key annotations by source span.** A consumer with the same glance AST can
  join inferred types back onto its expressions without girard exposing an AST
  fork.
- **Keep package inference resilient.** One unsupported or ill-typed definition
  must not prevent useful results for independent definitions.
- **Keep internals separate from the API.** `girard` is the single supported
  module; the private inference machinery it contains, and the helpers under
  `src/girard/internal/`, may evolve without compatibility guarantees.

## Limitations

- Parsing and imported-module parsing are bounded by glance's syntax support.
- Inference is validated against code accepted by the real compiler; girard is
  not intended to recover from arbitrary non-compiling programs.
- Error reporting stops at the first inference problem for strict single-module
  annotation rather than collecting compiler-style diagnostics.
