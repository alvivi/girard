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
import gleam/int
import gleam/io
import gleam/list
import gleam/string
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

// Resolve an imported module's source from a packages root (the directory
// holding `<pkg>/src/...`), instead of girard's own `build/packages` — so the
// swept closure never collides with girard's own compile dependencies. The
// same resolver `girard/diff` uses.
fn dir_resolver(root: String) -> girard.Resolver {
  fn(path: String) -> Result(String, Nil) {
    case simplifile.read_directory(root) {
      Ok(pkgs) ->
        first_readable(
          list.map(pkgs, fn(pkg) {
            root <> "/" <> pkg <> "/src/" <> path <> ".gleam"
          }),
        )
      Error(_) -> Error(Nil)
    }
  }
}

fn first_readable(paths: List(String)) -> Result(String, Nil) {
  case paths {
    [] -> Error(Nil)
    [path, ..rest] ->
      case simplifile.read(path) {
        Ok(source) -> Ok(source)
        Error(_) -> first_readable(rest)
      }
  }
}

// Read the package's build target from its `gleam.toml`, defaulting to `Erlang`
// when unset or unreadable, as `girard/diff` does.
fn target_of(toml_path: String) -> girard.Target {
  case simplifile.read(toml_path) {
    Ok(toml) ->
      case string.contains(toml, "target = \"javascript\"") {
        True -> girard.JavaScript
        False -> girard.Erlang
      }
    Error(_) -> girard.Erlang
  }
}

// Every `.gleam` module under a source root, as a module path (the path under
// the root, without the extension). `girard/diff` takes its module list from
// the compiler's oracle JSON; there is no oracle here, so the sources are the
// list.
fn modules(root: String, prefix: String) -> List(String) {
  case simplifile.read_directory(root <> "/" <> prefix) {
    Error(_) -> []
    Ok(entries) ->
      list.sort(entries, string.compare)
      |> list.flat_map(fn(entry) {
        let path = join(prefix, entry)
        case simplifile.is_directory(root <> "/" <> path) {
          Ok(True) -> modules(root, path)
          _ ->
            case string.ends_with(entry, ".gleam") {
              True -> [drop_extension(path)]
              False -> []
            }
        }
      })
  }
}

fn join(prefix: String, entry: String) -> String {
  case prefix {
    "" -> entry
    _ -> prefix <> "/" <> entry
  }
}

fn drop_extension(path: String) -> String {
  string.drop_end(path, string.length(".gleam"))
}

fn census(package: String, pkg_root: String) -> Nil {
  let resolver = dir_resolver(pkg_root)
  let target = target_of(pkg_root <> "/" <> package <> "/gleam.toml")
  let src = pkg_root <> "/" <> package <> "/src"

  let options =
    girard.default_options()
    |> girard.with_resolver(resolver)
    |> girard.with_target(target)

  // One interface cache across the package's modules, as `girard/diff` threads
  // one: a shared import is inferred once for the package rather than once per
  // importing module. Per-module semantics are unchanged.
  let #(checked, references, unresolved, errored, _cache) =
    list.fold(
      modules(src, ""),
      #(0, 0, 0, 0, girard.new_cache()),
      fn(acc, module_name) {
        let #(checked, references, unresolved, errored, cache) = acc
        let path = src <> "/" <> module_name <> ".gleam"
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
