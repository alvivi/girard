//// Package sweep: run girard over every module of an installed package and
//// bucket the outcome as `ok` or an error reason. This turns real-world code
//// into a coverage report and a prioritised backlog of inference gaps.
////
//// Run it against a dependency in `build/packages` (default `gleam_stdlib`):
////
////     gleam run -m girard/sweep              # sweep gleam_stdlib
////     gleam run -m girard/sweep gleam_json   # sweep another installed package
////
//// It relies on the same on-disk resolver `girard.annotate` uses, so a module's
//// imports are resolved from `build/packages` too.

import argv
import girard
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import simplifile

pub fn main() -> Nil {
  let package = case argv.load().arguments {
    [package, ..] -> package
    [] -> "gleam_stdlib"
  }
  sweep(package)
}

/// Sweep every `.gleam` module under `build/packages/<package>/src`.
pub fn sweep(package: String) -> Nil {
  let source_root = "build/packages/" <> package <> "/src"
  case simplifile.get_files(source_root) {
    Error(_) -> io.println("could not read package: " <> source_root)
    Ok(files) -> {
      let modules = list.filter(files, string.ends_with(_, ".gleam"))
      let outcomes = list.map(modules, classify)
      report(package, outcomes)
    }
  }
}

// `#(module path, outcome)` where outcome is "ok" or an error description.
fn classify(path: String) -> #(String, String) {
  case simplifile.read(path) {
    Error(_) -> #(path, "could not read file")
    Ok(source) ->
      case girard.annotate(source, girard.default_options()) {
        Ok(_) -> #(path, "ok")
        Error(error) -> #(path, girard.describe_error(error))
      }
  }
}

fn report(package: String, outcomes: List(#(String, String))) -> Nil {
  let total = list.length(outcomes)
  let ok = list.count(outcomes, fn(o) { o.1 == "ok" })

  io.println("")
  io.println("girard sweep of " <> package)
  io.println(
    "  "
    <> int.to_string(ok)
    <> "/"
    <> int.to_string(total)
    <> " modules fully typed",
  )

  // Group the failures by their reason, most common first.
  let failures = list.filter(outcomes, fn(o) { o.1 != "ok" })
  let by_reason =
    list.fold(failures, dict.new(), fn(counts, outcome) {
      let reason = generalise(outcome.1)
      dict.upsert(counts, reason, fn(existing) {
        case existing {
          option.Some(n) -> n + 1
          option.None -> 1
        }
      })
    })

  case dict.size(by_reason) {
    0 -> Nil
    _ -> {
      io.println("  failures by reason:")
      by_reason
      |> dict.to_list
      |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
      |> list.each(fn(entry) {
        io.println("    " <> int.to_string(entry.1) <> "  " <> entry.0)
      })
    }
  }
}

// Collapse a specific error message into a coarse bucket (dropping the variable
// parts) so similar failures group together.
fn generalise(reason: String) -> String {
  case string.split_once(reason, ":") {
    Ok(#(head, _)) -> head
    Error(_) -> reason
  }
}
