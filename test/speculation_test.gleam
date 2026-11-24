// The compiler's order where it decides what a failure skips, and the
// probes that pin it against Gleam 1.19.2: unification compares lengths
// before any element, a pattern size reads its own scope, a later `case`
// alternative sees the first one's bindings, a guard's `name.label` is
// classified by the guard-variable lookup, and a record update copies every
// field it does not name.
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
  let source = "pub fn f(a) { [#(a, 1), #(True, 1, 1)] }"
  let assert girard.TypeMismatch(girard.Tuple([_, _, _]), girard.Tuple([_, _])) =
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
