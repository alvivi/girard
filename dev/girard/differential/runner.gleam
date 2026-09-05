//// The two sides' answers, in one representation.
////
//// girard's answer comes from running it over the fixture with the composite
//// resolver below; the compiler's comes from decoding its `package-interface`
//// export into girard's own `Type` and rendering it with girard's printer. One
//// printer for both sides, so a difference in the rendered string is a
//// difference in the type and not in the spelling.

import girard
import girard/compiler_json
import girard/differential/manifest.{type At, type Outcome, At, Outcome}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile

/// The module path the driver stages every case source under. Fixed, because
/// each temp project holds exactly one case and is then thrown away, so the
/// package name and module path carry no information — and fixing them is what
/// lets `differential/gleam.toml` be copied byte for byte instead of patched.
pub const case_module = "differential_case"

// The girard side
//
// `disk_resolver` reads `src/` then `build/packages/*/src`, relative to the
// working directory, so from the repo root it cannot see
// `differential/support`. The resolver has to be *composite* rather than a
// replacement: `with_resolver` swaps the disk resolver out entirely, and the
// `result.try` control still needs the real `gleam/result`.

/// Resolve `differential/support` first, then fall through to girard's own disk
/// resolver.
pub fn resolver() -> girard.Resolver {
  let disk = girard.disk_resolver()
  fn(path: String) -> Result(String, Nil) {
    case simplifile.read("differential/support/" <> path <> ".gleam") {
      Ok(source) -> Ok(source)
      Error(_) -> disk(path)
    }
  }
}

/// girard's whole answer for one fixture, in one pass: the inferred return type
/// of the function under test, and what each field access and each called bare
/// name resolved to. A source girard cannot type answers an error and resolves
/// nothing. Both halves come from one inference, so a caller that reads the
/// type *and* the resolutions does not infer the module twice.
pub fn girard_analysis(
  source: String,
  function: String,
) -> #(Outcome, List(girard.ResolvedReference)) {
  let options = girard.with_resolver(girard.default_options(), resolver())
  case girard.annotate(source, options) {
    Error(error) -> #(girard_error(error_variant(error)), [])
    Ok(annotated) -> #(
      case list.key_find(annotated.functions, function) {
        Error(_) -> girard_error("MissingFunction")
        Ok(scheme) ->
          Outcome(
            status: manifest.status_ok,
            return: Some(girard.type_to_string(return_of(scheme.type_))),
            diagnostic: None,
            at: None,
            error_variant: None,
          )
      },
      annotated.resolutions,
    )
  }
}

/// Annotate a fixture and read off the inferred return type of the one function
/// under test.
pub fn girard_outcome(source: String, function: String) -> Outcome {
  girard_analysis(source, function).0
}

// A girard-side failure: the constructor tag and nothing else. `diagnostic` and
// `at` are compiler-side keys and stay null here.
fn girard_error(variant: String) -> Outcome {
  Outcome(
    status: manifest.status_error,
    return: None,
    diagnostic: None,
    at: None,
    error_variant: Some(variant),
  )
}

fn return_of(type_: girard.Type) -> girard.Type {
  case type_ {
    girard.Fn(_, return) -> return
    other -> other
  }
}

/// The constructor tag of a girard error, with no payload. The tag is the part
/// of girard's answer that carries meaning across releases; the human text is
/// its own vocabulary, will never match the compiler's, and is never compared.
pub fn error_variant(error: girard.Error) -> String {
  case error {
    girard.TypeMismatch(..) -> "TypeMismatch"
    girard.ArityMismatch -> "ArityMismatch"
    girard.RecursiveType(..) -> "RecursiveType"
    girard.UnboundVariable(..) -> "UnboundVariable"
    girard.UnknownConstructor(..) -> "UnknownConstructor"
    girard.UnknownModule(..) -> "UnknownModule"
    girard.NoSuchExport(..) -> "NoSuchExport"
    girard.NoSuchField(..) -> "NoSuchField"
    girard.NotARecord -> "NotARecord"
    girard.NotATuple -> "NotATuple"
    girard.TupleIndexOutOfRange(..) -> "TupleIndexOutOfRange"
    girard.UnknownLabel(..) -> "UnknownLabel"
    girard.AmbiguousCall -> "AmbiguousCall"
    girard.MissingArgument -> "MissingArgument"
    girard.Unsupported(..) -> "Unsupported"
    girard.ParseFailed(..) -> "ParseFailed"
  }
}

// The compiler side
//
// `gleam export package-interface` on success; the human diagnostic on failure,
// normalized to the first `error:` line's title and the position under it. No
// spans, no paths and no hints — the parts that move between releases. The
// pinned 1.18.0 toolchain is what makes even the title stable, and the title is
// advisory: nothing keys on the string.

/// Decode the compiler's answer for `function` out of a `package-interface`
/// export.
pub fn compiler_ok(
  interface: String,
  function: String,
) -> Result(Outcome, Nil) {
  json.parse(
    interface,
    decode.at(
      ["modules", case_module, "functions", function, "return"],
      compiler_json.type_decoder(),
    ),
  )
  |> result.replace_error(Nil)
  |> result.map(fn(type_) {
    Outcome(
      status: manifest.status_ok,
      return: Some(girard.type_to_string(type_)),
      diagnostic: None,
      at: None,
      error_variant: None,
    )
  })
}

/// Read a failed compile's primary diagnostic: the title of the first `error:`
/// line, and the `┌─ path:line:column` position beneath it.
pub fn compiler_error(output: String) -> Outcome {
  let lines = string.split(output, "\n")
  let after =
    list.drop_while(lines, fn(line) {
      !string.starts_with(string.trim_start(line), "error:")
    })
  let #(diagnostic, rest) = case after {
    [first, ..rest] -> #(
      string.trim(string.drop_start(string.trim_start(first), 6)),
      rest,
    )
    [] -> #("", [])
  }
  Outcome(
    status: manifest.status_error,
    return: None,
    diagnostic: Some(diagnostic),
    at: position(rest),
    error_variant: None,
  )
}

fn position(lines: List(String)) -> option.Option(At) {
  lines
  |> list.find_map(fn(line) {
    let trimmed = string.trim(line)
    case string.starts_with(trimmed, "┌─ ") {
      False -> Error(Nil)
      True -> parse_position(string.drop_start(trimmed, 4))
    }
  })
  |> option.from_result
}

// `path:line:column`, where the path may itself contain colons on no platform
// this driver runs on but is never needed: the line and column are the last two
// segments.
fn parse_position(text: String) -> Result(At, Nil) {
  let segments = list.reverse(string.split(string.trim(text), ":"))
  case segments {
    [column, line, ..] -> {
      use column <- result.try(int_of(column))
      use line <- result.try(int_of(line))
      Ok(At(line:, column:))
    }
    _ -> Error(Nil)
  }
}

fn int_of(text: String) -> Result(Int, Nil) {
  int.parse(string.trim(text))
}
// Decoding the compiler's `package-interface` types into girard's own `Type`,
// exactly as `test/oracle_test` does, so both sides render through one printer.
