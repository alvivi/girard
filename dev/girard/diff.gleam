//// Differential per-expression check against the real compiler over a whole
//// installed package. Given a package name and the JSON produced by the patched
//// compiler's `gleam export expression-types`, it runs girard over every module
//// of `<packages-root>/<package>/src` and reports every span where the compiler
//// reports a single type and girard disagrees. The packages root defaults to
//// girard's `build/packages`.
////
////     gleam run -m girard/diff <package> <expr-types.json> [packages-root]
////
//// Spans the compiler overlays with several types (desugaring artifacts) are
//// skipped, as are spans girard does not annotate.

import argv
import girard.{type Type}
import girard/compiler_json
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option
import gleam/set
import gleam/string
import simplifile

// Differential check
//
// Run girard over every module of an installed package and report each span
// where girard's inferred type disagrees with the compiler's single reported
// type.

pub fn main() -> Nil {
  case argv.load().arguments {
    [package, json_path] -> diff(package, json_path, "build/packages")
    [package, json_path, pkg_root] -> diff(package, json_path, pkg_root)
    _ ->
      io.println(
        "usage: gleam run -m girard/diff <package> <expr-types.json> [packages-root]",
      )
  }
}

// Resolve an imported module's source from a packages root (the directory
// holding `<pkg>/src/...`), instead of girard's own `build/packages` — so the
// swept closure never collides with girard's own compile dependencies.
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

// Read the package's build target from its `gleam.toml`, defaulting to `Erlang`
// when unset or unreadable. The generated manifests spell JavaScript as the
// exact line `target = "javascript"`, so a substring check is sufficient.
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

fn diff(package: String, json_path: String, pkg_root: String) -> Nil {
  let resolver = dir_resolver(pkg_root)
  let target = target_of(pkg_root <> "/" <> package <> "/gleam.toml")
  let assert Ok(json_string) = simplifile.read(json_path)
  let assert Ok(modules) =
    json.parse(
      json_string,
      decode.at(
        ["modules"],
        decode.dict(decode.string, decode.list(expression_decoder())),
      ),
    )

  let options =
    girard.default_options()
    |> girard.with_resolver(resolver)
    |> girard.with_target(target)

  // Thread one interface cache across the package's modules so each shared
  // import is inferred once for the whole package, not once per importing
  // module. Strict per-module semantics are unchanged (annotate_with_cache
  // fails a module exactly as annotate does); only the redundant work is shared.
  let #(checked, mismatches, errored, _cache) =
    list.fold(
      dict.to_list(modules),
      #(0, 0, 0, girard.new_cache()),
      fn(acc, entry) {
        let #(checked, mismatches, errored, cache) = acc
        let #(module_name, oracle_exprs) = entry
        let path =
          pkg_root <> "/" <> package <> "/src/" <> module_name <> ".gleam"
        case simplifile.read(path) {
          Error(_) -> #(checked, mismatches, errored, cache)
          Ok(source) -> {
            let #(result, cache) =
              girard.annotate_with_cache(source, options, cache)
            case result {
              Error(e) -> {
                io.println(
                  module_name <> ": ERROR " <> girard.describe_error(e),
                )
                #(checked, mismatches, errored + 1, cache)
              }
              Ok(annotated) -> {
                let found = compare(module_name, annotated, oracle_exprs)
                #(checked + 1, mismatches + found, errored, cache)
              }
            }
          }
        }
      },
    )

  io.println(
    "diff "
    <> package
    <> ": "
    <> int.to_string(checked)
    <> " modules checked, "
    <> int.to_string(errored)
    <> " errored, "
    <> int.to_string(mismatches)
    <> " expression mismatches",
  )
}

// Report mismatches for one module; return how many were found.
fn compare(
  module_name: String,
  annotated: girard.AnnotatedModule,
  oracle_exprs: List(#(Int, Int, Type)),
) -> Int {
  let ours =
    list.fold(annotated.expressions, dict.new(), fn(acc, a) {
      dict.insert(
        acc,
        #(a.span.start, a.span.end),
        canonicalize(girard.type_to_string(a.type_)),
      )
    })
  let theirs =
    list.fold(oracle_exprs, dict.new(), fn(acc, entry) {
      let #(start, end, type_) = entry
      dict.upsert(acc, #(start, end), fn(existing) {
        case existing {
          option.Some(s) ->
            set.insert(s, canonicalize(girard.type_to_string(type_)))
          option.None ->
            set.from_list([canonicalize(girard.type_to_string(type_))])
        }
      })
    })

  list.fold(dict.to_list(theirs), 0, fn(found, entry) {
    let #(span, rendered) = entry
    case set.to_list(rendered), dict.get(ours, span) {
      [expected], Ok(actual) if actual != expected -> {
        io.println(
          module_name
          <> " "
          <> int.to_string(span.0)
          <> "-"
          <> int.to_string(span.1)
          <> ": girard `"
          <> actual
          <> "` vs compiler `"
          <> expected
          <> "`",
        )
        found + 1
      }
      _, _ -> found
    }
  })
}

// Decoding the compiler's expression JSON
//
// Turn the JSON from the patched compiler's `gleam export expression-types`
// into spans paired with girard's own `Type`.

fn expression_decoder() -> Decoder(#(Int, Int, Type)) {
  use start <- decode.field("start", decode.int)
  use end <- decode.field("end", decode.int)
  use type_ <- decode.field("type", compiler_json.type_decoder())
  decode.success(#(start, end, type_))
}

// Canonical type-variable spelling
//
// Rename type variables to a canonical sequence before comparison, since girard
// and the compiler number them differently though equivalently.

// Rename type variables to a canonical first-seen sequence.
fn canonicalize(rendered: String) -> String {
  let #(out, run, map, next) =
    list.fold(
      string.to_graphemes(rendered),
      #("", "", dict.new(), 0),
      fn(state, grapheme) {
        let #(out, run, map, next) = state
        case is_identifier_char(grapheme) {
          True -> #(out, run <> grapheme, map, next)
          False -> {
            let #(out, map, next) = flush(out, run, map, next)
            #(out <> grapheme, "", map, next)
          }
        }
      },
    )
  let #(out, _, _) = flush(out, run, map, next)
  out
}

fn flush(
  out: String,
  run: String,
  map: Dict(String, String),
  next: Int,
) -> #(String, Dict(String, String), Int) {
  case run != "" && run != "fn" && is_lower(run) {
    False ->
      case run {
        "" -> #(out, map, next)
        _ -> #(out <> run, map, next)
      }
    True ->
      case dict.get(map, run) {
        Ok(c) -> #(out <> c, map, next)
        Error(_) -> {
          let c = "$" <> int.to_string(next)
          #(out <> c, dict.insert(map, run, c), next + 1)
        }
      }
  }
}

fn is_lower(run: String) -> Bool {
  case string.first(run) {
    Ok(c) -> string.lowercase(c) == c && string.uppercase(c) != c
    Error(_) -> False
  }
}

fn is_identifier_char(g: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    g,
  )
}
