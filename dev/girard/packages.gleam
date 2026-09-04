//// Reading an installed package off disk: resolving its imports, reading its
//// build target, and enumerating its modules.
////
//// Every package-walking dev tool needs the same three things, and each one
//// staged its packages the same way — a directory of `<pkg>/src/...`, built by
//// `scripts/cache.sh` or `scripts/bench.sh` from the sweep cache. Keeping the
//// three in one place is what makes "girard over package P" mean the same
//// thing in `girard/diff`, `girard/bench` and `girard/census`, the way
//// `girard/compiler_json` does for "the compiler said X".

import girard
import gleam/list
import gleam/string
import simplifile

// Imports
//
// Resolve an imported module from a staged packages root rather than girard's
// own `build/packages`, so a swept closure never collides with girard's own
// compile dependencies.

/// Resolve an imported module's source from `root`, the directory holding
/// `<pkg>/src/...`.
pub fn dir_resolver(root: String) -> girard.Resolver {
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

// Target
//
// The build target a package is compiled for, which decides which
// `@target(...)` definitions girard keeps.

/// Read the build target from a package's `gleam.toml`, defaulting to `Erlang`
/// when unset or unreadable. The generated manifests spell JavaScript as the
/// exact line `target = "javascript"`, so a substring check is sufficient.
pub fn target_of(toml_path: String) -> girard.Target {
  case simplifile.read(toml_path) {
    Ok(toml) ->
      case string.contains(toml, "target = \"javascript\"") {
        True -> girard.JavaScript
        False -> girard.Erlang
      }
    Error(_) -> girard.Erlang
  }
}

// Modules
//
// A package's own modules, for the tools that have no compiler export to take
// a module list from.

/// Every `.gleam` file under `root`, recursively, as full paths in a stable
/// order.
pub fn sources(root: String) -> List(String) {
  case simplifile.get_files(root) {
    Error(_) -> []
    Ok(paths) ->
      paths
      |> list.filter(string.ends_with(_, ".gleam"))
      |> list.sort(string.compare)
  }
}

/// Every module under a package's source root, as `#(module path, file path)`
/// — the module path being what an `import` names it by, so a caller reporting
/// a module never has to rebuild the file path it already read.
pub fn modules(root: String) -> List(#(String, String)) {
  list.map(sources(root), fn(path) {
    let module =
      path
      |> string.drop_start(string.length(root <> "/"))
      |> string.drop_end(string.length(".gleam"))
    #(module, path)
  })
}
