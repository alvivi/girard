//// Differential per-expression check against the real compiler over a whole
//// installed package. Given a package name and the JSON produced by the patched
//// compiler's `gleam export expression-types`, it runs girard over every module
//// of `build/packages/<package>/src` and reports every span where the compiler
//// reports a single type and girard disagrees.
////
////     gleam run -m girard/diff <package> <expr-types.json>
////
//// Spans the compiler overlays with several types (desugaring artifacts) are
//// skipped, as are spans girard does not annotate.

import argv
import girard
import girard/internal/printer
import girard/types.{type Type, Fn, Named, Tuple, Var}
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

/// Resolve an imported module's source from a packages root (the directory
/// holding `<pkg>/src/...`), instead of girard's own `build/packages` — so the
/// swept closure never collides with girard's own compile dependencies.
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

fn diff(package: String, json_path: String, pkg_root: String) -> Nil {
  let resolver = dir_resolver(pkg_root)
  let assert Ok(json_string) = simplifile.read(json_path)
  let assert Ok(modules) =
    json.parse(
      json_string,
      decode.at(
        ["modules"],
        decode.dict(decode.string, decode.list(expression_decoder())),
      ),
    )

  let #(checked, mismatches, errored) =
    list.fold(dict.to_list(modules), #(0, 0, 0), fn(acc, entry) {
      let #(checked, mismatches, errored) = acc
      let #(module_name, oracle_exprs) = entry
      let path =
        pkg_root <> "/" <> package <> "/src/" <> module_name <> ".gleam"
      case simplifile.read(path) {
        Error(_) -> #(checked, mismatches, errored)
        Ok(source) ->
          case girard.annotate_with(source, resolver) {
            Error(e) -> {
              io.println(module_name <> ": ERROR " <> girard.describe_error(e))
              #(checked, mismatches, errored + 1)
            }
            Ok(annotated) -> {
              let found = compare(module_name, annotated, oracle_exprs)
              #(checked + 1, mismatches + found, errored)
            }
          }
      }
    })

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

/// Report mismatches for one module; returns how many were found.
fn compare(
  module_name: String,
  annotated: girard.Annotated,
  oracle_exprs: List(#(Int, Int, Type)),
) -> Int {
  let ours =
    list.fold(annotated.expressions, dict.new(), fn(acc, a) {
      dict.insert(
        acc,
        #(a.span.start, a.span.end),
        canonicalize(printer.to_string(a.type_)),
      )
    })
  let theirs =
    list.fold(oracle_exprs, dict.new(), fn(acc, entry) {
      let #(start, end, type_) = entry
      dict.upsert(acc, #(start, end), fn(existing) {
        case existing {
          option.Some(s) ->
            set.insert(s, canonicalize(printer.to_string(type_)))
          option.None -> set.from_list([canonicalize(printer.to_string(type_))])
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

fn expression_decoder() -> Decoder(#(Int, Int, Type)) {
  use start <- decode.field("start", decode.int)
  use end <- decode.field("end", decode.int)
  use type_ <- decode.field("type", type_decoder())
  decode.success(#(start, end, type_))
}

fn type_decoder() -> Decoder(Type) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "named" -> {
      use name <- decode.field("name", decode.string)
      use module <- decode.field("module", decode.string)
      use parameters <- decode.field("parameters", decode.list(type_decoder()))
      decode.success(Named(module, name, parameters))
    }
    "fn" -> {
      use parameters <- decode.field("parameters", decode.list(type_decoder()))
      use return <- decode.field("return", type_decoder())
      decode.success(Fn(parameters, return))
    }
    "tuple" -> {
      use elements <- decode.field("elements", decode.list(type_decoder()))
      decode.success(Tuple(elements))
    }
    "variable" -> {
      use id <- decode.field("id", decode.int)
      decode.success(Var(id))
    }
    other -> decode.failure(Var(0), "Type(kind=" <> other <> ")")
  }
}

/// Rename type variables to a canonical first-seen sequence.
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
