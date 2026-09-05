# AGENTS.md

This file provides guidance to coding agents when working with code in this
repository.

## Project Overview

**girard** is a type annotator for Gleam, written in Gleam. It runs
Hindley-Milner inference over a `glance` AST, mirroring the real Gleam compiler,
and reports the inferred type of every expression by source span together with
each top-level definition's signature.

The public API accepts source text, a pre-parsed `glance.Module`, or a whole
package. Every result also reports **which member each reference resolved to** —
a record field, a module function, constant or constructor under the module's
canonical path, a local variable, or unresolved — for every field access and
every bare name in call position. Imported modules are resolved through an
injectable resolver. Package annotation is best-effort per definition:
definitions that cannot be typed and their dependants are reported as skipped
while independent definitions are still annotated.

## Build and Test

```sh
gleam format --check src/ test/ dev/  # check formatting
gleam build --warnings-as-errors      # compile; no warnings allowed
gleam test                            # run the full test suite
gleam run -m birdie                   # review golden snapshot changes
gleam run -m girard/sweep [package]   # sweep an installed dependency
bash scripts/gen-oracle.sh            # regenerate compiler oracle fixtures
bash scripts/gen-differential.sh      # regenerate the resolution manifest
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local dev loop, differential
testing workflow, and code/changelog/commit conventions.

Tests use **gleeunit**. `test/girard_test.gleam` covers inference and the public
API directly. `test/oracle_test.gleam` compares inferred public signatures and
per-expression types with committed JSON exports from the real Gleam compiler
for sources under `oracle/`. `test/golden_test.gleam` uses **birdie** to
snapshot `girard.report`'s rendered output for each fixture under `golden/`;
review pending snapshots with `gleam run -m birdie`.
`test/differential_test.gleam` re-derives girard's answer for every case under
`differential/` and asserts it still matches the committed manifest of compiler
answers there. `oracle/`, `golden/` and `differential/` all sit at the repo
root, outside `src/` and `test/`, so `gleam` does not compile the fixtures as
modules.

## Architecture

The public API is a single module, `girard`. Everything under
`src/girard/internal/` is an implementation detail rather than documented/stable
API.

| File | Responsibility |
|---|---|
| `src/girard.gleam` | The whole public API and inference engine, in labelled comment sections, public API first: source/AST/package entry points and CLI; the public `Type`, `Scheme`, and inference `Error` vocabulary, and the `Resolution` / `ResolvedReference` / `Dropped` resolution and absence vocabulary; Hindley-Milner inference (state, substitutions, environments and schemes, unification, generalization/instantiation, expression/pattern/statement inference, type hydration, module interfaces); the built-in prelude type constructors; and the type printer |
| `src/girard/internal/ty.gleam` | The inference-side `Type` and `Scheme`: the public vocabulary plus the narrowed variant on `Named`, converted to the public types when a result or an error is published |
| `src/girard/internal/scc.gleam` | Tarjan strongly-connected components for dependency-ordered inference |
| `src/girard/internal/reference.gleam` | Lexically scoped reference collection for the top-level definition graph |

Development-only modules under `dev/girard/` provide package sweeps,
per-expression compiler diffs, benchmarks, and the resolution differential
driver (`girard/differential`, whose `manifest`, `source` and `runner`
submodules are shared with `test/differential_test.gleam`). Shell scripts under
`scripts/` stage packages and compiler output for those tools.

## Inference Pipeline

For a module, girard:

1. Parses source with `glance` unless it receives an existing AST.
2. Resolves imports and builds public interfaces for imported modules.
3. Registers custom types, constructors, aliases, and external definitions.
4. Collects top-level value references and orders definitions by strongly
   connected component.
5. Infers each component, unifies constraints, then generalizes at the
   top-level definition boundary.
6. Zonks substitutions through signatures, expression annotations and
   resolutions before returning structured public types.

Package annotation caches imported interfaces and infers shared imports once.
It is deliberately best-effort: a failed definition and its dependants are
skipped without discarding unrelated inferred definitions.

## Type and State Model

The real compiler mutates type variables in place through
`Arc<RefCell<TypeVar>>`. Gleam-the-language is pure, so girard represents a type
variable as `Var(id)` and carries a `Dict(Int, Type)` substitution in the
threaded inference `State`. An absent id is unbound; a present id is bound.
The substitution, the environment and module interfaces hold the inference-side
`Type` from `girard/internal/ty`; the public `Type` is produced from it
only where a result or an error is published.

The inference-side `Named` carries the variant a value is known to have been
built with, as the compiler's `Type::Named { inferred_variant }` does. A
constructor's return type is stamped with its index; a pattern that matches a
bare subject variable rebinds it, in that scope only, to a stamped copy of its
type; field access on a stamped type reads that variant's own accessors instead
of the shared ones. The stamp is erased when a type variable is bound to the
type and when a top-level definition is generalized, so it never survives a
generic function, a `case` result, or a module boundary except on a
constructor.

`infer_pattern` returns the pattern's own type — the compiler's
`Pattern::type_()` — so an `as` name binds at what the pattern matched rather
than at what it was matched against: a tuple pattern's type is rebuilt from its
elements', recursively, and stops at a constructor's arguments. Across a
clause's alternatives the two name classes follow different rules, as they do in
the compiler: only the first alternative may set a *subject* variable's variant
and a later one may only take it away by naming a different index, while a name
the patterns *bind* keeps its variant only where every alternative agrees.

Generalization normally happens at module-level definition boundaries, so
unannotated local `let` bindings remain monomorphic. The compiler-matching
exception is a local function whose annotations name type variables: those
variables are generalized explicitly. Type variables in a top-level signature
are rigid while the definition is checked. Pending field and tuple accesses are
revisited after inference fixes their container types.

Wherever the type a lambda will be called at is already known, it is pushed
into the lambda's parameters before its body is walked, as the compiler's
`infer_fn_with_known_types` does: a lambda passed as a call argument, piped
into, called directly, given as a `use` callback, or passed beside a capture's
hole. A `use` and a capture reach it the way a call does — the callee first,
then the complete argument list reordered through its field map, then each slot
checked against the parameter it was placed against — so the callback and the
hole are placed by the same reorder as everything around them rather than
assumed to come last.

**Resolution.** `Env.values` holds one `ValueConstructor` per name in scope,
as the compiler's `Environment.scope` does: the value's scheme and a variant
saying local, function, constant or constructor, the module-level ones carrying
the declaring module's canonical path, the declared name and, for a function or
a constructor, its field map. `ModuleInterface.values` holds the same entry for
each export, so an importer reads the identity a value was declared under
rather than a reconstruction of it. A local shadows a module-level name's
labels and identity by replacing its entry, which is all that binding a name
does. `infer_field_access` and `infer_callee` record a `Reference` into
`State.references` for every field access and every bare name in call position;
`publish_references` zonks each accessed record, converts it and keeps one
entry per span, which is what `AnnotatedModule.resolutions` promises: no walk
produces a duplicate today, but the guarantee is the API's rather than any one
walk's.

Absence has exactly three shapes. A definition in `ModuleResult.skipped`
contributes no references, because `best_effort_group` discards its component's
whole `State`. A definition dropped for the other build target is listed in
`AnnotatedModule.dropped` with its span, and is neither skipped nor walked;
`for_target` collects the two value categories it filters and `render` stores
them, and it renders the *filtered* module, so a target sibling is published
once and a dropped definition cannot borrow a same-named import's scheme. And
an access girard deferred as a `PendingField` and read
only once later inference fixed the record's type publishes
`Unresolved(RecordAccessUnknownType)` — girard reached the field type but never
a member at the access. That last is a tripwire as much as a result: over code
the compiler accepts, each one is a place where girard's inference order lags
the compiler's.

The public `Type` model has four variants:

- `Named(module, name, arguments)` for nominal and prelude types.
- `Fn(arguments, return)` for functions.
- `Var(id)` for type variables.
- `Tuple(elements)` for tuples.

## Import Resolution and Caching

`Options` holds the target and resolver. Reusable inference state is a separate
`Cache`, passed to `annotate_with_cache` and returned for the next call. The
default disk resolver searches project sources and installed packages under
`build/packages`; callers can inject an in-memory or otherwise custom resolver.

An interface contains the public values — one scope entry each, so a scheme,
its labels and its identity travel together — plus the types, aliases and
accessors required by importing modules, and the modules it resolved keyed two
ways: by the alias each is reachable under here, for qualified lookup, and by
real module name, which is how accessors are addressed and the only key a
discard-aliased import has. The reusable cache avoids parsing and
inferring a shared import more than once and can invalidate a single module when
its source changes.

## Differential Testing

There are three levels of compiler comparison:

- `test/oracle_test.gleam` compares top-level public signatures and
  per-expression types against committed `package-interface` and
  `expression-types` JSON fixtures. Regenerate them with
  `scripts/gen-oracle.sh`.
- `scripts/sweep.sh <package>` compares per-expression types with a patched
  compiler's `gleam export expression-types` over a package's resolved
  dependency closure.
- `scripts/batch_sweep.sh` repeats the per-expression sweep across many Hex
  packages. [PACKAGES.md](PACKAGES.md) records the resulting ecosystem
  coverage.
- `test/differential_test.gleam` compares *which* member a name resolves to —
  record field or same-named module export — against a manifest of answers from
  a pinned gleam 1.18.0 under `differential/`. Regenerate it with
  `scripts/gen-differential.sh`. Divergences are recorded rather than hidden:
  the manifest flags each one, names the change that must remove it, and the
  test pins their count so the total cannot quietly grow.

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
