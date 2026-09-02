# Contributing to girard

Thanks for helping out. This file is the dev loop and house conventions; for
*what the code is* (architecture, design decisions, and the inference model)
read [AGENTS.md](AGENTS.md).

The audience here is both human contributors and coding agents, so it is
command-first: run the commands, match the conventions, and a change is
mergeable.

## Setup

Versions are pinned in [`.tool-versions`](.tool-versions). With `asdf` or
`mise`:

```sh
asdf install                         # Erlang + Gleam at the pinned versions
gleam deps download
gleam build
gleam test
git config core.hooksPath .githooks # local commit-msg + branch-name hooks
pip install gitlint                  # optional: local commit-message linting
```

The hooks in [`.githooks/`](.githooks/) mirror the `Commit checks` CI: a
`commit-msg` hook runs gitlint (a no-op if gitlint is not installed) and a
`pre-push` hook rejects git-flow / conventional branch prefixes.
`core.hooksPath` is per-clone, so the `git config` line above is needed once
after cloning.

## Pre-flight checklist

CI runs three gates. Run them locally before pushing — green here means green
on CI:

```sh
gleam format --check src/ test/ dev/ # formatting (all Gleam source trees)
gleam build --warnings-as-errors     # no warnings allowed
gleam test                           # full suite, including oracle fixtures
```

A fourth gate, `gleam run -m glinter`, is temporarily disabled until glinter
publishes a glance-7-compatible release (see the note in `gleam.toml`).

`gleam format src/ test/ dev/` (no `--check`) fixes formatting in place.

## Tests

- Unit and integration tests use gleeunit and live in [`test/`](test/). Public
  test functions are suffixed `_test`.
- [`test/girard_test.gleam`](test/girard_test.gleam) exercises inference and the
  public API. Add or update a focused test with every behaviour change.
- [`test/oracle_test.gleam`](test/oracle_test.gleam) compares girard's inferred
  public signatures and per-expression types with committed exports from the
  real compiler.
- [`test/golden_test.gleam`](test/golden_test.gleam) snapshots girard's own
  rendered report for each [`golden/`](golden/) fixture — see below.

## Golden snapshots

[`test/golden_test.gleam`](test/golden_test.gleam) annotates every
[`golden/`](golden/) `*.gleam` fixture and captures `girard.report`'s output —
the source paired with its inferred annotation — as a [Birdie][birdie] snapshot.
Unlike the oracle suite (parity against the real compiler) these guard girard's
own human-readable output against unintended regressions and make deliberate
printer changes reviewable as a diff. Fixtures live at the repo root, beside
`oracle/`, so `gleam` does not compile them as project modules.

Add a fixture by dropping a `.gleam` file into `golden/`; it is picked up
automatically. A new or changed snapshot fails the test until reviewed:

```sh
gleam test              # writes pending `.new` snapshots
gleam run -m birdie     # review and accept/reject them interactively
```

Commit the resulting `.accepted` files; the `.new` files are git-ignored.

[birdie]: https://hexdocs.pm/birdie/

## Differential testing against the real compiler

For every [`oracle/`](oracle/) Gleam fixture, the compiler exports both its
public package interface and its per-expression types. The oracle test decodes
both JSON files into girard's `Type`, renders them with girard's printer, and
compares signatures and shared expression spans modulo canonical type-variable
renaming. [`oracle/README.md`](oracle/README.md) describes the fixture layout and
comparison rules. Regenerate the fixtures after adding or changing one:

```sh
bash scripts/gen-oracle.sh
gleam test
```

A third fixture corpus, [`differential/`](differential/), measures something the
oracle cannot: **which** `x.label` a name resolves to when a record field and a
same-named module export both offer one. Each fixture makes the decision visible
in a type — the module's export returns something different from the field — and
the manifest records both sides' answers with each disagreement flagged, owned,
and explained. The suite is green and the divergences are data:
[`differential/README.md`](differential/README.md) describes the layout, the
manifest and how to add a case. Regenerate it after adding or changing a
fixture; it needs the pinned gleam 1.18.0 but no patched compiler:

```sh
bash scripts/gen-differential.sh
gleam test
```

For full breadth, `scripts/sweep.sh <package>` checks girard's
**per-expression** output against a patched compiler's `gleam export
expression-types` over a package's whole Hex-resolved dependency closure;
`scripts/batch_sweep.sh` runs it across many packages. Results across the Hex
ecosystem are tracked in [PACKAGES.md](PACKAGES.md).

The package sweep below is a faster coverage report that runs girard without
the patched-compiler comparison:

```sh
gleam run -m girard/sweep             # sweep gleam_stdlib
gleam run -m girard/sweep gleam_json  # sweep another installed dependency
```

It buckets every module as fully typed or by error reason, giving a prioritised
backlog of inference gaps. The per-expression Hex sweep needs a patched compiler
and network access, so it is run locally rather than in CI; `PACKAGES.md` is the
record of that coverage.

## Conventions

- **Gleam idioms.** Follow Gleam's
  [conventions, patterns, and anti-patterns](https://gleam.run/documentation/conventions-patterns-and-anti-patterns/).
  The ones that come up most here:
  - Return `Result` for fallible functions; never `panic` to signal an error a
    caller could handle.
  - Replace `Bool` with custom types when it makes invalid states impossible.
  - Match all meaningful variants explicitly; avoid catch-all `_` patterns when
    they would hide a newly added variant.
  - Annotate every module function's arguments and return type.

  Keep new code reading like its neighbours.
- **Comments explain the code.** Do not reference internal planning documents
  or this guide from source comments, changelog entries, or public docs.
- **Doc-comment slashes.** `////` documents a module and `///` documents its
  public members. Use `//` for implementation notes and private entities.
- **No ASCII-art rules.** Do not decorate code or docs with divider or banner
  lines built from repeated characters — no `// ====`, `// ----`, `# ----`, or
  similar rows. A plain comment naming a section is fine; the row of dashes or
  equals signs is not.
- **Semantic sections.** Group a file into sections by topic, each introduced
  by a header — a `//` line naming the section, a blank `//` line, then a short
  description of what it covers and why:

  ```gleam
  // Section name
  //
  // One or two sentences on what this section covers and why.
  ```

  A file that is a single section needs no header; its `////` module doc is
  enough. Order the entities within a section for readability: lead with the
  public API (including `pub opaque` types), then the private implementation,
  and within each put constants before types before functions — but keep a type
  next to the functions that build and operate on it, put an entry point ahead
  of the helpers it calls, and fall back to alphabetical order only to break
  ties among unrelated peers. Test
  modules follow the same sectioning and module-doc rules, but keep their
  sections in narrative order (by feature or scenario) rather than reordering by
  visibility or kind.
- **Public surface.** Treat `src/girard.gleam` as the stable API. Everything
  under `src/girard/internal/` is implementation detail even where Gleam
  visibility is needed between modules.
- **No circular dependencies** between modules under `src/girard/internal/`.

## Changelog & commits

- Record every notable change in [CHANGELOG.md](CHANGELOG.md). The format is
  [Keep a Changelog](https://keepachangelog.com/) and the project follows
  [SemVer](https://semver.org/). Entries lead with a concise summary of the
  observable change, then explain it — match the existing style.
- Version bumps and `Release vX.Y.Z` commits are cut by the maintainer.
- Branch off `main` with a short, descriptive kebab-case name
  (`labelled-argument-inference`). This project does not use git-flow — no
  `feature/`, `fix/`, `release/`, or similar prefixes.

### Commit messages

Follow [the seven rules of a great commit message](https://chris.beams.io/posts/git-commit/#seven-rules):

1. Separate subject from body with a blank line.
2. Limit the subject line to 50 characters.
3. Capitalize the subject line.
4. Do not end the subject line with a period.
5. Use the imperative mood in the subject line ("Infer …", not "Inferred …").
6. Wrap the body at 72 characters.
7. Use the body to explain what and why, not how.

Do **not** use [Conventional Commits](https://www.conventionalcommits.org/) — no
`feat:` / `fix:` / `chore:` prefixes. Write commit messages and PR descriptions
as your own work, and do not add AI-attribution trailers (`Co-Authored-By:
Claude …`, "Generated with …", and the like).

A `Commit checks` workflow enforces the mechanical rules on every PR via
[gitlint](https://jorisroovers.github.io/gitlint/) (subject ≤ 72, capitalized,
no trailing period, body wrapped at 72; config in [`.gitlint`](.gitlint)) and
rejects git-flow / conventional branch prefixes. Imperative mood and the
what-and-why body are on you.
