# Contributing to girard

## Development

```sh
gleam test                  # run the test suite (the primary workflow for now)
gleam build --warnings-as-errors  # compile; any warning is an error
gleam run -m glinter        # lint src/ (config under [tools.glinter] in gleam.toml)
gleam format --check src test dev # check formatting
gleam run -m girard/sweep   # run girard over every gleam_stdlib module
bash scripts/gen-oracle.sh  # regenerate the differential-testing fixtures
```

The toolchain is pinned in `.tool-versions` (gleam 1.16.0, erlang 28.4.2).

The **package sweep** (`gleam run -m girard/sweep [package]`) runs girard over
every module of an installed dependency and buckets each as fully typed or by
error reason — a coverage report and a prioritised backlog of inference gaps.
girard fully types every module of gleam_stdlib and of every other package swept
so far (glance, glexer, gleam_json, tom, simplifile, filepath, gleam_time,
gleeunit, glinter, …).

## Differential testing against the real compiler

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

**What CI covers.** CI runs `gleam build --warnings-as-errors`, `gleam test`
(the unit suite plus the committed oracle fixtures), `gleam format --check`, and
`gleam run -m glinter`. The per-expression hex sweep is a manual safety net — it
needs the patched compiler and network access to hex — so it is run locally, not
in CI; `PACKAGES.md` is the record of that coverage.

## Architecture

The public API is two modules — `girard` (the driver) and `girard/types` (the
`Type` and `Error` vocabulary it reports). Everything else is implementation
detail under `girard/internal/` (not part of the documented/stable API).

| Module                      | Responsibility                                                                                                                                                                                          |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `girard`                    | **Public.** The driver: parse → resolve imports → register types → infer in SCC order → emit annotations                                                                                                 |
| `girard/types`              | **Public.** The `Type` model (`Named`/`Fn`/`Var`/`Tuple`) and the `Error` reported when a module can't be typed                                                                                          |
| `girard/internal/infer`     | Threaded `State` (substitution + fresh-var counter + span→type map), `Scheme`, unification, generalize/instantiate, inference of expressions/statements/patterns, hydration, module interfaces & imports |
| `girard/internal/prelude`   | Constructors for the built-in prelude types (`Int`, `List`, …)                                                                                                                                          |
| `girard/internal/scc`       | Tarjan strongly-connected components, for dependency-ordered inference                                                                                                                                  |
| `girard/internal/reference` | Collect the names a definition refers to, to build the call graph                                                                                                                                       |
| `girard/internal/printer`   | Rendering a `Type` back to Gleam syntax with `a, b, c …` variable naming                                                                                                                                |

**Mutability model.** The real compiler mutates type variables in place via
`Arc<RefCell<TypeVar>>`. Since Gleam-the-language is pure, a `Var(id)` instead
carries an integer id that is resolved through a substitution `Dict(Int, Type)`
threaded in the inference `State` (absent = unbound, present = bound). Like the
real compiler, generalization happens only at module-level definition
boundaries; local `let` bindings stay monomorphic.
