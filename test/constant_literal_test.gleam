// A module constant's literal is live, as the compiler's is, and the probes
// that pin it against Gleam 1.19.2. A literal reader — a bare guard name, or
// a constant record update's spread naming a module constant — reads the
// constant's stored literal rather than a copy of its scheme, so a binding a
// guard or an update makes is seen by every later reader: in the defining
// module through the original literal, and in an importer through
// identities that name each variable by the module that created it, with the
// bindings each module's import closure made replayed before it is inferred.
//
// Every probe test runs a probe from girard's PR L inventory through the
// normal entry point with 1.19.2's answer pinned: each public signature and
// constant its interface exports, and, where the probe's point is a
// constant's scheme, that scheme. Each test names its probe. One pins
// girard's documented answer instead: in
// `binding_outside_the_import_closure_is_not_seen_test` the binding is made
// outside the import closure, and the probe is recorded as `known`, since
// 1.19.2's answer differs. Every probe test also checks that no expression
// is annotated twice, except the package and warm-cache tests and
// `constant_annotation_in_a_group_starts_its_own_scope_test`, which check
// signatures only, as do the tests that name no probe.

import girard
import glance
import gleam/dict
import gleam/list
import gleeunit/should
import probe_support.{constant, repeated_spans, scheme_of, signature}

pub fn guard_pin_reaches_an_importer_test() {
  // Probe `k_r7_constant_shared_local`.
  // `pin`'s guard pins `xs` to `List(Int)` in `helper`, and the importer's
  // bare reader sees the pinned literal.
  let source =
    "import helper.{xs}

pub fn run(x) {
  case x {
    _ if x == xs -> x
    _ -> x
  }
}
"
  let modules = [
    #(
      "helper",
      "pub const xs = []

pub fn pin() {
  case True {
    _ if xs == [1] -> Nil
    _ -> Nil
  }
}
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(List(Int)) -> List(Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn guard_pin_reaches_an_importer_through_another_test() {
  // Probe `k_r7_constant_shared_import`.
  // `pinning` pins `helper`'s `xs`; the consumer imports both and its bare
  // reader sees the pin, which `pinning`'s interface carries.
  let source =
    "import helper.{xs}
import pinning

pub fn run(x) {
  pinning.pin()
  case x {
    _ if x == xs -> x
    _ -> x
  }
}
"
  let modules = [
    #(
      "helper",
      "pub const xs = []
",
    ),
    #(
      "pinning",
      "import helper.{xs}

pub fn pin() {
  case True {
    _ if xs == [1] -> Nil
    _ -> Nil
  }
}
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(List(Int)) -> List(Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pins_from_two_imports_merge_test() {
  // Probe `k_l1_constant_merge`.
  // `first` pins `pair.0` and `second` pins `pair.1`: the consumer replays
  // both and reads `#(List(Int), List(String))`.
  let source =
    "import first
import helper.{pair}
import second

pub fn run(x) {
  first.pin()
  second.pin()
  case x {
    _ if x == pair -> x
    _ -> x
  }
}
"
  let modules = [
    #(
      "first",
      "import helper.{pair}

pub fn pin() {
  case True {
    _ if pair.0 == [1] -> Nil
    _ -> Nil
  }
}
",
    ),
    #(
      "helper",
      "pub const pair = #([], [])
",
    ),
    #(
      "second",
      "import helper.{pair}

pub fn pin() {
  case True {
    _ if pair.1 == [\"a\"] -> Nil
    _ -> Nil
  }
}
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal(
    "fn(#(List(Int), List(String))) -> #(List(Int), List(String))",
  )
  repeated_spans(source, modules) |> should.equal([])
}

pub fn guard_pin_applies_in_group_order_test() {
  // Probe `k_l3_constant_local_order`.
  // `early` reads `xs` before `pin` pins it and keeps its generic signature;
  // `late` and the importer read the pinned literal. The constant's scheme
  // stays `List(a)`.
  let source =
    "import helper.{xs}

pub fn run(x) {
  case x {
    _ if x == xs -> x
    _ -> x
  }
}
"
  let modules = [
    #(
      "helper",
      "pub const xs = []

pub fn early(x) {
  case x {
    _ if x == xs -> x
    _ -> x
  }
}

pub fn pin() {
  case True {
    _ if xs == [1] -> Nil
    _ -> Nil
  }
}

pub fn late(x) {
  case x {
    _ if x == xs -> x
    _ -> x
  }
}
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(List(Int)) -> List(Int)")
  let #(_, helper) = case modules {
    [helper] -> helper
    _ -> panic as "one helper"
  }
  constant(helper, [], "xs") |> should.equal("List(a)")
  signature(helper, [], "early") |> should.equal("fn(List(a)) -> List(a)")
  signature(helper, [], "late") |> should.equal("fn(List(Int)) -> List(Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn variables_no_constant_names_still_link_test() {
  // Probe `k_l_r1_b2_flexible_bridge`.
  // `helper` links `xs` and `ys`; `first` links `xs` to its `ls`, `second`
  // links `ys` to its `rs`. The consumer imports only `ls` and `rs`, and the
  // chain of shared variables carries its pin of `ls` to `rs`.
  let source =
    "import first.{ls}
import second.{rs}
pub fn run(x) {
  case x {
    _ if ls == [1] && x == rs -> x
    _ -> x
  }
}
"
  let modules = [
    #(
      "first",
      "import helper.{xs}
pub const ls = []
pub fn link() {
  case True { _ if xs == ls -> Nil _ -> Nil }
}
",
    ),
    #(
      "helper",
      "pub const xs = []
pub const ys = []
pub fn link() {
  case True { _ if xs == ys -> Nil _ -> Nil }
}
",
    ),
    #(
      "second",
      "import helper.{ys}
pub const rs = []
pub fn link() {
  case True { _ if ys == rs -> Nil _ -> Nil }
}
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(List(Int)) -> List(Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn one_generic_reached_twice_is_one_test() {
  // Probe `k_l_r1_b2_rigid_diamond`.
  // `helper` binds `xs` to a signature generic, and two importers link it
  // to `ys` and `zs`: in the consumer the generic is one rigid variable, so
  // `ys == zs` unifies it with itself.
  let source =
    "import first
import helper.{ys, zs}
import second
pub fn run(x) {
  first.link()
  second.link()
  case x {
    _ if ys == zs && x == ys -> x
    _ -> x
  }
}
"
  let modules = [
    #(
      "first",
      "import helper.{xs, ys}
pub fn link() {
  case True { _ if xs == ys -> Nil _ -> Nil }
}
",
    ),
    #(
      "helper",
      "pub const xs = []
pub const ys = []
pub const zs = []
pub fn pin(x: List(a)) {
  case x { _ if x == xs -> Nil _ -> Nil }
}
",
    ),
    #(
      "second",
      "import helper.{xs, zs}
pub fn link() {
  case True { _ if xs == zs -> Nil _ -> Nil }
}
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(List(a)) -> List(b)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn constants_sharing_open_cells_share_a_pin_test() {
  // Probe `k_l_r2_b1_open_literal`.
  // `c` and `d` are read from `f` in its group and share its cells: `pin`'s
  // guard pins `c`, and `run`'s guard on `d` sees it. Both schemes stay
  // `fn(a) -> a`.
  let source =
    "pub const c = f
pub const d = f
pub fn f(x) {
  case True {
    _ if c == d -> x
    _ -> x
  }
}
pub fn pin() {
  let need = need_int
  case True {
    _ if c == need -> Nil
    _ -> Nil
  }
}
fn need_int(x: Int) { x }
pub fn run(g) {
  let _ = pin()
  case True {
    _ if g == d -> Nil
    _ -> Nil
  }
}
"
  let modules = []
  signature(source, modules, "f") |> should.equal("fn(a) -> a")
  signature(source, modules, "pin") |> should.equal("fn() -> Nil")
  signature(source, modules, "run") |> should.equal("fn(fn(Int) -> Int) -> Nil")
  constant(source, modules, "c") |> should.equal("fn(a) -> a")
  constant(source, modules, "d") |> should.equal("fn(a) -> a")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn qualified_guard_select_reads_the_scheme_test() {
  // Probe `k_l_r2_b2_qualified_guard`.
  // The bare reader sees the pin; the qualified `helper.xs` is a module
  // select over the instantiated scheme and does not.
  let source =
    "import helper.{xs}
pub fn qualified(x) {
  case x { _ if x == helper.xs -> x _ -> x }
}
pub fn bare(x) {
  case x { _ if x == xs -> x _ -> x }
}
"
  let modules = [
    #(
      "helper",
      "pub const xs = []
pub fn pin() {
  case True { _ if xs == [1] -> Nil _ -> Nil }
}
",
    ),
  ]
  signature(source, modules, "bare")
  |> should.equal("fn(List(Int)) -> List(Int)")
  signature(source, modules, "qualified")
  |> should.equal("fn(List(a)) -> List(a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn constant_update_shares_its_spread_literal_test() {
  // Probe `k_l_r4_b1_update_lives`.
  // `extra = Box(..base, flag: True)` keeps `base`'s unnamed field, cells
  // and all: a later guard pins `base`, and `extra`'s reader sees it. Both
  // schemes stay `Box(a)`.
  let source =
    "pub type Box(a) { Box(List(a), flag: Bool) }
pub const base = Box([], False)
pub const extra = Box(..base, flag: True)
pub fn pin() {
  let _ = extra
  case True { _ if base == Box([1], False) -> Nil _ -> Nil }
}
pub fn run(x) {
  let _ = pin()
  case x { _ if x == extra -> x _ -> x }
}
"
  let modules = []
  signature(source, modules, "pin") |> should.equal("fn() -> Nil")
  signature(source, modules, "run") |> should.equal("fn(Box(Int)) -> Box(Int)")
  constant(source, modules, "base") |> should.equal("Box(a)")
  constant(source, modules, "extra") |> should.equal("Box(a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn constant_update_shares_its_spread_literal_across_modules_test() {
  // Probe `k_l_r4_b2_update_lives`.
  // The same, along a fixed import chain.
  let source =
    "import pinner
import updates.{extra}
pub fn run(x) {
  let _ = pinner.pin()
  case x { _ if x == extra -> x _ -> x }
}
"
  let modules = [
    #(
      "helper",
      "pub type Box(a) { Box(List(a), flag: Bool) }
pub const base = Box([], False)
",
    ),
    #(
      "pinner",
      "import helper.{base, Box}
import updates
pub fn pin() {
  let _ = updates.extra
  case True { _ if base == Box([1], False) -> Nil _ -> Nil }
}
",
    ),
    #(
      "updates",
      "import helper
pub const extra = helper.Box(..helper.base, flag: True)
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Box(Int)) -> Box(Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn constant_update_binds_a_foreign_literal_test() {
  // Probe `k_l_r4_b2_update_pins_without_guard`.
  // `updates` has no guard: its update's explicit field binds `helper.base`'s
  // element through the kept field, and the binding reaches the consumer.
  let source =
    "import helper.{base}
import updates
pub fn run(x) {
  let _ = updates.extra
  case x { _ if x == base -> x _ -> x }
}
"
  let modules = [
    #(
      "helper",
      "pub type Box(a) { Box(List(a), item: a) }
pub const base = Box([], [])
",
    ),
    #(
      "updates",
      "import helper
pub const extra = helper.Box(..helper.base, item: [1])
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(Box(List(Int))) -> Box(List(Int))")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pin_reaches_through_a_bridge_test() {
  // Probe `k_l_r5_b2_invalidate_before`.
  // The pinner binds `shared.xs`, the bridge imports the pinner, and the
  // consumer behind the bridge sees the pin.
  let source =
    "import bridge
import shared.{xs}
pub fn run(x) {
  let _ = bridge.ready()
  case x { _ if x == xs -> x _ -> x }
}
"
  let modules = [
    #(
      "bridge",
      "import pinner
pub fn ready() { pinner.pin() }
",
    ),
    #(
      "pinner",
      "import shared.{xs}
pub fn pin() { case True { _ if xs == [1] -> Nil _ -> Nil } }
",
    ),
    #(
      "shared",
      "pub const xs = []
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(List(Int)) -> List(Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn no_pin_no_binding_test() {
  // Probe `k_l_r5_b2_invalidate_after`.
  // The same program without the pin: the consumer's reader stays generic.
  let source =
    "import bridge
import shared.{xs}
pub fn run(x) {
  let _ = bridge.ready()
  case x { _ if x == xs -> x _ -> x }
}
"
  let modules = [
    #(
      "bridge",
      "import pinner
pub fn ready() { pinner.pin() }
",
    ),
    #(
      "pinner",
      "pub fn pin() { Nil }
",
    ),
    #(
      "shared",
      "pub const xs = []
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(List(a)) -> List(a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn constant_update_respecializes_its_parameters_test() {
  // Probe `k_l_r5_r17_update_respecializes`.
  // The update's result is a separate instance of the constructor, joined
  // to the spread only through the copied fields, so an overwritten field
  // may change a parameter.
  let source =
    "pub type Box(a) { Box(item: a, flag: Bool) }
pub const base = Box(\"old\", False)
pub const extra = Box(..base, item: 1)
pub fn run() { #(base, extra) }
"
  let modules = []
  signature(source, modules, "run")
  |> should.equal("fn() -> #(Box(String), Box(Int))")
  constant(source, modules, "base") |> should.equal("Box(String)")
  constant(source, modules, "extra") |> should.equal("Box(Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn overwritten_field_never_binds_the_spread_test() {
  // Probe `k_l_r5_r17_overwritten_stays_independent`.
  // The update's explicit field is not copied, so it never binds the
  // spread's literal: a later reader of the spread stays generic.
  let source =
    "pub type Box(a) { Box(item: a, flag: Bool) }
pub const base = Box([], False)
pub const extra = Box(..base, item: [1])
pub fn run(x) {
  let _ = extra
  case x { _ if x == base -> x _ -> x }
}
"
  let modules = []
  signature(source, modules, "run")
  |> should.equal("fn(Box(List(a))) -> Box(List(a))")
  constant(source, modules, "base") |> should.equal("Box(List(a))")
  constant(source, modules, "extra") |> should.equal("Box(List(Int))")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn narrowed_constant_is_a_local_test() {
  // Probe `k_l_rv1_narrowed_constant`.
  // A subject the clause narrows is rebound as a local, whatever it was
  // (`pattern.rs:229-235`): the guard reads the narrowed `base` at its
  // scheme, not at the literal `helper`'s `pin` pinned.
  let source =
    "import helper.{Box, base}

pub fn run() {
  case base {
    Box(..) if base == Box([\"s\"]) -> 1
    _ -> 0
  }
}
"
  let modules = [
    #(
      "helper",
      "pub type Container(a) {
  Box(value: a)
  Other
}

pub const base = Box([])

pub fn pin() {
  case True {
    _ if base == Box([1]) -> Nil
    _ -> Nil
  }
}
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn narrowed_local_constant_is_a_local_test() {
  // Probe `k_l_rv1_narrowed_constant_local`.
  // The same in the defining module, where PR K's shared guard copy was
  // pinned too.
  let source =
    "pub type Container(a) {
  Box(value: a)
  Other
}

pub const base = Box([])

pub fn pin() {
  case True {
    _ if base == Box([1]) -> Nil
    _ -> Nil
  }
}

pub fn run() {
  case base {
    Box(..) if base == Box([\"s\"]) -> 1
    _ -> 0
  }
}
"
  let modules = []
  signature(source, modules, "pin") |> should.equal("fn() -> Nil")
  signature(source, modules, "run") |> should.equal("fn() -> Int")
  constant(source, modules, "base") |> should.equal("Container(List(a))")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pin_reaches_through_a_bridge_update_test() {
  // Probe `k_l_rv1_bridge_update`.
  // `bridge`'s update of `base` shares its cells and `pin` pins them, so the
  // importer sees the pin through `extra` alone; the compiler's group order
  // infers `pin` before `extra`, so `extra` itself is `Box(Int)`.
  let source =
    "import bridge.{extra}

pub fn read(b) {
  case b {
    _ if b == extra -> b
    _ -> b
  }
}

pub fn scheme() {
  extra
}
"
  let modules = [
    #(
      "bridge",
      "import helper.{Box, base}

pub const extra = Box(..base, n: 1)

pub fn pin() {
  case True {
    _ if base == Box([1], 0) -> Nil
    _ -> Nil
  }
}
",
    ),
    #(
      "helper",
      "pub type Box(a) {
  Box(items: List(a), n: Int)
}

pub const base = Box([], 0)
",
    ),
  ]
  signature(source, modules, "read") |> should.equal("fn(Box(Int)) -> Box(Int)")
  signature(source, modules, "scheme") |> should.equal("fn() -> Box(Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pin_made_inside_a_speculated_argument_test() {
  // Probe `k_l_rv1_spec_pin`.
  // A guard inside a speculated callback ties `xs`'s element to `n`, and the
  // callback's real pass makes `n` an `Int`: the link is kept, so `read`
  // sees `List(Int)`.
  let source =
    "pub const xs = []

pub fn pin() {
  fn(f) { f(1) }(fn(n) {
    case True {
      _ if xs == [n] -> Nil
      _ -> Nil
    }
  })
}

pub fn read(l) {
  case l {
    _ if l == xs -> l
    _ -> l
  }
}
"
  let modules = []
  signature(source, modules, "pin") |> should.equal("fn() -> Nil")
  signature(source, modules, "read")
  |> should.equal("fn(List(Int)) -> List(Int)")
  constant(source, modules, "xs") |> should.equal("List(a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn assert_narrowed_constant_is_a_local_test() {
  // Probe `k_l_rv2_assert_narrowed_constant`.
  // A `let assert` narrows an imported constant as a clause does: `base` is
  // then a local, read at its scheme, so `helper`'s pin does not reach it.
  let source =
    "import helper.{Box, base}

pub fn run() {
  let assert Box(..) = base
  case True {
    _ if base == Box([\"s\"]) -> base.value
    _ -> []
  }
}
"
  let modules = [
    #(
      "helper",
      "pub type Container(a) {
  Box(value: a)
  Other
}

pub const base = Box([])

pub fn pin() {
  case True {
    _ if base == Box([1]) -> Nil
    _ -> Nil
  }
}
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> List(a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn narrowed_function_is_a_local_test() {
  // Probe `k_l_rv5_narrowed_function_subject`.
  // A narrowed subject is a local whatever its type (`pattern.rs:206-235`).
  // In speculation the tuple pattern meets the module's `String`, so
  // `value` is the module function, and `B(..)` rebinds it as a local: the
  // guard's `value.field` is a record access that recovers fresh, not the
  // imported module `value`'s `Int`, and `x` is left for the real pass.
  let source =
    "import helper as r
import value

pub type T {
  A
  B(field: String)
}

pub type Row {
  Row(field: #(T))
}

fn value() {
  Nil
}

pub fn run(x) {
  fn(cb) { cb(Row(#(B(\"s\")))) }(fn(r) {
    case r.field {
      #(value) ->
        case value {
          B(..) if x == value.field -> Nil
          _ -> Nil
        }
    }
  })
  let _ = value
  x
}
"
  let modules = [
    #(
      "helper",
      "pub const field = 0
",
    ),
    #(
      "value",
      "pub const field = 0
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(String) -> String")
  repeated_spans(source, modules) |> should.equal([])
}

// Annotate `modules` (path and source) as one package, in `order`, and read
// `name`'s signature in `root`; every module must be complete.
fn package_signature(
  modules: List(#(String, String)),
  order: List(String),
  root: String,
  name: String,
) -> String {
  let parsed =
    list.map(order, fn(path) {
      let assert Ok(text) = list.key_find(modules, path)
      let assert Ok(module) = glance.module(text)
      #(path, module)
    })
  let results =
    girard.annotate_package(parsed, probe_support.options_with(modules))
  list.each(order, fn(path) {
    let assert Ok(result) = dict.get(results, path)
    girard.is_complete(result) |> should.be_true
  })
  let assert Ok(result) = dict.get(results, root)
  scheme_of(result.annotated.functions, name)
}

// `name`'s signature in `source` on a fresh cache, then again on the cache
// that run left, with a resolver that has none of the imports: the second run
// reads every import from the cache.
fn cached_signatures(
  source: String,
  modules: List(#(String, String)),
  name: String,
) -> #(String, String) {
  let #(fresh, cache) =
    girard.annotate_with_cache(
      source,
      probe_support.options_with(modules),
      girard.new_cache(),
    )
  let assert Ok(fresh) = fresh
  let #(cached, _) =
    girard.annotate_with_cache(source, probe_support.options_with([]), cache)
  let assert Ok(cached) = cached
  #(scheme_of(fresh.functions, name), scheme_of(cached.functions, name))
}

pub fn shared_import_pin_holds_in_a_package_and_a_cache_test() {
  // Probe `k_r7_constant_shared_import`, through `annotate_package` in
  // dependency order and in reverse, and through `annotate_with_cache` on a
  // fresh cache and on a cache hit: the binding travels in `pinning`'s
  // interface, so every path gives the consumer 1.19.2's signature.
  let modules = [
    #(
      "helper",
      "pub const xs = []

pub fn pin() {
  case True {
    _ if xs == [] -> Nil
    _ -> Nil
  }
}
",
    ),
    #(
      "pinning",
      "import helper.{xs}

pub fn pin() {
  case True {
    _ if xs == [1] -> Nil
    _ -> Nil
  }
}
",
    ),
    #(
      "consumer",
      "import helper.{xs}
import pinning

pub fn run(x) {
  pinning.pin()
  case x {
    _ if x == xs -> x
    _ -> x
  }
}
",
    ),
  ]
  let expected = "fn(List(Int)) -> List(Int)"
  package_signature(
    modules,
    ["helper", "pinning", "consumer"],
    "consumer",
    "run",
  )
  |> should.equal(expected)
  package_signature(
    modules,
    ["consumer", "pinning", "helper"],
    "consumer",
    "run",
  )
  |> should.equal(expected)
  let assert Ok(consumer) = list.key_find(modules, "consumer")
  cached_signatures(consumer, modules, "run")
  |> should.equal(#(expected, expected))
}

pub fn bridged_links_hold_in_a_package_and_a_cache_test() {
  // Probe `k_l_r1_b2_flexible_bridge` through the same four paths: the
  // consumer imports neither `helper` nor its constants, and the variables'
  // identities still meet.
  let modules = [
    #(
      "helper",
      "pub const xs = []
pub const ys = []
pub fn link() {
  case True { _ if xs == ys -> Nil _ -> Nil }
}
",
    ),
    #(
      "first",
      "import helper.{xs}
pub const ls = []
pub fn link() {
  case True { _ if xs == ls -> Nil _ -> Nil }
}
",
    ),
    #(
      "second",
      "import helper.{ys}
pub const rs = []
pub fn link() {
  case True { _ if ys == rs -> Nil _ -> Nil }
}
",
    ),
    #(
      "consumer",
      "import first.{ls}
import second.{rs}
pub fn run(x) {
  case x {
    _ if ls == [1] && x == rs -> x
    _ -> x
  }
}
",
    ),
  ]
  let expected = "fn(List(Int)) -> List(Int)"
  package_signature(
    modules,
    ["helper", "first", "second", "consumer"],
    "consumer",
    "run",
  )
  |> should.equal(expected)
  package_signature(
    modules,
    ["consumer", "second", "first", "helper"],
    "consumer",
    "run",
  )
  |> should.equal(expected)
  let assert Ok(consumer) = list.key_find(modules, "consumer")
  cached_signatures(consumer, modules, "run")
  |> should.equal(#(expected, expected))
}

pub fn warm_cache_follows_a_removed_pin_once_importers_are_invalidated_test() {
  // Probes `k_l_r5_b2_invalidate_before` and `_after`: the pinner's body
  // changes, and no signature does, yet the consumer behind the bridge goes
  // from `List(Int)` to `List(a)`. A binding is part of an interface, so
  // after invalidating the pinner and the bridge the warm cache agrees with a
  // fresh one; invalidating the pinner alone leaves the bridge's interface,
  // and the binding it carries, in the cache.
  let shared = #("shared", "pub const xs = []\n")
  let bridge = #("bridge", "import pinner\npub fn ready() { pinner.pin() }\n")
  let pinning =
    "import shared.{xs}
pub fn pin() { case True { _ if xs == [1] -> Nil _ -> Nil } }
"
  let consumer =
    "import bridge
import shared.{xs}
pub fn run(x) {
  let _ = bridge.ready()
  case x { _ if x == xs -> x _ -> x }
}
"
  let before =
    probe_support.options_with([shared, bridge, #("pinner", pinning)])
  let after =
    probe_support.options_with([
      shared,
      bridge,
      #("pinner", "pub fn pin() { Nil }\n"),
    ])
  let #(warm, cache) =
    girard.annotate_with_cache(consumer, before, girard.new_cache())
  let assert Ok(warm) = warm
  scheme_of(warm.functions, "run")
  |> should.equal("fn(List(Int)) -> List(Int)")
  let invalidated =
    cache |> girard.invalidate("pinner") |> girard.invalidate("bridge")
  let #(rewarmed, _) = girard.annotate_with_cache(consumer, after, invalidated)
  let assert Ok(rewarmed) = rewarmed
  let assert Ok(fresh) = girard.annotate(consumer, after)
  scheme_of(rewarmed.functions, "run") |> should.equal("fn(List(a)) -> List(a)")
  scheme_of(fresh.functions, "run") |> should.equal("fn(List(a)) -> List(a)")
  let #(stale, _) =
    girard.annotate_with_cache(
      consumer,
      after,
      girard.invalidate(cache, "pinner"),
    )
  let assert Ok(stale) = stale
  scheme_of(stale.functions, "run")
  |> should.equal("fn(List(Int)) -> List(Int)")
}

pub fn conflicting_bindings_keep_the_first_import_test() {
  // Two imports bind one literal variable incompatibly, a program 1.19.2
  // rejects in whichever it compiles second. girard infers each with its own
  // imports, so both are typed, and the importer replays the first import's
  // binding in source order and drops the second's: its definitions still
  // type, the unrelated one included.
  let modules = [
    #("helper", "pub const xs = []\n"),
    #(
      "ints",
      "import helper.{xs}
pub fn pin() { case True { _ if xs == [1] -> Nil _ -> Nil } }
",
    ),
    #(
      "strings",
      "import helper.{xs}
pub fn pin() { case True { _ if xs == [\"s\"] -> Nil _ -> Nil } }
",
    ),
  ]
  let source =
    "import helper.{xs}
import ints
import strings
pub fn run(x) {
  case x { _ if x == xs -> x _ -> x }
}
pub fn unrelated() { #(ints.pin(), strings.pin()) }
"
  signature(source, modules, "run")
  |> should.equal("fn(List(Int)) -> List(Int)")
  signature(source, modules, "unrelated") |> should.equal("fn() -> #(Nil, Nil)")
}

pub fn a_relayed_binding_keeps_what_another_import_added_test() {
  // `pinner` binds the element of `xs`'s literal to `List(a)`. `relay` only
  // passes that binding on; `refiner` imports `pinner` too and binds its `a`
  // to `Int`. Through `relay` first, the importer skips `refiner`'s copy of
  // the binding it already holds and gets `Int` from `a`'s own link. 1.19.2:
  // `fn(List(List(Int))) -> List(List(Int))`, in either import order.
  let modules = [
    #("helper", "pub const xs = []\n"),
    #(
      "pinner",
      "import helper.{xs}
pub fn pin() { case True { _ if xs == [[]] -> Nil _ -> Nil } }
",
    ),
    #("relay", "import pinner\npub fn run() { pinner.pin() }\n"),
    #(
      "refiner",
      "import helper.{xs}
import pinner
pub fn run() {
  let _ = pinner.pin()
  case True { _ if xs == [[1]] -> Nil _ -> Nil }
}
",
    ),
  ]
  let body =
    "import helper.{xs}
pub fn run(x) {
  let _ = #(relay.run(), refiner.run())
  case x { _ if x == xs -> x _ -> x }
}
"
  signature("import relay\nimport refiner\n" <> body, modules, "run")
  |> should.equal("fn(List(List(Int))) -> List(List(Int))")
  signature("import refiner\nimport relay\n" <> body, modules, "run")
  |> should.equal("fn(List(List(Int))) -> List(List(Int))")
}

pub fn independent_bindings_of_one_variable_meet_test() {
  // `a_pin` and `z_pin` do not import each other, and each binds the element
  // of `xs`'s literal on its own: to `List(a)` and to `List(Int)`. The two
  // bindings have two origins, so the importer unifies them in either import
  // order, as the compiler's one cell takes both whichever binds it first.
  // 1.19.2: `fn(List(List(Int))) -> List(List(Int))`.
  let modules = [
    #("helper", "pub const xs = []\n"),
    #(
      "a_pin",
      "import helper.{xs}
pub fn pin() { case True { _ if xs == [[]] -> Nil _ -> Nil } }
",
    ),
    #(
      "z_pin",
      "import helper.{xs}
pub fn pin() { case True { _ if xs == [[1]] -> Nil _ -> Nil } }
",
    ),
  ]
  let body =
    "import helper.{xs}
pub fn run(x) {
  let _ = #(a_pin.pin(), z_pin.pin())
  case x { _ if x == xs -> x _ -> x }
}
"
  signature("import a_pin\nimport z_pin\n" <> body, modules, "run")
  |> should.equal("fn(List(List(Int))) -> List(List(Int))")
  signature("import z_pin\nimport a_pin\n" <> body, modules, "run")
  |> should.equal("fn(List(List(Int))) -> List(List(Int))")
}

pub fn binding_outside_the_import_closure_is_not_seen_test() {
  // Probe `k_l2_constant_unimported_a` (recorded as `known`). The consumer
  // does not import `a_pin`, which pins `xs`. 1.19.2 compiles `a_pin` first
  // because of its name and gives `fn(List(Int)) -> List(Int)`; girard infers
  // each module with the bindings of its own import closure only, so the
  // consumer's reader stays generic.
  let modules = [
    #("helper", "pub const xs = []\n"),
    #(
      "a_pin",
      "import helper.{xs}

pub fn pin() {
  case True {
    _ if xs == [1] -> Nil
    _ -> Nil
  }
}
",
    ),
  ]
  let source =
    "import helper.{xs}

pub fn run(x) {
  case x {
    _ if x == xs -> x
    _ -> x
  }
}
"
  signature(source, modules, "run") |> should.equal("fn(List(a)) -> List(a)")
}

pub fn constant_annotation_in_a_group_starts_its_own_scope_test() {
  // Probe `k_l_rv1_group_scope`. A constant is inferred with a scope of its own, empty however it is
  // entered (`analyse.rs:446-453`). `c` is inferred in `f`'s group, after
  // `f`'s body, and its annotation's `a` is a generic of its own, not `f`'s
  // signature variable: reading `f` copies `f`'s, and both publish their own
  // `fn(a) -> List(a)`, as 1.19.2 does.
  let source =
    "pub const c: fn(a) -> List(a) = f

pub fn f(x: a) -> List(a) {
  let _ = c
  [x]
}
"
  constant(source, [], "c") |> should.equal("fn(a) -> List(a)")
  signature(source, [], "f") |> should.equal("fn(a) -> List(a)")
}
