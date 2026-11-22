// Probe tests for the compiler's dependency order and group inference.
//
// Every test here is a probe from girard's PR J inventory
// (`.misc/pr-j/PROBES.md`), run through the normal entry point with the
// compiler's answer pinned: the signatures Gleam 1.19.2's interface exports,
// and the resolution where it matters. Each test names the probe it came
// from, under `.misc/pr-j/inputs/`.

import girard
import gleeunit/should
import probe_support.{
  callee_resolution, constant, error_with, order, resolution, signature,
}

// PR G: references the old collector missed
//
// A definition read only by a bit-array size, a record-update shorthand, a
// pattern size or an alias-named qualifier is ordered before its reader, as
// the compiler's call graph orders it.

pub fn size_reads_a_constant_declared_after_test() {
  // Probe `m2/g_const_after`: a size option reads a constant declared later.
  // `main` reported `unbound variable: width`.
  let source =
    "pub fn run() {
  <<0:size(width)>>
}

const width = 8
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn() -> BitArray")
  constant(source, modules, "width") |> should.equal("Int")
}

pub fn constant_update_shorthand_in_a_cycle_test() {
  // Probe `m2/g_const_cycle`: a constant record update's shorthand reads a
  // function that reads the constant back. `main` reported `unbound variable:
  // render`.
  let source =
    "pub type F {
  F(n: Int, render: fn() -> Int)
}

const base = F(1, zero)

fn zero() -> Int {
  0
}

pub const updated = F(..base, render:)

fn render() -> Int {
  updated.n
}
"
  let modules = []
  signature(source, modules, "render") |> should.equal("fn() -> Int")
  constant(source, modules, "updated") |> should.equal("F")
  resolution(source, modules, "updated.n", 1)
  |> should.equal(girard.RecordField(girard.Named("", "F", []), "n"))
}

pub fn constant_update_shorthand_reads_a_constant_test() {
  // Probe `m2/g_const_update`. `main` reported `unbound variable: n`.
  let source =
    "pub type B {
  B(n: Int, m: Int)
}

const base = B(1, 2)

const n = 3

pub const updated = B(..base, n:)
"
  let modules = []
  constant(source, modules, "updated") |> should.equal("B")
}

pub fn update_shorthand_reads_a_constant_test() {
  // Probe `m2/g_defaults`. `main` reported `unbound variable: retries`.
  let source =
    "pub type Config {
  Config(retries: Int, timeout: Int)
}

const retries = 3

pub fn defaults(config: Config) -> Config {
  Config(..config, retries:)
}
"
  let modules = []
  signature(source, modules, "defaults") |> should.equal("fn(Config) -> Config")
}

pub fn size_option_reads_a_constant_test() {
  // Probe `m2/g_expr_const`: a size beside a unit option reads a constant.
  // `main` reported `unbound variable: size`.
  let source =
    "pub type Address {
  Address(BitArray)
}

const size = 20

pub fn zero() -> Address {
  Address(<<0:unit(8)-size(size)>>)
}
"
  let modules = []
  signature(source, modules, "zero") |> should.equal("fn() -> Address")
}

pub fn alias_qualifier_falls_back_to_the_constant_record_test() {
  // Probe `m2/g_fallback_priority`: `layout.width` with `import helper.{depth}
  // as layout` and a local `const layout` reads the local record's field.
  let source =
    "import helper.{depth} as layout

pub type Layout {
  Layout(width: Int)
}

const layout = Layout(8)

fn check() -> Int {
  layout.width
}

pub fn keep() -> Nil {
  let _ = check()
  let _ = layout
  Nil
}

const depth = #(8, check)

pub fn standalone() -> BitArray {
  <<0:size(depth.0)>>
}
"
  let modules = [
    #(
      "helper",
      "pub fn width() -> Int {
  16
}

pub const depth = #(8, width)
",
    ),
  ]
  signature(source, modules, "keep") |> should.equal("fn() -> Nil")
  signature(source, modules, "standalone") |> should.equal("fn() -> BitArray")
  resolution(source, modules, "layout.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Layout", []), "width"))
}

pub fn size_calls_a_function_declared_after_test() {
  // Probe `m2/g_fn_after`.
  let source =
    "pub fn aaa_run() {
  <<0:size(zzz_size())>>
}

fn zzz_size() -> Int {
  8
}
"
  let modules = []
  signature(source, modules, "aaa_run") |> should.equal("fn() -> BitArray")
}

pub fn size_calls_a_function_declared_before_test() {
  // Probe `m2/g_fn_before`. `main` reported `unbound variable: aaa_size`.
  let source =
    "fn aaa_size() -> Int {
  8
}

pub fn zzz_run() {
  <<0:size(aaa_size())>>
}
"
  let modules = []
  signature(source, modules, "zzz_run") |> should.equal("fn() -> BitArray")
}

pub fn size_call_reads_the_local_function_over_an_import_test() {
  // Probe `m2/g_import_shadow`: the size calls the local `width`, not the
  // unqualified import it shadows. `main` resolved `helper.width`.
  let source =
    "import helper.{width}

fn width() -> Int {
  16
}

pub fn run() -> BitArray {
  <<0:size(width())>>
}
"
  let modules = [
    #(
      "helper",
      "pub fn width() -> Int {
  16
}

pub const depth = #(8, width)
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> BitArray")
  callee_resolution(source, modules, "width()", 2)
  |> should.equal(girard.ModuleFn("", "width"))
}

pub fn alias_qualifier_reads_the_local_constant_test() {
  // Probe `m2/g_independent_alias`: a top-level constant named like a module
  // alias is a dependency of `layout.width`.
  let source =
    "import helper as layout

pub type Layout {
  Layout(width: Int)
}

const layout = Layout(8)

fn check() -> Int {
  layout.width
}

fn child() -> Int {
  check()
}

fn bits() -> BitArray {
  let _ = run()
  <<0:size(child())>>
}

pub fn run() -> Nil {
  let _ = child()
  let _ = layout
  let _ = bits()
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub fn width() -> Int {
  16
}

pub const depth = #(8, width)
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> Nil")
  resolution(source, modules, "layout.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Layout", []), "width"))
}

pub fn alias_qualifier_reads_the_local_constant_through_an_update_test() {
  // Probe `m2/g_independent_alias_update`.
  let source =
    "import helper as layout

pub type Layout {
  Layout(width: Int)
}

pub type Formatter {
  Formatter(child: fn() -> Int, other: Int)
}

const layout = Layout(8)

fn check() -> Int {
  layout.width
}

fn child() -> Int {
  check()
}

fn update() -> Formatter {
  let _ = run()
  let original = Formatter(fn() { 0 }, 0)
  Formatter(..original, child:)
}

pub fn run() -> Nil {
  let _ = child()
  let _ = layout
  let _ = update()
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub fn width() -> Int {
  16
}

pub const depth = #(8, width)
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> Nil")
  resolution(source, modules, "layout.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Layout", []), "width"))
}

pub fn size_call_through_a_group_reads_the_field_test() {
  // Probe `m2/g_late_new_size`.
  let source =
    "pub type Packet {
  Packet(width: Int)
}

fn build_bits(x: Bool) -> BitArray {
  let _ = run(x)
  <<0:size(read_width(x))>>
}

fn packet(x: Bool) -> Packet {
  let _ = run(x)
  Packet(8)
}

fn read_width(x: Bool) -> Int {
  packet(x).width
}

pub fn run(x: Bool) -> Nil {
  let _ = read_width(x)
  let _ = packet(x)
  let _ = build_bits(x)
  Nil
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(Bool) -> Nil")
  resolution(source, modules, "packet(x).width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Packet", []), "width"))
}

pub fn update_shorthand_through_a_group_reads_the_field_test() {
  // Probe `m2/g_late_new_update`.
  let source =
    "pub type Packet {
  Packet(width: Int)
}

pub type Formatter {
  Formatter(render: fn(Bool) -> Int, other: Int)
}

fn change_formatter(x: Bool) -> Formatter {
  let _ = run(x)
  let original = Formatter(fn(_) { 0 }, 0)
  Formatter(..original, render:)
}

fn packet(x: Bool) -> Packet {
  let _ = run(x)
  Packet(8)
}

fn render(x: Bool) -> Int {
  packet(x).width
}

pub fn run(x: Bool) -> Nil {
  let _ = render(x)
  let _ = packet(x)
  let _ = change_formatter(x)
  Nil
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(Bool) -> Nil")
  resolution(source, modules, "packet(x).width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Packet", []), "width"))
}

pub fn size_qualifier_reads_a_constant_record_test() {
  // Probe `m2/g_late_qualifier`. `main` reported `unbound variable: layout`.
  let source =
    "pub type Layout {
  Layout(width: Int)
}

const layout = Layout(8)

pub fn run() -> BitArray {
  <<0:size(layout.width)>>
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn() -> BitArray")
  resolution(source, modules, "layout.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Layout", []), "width"))
}

pub fn size_in_a_group_reads_the_field_test() {
  // Probe `m2/g_order_size`. The compiler's order without its group inference
  // left this access unresolved (`Unresolved(RecordAccessUnknownType)`).
  let source =
    "pub type Packet {
  Packet(width: Int)
}

fn a(x: Bool) -> Packet {
  let _ = run(x)
  Packet(8)
}

fn b(x: Bool) -> Int {
  a(x).width
}

pub fn run(x: Bool) -> BitArray {
  let _ = b(x)
  let _ = a(x)
  <<0:size(b(x))>>
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(Bool) -> BitArray")
  resolution(source, modules, "a(x).width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Packet", []), "width"))
}

pub fn update_shorthand_in_a_group_reads_the_field_test() {
  // Probe `m2/g_order_update`, the update-shorthand twin of `order_size`.
  let source =
    "pub type Packet {
  Packet(width: Int)
}

pub type Formatter {
  Formatter(render: fn(Bool) -> Int)
}

fn a(x: Bool) -> Packet {
  let _ = run(x)
  Packet(8)
}

fn render(x: Bool) -> Int {
  a(x).width
}

pub fn run(x: Bool) -> Formatter {
  let _ = render(x)
  let _ = a(x)
  let original = Formatter(fn(_) { 0 })
  Formatter(..original, render:)
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(Bool) -> Formatter")
  resolution(source, modules, "a(x).width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Packet", []), "width"))
}

pub fn pattern_size_reads_a_constant_test() {
  // Probe `m2/g_pattern_const`.
  let source =
    "const key_size = 32

pub fn key(data: BitArray) -> Result(BitArray, Nil) {
  case data {
    <<k:bytes-size(key_size)>> -> Ok(k)
    _ -> Error(Nil)
  }
}
"
  let modules = []
  signature(source, modules, "key")
  |> should.equal("fn(BitArray) -> Result(BitArray, Nil)")
}

pub fn pattern_size_reads_the_constant_before_a_later_binding_test() {
  // Probe `m2/g_pattern_later_binding`: `<<v:size(width), width>>` reads the
  // constant `width`, which the later segment then shadows. `main` reported
  // `unbound variable: width`.
  let source =
    "const width = 8

pub fn f(b: BitArray) -> Int {
  case b {
    <<v:size(width), width>> -> v + width
    _ -> 0
  }
}
"
  let modules = []
  signature(source, modules, "f") |> should.equal("fn(BitArray) -> Int")
}

pub fn size_expression_calls_a_function_test() {
  // Probe `m2/g_sized_op`. `main` reported `unbound variable: aaa_size`.
  let source =
    "fn aaa_size() -> Int {
  8
}

pub fn sized() -> BitArray {
  <<0:size(aaa_size() * 2)>>
}
"
  let modules = []
  signature(source, modules, "sized") |> should.equal("fn() -> BitArray")
}

pub fn size_reads_a_parameter_named_like_a_function_test() {
  // Probe `m2/g_size_shadowed`: the parameter `width` shadows the top-level
  // `width`, so `pad` stays generic.
  let source =
    "pub fn pad(value, width) {
  #(value, <<0:size(width)>>)
}

pub fn width(x: Int, y: String) {
  #(pad(x, 8), pad(y, 16))
}
"
  let modules = []
  signature(source, modules, "pad")
  |> should.equal("fn(a, Int) -> #(a, BitArray)")
  signature(source, modules, "width")
  |> should.equal("fn(Int, String) -> #(#(Int, BitArray), #(String, BitArray))")
}

pub fn update_shorthand_reads_a_function_declared_after_test() {
  // Probe `m2/g_update_after`.
  let source =
    "pub type F {
  F(render: fn(Int) -> String)
}

pub fn aaa_run(f: F) -> F {
  F(..f, render:)
}

fn render(_x: Int) -> String {
  \"x\"
}
"
  let modules = []
  signature(source, modules, "aaa_run") |> should.equal("fn(F) -> F")
}

pub fn update_shorthand_reads_a_parameter_named_like_a_function_test() {
  // Probe `m2/g_update_shadowed`: the parameter `name` shadows the top-level
  // `name`, so `with_name` stays generic.
  let source =
    "pub type Box(a) {
  Box(name: a)
}

pub fn with_name(b, name) {
  Box(..b, name:)
}

pub fn name(x: Int, y: String) {
  #(with_name(Box(name: 0), x), with_name(Box(name: \"\"), y))
}
"
  let modules = []
  signature(source, modules, "with_name")
  |> should.equal("fn(Box(a), b) -> Box(b)")
  signature(source, modules, "name")
  |> should.equal("fn(Int, String) -> #(Box(Int), Box(String))")
}

pub fn update_shorthand_reads_a_function_declared_before_test() {
  // Probe `m2/g_update_shorthand`. `main` reported `unbound variable: render`.
  let source =
    "pub type Formatter {
  Formatter(render: fn(Int) -> String)
}

fn render(_x: Int) -> String {
  \"x\"
}

pub fn zzz_run(original: Formatter) -> Formatter {
  Formatter(..original, render:)
}
"
  let modules = []
  signature(source, modules, "zzz_run")
  |> should.equal("fn(Formatter) -> Formatter")
}

// Group inference
//
// Inside a group of mutually recursive definitions, every function is
// registered at its annotation shape, bodies are checked against the
// registered types, members are inferred in the compiler's order, and every
// value read copies the other members' signature variables.

pub fn body_reads_a_parameter_a_sibling_constrained_test() {
  // Probe `m2/i_commit2`: `seed` constrains `provider`'s registered parameter to
  // `Record` before `provider`'s body reads `m.width`, as the compiler's group
  // order `start,seed,provider,fix` has it. `main` reported `type mismatch:
  // String vs Int`.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn fix(r) -> Nil {
  let Record(_) = r
  let _ = provider
  Nil
}

pub fn provider(m) -> Int {
  let _ = fix(m)
  let _ = seed
  let _ = start
  m.width
}

pub fn start() -> Nil {
  let _ = fix
  Nil
}

pub fn seed() -> Int {
  provider(Record(0))
}
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"
",
    ),
  ]
  signature(source, modules, "fix") |> should.equal("fn(Record) -> Nil")
  signature(source, modules, "provider") |> should.equal("fn(Record) -> Int")
  signature(source, modules, "seed") |> should.equal("fn() -> Int")
  signature(source, modules, "start") |> should.equal("fn() -> Nil")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Record", []), "width"))
}

pub fn body_reads_its_parameter_before_a_later_sibling_constrains_it_test() {
  // Probe `m2/i_i2_regression`: the compiler checks `read` (order
  // `read,seed,start`) while `m` is still unknown, so `m.width` is the imported
  // constant.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn start() -> Nil {
  let _ = seed
  Nil
}

pub fn read(m) -> String {
  let _ = start
  m.width
}

pub fn seed() -> String {
  read(Record(10))
}
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"
",
    ),
  ]
  signature(source, modules, "read") |> should.equal("fn(Record) -> String")
  signature(source, modules, "seed") |> should.equal("fn() -> String")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.ModuleConstant("helper", "width"))
}

pub fn body_reads_its_parameter_before_a_later_sibling_same_type_test() {
  // Probe `m2/i_i2_same_type`: as `i2_regression` with every type `Int`. The
  // compiled `runner` prints `20`, the imported constant, and the compiler warns
  // that `read`'s argument `m` is never used.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn start() -> Nil {
  let _ = seed
  Nil
}

pub fn read(m) -> Int {
  let _ = start
  m.width
}

pub fn seed() -> Int {
  read(Record(10))
}
"
  let modules = [
    #(
      "helper",
      "pub const width = 20
",
    ),
  ]
  signature(source, modules, "read") |> should.equal("fn(Record) -> Int")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.ModuleConstant("helper", "width"))
}

pub fn partition_probe_reads_the_field_test() {
  // Probe `m2/i_partition`: with an unused `_tag: a` parameter on `fix` and
  // `provider`, the old providers-first partition reordered the group and
  // failed with `type mismatch: String vs Int`.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn fix(r, _tag: a) -> Nil {
  let Record(_) = r
  let _ = provider
  Nil
}

pub fn provider(m, _tag: a) -> Int {
  let _ = fix(m, Nil)
  let _ = seed
  let _ = start
  m.width
}

pub fn seed() -> Int {
  provider(Record(0), Nil)
}

pub fn start() -> Nil {
  let _ = fix
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"
",
    ),
  ]
  signature(source, modules, "fix") |> should.equal("fn(Record, a) -> Nil")
  signature(source, modules, "provider") |> should.equal("fn(Record, a) -> Int")
  signature(source, modules, "seed") |> should.equal("fn() -> Int")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Record", []), "width"))
}

pub fn partition_probe_same_type_reads_the_field_test() {
  // Probe `m2/i_partition_same_type`: the same with an `Int` import, where the
  // partition silently read the module. The compiler reads the field (it does
  // not warn that `m` is unused).
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn fix(r, _tag: a) -> Nil {
  let Record(_) = r
  let _ = provider
  Nil
}

pub fn provider(m, _tag: a) -> Int {
  let _ = fix(m, Nil)
  let _ = seed
  let _ = start
  m.width
}

pub fn seed() -> Int {
  provider(Record(0), Nil)
}

pub fn start() -> Nil {
  let _ = fix
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub const width = 20
",
    ),
  ]
  signature(source, modules, "provider") |> should.equal("fn(Record, a) -> Int")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Record", []), "width"))
}

pub fn registration_does_not_propagate_early_test() {
  // Probe `m2/i_r3_propagate`: the compiler checks `read` (order
  // `read,hinted,seed,record`) before `seed` ties `record()` to `hinted`'s
  // annotated `Record`, so `m.width` is the imported constant.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn record() {
  let _ = seed
  Record(10)
}

pub fn read() -> String {
  let m = record()
  m.width
}

pub fn hinted() -> Record {
  let _ = record
  Record(11)
}

pub fn seed() -> Nil {
  let _ = [record(), hinted()]
  let _ = read
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"
",
    ),
  ]
  signature(source, modules, "read") |> should.equal("fn() -> String")
  signature(source, modules, "record") |> should.equal("fn() -> Record")
  signature(source, modules, "seed") |> should.equal("fn() -> Nil")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.ModuleConstant("helper", "width"))
}

pub fn registration_does_not_propagate_early_same_type_test() {
  // Probe `m2/i_r3_same_type`: the same with an `Int` import. The compiled
  // `runner` prints `20`, the imported constant.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn record() {
  let _ = seed
  Record(10)
}

pub fn read() -> Int {
  let m = record()
  m.width
}

pub fn hinted() -> Record {
  let _ = record
  Record(11)
}

pub fn seed() -> Nil {
  let _ = [record(), hinted()]
  let _ = read
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub const width = 20
",
    ),
  ]
  signature(source, modules, "read") |> should.equal("fn() -> Int")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.ModuleConstant("helper", "width"))
}

pub fn reader_sees_a_sibling_annotated_return_test() {
  // Probe `m2/i_reader_first`: `provider` is registered at its annotated return
  // before `read` is inferred. `main` reported `type mismatch: String vs Int`.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn provider() -> Record {
  let _ = read
  Record(10)
}

pub fn read() -> Int {
  let m = provider()
  m.width
}
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"
",
    ),
  ]
  signature(source, modules, "read") |> should.equal("fn() -> Int")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Record", []), "width"))
}

pub fn body_shares_registered_parameter_types_test() {
  // Probe `m2/i_shared_args`, the PR H §4.0b shared-parameter probe in its
  // original order; the compiler's group is `start,seed,provider,fix`.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn fix(r) -> Nil {
  let Record(_) = r
  let _ = provider
  Nil
}

pub fn provider(m) -> Int {
  let _ = fix(m)
  let _ = seed
  let _ = start
  m.width
}

pub fn seed() -> Int {
  provider(Record(0))
}

pub fn start() -> Nil {
  let _ = fix
  Nil
}
"
  let modules = [
    #(
      "helper",
      "pub const width = \"module\"
",
    ),
  ]
  signature(source, modules, "fix") |> should.equal("fn(Record) -> Nil")
  signature(source, modules, "provider") |> should.equal("fn(Record) -> Int")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Record", []), "width"))
  order(source) |> should.equal([["start", "seed", "provider", "fix"]])
}

pub fn unannotated_group_shares_parameter_types_test() {
  // Probe `m2/x_i_review_no_annotations`: the shared-parameter group with no
  // annotations at all. `main` gave `provider: fn(Record) -> String` and the
  // imported constant.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn fix(r) {
  let Record(_) = r
  let _ = provider
  Nil
}

pub fn provider(m) {
  let _ = fix(m)
  let _ = seed
  let _ = start
  m.width
}

pub fn start() {
  let _ = fix
  Nil
}

pub fn seed() {
  provider(Record(0))
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
  signature(source, modules, "provider") |> should.equal("fn(Record) -> Int")
  signature(source, modules, "seed") |> should.equal("fn() -> Int")
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Record", []), "width"))
}

pub fn q1_cycle_reads_the_field_test() {
  // Probe `m2/x_h_round3_q1cycle`: `m.marker` in `provider` references the
  // top-level `fn m` (Q1), closing the group `read,m,provider`. `provider` is
  // registered at `fn() -> Record` before `read` runs.
  let source =
    "import helper as m

pub type Record {
  Record(width: Int)
}

pub fn provider() -> Record {
  let _ = m.marker
  Record(10)
}

pub fn m() -> Int {
  read()
}

pub fn read() -> Int {
  let m = provider()
  m.width
}
"
  let modules = [
    #(
      "helper",
      "pub const marker = 0
pub const width = \"module\"
",
    ),
  ]
  signature(source, modules, "m") |> should.equal("fn() -> Int")
  signature(source, modules, "read") |> should.equal("fn() -> Int")
  signature(source, modules, "provider") |> should.equal("fn() -> Record")
  resolution(source, modules, "m.marker", 1)
  |> should.equal(girard.ModuleConstant("helper", "marker"))
  resolution(source, modules, "m.width", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Record", []), "width"))
  order(source) |> should.equal([["read", "m", "provider"]])
}

pub fn constant_enters_scope_once_inferred_test() {
  // Probe `m2/x_h_round3_constant_scc`: in the group `f,c`, `f` is inferred
  // before the constant `c`, so `c(0)` calls the unqualified import. `main`
  // reported `wrong number of arguments`.
  let source =
    "import helper.{c}

pub fn root() {
  c
}

pub fn f() -> Nil {
  let _ = c(0)
  Nil
}

pub const c = f
"
  let modules = [
    #(
      "helper",
      "pub fn c(x: Int) -> Int {
  x
}
",
    ),
  ]
  signature(source, modules, "root") |> should.equal("fn() -> fn() -> Nil")
  signature(source, modules, "f") |> should.equal("fn() -> Nil")
  constant(source, modules, "c") |> should.equal("fn() -> Nil")
  callee_resolution(source, modules, "c(0)", 1)
  |> should.equal(girard.ModuleFn("helper", "c"))
  order(source) |> should.equal([["f", "c"], ["root"]])
}

pub fn foreign_generic_through_a_local_callee_test() {
  // Probe `pr-j/read_sites/callee`: `a`'s parameter `f` is linked to `b`'s
  // generic `fn(x) -> x`, and each read of `f` copies it, so the two calls get
  // distinct copies that each keep the argument/return link. 1.19.2 exports
  // `a: fn(fn(a) -> a) -> #(Int, String)`.
  let source =
    "pub fn a(f) {
  let _ = b
  #(f(1), f(\"s\"))
}

fn b(f: fn(x) -> x) {
  a(f)
}
"
  let modules = []
  signature(source, modules, "a")
  |> should.equal("fn(fn(a) -> a) -> #(Int, String)")
}

pub fn foreign_generic_through_an_update_shorthand_test() {
  // Probe `pr-j/read_sites/shorthand`: the shorthand `value:` reads `a`'s
  // parameter, linked to `b`'s generic `x`, as a fresh copy. 1.19.2 exports
  // `a: fn(a) -> Box`.
  let source =
    "pub type Box {
  Box(value: Int, keep: Int)
}

pub fn a(value) {
  let _ = b
  let base = Box(0, 0)
  Box(..base, value:)
}

fn b(value: x) {
  a(value)
}
"
  let modules = []
  signature(source, modules, "a") |> should.equal("fn(a) -> Box")
}

pub fn foreign_generic_through_a_pattern_size_test() {
  // Probe `pr-j/read_sites/pattern_size`: the size reads `a`'s parameter,
  // linked to `b`'s generic `x`, as a fresh copy. 1.19.2 exports
  // `a: fn(a, BitArray) -> Int`.
  let source =
    "pub fn a(width, bits: BitArray) {
  let _ = b
  case bits {
    <<v:size(width)>> -> v
    _ -> 0
  }
}

fn b(width: x, bits: BitArray) {
  a(width, bits)
}
"
  let modules = []
  signature(source, modules, "a") |> should.equal("fn(a, BitArray) -> Int")
}

// Q4 and the other call-graph quirks
//
// The compiler's graph walks a `let assert` message after its pattern (Q4)
// and only a clause's first alternative (Q2). girard's graph is the same; a
// function read through an edge the graph misses is found through its
// module-wide registration, as in the compiler.

pub fn q4_message_keeps_the_compiler_order_test() {
  // Probe `m2/x_h_review_q4_reorder`: neither name is shadowed, so the order
  // is the compiler's `message|width|run`.
  let source =
    "pub fn run(x: BitArray) {
  let assert <<v:size(width)>> = x as message()
  v
}

fn message() { \"\" }

const width = 8
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(BitArray) -> Int")
  signature(source, modules, "message") |> should.equal("fn() -> String")
  order(source) |> should.equal([["message"], ["width"], ["run"]])
}

pub fn q4_shadowed_function_is_specialised_by_its_reader_test() {
  // Probe `m2/x_h_review_q4_specialization`: the compiler's graph has no edge from
  // `run` to `message` (the pattern shadows it, Q4), so `run` is inferred first
  // and calls `message` through its registration, at `0`. 1.19.2 exports
  // `message: fn(Int) -> String`; girard registers every function before any
  // group, as the compiler does, and gives the same.
  let source =
    "pub fn run(x) {
  let assert Ok(message) = x as message(0)
  message
}

pub fn message(_x) {
  \"\"
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(Result(a, b)) -> a")
  signature(source, modules, "message") |> should.equal("fn(Int) -> String")
  order(source) |> should.equal([["run"], ["message"]])
}

pub fn alternative_size_reads_the_import_test() {
  // Probe `m2/x_h_round2_q2import`: the size in the second alternative is not
  // an edge (Q2), so `f` is inferred before the constant `width` and reads the
  // unqualified import.
  let source =
    "import helper.{width}

pub fn f(bits: BitArray) -> Int {
  case bits {
    <<1, v>> | <<2, v:size(width)>> -> v
    _ -> 0
  }
}

pub const width = 16
"
  let modules = [
    #(
      "helper",
      "pub const width = 8
",
    ),
  ]
  signature(source, modules, "f") |> should.equal("fn(BitArray) -> Int")
  constant(source, modules, "width") |> should.equal("Int")
}

pub fn q4_nested_message_reads_the_function_test() {
  // Probe `m2/x_h_round2_q4nested`: the inner `message()` reads the top-level
  // function.
  let source =
    "pub fn run(x: Result(Int, Nil), y: Result(String, Nil)) -> Int {
  let assert Ok(message) = x as {
    let assert Ok(message) = y as message()
    message
  }
  message
}

fn message() -> String {
  \"failed\"
}
"
  let modules = []
  signature(source, modules, "run")
  |> should.equal("fn(Result(Int, Nil), Result(String, Nil)) -> Int")
}

pub fn q4_prefix_message_reads_the_prefix_variable_test() {
  // Probe `m2/x_h_round2_q4prefix`: the message reads the string prefix's
  // `as` name, so there is no edge, `run` stays generic and `message` calls it
  // at two types.
  let source =
    "pub fn run(s, x) {
  let assert \"a\" as message <> _ = s
  let assert Ok(message) = x as message
  message
}

pub fn message() {
  #(run(\"a\", Ok(1)), run(\"a\", Ok(\"s\")))
}
"
  let modules = []
  signature(source, modules, "run")
  |> should.equal("fn(String, Result(a, b)) -> a")
  signature(source, modules, "message")
  |> should.equal("fn() -> #(Int, String)")
}

pub fn q4_bare_receiver_reads_the_module_test() {
  // Probe `m2/x_h_round2_q4qualifier`: `m.reason` is module access, never a
  // Q4 edge, so `run` and `m` stay in separate groups.
  let source =
    "import helper as m

pub fn run(x) {
  let assert Ok(m) = x as m.reason
  m
}

pub fn m() {
  #(run(Ok(1)), run(Ok(\"s\")))
}
"
  let modules = [
    #(
      "helper",
      "pub const reason = \"failed\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Result(a, b)) -> a")
  signature(source, modules, "m") |> should.equal("fn() -> #(Int, String)")
  resolution(source, modules, "m.reason", 1)
  |> should.equal(girard.ModuleConstant("helper", "reason"))
}

pub fn q4_call_shorthand_reads_the_function_test() {
  // Probe `m2/x_h_round2_q4shorthand`: `invoke(message:)` reads the top-level
  // function through a shorthand.
  let source =
    "pub fn run(x: Result(Int, Nil)) -> Int {
  let assert Ok(message) = x as invoke(message:)
  message
}

fn invoke(message message: fn() -> String) -> String {
  message()
}

fn message() -> String {
  \"failed\"
}
"
  let modules = []
  signature(source, modules, "run")
  |> should.equal("fn(Result(Int, Nil)) -> Int")
}

// Code the compiler rejects
//
// Each of these is rejected by 1.19.2, and girard rejects it too.

pub fn constant_cycle_is_rejected_test() {
  // Probe `m2/x_h_review_constant_cycle`.
  let source =
    "pub fn a() { b }
pub const b = a
"
  let modules = []
  let assert girard.RecursiveType(..) = error_with(source, modules)
}

pub fn constant_read_before_it_is_inferred_is_unbound_test() {
  // Probe `m2/x_h_review_cross_group_const`: `f` is inferred before the
  // constant `c` it reads, as in the compiler, which reports an unknown
  // variable.
  let source =
    "pub fn root() { c }
pub fn f() -> Nil {
  let _ = c
  Nil
}
pub const c = f
"
  let modules = []
  let assert girard.UnboundVariable("c") = error_with(source, modules)
}

pub fn q6_pattern_label_size_is_unbound_test() {
  // Probe `m2/x_h_review_pattern_labels`: the graph walks the constructor
  // pattern in written order and misses the constant `width` the size reads
  // (Q6), as the compiler does.
  let source =
    "pub type Box {
  Box(bits: BitArray, width: Int)
}

pub fn f(box: Box) {
  let assert Box(width:, bits: <<v:size(width)>>) = box
  v + width
}

const width = 8
"
  let modules = []
  let assert girard.UnboundVariable("width") = error_with(source, modules)
}

pub fn q4_shadowed_constant_is_unbound_test() {
  // Probe `m2/x_h_review_q4_const`: Q4 drops the edge to the constant
  // `message`, which is not in scope when `run` is inferred.
  let source =
    "pub fn run(x) {
  let assert Ok(message) = x as message
  message
}
pub const message = \"error\"
"
  let modules = []
  let assert girard.UnboundVariable("message") = error_with(source, modules)
}
