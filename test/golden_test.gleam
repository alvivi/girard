//// Golden snapshots of girard's complete, human-readable module report.
////
//// Each `golden/*.gleam` fixture is annotated and rendered with
//// `girard.report`, then captured as a Birdie snapshot pairing the source with
//// its inferred annotation — analogous to glance's source-plus-AST snapshots.
//// This complements the suite rather than duplicating it:
////
////   - `oracle_test.gleam` checks parity against the real compiler.
////   - `golden_test.gleam` (here) guards girard's own rendered output against
////     unintended regressions and makes deliberate format changes reviewable.
////   - `girard_test.gleam` holds focused behavioural specifications.
////
//// Fixtures live at the repo root under `golden/` (like `oracle/`) rather than
//// under `test/`, so `gleam` does not try to compile them as modules — a
//// fixture is inference input, not project code. Drop a `.gleam` file in and it
//// is picked up automatically. Review new or changed snapshots with
//// `gleam run -m birdie`.

import birdie
import girard
import gleam/list
import gleam/string
import simplifile

// Annotate every fixture under `golden/` and snapshot its report. The snapshot
// title is the fixture's base name, so each fixture owns one snapshot. A pending
// (new or changed) snapshot halts the loop, so after adding several fixtures at
// once, accept with `gleam run -m birdie` and rerun to reach the rest.
pub fn golden_modules_test() {
  let assert Ok(entries) = simplifile.read_directory("golden")

  entries
  |> list.filter(string.ends_with(_, ".gleam"))
  |> list.sort(string.compare)
  |> list.each(fn(entry) {
    let name = string.replace(entry, ".gleam", "")
    let assert Ok(source) = simplifile.read("golden/" <> entry)

    snapshot(source)
    |> birdie.snap(title: "golden: " <> name)
  })
}

// Pair the source with girard's rendered annotation so a snapshot diff shows
// both the input and the inferred output in one place.
fn snapshot(source: String) -> String {
  string.join(
    [
      "=== source ===",
      string.trim_end(source),
      "",
      "=== annotation ===",
      girard.report(source),
    ],
    "\n",
  )
}
