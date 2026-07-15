//// A repeatable throughput benchmark for girard's inference, run over a corpus
//// of real hex packages staged from the offline sweep cache (see
//// `scripts/bench.sh`).
////
////     gleam run -m girard/bench <spec-file> [warmup-rounds] [measure-rounds]
////
//// The spec file has one `<package>\t<packages-root>` line per package: the
//// root holds `<package>/src/**.gleam` plus the package's resolved dependency
//// closure (symlinked from the cache pool), so imports resolve exactly as in a
//// sweep. The harness annotates every module of every listed package inside a
//// single VM process, timing only the `girard.annotate_with_cache` calls — not
//// VM startup, file I/O, or directory walking — and reports total elapsed time
//// and throughput (expressions annotated per second).
////
//// The same spec over the same cache fixes the module set and expression count;
//// repeated measured rounds reduce, but do not eliminate, runtime noise.

import argv
import girard
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

// Benchmark harness
//
// Annotate every module of every package in the spec across warmup and measure
// rounds, timing only `girard.annotate_with_cache`, and report elapsed time and
// throughput.

/// Microsecond-resolution monotonic elapsed-time counter, unaffected by system
/// clock adjustments.
@external(erlang, "os", "perf_counter")
fn perf_counter(resolution: Int) -> Int

type PkgSpec {
  PkgSpec(package: String, root: String)
}

/// What one annotate pass produced — the denominators for throughput.
type Tally {
  Tally(modules: Int, expressions: Int, errored: Int, micros: Int)
}

fn empty() -> Tally {
  Tally(0, 0, 0, 0)
}

fn add(a: Tally, b: Tally) -> Tally {
  Tally(
    a.modules + b.modules,
    a.expressions + b.expressions,
    a.errored + b.errored,
    a.micros + b.micros,
  )
}

pub fn main() -> Nil {
  case argv.load().arguments {
    [spec_path, ..rest] -> {
      let warmup = nth_int(rest, 0, 1)
      let measure = nth_int(rest, 1, 1)
      run(spec_path, warmup, measure)
    }
    _ ->
      io.println(
        "usage: gleam run -m girard/bench <spec-file> [warmup-rounds] [measure-rounds]",
      )
  }
}

fn nth_int(args: List(String), index: Int, default: Int) -> Int {
  case list.drop(args, index) {
    [s, ..] -> result.unwrap(int.parse(s), default)
    [] -> default
  }
}

fn run(spec_path: String, warmup: Int, measure: Int) -> Nil {
  let assert Ok(raw) = simplifile.read(spec_path)
  let specs = parse_spec(raw)
  io.println(
    "bench: "
    <> int.to_string(list.length(specs))
    <> " packages, "
    <> int.to_string(warmup)
    <> " warmup + "
    <> int.to_string(measure)
    <> " measured rounds",
  )

  // Warm the JIT and filesystem cache without recording timings.
  list.each(list.repeat(Nil, warmup), fn(_) {
    list.each(specs, fn(spec) {
      let _ = bench_package(spec)
      Nil
    })
  })

  let total =
    list.fold(list.repeat(Nil, measure), empty(), fn(acc, _round) {
      list.fold(specs, acc, fn(acc, spec) { add(acc, bench_package(spec)) })
    })

  report(total, measure)
}

fn parse_spec(raw: String) -> List(PkgSpec) {
  raw
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.split(string.trim(line), "\t") {
      [package, root] if package != "" -> Ok(PkgSpec(package, root))
      _ -> Error(Nil)
    }
  })
}

/// Annotate every module of one package, timing only `annotate_with_cache`. One
/// interface cache is threaded across the package's modules, so a shared import
/// is inferred once for the whole package rather than once per importing module
/// — the way a package-walking tool (or an editor across sibling files) uses
/// girard.
fn bench_package(spec: PkgSpec) -> Tally {
  let resolver = dir_resolver(spec.root)
  let target = target_of(spec.root <> "/" <> spec.package <> "/gleam.toml")
  let options =
    girard.default_options()
    |> girard.with_resolver(resolver)
    |> girard.with_target(target)

  let src = spec.root <> "/" <> spec.package <> "/src"
  let #(tally, _cache) =
    list.fold(gleam_sources(src), #(empty(), girard.new_cache()), fn(acc, path) {
      let #(tally, cache) = acc
      case simplifile.read(path) {
        Error(_) -> #(tally, cache)
        Ok(source) -> {
          let #(t, cache) = time_annotate(source, options, cache)
          #(add(tally, t), cache)
        }
      }
    })
  tally
}

/// Time a single annotate call (cache threaded in and out) and bucket the result.
fn time_annotate(
  source: String,
  options: girard.Options,
  cache: girard.Cache,
) -> #(Tally, girard.Cache) {
  let t0 = perf_counter(1_000_000)
  let #(outcome, cache) = girard.annotate_with_cache(source, options, cache)
  let t1 = perf_counter(1_000_000)
  let micros = t1 - t0
  let tally = case outcome {
    Ok(annotated) -> Tally(1, list.length(annotated.expressions), 0, micros)
    Error(_) -> Tally(0, 0, 1, micros)
  }
  #(tally, cache)
}

fn report(total: Tally, rounds: Int) -> Nil {
  let secs = int.to_float(total.micros) /. 1_000_000.0
  let per_round_ms = total.micros / { rounds * 1000 }
  let exprs_per_sec = case secs >. 0.0 {
    True -> int.to_float(total.expressions) /. secs
    False -> 0.0
  }
  io.println(
    "bench result: "
    <> int.to_string(total.modules)
    <> " modules, "
    <> int.to_string(total.expressions)
    <> " expressions, "
    <> int.to_string(total.errored)
    <> " errored",
  )
  io.println(
    "bench time: "
    <> int.to_string(total.micros / 1000)
    <> " ms total over "
    <> int.to_string(rounds)
    <> " rounds ("
    <> int.to_string(per_round_ms)
    <> " ms/round)",
  )
  io.println(
    "bench throughput: " <> float_to_string(exprs_per_sec) <> " expressions/sec",
  )
}

fn float_to_string(f: Float) -> String {
  int.to_string(float.round(f))
}

// Resolver and target
//
// Resolve a package's imports from its staged dependency root, mirroring the
// on-disk resolver a real sweep uses (see `dev/girard/diff.gleam`).

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

// Recursive module walk
//
// List every `.gleam` source under a directory, so a package's modules can be
// discovered without a manifest.

/// Every `.gleam` file under `dir`, recursively, as full paths.
fn gleam_sources(dir: String) -> List(String) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(entries) ->
      list.flat_map(entries, fn(entry) {
        let path = dir <> "/" <> entry
        case simplifile.is_directory(path) {
          Ok(True) -> gleam_sources(path)
          _ ->
            case string.ends_with(path, ".gleam") {
              True -> [path]
              False -> []
            }
        }
      })
  }
}
