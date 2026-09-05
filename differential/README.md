# Resolution differential fixtures

The corpus that measures where girard and the real compiler disagree about
**which `x.label` a name resolves to** — a record field, or a same-named
module's export.

The compiler has no API that reports a resolution decision, so each fixture
makes the decision visible *in a type*: the shadow module's export has a
**different return type** from the field, and the contested access sits in
return position of an **unannotated** function. The decision is then the
function's inferred return type — reported by the compiler in
`package-interface`, and by girard in `annotate(...).functions`. That type
reading is the corpus's mechanism, because it is the only question both sides
answer.

girard *does* report the decision directly, in `annotate(...).resolutions`, and
the suite asserts it beside the type: the resolution at each contested access
must be the branch girard's own return type decodes to, and a module answer must
name the module's canonical path. That last is the one thing no type answer can
show, since an alias and the path it stands for read identically in a type.

Both readings must type-check wherever the row contests a genuine choice.
Argument types stay identical and only the return differs; otherwise the
compiler's answer is forced by unification rather than by resolution. Every
non-target `case` arm is bottom (`panic`), because every arm of a `case` shares
one type and an arm committing to either return decides the fixture by
unification instead.

## Layout

```
.tool-versions       gleam 1.18.0 — the pinned compiler the evidence comes from
gleam.toml           zero-dependency project template (almost every case)
pinned/              template + committed lock for the one case using stdlib
support/             modules staged alongside a case, never compiled as fixtures
  differential/io.gleam       the shadow module
  differential/shadow.gleam   a second shadow, for the aliased-import case
  differential/kinds.gleam    a record type, for the cross-module and renamed-import cases
  differential/labelled.gleam a shadow with a labelled export, for the labelled probe
  differential/box.gleam      a generic wrapper, for the erase-through-a-type-variable case
cases/<case>/base.gleam           the fixture
cases/<case>/forced_field.gleam   companion: no colliding module in scope
cases/<case>/forced_module.gleam  companion: the receiver binding renamed away
expected.json        the manifest
```

`differential/` sits at the repo root beside `oracle/` and `golden/`, outside
`src/` and `test/`, so `gleam` does not compile the fixtures as modules.

## The shadow module

`import differential/io` binds the name `io`, which collides with any receiver a
fixture calls `io`. It is **local rather than `gleam/io`** for two reasons: the
mechanism needs to choose the export's type, where `gleam/io.println` has the
same type as the field; and a local module has no version, so the compiler and
girard cannot resolve different ones.

Every label a fixture puts in contest needs an export there. Miss one and the
compiler reports an unknown field instead of choosing a branch, and the row
records an error rather than a reading.

## A case

A case is a fixture plus up to two **companions**, each a committed source file
and each compiled in its **own** fresh project — because some companions are
required *not* to compile, and `package-interface` is package-wide, so a project
holding a base and its expected-failure companion would export nothing at all.

| Companion | How it differs from the base | Exists when |
|---|---|---|
| `forced_field.gleam` | the target import's line is removed, so the name cannot denote a module | a colliding module is in scope |
| `forced_module.gleam` | every occurrence of the receiver's name is renamed except inside the imports and except the contested access, so the name denotes only the module | a local binding shadows the module name |

A `kind: "probe"` row has **neither**, whatever its source looks like.

The companions are the counterfactual check: they leave exactly one reading
available, and what each must do is set by that side's availability rather than
fixed at "must compile". Forcing a branch the row records as absent — an
`unavailable`, `undeclared` or `unknown_receiver` field, or an `undeclared`
module — **must fail**, at a position inside the contested access. That failing
half is the stronger check: it proves the availability metadata empirically
instead of trusting a reading of the declarations.

Companions are generated on first run and then **committed**. The committed
bytes are what every later run compiles, and `test/differential_test.gleam`
rebuilds each one from the base and compares byte for byte.

## Reading the manifest

`expected.json` holds one row per case. Every field is always present; absence
is JSON `null`, recursively — a missing key is a malformed manifest at any
depth.

- **`kind`** is `resolution` or `probe`, and it selects both the `expect`
  vocabulary and what a divergence means. A resolution row asks *which* of two
  readings won (`expect: "field"` / `"module"`); a probe asks only whether the
  program was accepted (`"ok"` / `"error"`).
- **`expect`** is hand-authored. It is what the compiler is expected to answer,
  and it does not change as girard's resolution is corrected.
- **`compiler` and `girard` are machine-written** by `scripts/gen-differential.sh`
  and are never edited by hand. Both are outcome objects with the same five keys
  — `status`, `return`, `diagnostic`, `at`, `error_variant`. A compiler-side
  error carries `diagnostic` (the normalized title of the first `error:` line)
  and `at`; a girard error carries `error_variant`, the constructor tag alone,
  because girard's diagnostics are its own vocabulary and its `Error` carries no
  spans.
- **`divergent`** is derived, not asserted: the test recomputes it from the
  committed compiler result and a live girard run, and fails if the stored flag
  disagrees. The compiler and girard disagree when their statuses differ, when
  both are `ok` and decode to different branches, or when either decodes to a
  third answer nobody predicted.
- **`why`** is a hand-written one-liner naming the mechanism and, for a
  divergence, the change that must remove it. It is what makes the manifest a
  document rather than a blob.
- **`inputs_hash` and `evidence_hash`** answer two different questions: what was
  compiled, and what came out. CI re-runs only girard, so editing a fixture would
  otherwise invalidate the committed compiler evidence while every other
  assertion kept passing. Both are recomputed by the test — `inputs_hash` from
  the working tree, `evidence_hash` from the row's own outcome objects — and the
  aggregate over all rows is pinned as a literal in the test file, so tampering
  has to touch two files in one diff.

**The suite is green and there are no divergences.** girard and the pinned
compiler answer every row here the same way. That is a floor rather than a
finish: a new divergence means girard has drifted, and it has to be recorded
here — with the mechanism and the change that removes it in `why` — before the
suite can go green again, which is a reviewable diff and a raised count
literal in `test/differential_test.gleam`. The literal is what stops the
ratchet being walked around: it may fall when a divergence is fixed, and
nothing else may move it.

The rows that used to diverge shared one root, and it is worth stating because
it is what a regression would look like: a narrowing was tracked by the *name*
it was bound under and re-derived from the shape of the expression it came
from, so it was lost wherever the value was re-bound or arrived by a shape
nothing matched, and wrongly kept where a sibling pattern rebound the name. It
now lives on the value's own type, as it does in the compiler.

## Regenerating

The driver needs the pinned **gleam 1.18.0** — the repo root is on 1.18.1 and is
deliberately left alone — but no patched compiler: `package-interface` is a stock
export.

```sh
bash scripts/gen-differential.sh
gleam test
```

Override the binary with `GLEAM=`. The driver prints the divergence count and
the evidence aggregate; both are literals in `test/differential_test.gleam` and
must be updated with it. `gleam run -m girard/differential aggregate` reprints
them from the committed manifest without recompiling anything.

Because the driver needs a pinned toolchain it is manual, like
`scripts/gen-oracle.sh`, rather than a CI gate. `inputs_hash` is what keeps that
honest: change a fixture without rerunning the driver and the test fails,
pointing at the driver rather than at a diff.

## Adding a case

1. Write `cases/<case>/base.gleam`: one function under test per module,
   unannotated return, every other `case` arm bottom.
2. Add its row to the case table in `dev/girard/differential.gleam`, which is the
   hand-authored half of the manifest — what the fixture contests, which reading
   the compiler should take, and why.
3. Run `bash scripts/gen-differential.sh`. It writes the companions, compiles
   everything, and rewrites `expected.json`.
4. Update the two literals in `test/differential_test.gleam` if the divergence
   count or the aggregate moved, and run `gleam test`.

`gleam run -m girard/differential answer <path> <function>` prints girard's
reading of one file with the corpus resolver. Run it on a forced-field
companion, where no colliding module is in scope, to diagnose a new divergence:
girard erroring there means the receiver's type never carried the variant, so
the narrowing was lost upstream of the resolution rather than at it.
Girard reading the field there while the base row still reads the module would
mean call position and projection have drifted apart again, which the shared
resolver closed and nothing should reopen.

## Not covered

- **Same-typed fixtures.** With the field and the module export at the same
  type, girard reports one signature either way and there is nothing to compare.
- **Record update**, in both directions: girard returns the same type for the
  narrowed and un-narrowed forms, so the pair discriminates nothing, and its one
  divergent direction — rejecting an unsafe update — is a diagnostic rather than
  an inference result, which is outside girard's remit.
- **Narrowing to more than one variant at once.** `narrowed_to` names a single
  variant by schema, so `alternatives_agree` uses two alternatives of the *same*
  variant; an alternative pattern narrowing to two different declaring variants
  has no representation here.
