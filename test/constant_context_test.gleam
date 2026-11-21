// Probe tests for the constant context.
//
// The compiler parses `name.member` in a constant initializer, and in a guard
// subtree it parses as a constant, as module access, never as record access.
// Every test here is a probe from girard's PR J inventory
// (`.misc/pr-j/PROBES.md`), run through the normal entry point with the
// compiler's answer pinned. Each test names the probe it came from, under
// `.misc/pr-j/inputs/`.

import girard
import gleam/list
import gleeunit/should
import probe_support.{annotations, constant, error_with, resolution, signature}

// Constants
//
// `name.member` in a constant initializer reads the module member.

pub fn constant_qualifier_reads_the_module_test() {
  // Probes `m2/i_qualified_constant` (both declaration orders) and
  // `m2/i_shadow/qualified_constant`: `cfg.value` is `helper.value`, an `Int`,
  // although a local `const cfg` record has a `value` field. `main` read the
  // field whenever its order had inferred `cfg` first.
  let probes = [
    #(
      "import helper as cfg

pub type Config {
  Config(value: String)
}

pub const cfg = Config(\"local\")

pub const amount = cfg.value
",
      [
        #(
          "helper",
          "pub const width = \"module\"

pub const value = 4
",
        ),
      ],
    ),
    #(
      "import helper as cfg

pub type Config {
  Config(value: String)
}

pub const amount = cfg.value

pub const cfg = Config(\"local\")
",
      [
        #(
          "helper",
          "pub const width = \"module\"

pub const value = 4
",
        ),
      ],
    ),
    #(
      "import helper as cfg

pub type Config {
  Config(value: String)
}

pub const cfg = Config(\"local\")
pub const amount = cfg.value
",
      [
        #(
          "helper",
          "pub fn width() -> Int {
  16
}

pub const depth = #(8, width)

pub const value = 4
",
        ),
      ],
    ),
  ]
  list.each(probes, fn(probe) {
    let #(source, modules) = probe
    constant(source, modules, "amount") |> should.equal("Int")
    constant(source, modules, "cfg") |> should.equal("Config")
    resolution(source, modules, "cfg.value", 1)
    |> should.equal(girard.ModuleConstant("helper", "value"))
  })
}

pub fn constant_context_missing_export_is_rejected_test() {
  // Probe `m2/x_i_review_missing_export`: in a constant, a module with no such
  // member is an error, never a fall-through to record access.
  let source =
    "import helper as cfg
pub const example = cfg.missing
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"

pub const value = 4

pub type Box {
  Box(name: String)
}
",
    ),
  ]
  let assert girard.NoSuchExport("cfg", "missing") = error_with(source, modules)
}

pub fn constant_context_missing_module_is_rejected_test() {
  // Probe `m2/x_i_review_missing_module`: in a constant, a name that is no
  // module is an unknown module.
  let source =
    "pub const example = cfg.missing
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"

pub const value = 4

pub type Box {
  Box(name: String)
}
",
    ),
  ]
  let assert girard.UnknownModule("cfg") = error_with(source, modules)
}

// Guards
//
// A guard subtree the compiler parses as a constant (a tuple, a list, a
// qualified constructor, a record update, ...) reads `name.member` as module
// access. A direct guard field access stays record-first.

pub fn guard_tuple_reads_the_module_after_expose_test() {
  // Probes `m2/i_guard` and `m2/x_h_round2_guard` (the same module): in the
  // compiler's order `cfg|expose|guarded` the local `cfg` is in scope when
  // `guarded` is inferred, and `#(cfg.value)` still reads `helper.value`. The
  // compiler's order without the constant context failed with `type mismatch:
  // Int vs String`.
  let source =
    "import helper as cfg

pub type Config {
  Config(value: String)
}

pub fn expose() {
  cfg
}

pub fn guarded(x: #(Int)) {
  case x {
    _ if x == #(cfg.value) -> 1
    _ -> 0
  }
}

pub const cfg = Config(\"local\")
"
  let modules = [
    #(
      "helper",
      "pub const value = 4
",
    ),
  ]
  signature(source, modules, "guarded") |> should.equal("fn(#(Int)) -> Int")
  signature(source, modules, "expose") |> should.equal("fn() -> Config")
  resolution(source, modules, "cfg.value", 1)
  |> should.equal(girard.ModuleConstant("helper", "value"))
}

pub fn guard_tuple_reads_the_module_before_expose_test() {
  // Probe `m2/i_guard_redeclared`: the other declaration order. `main` failed
  // with `type mismatch: Int vs String`.
  let source =
    "import helper as cfg

pub type Config {
  Config(value: String)
}

pub fn guarded(x: #(Int)) {
  case x {
    _ if x == #(cfg.value) -> 1
    _ -> 0
  }
}

pub fn expose() {
  cfg
}

pub const cfg = Config(\"local\")
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"

pub const value = 4
",
    ),
  ]
  signature(source, modules, "guarded") |> should.equal("fn(#(Int)) -> Int")
  resolution(source, modules, "cfg.value", 1)
  |> should.equal(girard.ModuleConstant("helper", "value"))
}

pub fn guard_record_update_reads_the_module_test() {
  // Probe `m2/i_guard_update`: a qualified record update in a guard is a
  // constant, so its base and field read `helper`, although the parameter `cfg`
  // is a local `Config`. `main` failed with `type mismatch: String vs Int`.
  let source =
    "import helper as cfg

pub type Config {
  Config(value: String)
}

pub fn guarded(x: cfg.Box, cfg: Config) {
  let _ = cfg
  case x {
    _ if x == cfg.Box(..cfg.base, size: cfg.value) -> 1
    _ -> 0
  }
}
"
  let modules = [
    #(
      "helper",
      "pub type Box {
  Box(name: String, size: Int)
}

pub const base = Box(\"original\", 0)

pub const value = 4
",
    ),
  ]
  signature(source, modules, "guarded")
  |> should.equal("fn(Box, Config) -> Int")
  resolution(source, modules, "cfg.base", 1)
  |> should.equal(girard.ModuleConstant("helper", "base"))
  resolution(source, modules, "cfg.value", 1)
  |> should.equal(girard.ModuleConstant("helper", "value"))
}

pub fn guard_qualified_constructor_reads_the_module_test() {
  // Probe `m2/x_i_review_constructor_guard`: `cfg.Box(name: "module")` in a
  // guard is a qualified constant record: the constructor is `helper.Box`, and
  // the local `cfg` gets no expression type.
  let source =
    "import helper as cfg

pub type Config {
  Config(value: String)
}

pub fn guarded(x: cfg.Box, cfg: Config) {
  let _ = cfg
  case x {
    _ if x == cfg.Box(name: \"module\") -> 1
    _ -> 0
  }
}
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"

pub const value = 4

pub type Box {
  Box(name: String)
}
",
    ),
  ]
  signature(source, modules, "guarded")
  |> should.equal("fn(Box, Config) -> Int")
  resolution(source, modules, "cfg.Box", 2)
  |> should.equal(girard.Constructor("helper", "Box"))
  annotations(source, modules, "cfg", 5) |> should.equal([])
}

pub fn guard_direct_qualifier_on_a_function_reads_the_module_test() {
  // Probe `m2/i_shadow/guard_constants`: beside a top-level `fn m`, a direct
  // guard `m.value` (record-first, but a function has no fields) and a tuple
  // `#(m.value)` (a constant) both read `helper.value`.
  let source =
    "import helper as m

pub fn plain(x: Int) {
  case x {
    _ if x == m.value -> 1
    _ -> 0
  }
}

pub fn nested(x: #(Int)) {
  case x {
    _ if x == #(m.value) -> 1
    _ -> 0
  }
}

pub fn m() { 4 }
"
  let modules = [
    #(
      "helper",
      "pub fn width() -> Int {
  16
}

pub const depth = #(8, width)

pub const value = 4
",
    ),
  ]
  signature(source, modules, "plain") |> should.equal("fn(Int) -> Int")
  signature(source, modules, "nested") |> should.equal("fn(#(Int)) -> Int")
  resolution(source, modules, "m.value", 1)
  |> should.equal(girard.ModuleConstant("helper", "value"))
  resolution(source, modules, "m.value", 2)
  |> should.equal(girard.ModuleConstant("helper", "value"))
}

pub fn guard_nested_qualifier_reads_the_module_test() {
  // Probe `m2/i_shadow/guard_nested_only`: the tuple alone, so a direct
  // reference cannot have brought `m` in early.
  let source =
    "import helper as m

pub fn nested(x: #(Int)) {
  case x {
    _ if x == #(m.value) -> 1
    _ -> 0
  }
}

pub fn m() { 4 }
"
  let modules = [
    #(
      "helper",
      "pub fn width() -> Int {
  16
}

pub const depth = #(8, width)

pub const value = 4
",
    ),
  ]
  signature(source, modules, "nested") |> should.equal("fn(#(Int)) -> Int")
  resolution(source, modules, "m.value", 1)
  |> should.equal(girard.ModuleConstant("helper", "value"))
}

pub fn guard_direct_access_reads_the_local_record_test() {
  // Probes `m2/x_i_review_direct_expose_first` and
  // `m2/x_i_review_direct_guard_first`: the tuple `#(cfg.value)` reads
  // `helper.value`, while the direct guard `cfg.value` keeps the record-first
  // rule and reads the top-level `cfg` record's field, in both orders.
  let probes = [
    #(
      "import helper as cfg

pub type Config {
  Config(value: String)
}

pub fn expose() {
  cfg
}

pub fn guarded(x: #(Int)) {
  case x {
    _ if x == #(cfg.value) -> 1
    _ if cfg.value == \"local\" -> 2
    _ -> 0
  }
}

pub const cfg = Config(\"local\")
",
      [
        #(
          "helper",
          "pub const width = \"module\"

pub const value = 4

pub type Box {
  Box(name: String)
}
",
        ),
      ],
    ),
    #(
      "import helper as cfg

pub type Config {
  Config(value: String)
}

pub fn guarded(x: #(Int)) {
  case x {
    _ if x == #(cfg.value) -> 1
    _ if cfg.value == \"local\" -> 2
    _ -> 0
  }
}

pub fn expose() {
  cfg
}

pub const cfg = Config(\"local\")
",
      [
        #(
          "helper",
          "pub const width = \"module\"

pub const value = 4

pub type Box {
  Box(name: String)
}
",
        ),
      ],
    ),
  ]
  list.each(probes, fn(probe) {
    let #(source, modules) = probe
    signature(source, modules, "guarded") |> should.equal("fn(#(Int)) -> Int")
    resolution(source, modules, "cfg.value", 1)
    |> should.equal(girard.ModuleConstant("helper", "value"))
    resolution(source, modules, "cfg.value", 2)
    |> should.equal(girard.RecordField(girard.Named("", "Config", []), "value"))
  })
}

pub fn guard_lexical_receiver_keeps_the_record_test() {
  // Probe `m2/x_i_review_guard_scope`: with a `cfg: Config` parameter, the
  // tuple reads `helper.value`, and the direct guard and both clause bodies read
  // the parameter's field, so the context ends with the guard.
  let source =
    "import helper as cfg

pub type Config {
  Config(value: String)
}

pub fn guarded(x: #(Int), cfg: Config) {
  case x {
    _ if x == #(cfg.value) -> cfg.value
    _ if cfg.value == \"local\" -> cfg.value
    _ -> \"\"
  }
}
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"

pub const value = 4

pub type Box {
  Box(name: String)
}
",
    ),
  ]
  signature(source, modules, "guarded")
  |> should.equal("fn(#(Int), Config) -> String")
  resolution(source, modules, "cfg.value", 1)
  |> should.equal(girard.ModuleConstant("helper", "value"))
  resolution(source, modules, "cfg.value", 2)
  |> should.equal(girard.RecordField(girard.Named("", "Config", []), "value"))
  resolution(source, modules, "cfg.value", 3)
  |> should.equal(girard.RecordField(girard.Named("", "Config", []), "value"))
  resolution(source, modules, "cfg.value", 4)
  |> should.equal(girard.RecordField(girard.Named("", "Config", []), "value"))
}

pub fn guard_constant_does_not_propagate_early_test() {
  // Probe `m2/i_r3_i1_propagate`: the guard constant reads `values.value`, a
  // `helper.Record`, and so ties `record()`'s return to it in `seed`. The
  // compiler checks `read` first (order `read,seed,record`), while `record()` is
  // still unknown, so `m.width` is the imported constant.
  let source =
    "import helper as m
import values as cfg

pub type Config(a) {
  Config(value: a)
}

pub fn record() {
  let _ = seed
  m.Record(10)
}

pub fn read() -> String {
  let m = record()
  m.width
}

pub fn seed(cfg) -> Nil {
  let Config(_) = cfg
  let x = #(record())
  let _ = case x {
    _ if x == #(cfg.value) -> 1
    _ -> 0
  }
  let _ = read
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub type Record {
  Record(width: Int)
}

pub const width = \"module\"
",
    ),
    #(
      "values",
      "import helper

pub const value = helper.Record(0)
",
    ),
  ]
  signature(source, modules, "read") |> should.equal("fn() -> String")
  signature(source, modules, "record") |> should.equal("fn() -> Record")
  signature(source, modules, "seed") |> should.equal("fn(Config(a)) -> Nil")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.ModuleConstant("helper", "width"))
  resolution(source, modules, "cfg.value", 1)
  |> should.equal(girard.ModuleConstant("values", "value"))
}

pub fn guard_constant_does_not_propagate_early_same_type_test() {
  // Probe `m2/i_r3_i1_same_type`: the same with an `Int` import. The compiled
  // `runner` prints `20`, the imported constant.
  let source =
    "import helper as m
import values as cfg

pub type Config(a) {
  Config(value: a)
}

pub fn record() {
  let _ = seed
  m.Record(10)
}

pub fn read() -> Int {
  let m = record()
  m.width
}

pub fn seed(cfg) -> Nil {
  let Config(_) = cfg
  let x = #(record())
  let _ = case x {
    _ if x == #(cfg.value) -> 1
    _ -> 0
  }
  let _ = read
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub type Record {
  Record(width: Int)
}

pub const width = 20
",
    ),
    #(
      "values",
      "import helper

pub const value = helper.Record(0)
",
    ),
  ]
  signature(source, modules, "read") |> should.equal("fn() -> Int")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.ModuleConstant("helper", "width"))
  resolution(source, modules, "cfg.value", 1)
  |> should.equal(girard.ModuleConstant("values", "value"))
}

// A module constant in a direct guard
//
// The compiler types a bare variable naming a module constant in a guard as
// the constant's stored literal (`infer_clause_guard_variable`,
// `type_/guard.rs:322-324`), not an instantiated copy (PR J review round 1).

pub fn guard_constant_variable_is_not_copied_test() {
  // A group ordered by the compiler as `c,b,a,provider`: `const c = provider`
  // shares `provider`'s parameter, which `b(x: t)` links to its own `t` by calling
  // `provider(x)` and `a(x, fn(_) { 1 })`. The guard `y == c` reads `c` at its
  // stored type, so `a`'s argument is tied to `t` too. 1.19.2 exports
  // `a: fn(a, fn(a) -> Int) -> Int`; copying `t` on the read gave
  // `fn(a, fn(b) -> Int) -> Int`.
  let source =
    "pub fn provider(p) {
  let _ = a
  p
}

pub const c = provider

pub fn b(x: t) {
  let _ = provider(x)
  a(x, fn(_) { 1 })
}

pub fn a(_x, y) {
  let _ = b
  case y {
    _ if y == c -> 1
    _ -> 0
  }
}
"
  signature(source, [], "a") |> should.equal("fn(a, fn(a) -> Int) -> Int")
  signature(source, [], "b") |> should.equal("fn(a) -> Int")
  signature(source, [], "provider") |> should.equal("fn(a) -> Int")
}

pub fn guard_generalized_constant_is_accepted_test() {
  // A generalized constant in a direct guard: 1.19.2 accepts `x == empty` for
  // `const empty = []` and `x: List(Int)`, its literal's element type unbound.
  let source =
    "const empty = []

pub fn check(x: List(Int)) -> Int {
  case x {
    _ if x == empty -> 1
    _ -> 0
  }
}
"
  signature(source, [], "check") |> should.equal("fn(List(Int)) -> Int")
}

pub fn guard_generalized_constant_reads_share_a_type_test() {
  // Every guard read of a generalized constant shares one literal: 1.19.2
  // exports `both: fn(List(a), List(a)) -> Int`, where a copy per read would give
  // `fn(List(a), List(b)) -> Int`.
  let source =
    "const empty = []

pub fn both(y, z) -> Int {
  case y {
    _ if y == empty && z == empty -> 1
    _ -> 0
  }
}
"
  signature(source, [], "both") |> should.equal("fn(List(a), List(a)) -> Int")
}
