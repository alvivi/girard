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
for sources under `fixtures/oracle/`. `test/golden_test.gleam` uses **birdie** to
snapshot `girard.report`'s rendered output for each fixture under `fixtures/golden/`;
review pending snapshots with `gleam run -m birdie`.
`test/differential_test.gleam` re-derives girard's answer for every case under
`fixtures/differential/` and asserts it still matches the committed manifest of
compiler answers there. The three corpora live under `fixtures/` at the repo
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
| `src/girard/internal/scc.gleam` | Strongly connected components as the compiler computes them: a port of petgraph 0.8.3's `TarjanScc` (Pearce's variant), which gives each group's members in the compiler's inference order |
| `src/girard/internal/reference.gleam` | The top-level definition graph, a port of Gleam 1.19.2's `call_graph.rs` over glance's AST: `dependency_edges` and `dependency_order`, and the `guard_constant` predicate inference shares |

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
4. Registers every function of the module at its annotation shape, then
   orders functions and constants exactly as the compiler's
   `into_dependency_order` does: the same graph walk, the same nodes in source
   order, and petgraph's SCC, so the groups, their members and their order
   are the compiler's, with no exception.
5. Infers each group as the compiler does: the members in the group's order,
   then the group generalized at the top-level definition boundary.
6. Zonks substitutions through signatures, expression annotations and
   resolutions before returning structured public types.

Package annotation caches imported interfaces and infers shared imports once.
It is deliberately best-effort: a failed definition and its dependants are
skipped without discarding unrelated inferred definitions. A skipped group's
functions leave scope, so a dependant fails in turn rather than typing against
the registration. A failed group of several members is first re-split along
the edges the typer really follows (`reference.strict_edges`: the compiler's
edges minus a bare receiver named like an import alias, with a string
prefix's `as` name binding, and with a `let assert` message walked before its
pattern binds), so an edge that only orders two definitions does not take an
independent one down with a failing one. Code the compiler accepts never
fails, so the split never changes a result it gives. One edge departs from
the rule that dependants are skipped: a definition that reads a later function
only in a `let assert` message whose pattern shadows it, an edge the
compiler's call graph misses, is checked against that function's registration
and published even if the function then fails. That matches the compiler,
which checks the reader first and blames only the function.

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
constructor or in a constant's guard literal. A lambda parameter takes its own
type, unified with the type it is called at, so a stamped seed loses its
variant there too, as in the compiler.

`infer_pattern` returns the pattern's own type — the compiler's
`Pattern::type_()` — so an `as` name binds at what the pattern matched rather
than at what it was matched against: a tuple pattern's type is rebuilt from its
elements', recursively, and stops at a constructor's arguments. Across a
clause's alternatives the two name classes follow different rules, as they do in
the compiler: only the first alternative may set a *subject* variable's variant
and a later one may only take it away by naming a different index, while a name
the patterns *bind* loses its variant where a later alternative binds it at a
named type of another variant; a binding at a type variable leaves it.

Generalization happens only at the top-level definition boundary, so a local
`let` binding stays monomorphic. A let-bound annotated lambda is still
polymorphic, as in the compiler, with no generalization step: its annotation's
generics leave scope with the `let` value, and each read of the binding copies
them. Pending field and tuple accesses are revisited after inference fixes
their container types.

**Groups of mutually recursive definitions** are inferred as the compiler
infers them. Every function of the module is registered before any group is
inferred (`analyse.rs:261-263`), at the shape its annotations give: its
signature's type variables rigid (`State.rigid`), each missing part a fresh
variable shared by every reader until its group is generalized, monomorphic.
So a function the compiler's graph does not order first, read in a
`let assert` message its own pattern shadows, is still found, at its
registration, exactly as in the compiler. Each body binds the registered
parameter types and is checked against the registered return, so a constraint
a sibling has already put on a parameter is visible while the body is walked.
The members are inferred in the order `dependency_order` lists them, with no
reordering, and each group is generalized over every variable still free, as
the compiler's `generalise` does, against the environment before any
registration. A constant is not registered: it enters scope only once
inferred, as in the compiler, so a function inferred before it still reads
whatever else binds the name.

**Annotation scopes.** Every annotation inside a function is hydrated through
one scope, as the compiler's per-function `Hydrator` hydrates it.
`State.scope` holds the type-variable names in scope and the generics the scope
owns. A function's scope starts with its signature's names and ids, a
constant's starts empty, and `scoped` saves and restores it around the
compiler's five boundaries: a `let` value, each `case` subject, a `case`
clause, a function body and a block. `hydrate_scoped` hydrates a body
annotation where the compiler does — a lambda's parameter and return
annotations in the enclosing scope before its body opens, a `let` annotation
after the value's scope has closed and after the pattern, a simple `use`
pattern's in the enclosing scope and a complex one's in the callback body: a
name in scope is that variable, and a new one is a generic (`State.rigid`) the
scope owns until its boundary closes. Generics never bind; only their copies
do.

Every value read instantiates, locals included, and `read_value` then copies
each generic its type reaches that the scope does not own into a fresh
variable, one per id per read: a variable, a callee name, a record-update
shorthand, a pattern size, and the reads the compiler generates for a pipe's
left value, a capture's hole and a complex `use` pattern's parameter. So a body
generic is rigid while in scope and copied at each read once out of it. Another
function's signature variables are never owned, generalized or not: a
generalized function's own reads replace its variables first, but one that
reached a later function's registration through an early read is still copied
there. That is how a member's generic that reaches a sibling through a shared,
unannotated part stays generic there, and why the compiler, and girard, publish
the looser signature it implies (for `fold_l(tree: Tree(u), acc) -> v` beside
an annotated sibling, `fn(Tree(a), b) -> c`).

**The constant context.** The compiler parses `name.member` in a constant
initializer, and in a guard subtree it parses as a constant
(`reference.guard_constant`), as module access, never as record access.
`Env.syntax` says which kind of syntax is being inferred: `infer_constant`
sets `ConstantSyntax`, the clause guard check sets `GuardSyntax`, and
`infer_expr` switches a guard to `ConstantSyntax` when it meets a constant
subtree. Under `ConstantSyntax` a bare-name `name.member` is module access only,
with `UnknownModule` or `NoSuchExport` on a miss. In a guard, `name.label` is
a record access, and nothing else, when the guard-variable lookup accepts
`name` — a local or a module constant — and module access otherwise
(`guard.rs:96-140`).

**Constant literals.** A bare variable naming a module constant in a guard is
the constant's stored literal (`type_/guard.rs:322-324`), not a copy, and so
is the spread of a constant record update that names one
(`constant.rs:186-221`): these two are the literal readers. A constant's scope
entry carries the literal beside the scheme — the type as inferred, variants
included — and the literal is live. The compiler shares a literal's cells
across the whole build; girard shares them within the defining module, and an
importer replays the bindings its import closure made. In the defining module a
reader reads the original literal, the type the constant's group inferred with
the ids generalization quantified, so a binding one reader makes is seen by
every later reader and by every expression holding the same id; the scheme does
not change, because nothing re-zonks a generalized scheme. Across modules a
literal variable keeps its identity, the module whose state created it and its
id there (`LiteralVar`). An exported literal is zonked with its module's final
state and names each variable by its identity, marking a generic, and an
importer maps each identity to one local id (`State.identities`), so a variable
two literals share in their exporter is shared here and a generic reached
through two imports is one rigid id. Each interface carries the bindings its
module's final state holds for other modules' literal variables, inherited
ones included (`literal_links`), and an importer replays them in source order
before inferring its own definitions; a replayed binding that does not unify
is dropped, so the first import wins. So a module sees exactly the bindings
its import closure made. The compiler infers a module with every binding made
by a module it scheduled earlier, which can be one outside that closure,
chosen by module name; girard reproduces neither those bindings nor the
conflicts between sibling imports the schedule decides, nor the expression
types the compiler's export reads after the whole build.

Wherever the type a lambda will be called at is already known, it is pushed
into the lambda's parameters before its body is walked, as the compiler's
`infer_fn_with_known_types` does: a lambda passed as a call argument, piped
into, called directly, given as a `use` callback, or passed beside a capture's
hole. A capture is the lambda the parser makes of it, so it is seeded the same
ways, and its body is an ordinary call. A `use` and a capture reach it the way
a call does — the callee first, then the complete argument list reordered
through its field map, then each slot checked against the parameter it was
placed against — so the callback and the hole are placed by the same reorder as
everything around them rather than assumed to come last.

Which names are in scope when an annotation is hydrated depends on what was
walked first, so girard follows the compiler's order there. A pipe types its
left side first; a call step infers its callee once, with no call context for a
literal, and reads the left value at the slot the reorder gives it. A lambda
or capture callee, `use` included, speculates the call's arguments first, the
`use` callback with no expected type, and keeps the names they create. That
pass is a speculative walk (`Env.recovering`): each site the compiler
recovers at recovers as it does, keeping every effect so far — a failed
sub-expression is a fresh variable, a failed unification keeps its partial
links, and a site with a fallback of its own (an invalid callee, a lambda
header, a return check, a field access, a pattern, a guard) takes it — and an
argument that still fails is a fresh variable, the next one continuing from
its state. Nothing recovers outside a speculative walk, so the real pass
stays strict. The orders that decide what a failure skips are the compiler's
in both modes: every operator but `|>` and a constant's `<>` infers both
operands before unifying either; a constant's `<>` infers and unifies its left
operand before its right, and `|>` types its left value before it walks its
step, which takes the value as an argument; an expression bit-array segment
walks its value, then its size, then unifies the value; a pattern segment types
its size before it binds, and a size reads only the names the pattern started
with plus its own bit array's earlier bindings, where in a later alternative a
binding of a name the first alternative bound reads as the first's; a later
`case` alternative starts with the first alternative's bindings and unifies
each of its own with the first's as it binds; an expression record update
checks the spread's variant before any field; and every record update copies
every field it does not name, by position. A `let` binds its pattern before it
checks its annotation. girard does not validate a bit-array segment's options
as the compiler's `type_options_for_value` does. The compiler rejects an
invalid option in its real pass, and its speculative walk stops at that
segment; girard walks on in speculation, and its strict pass may accept the
segment.

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
walk's. Expression types are not deduplicated at publication, so the walk
itself keeps them unique: `infer_expr` owns recording an ordinary expression's
span, and each path that walks an expression without it records that span
once, explicitly, where it walks it.

Absence has exactly three shapes. A definition in `ModuleResult.skipped`
contributes no references, because `best_effort_group` discards its component's
whole `State`, and no signature: `render` drops the declined names by name,
because a lookup only fails to find a skipped definition when nothing *else*
binds it, and an unqualified import it shadows does. A definition dropped for
the other build target is listed in
`AnnotatedModule.dropped` with its span, and is neither skipped nor walked:
`for_target` returns the functions and constants it filtered out beside the
filtered module, and `Inferred` carries the definitions inference walked, which
are the ones `render` publishes. And an access girard deferred as a
`PendingField` and read only once later inference fixed the record's type
publishes `Unresolved(RecordAccessUnknownType)` — girard reached the field type
but never a member at the access. That last is a tripwire as much as a result:
over code the compiler accepts, each one is a place where girard's inference
order lags the compiler's. A module girard could not load, listed in
`AnnotatedModule.unavailable`, is not a fourth shape: it removes nothing by
itself, but it explains skipped definitions whose lookups went through it and
types written against it that girard hydrated without seeing.

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
discard-aliased import has. It also carries the transitive `unavailable` set:
every module that could not be loaded, by path and reason, while it or any of
its own imports was inferred. An importer merges that set into its `Env`
whether the interface was inferred fresh or reused from a cache — a direct
failure overwrites, an inherited entry fills only an absent path, and a direct
success removes nothing — so a cached interface keeps the failures it was built
with until it and its cached importers are invalidated. It carries the
bindings of other modules' literal variables its module made or inherited
(`literal_links`, see "Constant literals"), so a change to a module's body can
change its interface with no signature changing, and a cached interface keeps
the bindings it was built with. The reusable cache avoids parsing and
inferring a shared import more than once and can invalidate a single module
when its source changes; after an edit, the module and every cached module
that imports it, directly or transitively, must be invalidated. A failure to
load is not cached.

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
  packages. [docs/PACKAGES.md](docs/PACKAGES.md) records the resulting ecosystem
  coverage.
- `test/differential_test.gleam` compares *which* member a name resolves to —
  record field or same-named module export — against a manifest of answers from
  a pinned gleam 1.18.0 under `fixtures/differential/`. Regenerate it with
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
