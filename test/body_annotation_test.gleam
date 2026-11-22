// Probe tests for body annotations scoped as the compiler's hydrator scopes
// them: one annotation scope per function, the compiler's five scope
// boundaries, every read copying the generics the scope does not own, the
// typing order the scope depends on, and a guard's read of a constant's
// literal.
//
// Every test here is a probe from girard's PR K inventory, run through the
// normal entry point with Gleam 1.19.2's answer pinned: the signatures its
// interface exports, and, where the probe's point is an expression, the
// expression's type or resolution. Each test names its probe, and every one
// checks that no expression is annotated twice.

import girard
import gleeunit/should
import probe_support.{
  annotations, callee_annotations, repeated_spans, resolution, signature,
}

pub fn block_value_is_not_a_read_test() {
  // Probe `k_block_value_no_read`.
  // A block's value is not a read: returning it keeps the tie that binding
  // it and reading it after the block (k_block_scope) copies.
  let source =
    "pub fn block_value(x) {
  {
    let y: a = x
    y
  }
}
"
  let modules = []
  signature(source, modules, "block_value") |> should.equal("fn(a) -> a")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn in_scope_body_generic_is_not_copied_test() {
  // Probe `k_body_return`.
  // A body annotation's generic read while still in scope is not copied.
  let source =
    "pub fn body_return(x) {
  let y: a = x
  y
}
"
  let modules = []
  signature(source, modules, "body_return") |> should.equal("fn(a) -> a")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn let_bound_annotated_lambda_is_polymorphic_test() {
  // Probe `k_let_poly`.
  // A let-bound annotated lambda is used at two types.
  let source =
    "pub fn main() {
  let id = fn(x: a) -> a { x }
  #(id(1), id(\"hi\"))
}
"
  let modules = []
  signature(source, modules, "main") |> should.equal("fn() -> #(Int, String)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn lambda_shares_names_across_its_annotations_test() {
  // Probe `k_param_then_return`.
  // One lambda's parameter and return annotations share a name.
  let source =
    "pub fn shared(p, q) {
  let f = fn(x: a, y: a) -> a {
    let _ = y
    x
  }
  f(p, q)
}
"
  let modules = []
  signature(source, modules, "shared") |> should.equal("fn(a, a) -> a")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn case_subjects_and_clauses_are_scoped_apart_test() {
  // Probe `k_r1_case_pair`.
  // Two subjects, and two clauses, each introduce `t` in a scope of its own.
  let source =
    "fn touch(x, f) { let _ = f(x) Nil }
pub fn subjects(x, y) {
  case touch(x, fn(v: t) { v }), touch(y, fn(v: t) { v }) {
    _, _ -> Nil
  }
  Nil
}
pub fn clauses(flag, x, y) {
  case flag {
    True -> touch(x, fn(v: t) { v })
    False -> touch(y, fn(v: t) { v })
  }
}
"
  let modules = []
  signature(source, modules, "subjects") |> should.equal("fn(a, b) -> Nil")
  signature(source, modules, "clauses") |> should.equal("fn(Bool, a, b) -> Nil")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn copied_generic_keeps_variant_stamps_test() {
  // Probe `k_r1_variant`.
  // A let-bound lambda's result keeps the variant it was built with at each
  // read, so the variant-only field is in reach at both types.
  let source =
    "pub type Choice(a) { Chosen(value: a) Missing }
pub fn run() {
  let wrap = fn(v: t) { Chosen(v) }
  #(wrap(1).value, wrap(\"s\").value)
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn() -> #(Int, String)")
  resolution(source, modules, "wrap(1).value", 1)
  |> should.equal(girard.RecordField(
    girard.Named("", "Choice", [girard.Named("gleam", "Int", [])]),
    "value",
  ))
  resolution(source, modules, "wrap(\"s\").value", 1)
  |> should.equal(girard.RecordField(
    girard.Named("", "Choice", [girard.Named("gleam", "String", [])]),
    "value",
  ))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn failed_speculation_keeps_a_direct_field_shape_test() {
  // Probe `k_r6_spec_shape`.
  // The callback fails to type while it is speculated, so the whole pass is
  // rewound; the real pass types it. (1.19.2 resolves
  // `callback(Row(0)).field` as a record field at the access; girard
  // defers it, a difference left to the speculation recovery follow-up.)
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
  repeated_spans(source, modules) |> should.equal([])
}

pub fn failed_speculation_keeps_an_annotated_return_test() {
  // Probe `k_r7_spec_annotated_return`.
  // A callback whose annotated return fails while speculated.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

pub fn run() {
  fn(callback) {
    callback(Row(0))
  }(fn(r) -> Int {
    r.field
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

pub fn failed_speculation_rewinds_the_whole_pass_test() {
  // Probe `k_r8_spec_fold_poison`.
  // The first speculated argument fails, so the whole pass is rewound: a
  // fold that kept the second argument's speculation would read the module
  // constant's `String` and reject the real pass.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

fn take(_value: Row) { Nil }

pub fn run(r) {
  let outer = r
  fn(callback, second) {
    take(r)
    callback(Row(0))
    second
  }(fn(r) {
    take(outer)
    r.field + 1
  }, r.field)
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
  annotations(
    source,
    modules,
    "fn(r) {\n    take(outer)\n    r.field + 1\n  }",
    1,
  )
  |> should.equal(["fn(Row) -> Int"])
  annotations(source, modules, "r.field", 2)
  |> should.equal(["Int"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn use_patterns_hydrate_their_annotations_test() {
  // Probe `k_use_annotation`.
  // A `use` with an annotated variable pattern and an annotated tuple
  // pattern.
  let source =
    "fn with(x: x, f: fn(x) -> y) -> y {
  f(x)
}

pub fn use_it(p, q) {
  use a: a <- with(p)
  use #(b, _): #(b, Int) <- with(#(q, 1))
  let c: a = a
  #(c, b)
}
"
  let modules = []
  signature(source, modules, "use_it") |> should.equal("fn(a, b) -> #(a, b)")
  callee_annotations(source, modules, "with(p)", 1)
  |> should.equal(["fn(a, fn(a) -> #(a, b)) -> #(a, b)"])
  callee_annotations(source, modules, "with(#(q, 1))", 1)
  |> should.equal(["fn(#(a, Int), fn(#(a, Int)) -> #(b, a)) -> #(b, a)"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pipe_lambda_parameter_forgets_the_seed_variant_test() {
  // Probe `k_r6_pipe_variant`.
  // A piped lambda's parameter takes its own type, unified with the piped
  // value's, which forgets the variant `A(0)` was built with: `r.field` is
  // then the module constant. `main` read the variant field: `fn() -> Int`.
  let source =
    "import helper as r

pub type Row {
  A(field: Int)
  B
}

pub fn run() {
  A(0) |> fn(r) { r.field }
}
"
  let modules = [
    #(
      "helper",
      "pub const field = \"module field\"
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn() -> String")
  resolution(source, modules, "r.field", 1)
  |> should.equal(girard.ModuleConstant("helper", "field"))
  annotations(source, modules, "A(0)", 1)
  |> should.equal(["Row"])
  annotations(source, modules, "fn(r) { r.field }", 1)
  |> should.equal(["fn(Row) -> String"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn rewritten_paths_annotate_each_expression_once_test() {
  // Probe `k_c1_rewritten_paths`.
  // Every path typed in the compiler's order records each source
  // expression once: a pipe's left side, call step and callee, a capture with
  // its callee and arguments, a literal callee, and a `use` callee.
  let source =
    "fn add(a: Int, b: Int) -> Int {
  a + b
}

fn adder(a: Int) -> fn(Int) -> Int {
  fn(b) { a + b }
}

fn with(x: a, f: fn(a) -> b) -> b {
  f(x)
}

pub fn run(x: Int) -> Int {
  let p = x |> add(1)
  let q = x |> adder(2)
  let r = x |> fn(v) { v + 1 }
  let s = x |> add(_, 3)
  let t = with(x, add(_, 4))
  let u = add(_, 5)(x)
  use v <- fn(f) { f(x) }
  p + q + r + s + t + u + v
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(Int) -> Int")
  annotations(source, modules, "x |> add(1)", 1)
  |> should.equal(["Int"])
  annotations(source, modules, "add(1)", 1)
  |> should.equal(["Int"])
  callee_annotations(source, modules, "add(1)", 1)
  |> should.equal(["fn(Int, Int) -> Int"])
  annotations(source, modules, "adder(2)", 1)
  |> should.equal(["fn(Int) -> Int"])
  callee_annotations(source, modules, "adder(2)", 1)
  |> should.equal(["fn(Int) -> fn(Int) -> Int"])
  annotations(source, modules, "fn(v) { v + 1 }", 1)
  |> should.equal(["fn(Int) -> Int"])
  annotations(source, modules, "add(_, 3)", 1)
  |> should.equal(["fn(Int) -> Int"])
  callee_annotations(source, modules, "add(_, 3)", 1)
  |> should.equal(["fn(Int, Int) -> Int"])
  callee_annotations(source, modules, "with(x, add(_, 4))", 1)
  |> should.equal(["fn(Int, fn(Int) -> Int) -> Int"])
  annotations(source, modules, "add(_, 4)", 1)
  |> should.equal(["fn(Int) -> Int"])
  annotations(source, modules, "add(_, 5)", 1)
  |> should.equal(["fn(Int) -> Int"])
  callee_annotations(source, modules, "add(_, 5)", 1)
  |> should.equal(["fn(Int, Int) -> Int"])
  annotations(source, modules, "add(_, 5)(x)", 1)
  |> should.equal(["Int"])
  annotations(source, modules, "fn(f) { f(x) }", 1)
  |> should.equal(["fn(fn(Int) -> Int) -> Int"])
  repeated_spans(source, modules) |> should.equal([])
}
