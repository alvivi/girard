//// Differential signature oracle: compare girard's inferred top-level
//// signatures against the *real* Gleam compiler's, using the JSON produced by
//// `gleam export package-interface` (see scripts/gen-oracle.sh).
////
//// The compiler's type JSON is decoded straight into girard's own `Type` and
//// rendered with girard's printer, so the only thing that can differ is the
//// inferred structure. Type-variable names are canonicalised before comparison
//// (the compiler numbers variables per signature; girard shares a naming
//// context across a module — both are correct, just different spellings).

import girard
import girard/printer
import girard/types.{type Type, Fn, Named, Tuple, Var}
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/set
import gleam/string
import simplifile

pub fn signatures_match_compiler_test() {
  let assert Ok(entries) = simplifile.read_directory("oracle")
  let samples =
    list.filter_map(entries, fn(entry) {
      case string.ends_with(entry, ".gleam") {
        True -> Ok(string.replace(entry, ".gleam", ""))
        False -> Error(Nil)
      }
    })
  list.each(samples, check_sample)
}

/// Compare every public function and constant of one oracle sample against the
/// compiler's interface for that module.
fn check_sample(name: String) -> Nil {
  let assert Ok(json_string) =
    simplifile.read("oracle/" <> name <> ".interface.json")
  let assert Ok(source) = simplifile.read("oracle/" <> name <> ".gleam")

  let assert Ok(#(oracle_functions, oracle_constants)) =
    json.parse(json_string, decode.at(["modules", name], module_decoder()))

  let assert Ok(annotated) = girard.annotate(source)

  list.each(dict.to_list(oracle_functions), fn(entry) {
    let #(fn_name, oracle_type) = entry
    let assert Ok(ours) = list.key_find(annotated.functions, fn_name)
    check(name <> "." <> fn_name, ours, oracle_type)
  })

  list.each(dict.to_list(oracle_constants), fn(entry) {
    let #(const_name, oracle_type) = entry
    let assert Ok(ours) = list.key_find(annotated.constants, const_name)
    check(name <> "." <> const_name, ours, oracle_type)
  })

  check_expressions(name, annotated)
}

/// Compare girard's per-expression types against the compiler's, on the spans
/// both sides report (the compiler desugars pipes/`use`, so it emits some spans
/// girard does not; we only require agreement where the spans coincide).
fn check_expressions(name: String, annotated: girard.Annotated) -> Nil {
  let assert Ok(expr_json) = simplifile.read("oracle/" <> name <> ".expr.json")
  let assert Ok(oracle_exprs) =
    json.parse(
      expr_json,
      decode.at(["modules", name], decode.list(expression_decoder())),
    )

  let ours =
    list.fold(annotated.expressions, dict.new(), fn(acc, a) {
      dict.insert(acc, #(a.span.start, a.span.end), canonicalize(a.type_))
    })

  // The compiler can overlay several types on one span when it desugars (e.g.
  // `Foo(..r, ...)` emits both the record and an implicit copy of each kept
  // field at the record's span). Only compare spans where it reports a single
  // type, so we diff genuine source expressions, not desugaring artifacts.
  let theirs =
    list.fold(oracle_exprs, dict.new(), fn(acc, entry) {
      let #(start, end, oracle_type) = entry
      let rendered = canonicalize(printer.to_string(oracle_type))
      dict.upsert(acc, #(start, end), fn(existing) {
        case existing {
          option.Some(set) -> set.insert(set, rendered)
          option.None -> set.from_list([rendered])
        }
      })
    })

  list.each(dict.to_list(theirs), fn(entry) {
    let #(span, rendered_types) = entry
    case set.to_list(rendered_types), dict.get(ours, span) {
      [expected], Ok(actual) ->
        case actual == expected {
          True -> Nil
          False ->
            panic as {
              name
              <> " "
              <> int.to_string(span.0)
              <> "-"
              <> int.to_string(span.1)
              <> ": girard `"
              <> actual
              <> "` but the compiler says `"
              <> expected
              <> "`"
            }
        }
      _, _ -> Nil
    }
  })
}

fn expression_decoder() -> Decoder(#(Int, Int, Type)) {
  use start <- decode.field("start", decode.int)
  use end <- decode.field("end", decode.int)
  use type_ <- decode.field("type", type_decoder())
  decode.success(#(start, end, type_))
}

/// Compare girard's rendered signature string against the compiler's type,
/// both reduced to a canonical type-variable spelling.
fn check(name: String, ours: String, theirs: Type) -> Nil {
  let expected = canonicalize(printer.to_string(theirs))
  let actual = canonicalize(ours)
  case actual == expected {
    True -> Nil
    False ->
      panic as {
        name
        <> ": girard inferred `"
        <> actual
        <> "` but the compiler says `"
        <> expected
        <> "`"
      }
  }
}

// --- Decoding the compiler's package-interface JSON ------------------------

fn module_decoder() -> Decoder(
  #(dict.Dict(String, Type), dict.Dict(String, Type)),
) {
  use functions <- decode.field(
    "functions",
    decode.dict(decode.string, function_decoder()),
  )
  use constants <- decode.field(
    "constants",
    decode.dict(decode.string, constant_decoder()),
  )
  decode.success(#(functions, constants))
}

fn function_decoder() -> Decoder(Type) {
  use parameters <- decode.field(
    "parameters",
    decode.list(parameter_type_decoder()),
  )
  use return <- decode.field("return", type_decoder())
  decode.success(Fn(parameters, return))
}

fn parameter_type_decoder() -> Decoder(Type) {
  use type_ <- decode.field("type", type_decoder())
  decode.success(type_)
}

fn constant_decoder() -> Decoder(Type) {
  use type_ <- decode.field("type", type_decoder())
  decode.success(type_)
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

// --- Canonical type-variable spelling --------------------------------------

/// Rename type variables to a canonical first-seen sequence so that, e.g.,
/// `fn(a) -> a` and `fn(x) -> x` compare equal. Type variables are the only
/// lowercase identifiers in a rendered type other than the `fn` keyword.
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
  let #(out, _map, _next) = flush(out, run, map, next)
  out
}

fn flush(
  out: String,
  run: String,
  map: dict.Dict(String, String),
  next: Int,
) -> #(String, dict.Dict(String, String), Int) {
  case run, is_type_variable(run) {
    "", _ -> #(out, map, next)
    _, False -> #(out <> run, map, next)
    _, True ->
      case dict.get(map, run) {
        Ok(canonical) -> #(out <> canonical, map, next)
        Error(_) -> {
          let canonical = "$" <> int.to_string(next)
          #(out <> canonical, dict.insert(map, run, canonical), next + 1)
        }
      }
  }
}

fn is_type_variable(run: String) -> Bool {
  run != "fn" && run != "" && starts_lowercase(run)
}

fn starts_lowercase(run: String) -> Bool {
  case string.first(run) {
    Ok(c) -> string.lowercase(c) == c && string.uppercase(c) != c
    Error(_) -> False
  }
}

fn is_identifier_char(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    grapheme,
  )
}
