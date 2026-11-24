// Speculation as the compiler runs it, and the probes that pin it against
// Gleam 1.19.2. When a function literal is called, its arguments are typed
// first to learn its parameter types; inside that speculative walk each site
// the compiler recovers at recovers as it does, keeping every effect so far,
// and nothing recovers outside one. The walk's outcome depends on the order
// the compiler walks in, so the orders that decide what a failure skips are
// here too: unification compares lengths before any element, a pattern size
// reads its own scope, a later `case` alternative sees the first one's
// bindings, a guard's `name.label` is classified by the guard-variable
// lookup, and a record update copies every field it does not name.
//
// Every probe test runs a probe from girard's PR L inventory through the
// normal entry point with 1.19.2's answer pinned: each public signature its
// interface exports and, where the probe's point is a reference, what it
// resolved to. Each test names its probe, and every one checks that no
// expression is annotated twice.

import girard
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import probe_support.{
  constant, error_with, repeated_spans, resolution, signature,
}

pub fn tuple_size_mismatch_is_a_type_mismatch_test() {
  // The second element is a tuple of another size: no element of the two is
  // unified, so the mismatch is the tuples', not a count of their elements.
  // The list's element type comes first, as the compiler reports it
  // (`expression.rs:1255`).
  let source = "pub fn f(a) { [#(a, 1), #(True, 1, 1)] }"
  let assert girard.TypeMismatch(girard.Tuple([_, _]), girard.Tuple([_, _, _])) =
    error_with(source, [])
}

pub fn function_arity_mismatch_is_checked_before_parameters_test() {
  // The first parameters mismatch too, but the arities are compared first.
  let source = "pub fn f() { [fn(x: Int, _y) { x }, fn(z: String) { 1 }] }"
  let assert girard.ArityMismatch = error_with(source, [])
}

pub fn pattern_size_reads_the_enclosing_scope_test() {
  // Probe `k_l_r2_r13_pattern_size_scope`.
  // A bit-array size reads the names the pattern started with, plus those
  // bound earlier in its own bit array: the tuple's `width` is out of its
  // reach, so it reads the outer `Int` one (`pattern.rs:419-428, 1405-1423`).
  let source =
    "pub fn run(bits: BitArray) {
  let width = 8
  let assert #(width, <<value:size(width)>>) = #(\"s\", bits)
  #(width, value)
}
"
  let modules = []
  signature(source, modules, "run")
  |> should.equal("fn(BitArray) -> #(String, Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn later_alternative_size_reads_the_first_alternative_test() {
  // Probe `k_l_r3_r13_alternative_sizes`.
  // The first alternative's bindings are in scope while a later one is
  // typed (`expression.rs:2404-2428`), so its size reads `width` before its
  // own binder.
  let source =
    "pub fn run(bits: BitArray) {
  case bits {
    <<width, value:size(width)>>
    | <<value:size(width), width>> -> #(width, value)
    _ -> #(0, 0)
  }
}
"
  let modules = []
  signature(source, modules, "run")
  |> should.equal("fn(BitArray) -> #(Int, Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn later_alternative_size_prefers_the_first_alternative_test() {
  // Probe `k_l_r3_r13_alternative_scope`.
  // The later alternative's size reads the first alternative's `Int`
  // `width`, not the `String` one outside the `case`.
  let source =
    "pub fn run(bits: BitArray) {
  let width = \"outer\"
  let _ = width
  case #(8, bits) {
    #(width, <<value, _:8>>) | #(width, <<value:size(width)>>) -> #(width, value)
    _ -> #(0, 0)
  }
}
"
  let modules = []
  signature(source, modules, "run")
  |> should.equal("fn(BitArray) -> #(Int, Int)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn record_update_copies_an_unlabelled_field_test() {
  // Probe `k_l_r3_r17_copied_positional`.
  // A record update copies every field it does not name, an unlabelled one
  // included (`expression.rs:2899-3025`), so the result keeps `value`'s `a`.
  let source =
    "pub type Wrap(a) { Wrap(a, label: Int) }
pub fn run(value: Wrap(a)) { Wrap(..value, label: 1) }
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(Wrap(a)) -> Wrap(a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn guard_access_on_a_function_name_is_a_module_select_test() {
  // Probe `k_l_r2_r12_bound_function`.
  // The guard-variable lookup rejects a module function, so `m.flag` beside
  // a local function `m` is the import's constant (`guard.rs:96-140, 318`).
  let source =
    "import helper as m
fn m() { Nil }
pub fn run() {
  let _ = m()
  case True {
    _ if m.flag -> 1
    _ -> 0
  }
}
"
  let modules = [
    #(
      "helper",
      "pub const flag = True
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> Int")
  resolution(source, modules, "m.flag", 1)
  |> should.equal(girard.ModuleConstant("helper", "flag"))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn constant_record_update_skips_the_variant_check_test() {
  // Probe `k_l_r2_r17_constant_variant`.
  // A constant's record update is not checked for the spread's variant as
  // an expression's is: the constant typer reads the constant's literal
  // (`constant.rs:164-245`), which the generalized scheme no longer carries.
  let source =
    "import helper
pub const updated = helper.Red(..helper.base, value: 2)
pub fn run(x: helper.Colour) {
  case x {
    _ if x == helper.Red(..helper.base, value: 3) -> 1
    _ -> 0
  }
}
"
  let modules = [
    #(
      "helper",
      "pub type Colour { Red(value: Int) Blue }
pub const base = Red(1)
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Colour) -> Int")
  constant(source, modules, "updated") |> should.equal("Colour")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn guard_reads_a_bare_constructor_test() {
  // Probe `k_l_r4_r12_bare_constructor`.
  // A bare uppercase name in a guard is a constructor read as a constant
  // (`parse.rs:1912-1932`), not a guard variable.
  let source =
    "pub type Flag { Off On }
pub fn bare_bool() {
  case Nil { _ if True -> 1 _ -> 0 }
}
pub fn bare_ctor(x) {
  case x { _ if x == Off -> x _ -> x }
}
"
  let modules = []
  signature(source, modules, "bare_bool") |> should.equal("fn() -> Int")
  signature(source, modules, "bare_ctor") |> should.equal("fn(Flag) -> Flag")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn record_update_of_a_known_variant_test() {
  // Probe `k_l_rv1_update_narrowed`.
  // An expression record update of a type with two variants takes a spread
  // known to be its variant: narrowed by a `case`, by `let assert .. as`,
  // or built by the constructor itself (`expression.rs:3096-3170`).
  let source =
    "pub type T(a) {
  A(x: a, y: Int)
  B(x: a)
}

pub fn by_case(t: T(a), v: b) -> T(b) {
  case t {
    A(..) -> A(..t, x: v)
    B(..) -> B(x: v)
  }
}

pub fn by_assert(t, v) {
  let assert A(..) as a = t
  A(..a, x: v)
}

pub fn by_let(v) {
  let a = A(1, 2)
  A(..a, x: v)
}
"
  let modules = []
  signature(source, modules, "by_assert") |> should.equal("fn(T(a), b) -> T(b)")
  signature(source, modules, "by_case") |> should.equal("fn(T(a), b) -> T(b)")
  signature(source, modules, "by_let") |> should.equal("fn(a) -> T(a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn later_alternative_leaves_an_inherited_variant_test() {
  // Probe `k_l_rv2_alternative_inherited_variant`.
  // The first alternative does not narrow `t`, so a later one cannot change
  // its variant (`pattern.rs:236-257`): the `B(..)` is ignored, `t` keeps the
  // `A` it was built with, and the update is safe. 1.19.2 warns that the
  // later pattern is unreachable.
  let source =
    "pub type T {
  A(value: Int)
  B(value: Int)
}

pub fn run(flag) {
  let t = A(0)
  case t, flag {
    _, True | B(..), False -> A(..t, value: 1)
    _, False -> t
  }
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(Bool) -> T")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn silent_later_alternative_keeps_the_narrowing_test() {
  // Probe `k_l_rv2_alternative_silent_later`.
  // A later alternative that narrows nothing leaves the first's narrowing,
  // whether `t` had no variant before the `case` or was built as `B`.
  let source =
    "pub type T {
  A(value: Int)
  B(value: Int)
}

pub fn run(t: T, flag) {
  case t, flag {
    A(..), True | _, False -> A(..t, value: 1)
    _, _ -> t
  }
}

pub fn inherited(flag) {
  let t = B(0)
  case t, flag {
    A(..), True | _, False -> A(..t, value: 1)
    _, _ -> t
  }
}
"
  let modules = []
  signature(source, modules, "inherited") |> should.equal("fn(Bool) -> T")
  signature(source, modules, "run") |> should.equal("fn(T, Bool) -> T")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn later_alternative_binding_at_a_link_keeps_the_variant_test() {
  // Probe `k_l_rv4_alternative_raw_link`.
  // The alternatives' bindings are compared raw (`pattern.rs:1654-1668`): the
  // later `v` is bound at `id`'s return, a type variable, which is the
  // compiler's link, so the first alternative's `B(..) as v` keeps its
  // variant and the update is safe.
  let source =
    "pub type T {
  A
  B(field: Int)
}

fn id(x) {
  x
}

pub fn run(t: T, flag) {
  case t, id(B(0)), flag {
    B(..) as v, _, True | _, v, False -> B(..v, field: 1)
    _, _, _ -> t
  }
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(T, Bool) -> T")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn later_alternative_binding_at_a_read_erases_the_variant_test() {
  // Probe `k_l_rv5_collapsed_subject_binding`.
  // A read is link-free, as the compiler's `instantiate` makes it, so the
  // later `_ as io` is bound at `T` itself, a named type with no variant,
  // which erases the first's `A` (`pattern.rs:1654-1668`): `io.value` is
  // no field of every variant, so it is `helper`'s `String`.
  let source =
    "import helper as io

pub type T {
  A(value: Int)
  B
}

pub fn run(t) -> String {
  let _: T = t
  case t {
    A(..) as io | _ as io -> io.value
  }
}
"
  let modules = [
    #(
      "helper",
      "pub const value = \"module\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(T) -> String")
  resolution(source, modules, "io.value", 1)
  |> should.equal(girard.ModuleConstant("helper", "value"))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn empty_block_is_an_implicit_todo_test() {
  // Probe `k_l_rv6_empty_block_strict`.
  // An empty block is the compiler's implicit `todo`, a fresh type
  // (`parse.rs:1310-1320`), so `x == {}` leaves `x` generic. girard typed
  // it `Nil`.
  let source =
    "pub fn run(x) {
  x == {}
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a) -> Bool")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn guard_module_select_of_a_function_is_rejected_test() {
  // A guard selects only a module's constant: `m.label` naming a function is
  // the compiler's `RecordAccessUnknownType` (`guard.rs:386-419`), which
  // 1.19.2 reports for this program.
  let source =
    "import helper as m

pub fn run(x) {
  case x {
    _ if x == m.label -> 1
    _ -> 0
  }
}
"
  let modules = [#("helper", "pub fn label() {\n  Nil\n}\n")]
  let assert girard.NotARecord = error_with(source, modules)
}

pub fn constant_concatenation_checks_left_before_right_test() {
  // A constant's `<>` unifies its left operand with `String` before it walks
  // the right one (`constant.rs:557-584`), so the first error is the left
  // operand's mismatch, not the right operand's unknown name.
  let source = "pub const label = 1 <> missing\n"
  let assert girard.TypeMismatch(..) = error_with(source, [])
}

pub fn empty_function_body_is_an_implicit_todo_test() {
  // An empty function body is the compiler's implicit `todo`, a fresh type
  // (`parse.rs:2294-2310`), an anonymous one's as a named one's; 1.19.2 gives
  // these signatures. girard typed the anonymous body `Nil`.
  let source =
    "pub fn run(x) {
  let f = fn() {}
  x == f()
}

pub fn empty() {}

pub fn declared() -> Int {}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a) -> Bool")
  signature(source, modules, "empty") |> should.equal("fn() -> a")
  signature(source, modules, "declared") |> should.equal("fn() -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn incomplete_use_is_an_implicit_todo_test() {
  // A `use` with nothing after it ends its callback with the compiler's
  // implicit `todo`, a fresh type, after the callback's generated assignments
  // (`expression.rs:815-822`); 1.19.2 gives these signatures. girard typed
  // the callback's body `Nil`.
  let source =
    "pub fn with(f: fn(Int) -> a) -> a {
  f(1)
}

pub fn run() {
  use n <- with()
}

pub fn pair(f: fn(#(Int, String)) -> a) -> a {
  f(#(1, \"s\"))
}

pub fn complex() {
  use #(n, s) <- pair
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn() -> a")
  signature(source, modules, "complex") |> should.equal("fn() -> a")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn wide_bit_array_pattern_reads_an_earlier_size_test() {
  // A bit-array pattern's walk keeps each segment's own bindings for the
  // sizes after it, so it is linear in the pattern's width, and a size still
  // reads a binding an earlier segment made: here the last segment's size
  // reads the first segment's `width`, across 500 segments between them.
  // 1.19.2 gives this signature.
  let segments =
    list.repeat(Nil, 500)
    |> list.index_map(fn(_, index) { "b" <> int.to_string(index) })
    |> string.join(", ")
  let source = "pub fn run(bits: BitArray) {
  let assert <<width, " <> segments <> ", rest:size(width)>> = bits
  rest
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(BitArray) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn later_alternative_narrowing_twice_erases_test() {
  // A later alternative that narrows the subject twice erases the first
  // alternative's variant if either narrowing names another one, in either
  // order (`pattern.rs:236-257`): 1.19.2 rejects both updates as unsafe, and
  // accepts the alternative that names the first's variant twice.
  let program = fn(later) { "pub type T {
  A(value: Int)
  B(value: Int)
}

pub fn run(t: T) -> T {
  case t, t {
    A(..), _ | " <> later <> " -> A(..t, value: 1)
    _, _ -> t
  }
}
" }
  signature(program("A(..), A(..)"), [], "run") |> should.equal("fn(T) -> T")
  let assert girard.TypeMismatch(..) = error_with(program("A(..), B(..)"), [])
  let assert girard.TypeMismatch(..) = error_with(program("B(..), A(..)"), [])
}

pub fn later_alternative_size_reads_the_first_binding_test() {
  // In a later alternative a segment's binding of a name the first
  // alternative bound is unified with the first's, and a size after it reads
  // the first's entry (`pattern.rs:163-184, 394-415, 1405-1419`); 1.19.2
  // gives this signature.
  let source =
    "pub fn run(bits: BitArray) {
  case bits {
    <<0, width, value:size(width)>> | <<1, width, value:size(width)>> ->
      value + width
    _ -> 0
  }
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(BitArray) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn wide_list_of_empty_lists_types_test() {
  // With the compiler's operand order each element's variable is linked to
  // the next, and `unify` compresses the chain as the compiler does
  // (`environment.rs:1103-1117`), so a wide list is linear. 1.19.2 gives this
  // signature.
  let elements = list.repeat("[]", 500) |> string.join(", ")
  let source = "pub fn run() {\n  [" <> elements <> "]\n}\n"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn() -> List(List(a))")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_header_names_survive_a_failed_body_test() {
  // Probe `k_r5_spec_collision`.
  // The callback's body fails while it is speculated, and its header's `t`,
  // hydrated in the enclosing scope, survives: the callee's `let _: t = y`
  // reuses it. The real pass's `r.field` is the record's.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

pub fn run(x, y) {
  fn(callback) {
    let _: t = y
    callback(x, Row(0))
  }(fn(_v: t, r) {
    r.field + 1
  })
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a, a) -> #(a, a)")
  resolution(source, modules, "r.field", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Row", []), "field"))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_call_walks_every_argument_test() {
  // Probe `k_r6_spec_call`.
  // A speculated call checks every argument and records each mismatch, so
  // `pick`'s lambda argument is walked after the failing one and mints `t`.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

fn use_row(_r: Row) { Nil }
fn pick(_field: Int, x, f) { f(x) }

pub fn run(x, y, r) {
  fn(_argument) {
    let _: t = y
    use_row(r)
  }(pick(r.field + 1, x, fn(v: t) { v }))
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a, a, Row) -> #(a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_callback_keeps_its_return_test() {
  // Probe `k_r6_spec_return`.
  // `r.field + 1` fails while speculated, but `Row(..)` still returns `Row`,
  // so the callee's `r.field` is the record's. `main` rejects it.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

pub fn run() {
  fn(callback) {
    let r = callback(Row(0))
    r.field + 1
  }(fn(r) {
    Row(r.field + 1)
  })
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_unification_keeps_its_prefix_test() {
  // Probe `k_r7_spec_prefix`.
  // Unifying `#(outer, r.field)` with `#(Row, Int)` links `outer` before it
  // fails, and the link is kept. `main` rejects it.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

fn take_tuple(_pair: #(Row, Int)) { Nil }

pub fn run(r) {
  let outer = r
  fn(callback) {
    callback(Row(0))
    r.field + 1
  }(fn(r) {
    take_tuple(#(outer, r.field))
  })
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Row) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_callback_shapes_the_callee_test() {
  // Probe `k_r6_spec_shape`.
  // The callback's `Row(..)` gives the callee's parameter its return, so
  // `callback(Row(0)).field` is a record field at the access.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

pub fn run() {
  fn(callback) {
    callback(Row(0)).field
  }(fn(r) {
    Row(r.field + 1)
  })
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> Int")
  resolution(source, modules, "callback(Row(0)).field", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Row", []), "field"))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_operator_walks_both_operands_test() {
  // Probe `k_l_r1_r11_operand_order`.
  // Both operands are walked before either is unified, so `x` is still
  // unbound when the annotated lambda's header meets it, and `take(y)` runs.
  // `main` rejects it.
  let source =
    "import helper as r
import fallback as y
pub type Row(a) { Row(field: fn(Int) -> a) }
pub type Mark { Mark(value: Int) }
fn take(_value: Mark) { Nil }
pub fn run(y) {
  fn(callback) {
    callback(Row(fn(_) { todo }))
    y.value + 1
  }(fn(r) {
    let x = todo
    x + {
      fn(_v: t) {
        take(y)
        0
      }(r.field(x))
    }
  })
}
"
  let modules = [
    #(
      "fallback",
      "pub const value = \"module value\"
",
    ),
    #(
      "helper",
      "pub fn field(x) { x }
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Mark) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_guard_access_stays_a_record_access_test() {
  // Probe `k_l_r1_r12_guard_shadow`.
  // A guard's `r.field` on a local is a record access only, so a speculated
  // guard never takes the module's `String`.
  let source =
    "import helper as r
pub type Row { Row(field: Int) }
pub fn run(x) {
  fn(callback) { callback(Row(0)) }(fn(r) {
    case True {
      _ if r.field == x -> Nil
      _ -> Nil
    }
    r.field + 1
  })
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Int) -> Int")
  resolution(source, modules, "r.field", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Row", []), "field"))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_constructor_pattern_binds_its_fields_test() {
  // Probe `k_l_r1_r13_constructor`.
  // The `Wrap(value)` pattern meets the module's `String` in speculation and
  // still binds `value: Row`, so the callee's outer `.field` is `Row`'s.
  let source =
    "import helper as r
pub type Row { Row(field: Int) }
pub type Wrap { Wrap(value: Row) }
pub type Outer { Outer(field: Wrap) }
pub fn run() {
  fn(callback) {
    callback(Outer(Wrap(Row(0)))).field + 1
  }(fn(r) {
    let assert Wrap(value) = r.field
    value
  })
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> Int")
  resolution(source, modules, "callback(Outer(Wrap(Row(0)))).field", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Row", []), "field"))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_bit_array_stops_at_a_failing_segment_test() {
  // Probe `k_l_r1_r16_bit_next_segment`.
  // The first segment that fails fails the bit array: the next segment's
  // `pick` is not walked.
  let source =
    "import helper as r
pub type Row { Row(field: Int) }
fn use_row(_row: Row) { Nil }
fn pick(x, f) { f(x) 8 }
pub fn run(x, y, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(<<r.field, pick(x, fn(v: t) { v })>>)
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a, b, Row) -> #(a, c)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_segment_walks_its_size_first_test() {
  // Probe `k_l_r1_r16_bit_value_size`.
  // A segment's size is walked before its value is unified, so `pick` mints
  // `t` though the value then fails.
  let source =
    "import helper as r
pub type Row { Row(field: Int) }
fn use_row(_row: Row) { Nil }
fn pick(x, f) { f(x) 8 }
pub fn run(x, y, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(<<r.field:size(pick(x, fn(v: t) { v }))>>)
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a, a, Row) -> #(a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_call_of_a_non_function_walks_no_argument_test() {
  // Probe `k_l_r1_r5_nonfn`.
  // A callee known not to be a function walks no argument, so the argument's
  // `t` is never minted.
  let source =
    "import helper as r
pub type Row { Row(field: fn(Nil) -> Nil) }
fn use_row(_row: Row) { Nil }
fn pick(x, f) { f(x) Nil }
pub fn run(x, y, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(r.field(pick(x, fn(v: t) { v })))
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a, b, Row) -> #(a, c)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_guard_name_that_fails_is_fresh_test() {
  // Probe `k_l_r2_r12_invalid_guard_name`.
  // A bare guard name the lookup cannot find is a fresh variable, and the
  // clause's body is still walked: `take(y)` pins `y`. `main` rejects it.
  let source =
    "import helper as r
import fallback as y
pub type Row { Row(field: #(Bool, Int)) }
pub type Mark { Mark(value: Int) }
fn take(_value: Mark) { Nil }
pub fn run(y) {
  fn(callback) {
    callback(Row(#(True, 0)))
    y.value + 1
  }(fn(r) {
    case r.field {
      #(flag, _) if flag -> { take(y) 0 }
      _ -> 1
    }
  })
}
"
  let modules = [
    #(
      "fallback",
      "pub const value = \"module value\"
",
    ),
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Mark) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_echo_walks_its_message_test() {
  // Probe `k_l_r2_r16_echo_value`.
  // `echo`'s value fails, and its message is still walked: `pick` mints `t`.
  let source =
    "import helper as r
pub type Row { Row(field: #(Int, Int)) }
fn use_row(_row: Row) { Nil }
fn pick(x, f) { f(x) \"message\" }
pub fn run(x, y, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(echo r.field.0 as pick(x, fn(v: t) { v }))
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a, a, Row) -> #(a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_tuple_index_on_an_unknown_type_fails_test() {
  // Probe `k_l_r2_r19_pending_before_options`.
  // A tuple index on an unknown type fails rather than deferring, so the
  // segment's size is not walked. The argument fails at its top level, so
  // `speculate` itself makes it a fresh variable and goes on.
  let source =
    "import helper as s
pub type Row { Row(field: Int) }
fn use_row(_row: Row) { Nil }
fn use_tuple(_pair: #(Int, Int)) { Nil }
fn pick(x, f) { f(x) 8 }
pub fn run(x, y, r, s) {
  fn(_argument) {
    use_tuple(r)
    use_row(s)
    let _: t = y
    Nil
  }(<<r.0:size(pick(x, fn(v: t) { v })), s.field>>)
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(a, b, #(Int, Int), Row) -> #(a, c)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_constant_update_fails_whole_test() {
  // Probe `k_l_r3_r17_guard_update_value`.
  // A guard's constant record update whose field fails is a fresh variable,
  // not its record type, so the guard does not shape `x`.
  let source =
    "import record
import helper as r
import fallback as x
pub type Row { Row(field: Int) }
pub fn run(x) {
  fn(cb) {
    let _: String = x.label
    cb(Row(0))
  }(fn(r) {
    let offered = r.field
    case True {
      _ if x == record.Box(..record.base, value: offered) -> Nil
      _ -> Nil
    }
  })
}
"
  let modules = [
    #(
      "fallback",
      "pub const label = \"module label\"
",
    ),
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
    #(
      "record",
      "pub type Box { Box(value: Int, label: Int) }
pub const base = Box(0, 0)
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Box) -> Nil")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_call_of_a_generic_walks_no_argument_test() {
  // Probe `k_l_r3_r5_rigid_callee`.
  // A generic callee is not a function, so its argument is not walked.
  let source =
    "import helper as r
pub type Row(a) { Row(field: fn(a) -> fn(Nil) -> Nil) }
fn use_row(_row: Row(a)) { Nil }
fn pick(x, f) { f(x) Nil }
pub fn run(x, y, r, u: a) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(r.field(u)(pick(x, fn(v: t) { v })))
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub fn field(value) { value }
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(a, b, Row(c), c) -> #(a, d)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_guard_index_reads_the_field_as_declared_test() {
  // Probe `k_l_r5_r12_guard_tuple_link`.
  // A guard index through a field declared as a type parameter meets a
  // variable, not a tuple, and is a fresh variable. `main` rejects it.
  let source =
    "import helper as r
pub type Fixed { Fixed(field: #(Int)) }
pub type Outer { Outer(item: Fixed) }
pub fn run(x) {
  fn(cb) {
    let _: t = x
    cb(Outer(Fixed(#(1))))
  }(fn(r) {
    let candidate = r.item
    case True {
      _ if candidate.field.0 == x -> Nil
      _ -> Nil
    }
  })
  x
}
"
  let modules = [
    #(
      "helper",
      "pub type Generic(a) { Generic(field: a) }
pub const item = Generic(#(1))
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a) -> b")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_guard_index_reads_each_element_as_selected_test() {
  // Probe `k_l_r6_r12_guard_nested_field_link`.
  // The second index meets the selected element's own variable, not the
  // tuple it is linked to. `main` rejects it.
  let source =
    "import helper as r
pub type Fixed { Fixed(field: #(#(Int))) }
pub type Outer { Outer(item: Fixed) }
pub fn run(x) {
  fn(cb) {
    let _: t = x
    cb(Outer(Fixed(#(#(1)))))
  }(fn(r) {
    let candidate = r.item
    case True {
      _ if candidate.field.0.0 == x -> Nil
      _ -> Nil
    }
  })
  x
}
"
  let modules = [
    #(
      "helper",
      "pub type Generic(a) { Generic(field: #(a)) }
pub const item = Generic(#(#(1)))
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a) -> b")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_guard_index_reads_a_local_whole_test() {
  // Probe `k_l_r6_r12_guard_nested_local_link`.
  // A local read follows every link, so both indexes find tuples and `x` is
  // pinned to `Row` before the outer literal's `x.field`.
  let source =
    "import helper as x
pub type Row { Row(field: Int) }
pub fn run(x) {
  let seed = todo
  let tuple = #(seed)
  let _: #(Row) = seed
  fn(_callback) { x.field + 1 }(fn() {
    case True {
      _ if x == tuple.0.0 -> Nil
      _ -> Nil
    }
  })
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Row) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_alternative_skips_a_name_the_first_did_not_bind_test() {
  // Probe `k_l_r6_r13_extra_after_invalid`.
  // The first alternative's tuple meets the module's `String`, so it binds
  // no `width`; the later alternative's `width` is skipped, and its size
  // reads the parameter.
  let source =
    "import helper as r
pub type Row { Row(field: #(Int, Int)) }
pub fn run(width) {
  fn(cb) { cb(Row(#(1, 0))) }(fn(r) {
    case r.field, <<0, 0>> {
      #(width, value), _ | _, <<width, value:size(width)>> -> #(width, value)
      _, _ -> #(0, 0)
    }
  })
  width
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Int) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_failed_callee_walks_its_arguments_test() {
  // Probe `k_l_b_r4_failed_callee`.
  // A callee that fails is an invalid callee, and its arguments are still
  // walked: `prepend` makes `rows` a `List(Row)`. `main` rejects it.
  let source =
    "import helper as r
import fallback as row
pub type Row { Row(field: Int) }
pub type Pair { Pair(field: #(fn(List(Row)) -> List(Row), Int)) }
fn use_pair(_pair: Pair) { Nil }
fn prepend(list: List(a), item: a) -> List(a) { [item, ..list] }
pub fn run(r) {
  let rows = []
  fn(p) {
    use_pair(r)
    case p {
      [row, ..] -> row.field + 1
      [] -> 0
    }
  }({
    case r.field {
      #(f, _) -> f(prepend(rows, Row(1)))
    }
    rows
  })
}
"
  let modules = [
    #(
      "fallback",
      "pub const field = \"fallback field\"
",
    ),
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Pair) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_call_of_another_arity_walks_the_common_prefix_test() {
  // Probe `k_l_b_r5_wrong_arity`.
  // A callee of another arity checks the arguments against the common
  // prefix: the first argument mints `t`, the second never mints `u`.
  let source =
    "import helper as r
pub type Row { Row(field: fn(Int, Int) -> Int) }
fn use_row(_row: Row) { Nil }
fn pick(x, f) { f(x) 8 }
pub fn run(x, y, z, w, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    let _: u = w
    Nil
  }(r.field(pick(x, fn(v: t) { v }), pick(z, fn(v: u) { v })))
  #(x, y, z, w)
}
"
  let modules = [
    #(
      "helper",
      "pub fn field(x) { x }
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(a, a, b, c, Row) -> #(a, a, b, d)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_statement_that_fails_is_fresh_test() {
  // Probe `k_l_b_r8_statement`.
  // An expression statement that fails is a fresh variable and the block
  // reaches `Row(1)`. `main` rejects it.
  let source =
    "import helper as r
import fallback as p
pub type Row { Row(field: Int) }
pub type Pair { Pair(field: #(Int, Int)) }
fn use_pair(_pair: Pair) { Nil }
pub fn run(r) {
  fn(p) {
    use_pair(r)
    p.field + 1
  }({
    r.field.0
    Row(1)
  })
}
"
  let modules = [
    #(
      "fallback",
      "pub const field = \"fallback field\"
",
    ),
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Pair) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_let_value_that_fails_is_fresh_test() {
  // Probe `k_l_b_r9_let_value`.
  // A `let` value that fails is a fresh variable and the block reaches
  // `Row(1)`. `main` rejects it.
  let source =
    "import helper as r
import fallback as p
pub type Row { Row(field: Int) }
pub type Pair { Pair(field: #(Int, Int)) }
fn use_pair(_pair: Pair) { Nil }
pub fn run(r) {
  fn(p) {
    use_pair(r)
    p.field + 1
  }({
    let _ = r.field.0
    Row(1)
  })
}
"
  let modules = [
    #(
      "fallback",
      "pub const field = \"fallback field\"
",
    ),
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Pair) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_assert_value_that_fails_is_fresh_test() {
  // Probe `k_l_b_r10_assert`.
  // An `assert` value that fails is a fresh variable and the block reaches
  // `Row(1)`. `main` rejects it.
  let source =
    "import helper as r
import fallback as p
pub type Row { Row(field: Int) }
pub type Pair { Pair(field: #(Bool, Int)) }
fn use_pair(_pair: Pair) { Nil }
pub fn run(r) {
  fn(p) {
    use_pair(r)
    p.field + 1
  }({
    assert r.field.0
    Row(1)
  })
}
"
  let modules = [
    #(
      "fallback",
      "pub const field = \"fallback field\"
",
    ),
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Pair) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_field_access_that_fails_is_fresh_test() {
  // Probe `k_l_b_r14_failed_access`.
  // A field access whose record and module branches both fail is a fresh
  // variable, so the segment's size is still walked.
  let source =
    "import helper as r
pub type Inner { Inner(missing: Int) }
pub type Row { Row(field: Inner) }
fn use_row(_row: Row) { Nil }
fn pick(x, f) { f(x) 8 }
pub fn run(x, y, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(<<r.field.missing:size(pick(x, fn(v: t) { v }))>>)
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a, a, Row) -> #(a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_pipe_walks_its_step_test() {
  // Probe `k_l_b_r15_pipe_value`.
  // A pipe's first value fails, and its step is still walked.
  let source =
    "import helper as r
pub type Row { Row(field: #(Int, Int)) }
fn use_row(_row: Row) { Nil }
fn pick(value: Int, x, f) { f(x) value }
pub fn run(x, y, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(r.field.0 |> pick(x, fn(v: t) { v }))
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a, a, Row) -> #(a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_record_update_walks_every_field_test() {
  // Probe `k_l_b_r17_update_value`.
  // A record update's field value fails, and the next field is walked.
  let source =
    "import helper as r
pub type Box { Box(a: Int, b: Int) }
pub type Row { Row(field: #(Int, Int)) }
fn use_row(_row: Row) { Nil }
fn pick(x, f) { f(x) 8 }
pub fn run(x, y, r, base: Box) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(Box(..base, a: r.field.0, b: pick(x, fn(v: t) { v })))
  #(x, y)
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run")
  |> should.equal("fn(a, a, Row, Box) -> #(a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_guard_select_of_a_module_function_is_fresh_test() {
  // Probe `k_l_rv1_guard_module_fn`.
  // The tuple pattern meets the module's `String`, so `m` is unbound and
  // `m.label` is a module select of a function, which a guard cannot make
  // (`guard.rs:386-419`): it is a fresh variable, and `x` is not pinned to
  // the function.
  let source =
    "import helper as m
import rows

pub type Inner {
  Inner(label: Int)
}

pub type Row {
  Row(field: #(Inner))
}

pub fn run(x) {
  fn(cb) { cb(Row(#(Inner(0)))) }(fn(rows) {
    case rows.field {
      #(m) if x == m.label -> Nil
      _ -> Nil
    }
  })
  x
}
"
  let modules = [
    #(
      "helper",
      "pub fn label() {
  Nil
}
",
    ),
    #(
      "rows",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Int) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_constant_name_that_fails_is_fresh_test() {
  // Probe `k_l_rv1_const_bits_var`.
  // The tuple pattern meets the module's `String`, so `v` is unbound: the
  // guard's constant `<<v, x>>` makes `v` fresh at the name
  // (`constant.rs:425-441`) and walks on to `x`, pinning the parameter to
  // `Int`.
  let source =
    "import helper as r

pub type Row {
  Row(field: #(Int, Int))
}

pub fn run(x) {
  fn(cb) { cb(Row(#(0, 0))) }(fn(r) {
    case r.field {
      #(v, x) if <<v, x>> == <<0, 0>> -> Nil
      _ -> Nil
    }
  })
  x
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Int) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_constant_list_walks_every_element_test() {
  // Probe `k_l_rv2_const_list_var`.
  // The tuple pattern meets the module's `String`, so `v` is unbound: the
  // guard's constant list makes `v` fresh and walks on to `x`, pinning the
  // parameter to `Int`.
  let source =
    "import helper as r

pub type Row {
  Row(field: #(Int, Int))
}

pub fn run(x) {
  fn(cb) { cb(Row(#(0, 0))) }(fn(r) {
    case r.field {
      #(v, x) if [v, x] == [0, 0] -> Nil
      _ -> Nil
    }
  })
  x
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Int) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_constant_record_walks_every_argument_test() {
  // Probe `k_l_rv2_const_record_var`.
  // The same through a constant record's arguments: `Pair(v, x)` makes `v`
  // fresh and checks `x` against `Int`.
  let source =
    "import helper as r

pub type Pair {
  Pair(a: Int, b: Int)
}

pub type Row {
  Row(field: #(Int, Int))
}

pub fn run(x) {
  fn(cb) { cb(Row(#(0, 0))) }(fn(r) {
    case r.field {
      #(v, x) if Pair(v, x) == Pair(0, 0) -> Nil
      _ -> Nil
    }
  })
  x
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(Int) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_constant_update_copies_the_spread_arguments_test() {
  // Probe `k_l_rv2_const_update_copied`.
  // The tuple pattern meets the module's `String`, so `v` is the outer
  // `String`: the inline spread `Wrap(v, 0)` records the mismatch and keeps
  // `v`'s type, and the update copies `a` from that argument
  // (`constant.rs:353-390`), which fails the whole update. It is a fresh
  // variable, so `x` is not pinned to `Wrap`.
  let source =
    "import helper as r

pub type Wrap {
  Wrap(a: Int, label: Int)
}

pub type Row {
  Row(field: #(Int, Wrap))
}

pub fn run(x) {
  let v = \"outer\"
  fn(cb) { cb(Row(#(1, Wrap(0, 0)))) }(fn(r) {
    case r.field {
      #(v, x) if x == Wrap(..Wrap(v, 0), label: 1) -> Nil
      _ -> Nil
    }
  })
  let _: String = x
  v
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(String) -> String")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_skipped_binding_does_not_block_a_narrowing_test() {
  // Probe `k_l_rv3_skipped_shadow_narrows`.
  // The tuple pattern meets the module's `String`, so `#(t)` binds nothing
  // and `B` narrows the outer `t` (`pattern.rs:197-235`). `B` has no
  // `field`, so `t.field` is a fresh variable and `x` is left for the real
  // pass to make a `String`.
  let source =
    "import helper as r

pub type T {
  A(field: Int)
  B
}

pub type Payload {
  Payload(field: String)
}

pub type Row {
  Row(field: #(Payload))
}

pub fn run(x) {
  let t = A(0)
  fn(cb) { cb(Row(#(Payload(\"s\")))) }(fn(r) {
    case t, r.field {
      B, #(t) if x == t.field -> Nil
      _, _ -> Nil
    }
  })
  x
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(String) -> String")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_skipped_earlier_binding_does_not_block_a_narrowing_test() {
  // Probe `k_l_rv3_skipped_shadow_narrows_reversed`.
  // The same with the skipped tuple walked first: it has bound nothing when
  // `B` is walked, so it does not block the narrowing.
  let source =
    "import helper as r

pub type T {
  A(field: Int)
  B
}

pub type Payload {
  Payload(field: String)
}

pub type Row {
  Row(field: #(Payload))
}

pub fn run(x) {
  let t = A(0)
  fn(cb) { cb(Row(#(Payload(\"s\")))) }(fn(r) {
    case r.field, t {
      #(t), B if x == t.field -> Nil
      _, _ -> Nil
    }
  })
  x
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(String) -> String")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_skipped_alternative_bindings_keep_a_narrowing_test() {
  // Probe `k_l_rv4_alternative_skipped_bindings`.
  // Both tuple patterns meet the module's `String`, so neither alternative
  // binds `t` or `x`, and there are no bindings to reconcile: `t` stays
  // narrowed to `B`, so `t.field` is `B`'s `String` and pins the outer `x`
  // to it. The real pass binds `t` and reads `tmod`'s `Int` `field`.
  let source =
    "import helper as r
import tmod as t

pub type T {
  A
  B(field: String)
}

pub type Row {
  Row(field: #(T, Int))
}

pub fn run(t: T, x) {
  fn(cb) { cb(Row(#(B(\"s\"), 0))) }(fn(r) {
    case t, r.field {
      B(..), #(t, x) | _, #(t, x) -> x == t.field
      _, _ -> False
    }
  })
  let _: String = x
  x
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module\"
",
    ),
    #(
      "tmod",
      "pub const field = 1
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(T, String) -> String")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_nested_constant_update_fails_the_outer_update_test() {
  // Probe `k_l_rv4_nested_const_update`.
  // The inner update's `label: v` meets the outer `String`, so the inner
  // update is invalid, and an invalid spread fails the outer update
  // (`constant.rs:186-232`): a fresh variable, so `x` is not pinned to
  // `Wrap`.
  let source =
    "import helper as r

pub type Wrap {
  Wrap(a: Int, label: Int)
}

pub type Row {
  Row(field: #(Int, Wrap))
}

pub fn run(x) {
  let v = \"outer\"
  fn(cb) { cb(Row(#(1, Wrap(0, 0)))) }(fn(r) {
    case r.field {
      #(v, x) if x == Wrap(..Wrap(..Wrap(0, 0), label: v), a: 1) -> Nil
      _ -> Nil
    }
  })
  let _: String = x
  v
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(String) -> String")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_empty_block_is_a_fresh_todo_test() {
  // Probe `k_l_rv6_empty_block_spec`.
  // The projection fails and the tuple pattern binds no `x`, so `x == {}`
  // reads the outer `x`; the empty block is a fresh `todo`, so `x` is not
  // pinned to `Nil` and the later `let _: String = x` types.
  let source =
    "import helper as r

pub type Row {
  Row(field: #(Nil))
}

pub fn run(x) {
  fn(cb) { cb(Row(#(Nil))) }(fn(r) {
    let _ = r.field.0
    case r.field {
      #(x) -> x == {}
    }
  })
  let _: String = x
  x
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(String) -> String")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn real_pass_stays_strict_test() {
  // The same ill-typed argument fails a call that is not speculated with the
  // error it always had, and a speculated call whose real pass meets it is
  // still rejected: nothing recovers outside a speculative walk.
  let plain =
    "fn take(_value: Int) { Nil }
pub fn run() { take(\"s\".0) }
"
  let assert girard.NotATuple = error_with(plain, [])
  let speculated =
    "pub fn run() { fn(_value) { Nil }(\"s\".0) }
"
  let assert girard.NotATuple = error_with(speculated, [])
}

pub fn speculated_length_mismatch_binds_nothing_test() {
  // Probe `k_l_rv1_len_mismatch`. In speculation `r.field` is the module's `#(True, 1, 1)`, recorded
  // against the list's `#(x, Int)`: the lengths differ, so `x` is not bound to
  // `Bool`, and the real pass ties it to the record's parameter. 1.19.2:
  // `fn(a, Row(a)) -> a`.
  let source =
    "import helper as r
pub type Row(a) { Row(field: #(a, Int)) }
fn use_row(_row: Row(a)) { Nil }
pub fn run(x, r) {
  fn(_argument) {
    use_row(r)
    Nil
  }([#(x, 1), r.field])
  x
}
"
  let modules = [#("helper", "pub const field = #(True, 1, 1)\n")]
  signature(source, modules, "run") |> should.equal("fn(a, Row(a)) -> a")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn speculated_lambda_body_names_leave_scope_test() {
  // Probe `k_l_rv1_lambda_scope`. The speculated lambda's body recovers from `r.field.0` and closes its
  // scope: its `u` is gone, while the header's `t`, hydrated in the enclosing
  // scope, stays for the callee's `let _: t = y`. 1.19.2:
  // `fn(a, b, c, Row) -> #(d, b, e)`.
  let source =
    "import helper as r
pub type Row { Row(field: #(Int, Int)) }
fn use_row(_row: Row) { Nil }
pub fn run(x, y, z, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    let _: u = z
    Nil
  }(fn(_v: t) {
    let _: u = x
    r.field.0
  })
  #(x, y, z)
}
"
  let modules = [#("helper", "pub const field = \"module field\"\n")]
  signature(source, modules, "run")
  |> should.equal("fn(a, b, c, Row) -> #(d, b, e)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn unsupported_in_speculation_is_still_declined_test() {
  // An operator after an `as` message is girard declining syntax, not a type
  // error: speculation turns it into a fresh variable like any failure, and
  // the real pass declines the argument.
  let source =
    "pub fn run() {
  fn(_value) { Nil }({
    assert True as \"a\" <> \"b\"
    Nil
  })
}
"
  let assert girard.Unsupported(_) = error_with(source, [])
}

pub fn unsupported_in_speculation_keeps_the_real_pass_order_test() {
  // Probe `k_l_r2_unsupported_priority` (1.19.2 rejects it at parse time).
  // The second argument's `Unsupported` stops at its own argument, so the
  // real pass reports the first argument's mismatch first, as `main` does.
  let source =
    "pub fn run() {
  fn(_first: Int, _second) { Nil }(\"wrong\", {
    assert True as \"a\" <> \"b\"
    Nil
  })
}
"
  let assert girard.TypeMismatch(
    girard.Named("gleam", "String", []),
    girard.Named("gleam", "Int", []),
  ) = error_with(source, [])
}
