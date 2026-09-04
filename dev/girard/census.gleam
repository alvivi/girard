//// Count what girard resolved, and what it did not, over a whole installed
//// package. It runs `analyse_with_cache` over every module of
//// `<packages-root>/<package>/src` and reports every reference published as
//// `Unresolved`, with the span it sits at.
////
////     gleam run -m girard/census <package> [packages-root]
////
//// The packages root defaults to girard's `build/packages`;
//// `scripts/cache.sh census` stages the pooled closure and passes its own.
////
//// Unlike `girard/diff` this needs no compiler oracle: the count is girard's
//// own. An `Unresolved` is a place girard reached the field's *type* but no
//// member at the access — over code the real compiler accepts, each one is a
//// place girard's inference order lags the compiler's, so the census is the
//// gate on closing that gap rather than a comparison with anything external.

import argv
import girard
import girard/packages
import gleam/int
import gleam/io
import gleam/list
import simplifile

// Census
//
// Walk a package's modules and report each unresolved reference.

pub fn main() -> Nil {
  case argv.load().arguments {
    [package] -> census(package, "build/packages")
    [package, pkg_root] -> census(package, pkg_root)
    _ ->
      io.println("usage: gleam run -m girard/census <package> [packages-root]")
  }
}

fn census(package: String, pkg_root: String) -> Nil {
  let src = pkg_root <> "/" <> package <> "/src"

  let options =
    girard.default_options()
    |> girard.with_resolver(packages.dir_resolver(pkg_root))
    |> girard.with_target(packages.target_of(
      pkg_root <> "/" <> package <> "/gleam.toml",
    ))

  // One interface cache across the package's modules, as `girard/diff` threads
  // one: a shared import is inferred once for the package rather than once per
  // importing module. Per-module semantics are unchanged.
  let #(checked, references, unresolved, errored, _cache) =
    list.fold(
      packages.modules(src),
      #(0, 0, 0, 0, girard.new_cache()),
      fn(acc, module) {
        let #(checked, references, unresolved, errored, cache) = acc
        let #(module_name, path) = module
        case simplifile.read(path) {
          Error(_) -> acc
          Ok(source) -> {
            let #(result, cache) =
              girard.analyse_with_cache(source, options, cache)
            case result {
              Error(e) -> {
                io.println(
                  module_name <> ": ERROR " <> girard.describe_error(e),
                )
                #(checked, references, unresolved, errored + 1, cache)
              }
              Ok(analysis) -> {
                let found = report(module_name, analysis)
                #(
                  checked + 1,
                  references + list.length(analysis.resolutions),
                  unresolved + found,
                  errored,
                  cache,
                )
              }
            }
          }
        }
      },
    )

  io.println(
    "census "
    <> package
    <> ": "
    <> int.to_string(checked)
    <> " modules, "
    <> int.to_string(errored)
    <> " errored, "
    <> int.to_string(references)
    <> " references, "
    <> int.to_string(unresolved)
    <> " unresolved",
  )
}

// Print one line per unresolved reference in a module; return how many.
fn report(module_name: String, analysis: girard.Analysis) -> Int {
  list.fold(analysis.resolutions, 0, fn(found, reference) {
    case reference.resolution {
      girard.Unresolved(reason) -> {
        io.println(
          module_name
          <> ":"
          <> int.to_string(reference.span.start)
          <> "-"
          <> int.to_string(reference.span.end)
          <> " "
          <> describe(reason),
        )
        found + 1
      }
      _ -> found
    }
  })
}

fn describe(reason: girard.UnresolvedReason) -> String {
  case reason {
    girard.RecordAccessUnknownType -> "RecordAccessUnknownType"
  }
}
