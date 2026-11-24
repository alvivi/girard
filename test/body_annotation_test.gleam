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
import glance
import gleam/dict
import gleam/list
import gleeunit/should
import probe_support.{
  annotations, callee_annotations, repeated_spans, resolution, scheme_of,
  signature,
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
  // The callback's `r.field + 1` fails while it is speculated and recovers,
  // so the callback still returns `Row`; the real pass types it.
  // (speculation_test pins the record field the callee's access resolves to.)
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

pub fn speculated_argument_recovers_inside_and_keeps_its_links_test() {
  // Probe `k_r8_spec_fold_poison`.
  // The first speculated argument's `r.field + 1` fails on the module's
  // `String` and recovers inside the argument, where the operator records
  // the mismatch, after `take(outer)` linked `r` to `Row`. The link is kept,
  // so the second argument's `r.field` is the record's. Dropping the first
  // argument's effects would read the module constant's `String` there and
  // reject the real pass.
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

pub fn guard_reads_a_constant_literal_variant_test() {
  // Probe `k_r6_constant_variant`.
  // A guard reads the constant's literal, which keeps the variant its value
  // was built with. `main` rejected it: type `Row` has no field `field`.
  let source =
    "pub type Row {
  A(field: Int)
  B
}

const value: Row = A(0)

pub fn run(x) {
  case x {
    _ if value.field == 0 -> 1
    _ -> 0
  }
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a) -> Int")
  resolution(source, modules, "value.field", 1)
  |> should.equal(girard.RecordField(girard.Named("", "Row", []), "field"))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn guard_reads_an_imported_constant_literal_variant_test() {
  // Probe `k_c2_import_constant_variant`.
  // The same through an unqualified import: the interface carries the
  // literal.
  let source =
    "import helper.{value}

pub fn run(x) {
  case x {
    _ if value.field == 0 -> 1
    _ -> 0
  }
}
"
  let modules = [
    #(
      "helper",
      "pub type Row {
  A(field: Int)
  B
}

pub const value: Row = A(0)
",
    ),
  ]
  signature(source, modules, "run") |> should.equal("fn(a) -> Int")
  resolution(source, modules, "value.field", 1)
  |> should.equal(girard.RecordField(girard.Named("helper", "Row", []), "field"))
  repeated_spans(source, modules) |> should.equal([])
}

pub fn body_generic_is_copied_after_a_let_value_test() {
  // Probe `k_omni_shape`.
  // omnimessage_lustre's `compose`: the let-bound lambda's `model` and `msg`
  // leave scope with the `let` value, so the reads in `#(omniinit,
  // omniupdate)` copy them and the two `Effect` message types come apart.
  // `main` tied them.
  let source =
    "pub type Effect(msg) {
  Effect(List(fn(fn(msg) -> Nil) -> Nil))
}

pub fn from(f: fn(fn(msg) -> Nil) -> Nil) -> Effect(msg) {
  Effect([f])
}

pub fn batch(effects: List(Effect(msg))) -> Effect(msg) {
  case effects {
    [] -> Effect([])
    [first, ..] -> first
  }
}

pub type Transport(msg) {
  Transport(send: fn(msg) -> Nil, listen: fn(fn(msg) -> Nil) -> Nil)
}

fn coded(transport: Transport(msg)) -> Transport(msg) {
  transport
}

fn compose(init, update, transport) {
  let t = coded(transport)
  let omniinit = fn(flags) {
    let transport_effect = from(fn(dispatch) { t.listen(dispatch) })
    let #(model, effect) = init(flags)
    #(model, batch([effect, transport_effect]))
  }
  let omniupdate = fn(model: model, msg: msg) {
    let #(updated_model, effect) = update(model, msg)
    #(updated_model, batch([from(fn(_dispatch) { t.send(msg) }), effect]))
  }
  #(omniinit, omniupdate)
}

pub fn app(init, update, transport) {
  let #(i, u) = compose(init, update, transport)
  #(i, u)
}
"
  let modules = []
  signature(source, modules, "app")
  |> should.equal(
    "fn(fn(a) -> #(b, Effect(c)), fn(d, c) -> #(e, Effect(f)), Transport(c)) -> #(fn(a) -> #(b, Effect(g)), fn(h, i) -> #(e, Effect(f)))",
  )
  annotations(source, modules, "#(omniinit, omniupdate)", 1)
  |> should.equal(["#(fn(a) -> #(b, Effect(c)), fn(d, e) -> #(f, Effect(g)))"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn body_annotation_reuses_a_signature_name_test() {
  // Probe `k_sig_reuse`.
  // A body annotation reusing a signature name is that variable. `main`:
  // `fn(a, b) -> #(a, b)`.
  let source =
    "pub fn pair(x: a, y) {
  let y: a = y
  #(x, y)
}
"
  let modules = []
  signature(source, modules, "pair") |> should.equal("fn(a, a) -> #(a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn body_generic_reaches_a_group_sibling_test() {
  // Probe `k_group_body_generic`.
  // A body generic of `b` reaches `a` through the shared, unannotated `x`
  // and is copied there. `main`: `fn(a, Int) -> a`.
  let source =
    "pub fn a(x, n: Int) -> v {
  case n {
    0 -> x
    _ -> b(x, n - 1)
  }
}

fn b(x, n: Int) {
  let y: v = x
  a(y, n)
}
"
  let modules = []
  signature(source, modules, "a") |> should.equal("fn(a, Int) -> b")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn body_annotation_reuses_a_name_in_a_group_test() {
  // Probe `k_group_sig_then_body`.
  // `b`'s body annotation is its own signature's `v`, which `a` copies at
  // each read. `main`: `fn(a, Int) -> a`.
  let source =
    "pub fn a(x, n: Int) -> v {
  case n {
    0 -> x
    _ -> b(x, n - 1, Nil)
  }
}

fn b(x, n: Int, _tag: v) {
  let y: v = x
  a(y, n)
}
"
  let modules = []
  signature(source, modules, "a") |> should.equal("fn(a, Int) -> b")
  callee_annotations(source, modules, "b(x, n - 1, Nil)", 1)
  |> should.equal(["fn(Nil, Int, Nil) -> a"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn lambda_parameter_name_stays_in_the_block_scope_test() {
  // Probe `k_stmt_leak`.
  // A lambda in a call argument hydrates its parameter annotation in the
  // enclosing block's scope, so the later `let z: a` reuses it. `main`:
  // `fn(a, b) -> #(a, b)`.
  let source =
    "fn apply(f: fn(x) -> x, x: x) -> x {
  f(x)
}

pub fn leak(p, q) {
  apply(fn(x: a) { x }, p)
  let z: a = q
  #(p, z)
}
"
  let modules = []
  signature(source, modules, "leak") |> should.equal("fn(a, a) -> #(a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn let_value_scope_drops_its_names_test() {
  // Probe `k_let_value_scope`.
  // The same lambda inside a `let` value: `a` leaves scope with the value.
  // `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "fn apply(f: fn(x) -> x, x: x) -> x {
  f(x)
}

pub fn scoped(p, q) {
  let _ = apply(fn(x: a) { x }, p)
  let z: a = q
  #(p, z)
}
"
  let modules = []
  signature(source, modules, "scoped") |> should.equal("fn(a, b) -> #(c, b)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn block_scope_drops_its_names_test() {
  // Probe `k_block_scope`.
  // A block's names leave scope with it, and reading `r` afterwards copies
  // its generic. `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "pub fn block_scope(p, q) {
  let r = {
    let y: a = p
    y
  }
  let z: a = q
  #(r, z)
}
"
  let modules = []
  signature(source, modules, "block_scope")
  |> should.equal("fn(a, b) -> #(c, b)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn bare_block_scope_drops_its_names_test() {
  // Probe `k_bare_block_scope`.
  // A bare block statement scopes its names too. `main`:
  // `fn(a, b) -> #(a, b)`.
  let source =
    "pub fn bare_block(p, q) {
  {
    let y: a = p
    y
  }
  let z: a = q
  #(p, z)
}
"
  let modules = []
  signature(source, modules, "bare_block")
  |> should.equal("fn(a, b) -> #(c, b)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn clause_scope_drops_its_names_test() {
  // Probe `k_clause_scope`.
  // A clause's names leave scope with it. `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "fn apply(f: fn(x) -> x, x: x) -> x {
  f(x)
}

pub fn clause_scope(p, q) {
  case p {
    _ -> apply(fn(x: a) { x }, p)
  }
  let z: a = q
  #(p, z)
}
"
  let modules = []
  signature(source, modules, "clause_scope")
  |> should.equal("fn(a, b) -> #(c, b)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn subject_scope_drops_its_names_test() {
  // Probe `k_subject_scope`.
  // A case subject's names leave scope with it. `main`:
  // `fn(a, b) -> #(a, b)`.
  let source =
    "fn apply(f: fn(x) -> x, x: x) -> x {
  f(x)
}

pub fn subject_scope(p, q) {
  case apply(fn(x: a) { x }, p) {
    _ -> Nil
  }
  let z: a = q
  #(p, z)
}
"
  let modules = []
  signature(source, modules, "subject_scope")
  |> should.equal("fn(a, b) -> #(c, b)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn lambda_body_scope_keeps_parameter_names_test() {
  // Probe `k_lambda_body_scope`.
  // A lambda body's `let` names leave scope with the body; its parameter
  // annotation's names belong to the enclosing scope. `main`:
  // `fn(a, b, c, d) -> #(a, b, d, c)`.
  let source =
    "fn apply2(f: fn(x, y) -> x, x: x, y: y) -> x {
  f(x, y)
}

pub fn lambda_body(p, q, s, t) {
  apply2(
    fn(x, _u: b) {
      let y: a = x
      y
    },
    p,
    s,
  )
  let z: a = q
  let w: b = t
  #(p, z, w, s)
}
"
  let modules = []
  signature(source, modules, "lambda_body")
  |> should.equal("fn(a, b, c, c) -> #(d, b, c, c)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn read_copies_an_unannotated_local_test() {
  // Probe `k_read_copies_local`.
  // An unannotated local whose type met a body generic is copied at each
  // read once the generic is out of scope. `main`:
  // `fn(a) -> #(#(a, a), #(a, a))`.
  let source =
    "pub fn copies(p) {
  let pair = #(p, p)
  let _ = fn(x: a) {
    let #(l, _) = pair
    let _: a = l
    x
  }
  #(pair, pair)
}
"
  let modules = []
  signature(source, modules, "copies")
  |> should.equal("fn(a) -> #(#(b, b), #(c, c))")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn guard_and_body_reads_copy_test() {
  // Probe `k_guard_read`.
  // Guard and body reads of a local that reached an out-of-scope generic
  // copy it. `main`: `fn(a, Int) -> #(a, a)`.
  let source =
    "pub fn guard(p, n: Int) {
  let r = {
    let y: a = p
    y
  }
  case n {
    _ if r == r -> #(r, p)
    _ -> #(r, p)
  }
}
"
  let modules = []
  signature(source, modules, "guard") |> should.equal("fn(a, Int) -> #(b, c)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn inner_lambda_sees_the_outer_lambda_names_test() {
  // Probe `k_nested_lambda_reuse`.
  // An inner lambda's parameter annotation is hydrated in the outer lambda's
  // body scope, where the outer `a` is visible. `main`:
  // `fn(a, b) -> #(a, b)`.
  let source =
    "pub fn nested(p, q) {
  let f = fn(x: a) {
    let g = fn(y: a) { y }
    let _ = g(q)
    #(x, q)
  }
  f(p)
}
"
  let modules = []
  signature(source, modules, "nested") |> should.equal("fn(a, b) -> #(a, a)")
  annotations(source, modules, "fn(y: a) { y }", 1)
  |> should.equal(["fn(a) -> a"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn capture_call_is_a_function_body_test() {
  // Probe `k_r1_capture`.
  // A capture is the lambda the parser makes of it, so its call is a
  // function body and the sibling lambda's `t` leaves scope with it.
  // `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "fn combine(x, cb, _hole) { cb(x) }
pub fn run(x, y) {
  combine(x, fn(v: t) { v }, _)
  let y: t = y
  #(x, y)
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a, b) -> #(c, b)")
  annotations(source, modules, "combine(x, fn(v: t) { v }, _)", 1)
  |> should.equal(["fn(a) -> b"])
  callee_annotations(source, modules, "combine(x, fn(v: t) { v }, _)", 1)
  |> should.equal(["fn(a, fn(a) -> a, b) -> a"])
  annotations(source, modules, "fn(v: t) { v }", 1)
  |> should.equal(["fn(a) -> a"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn capture_callee_speculates_its_arguments_test() {
  // Probe `k_r1_capture_callee`.
  // A capture callee speculates the call's argument first, so the argument's
  // `t` is in scope for the capture's body. `main` left the `combine`
  // reference untied.
  let source =
    "fn combine(a, cb, hole) {
  let _ = hole
  cb(a)
}

pub fn run(x) {
  combine(x, fn(v: t) { v }, _)(fn(w: t) { w })
  x
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a) -> a")
  callee_annotations(
    source,
    modules,
    "combine(x, fn(v: t) { v }, _)(fn(w: t) { w })",
    1,
  )
  |> should.equal(["fn(a, fn(a) -> a, fn(a) -> a) -> a"])
  annotations(source, modules, "fn(w: t) { w }", 1)
  |> should.equal(["fn(a) -> a"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn lambda_callee_speculation_keeps_names_test() {
  // Probe `k_r1_lambda_call`.
  // A lambda callee speculates its argument first, and the names the
  // argument creates stay in scope. `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "pub fn run(x, y) {
  fn(_z) -> t { y }(fn(v: t) { v }(x))
  #(x, y)
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a, a) -> #(a, a)")
  annotations(source, modules, "fn(v: t) { v }(x)", 1)
  |> should.equal(["a"])
  annotations(source, modules, "fn(_z) -> t { y }", 1)
  |> should.equal(["fn(a) -> a"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pipe_types_its_left_side_first_test() {
  // Probe `k_r1_pipe_order`.
  // A pipe types its left side before the step, so the left lambda's `t` is
  // in scope for the step's. `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "fn apply(x, f) { f(x) }
fn factory(f) { fn(_value) { f() } }
pub fn run(x, y) {
  apply(x, fn(v: t) { v })
  |> factory(fn() { let _: t = y
    y
  })
  #(x, y)
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a, a) -> #(a, a)")
  callee_annotations(source, modules, "factory(fn()", 1)
  |> should.equal(["fn(fn() -> a) -> fn(a) -> a"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pipe_call_step_reads_the_left_value_test() {
  // Probe `k_r1_pipe_read`.
  // A call step reads the piped value, which copies its escaped generic
  // before it meets `Int`. `main`: `fn(Int) -> Int`.
  let source =
    "fn take_int(x: Int) { x }
pub fn run(x) {
  { let _: t = x
    x
  } |> take_int()
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a) -> Int")
  annotations(source, modules, "{ let _: t = x\n    x\n  }", 1)
  |> should.equal(["a"])
  callee_annotations(source, modules, "take_int()", 1)
  |> should.equal(["fn(Int) -> Int"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn return_only_name_belongs_to_the_enclosing_scope_test() {
  // Probe `k_r1_return_scope`.
  // A name only a lambda's return annotation writes is hydrated before the
  // body, in the enclosing scope. `main`: `fn(a, b, c) -> #(a, b, c)`.
  let source =
    "pub fn run(x, y, z) {
  fn() -> t {
    let _: t = x
    y
  }
  let _: t = z
  #(x, y, z)
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a, a, a) -> #(a, a, a)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn use_with_a_lambda_callee_speculates_test() {
  // Probe `k_r1_use_applied`.
  // A `use` whose callee is a lambda speculates the callback first, so its
  // `t` is in scope for the callee's body. `main`: `fn(a, b) -> a`.
  let source =
    "pub fn run(x, y) {
  use a: t <- fn(cb) {
    let _: t = y
    cb(x)
  }()
  a
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a, a) -> a")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn complex_use_pattern_reads_its_parameter_test() {
  // Probe `k_r1_use_copy`.
  // A complex `use` pattern is a generated assignment that reads its
  // parameter, which copies the escaped generic. `main`:
  // `fn(#(Int, Int)) -> Int`.
  let source =
    "fn with(x, f) { f(x) }
pub fn run(x) {
  use #(a, _): #(Int, Int) <- with({ let _: t = x
    x
  })
  a + 1
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a) -> Int")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn use_patterns_hydrate_in_different_scopes_test() {
  // Probe `k_r1_use_scope`.
  // A simple `use` pattern's annotation is hydrated in the enclosing scope,
  // a complex one's in the callback body. `main` left `simple` untied.
  let source =
    "fn order(a, b, cb, next next) { #(cb(a), next(b)) }
pub fn simple(x, y) {
  use a: t <- order(x, y, next: fn(b: t) { b })
  a
}
pub fn complex(x, y) {
  use #(a, _): #(t, Int) <- order(#(x, 1), y, next: fn(b: t) { b })
  a
}
"
  let modules = []
  signature(source, modules, "simple") |> should.equal("fn(a, a) -> #(a, a)")
  signature(source, modules, "complex") |> should.equal("fn(a, b) -> #(a, b)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn use_callback_is_speculated_untyped_test() {
  // Probe `k_r2_use_spec_field`.
  // The callback is speculated with no expected type: its `b.field` is
  // deferred, `t` survives and the callee reuses it. `main`:
  // `fn(a, b) -> Int`.
  let source =
    "pub type Box {
  Box(field: Int)
}

pub fn run(x, y) {
  use a: t, #(b, _) <- fn(_x: t, cb) { cb(y, #(Box(1), 1)) }(x)
  let _ = a
  b.field
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a, a) -> Int")
  annotations(source, modules, "fn(_x: t, cb) { cb(y, #(Box(1), 1)) }", 1)
  |> should.equal(["fn(a, fn(a, #(Box, Int)) -> Int) -> Int"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn capture_argument_reads_its_hole_test() {
  // Probe `k_r5_capture_seed`.
  // A capture argument is seeded with the expected parameter type and reads
  // it at its hole, which copies the escaped generic. `main`:
  // `fn(Int) -> Int`.
  let source =
    "fn take_int(x: Int) { x }
fn with_capture(x: a, k: fn(a) -> Int) { k(x) }
pub fn run(x) {
  with_capture({
    let _: t = x
    x
  }, take_int(_))
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a) -> Int")
  callee_annotations(source, modules, "with_capture({", 1)
  |> should.equal(["fn(a, fn(a) -> Int) -> Int"])
  annotations(source, modules, "take_int(_)", 1)
  |> should.equal(["fn(a) -> Int"])
  callee_annotations(source, modules, "take_int(_)", 1)
  |> should.equal(["fn(Int) -> Int"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn capture_inner_lambda_callee_speculates_test() {
  // Probe `k_r5_capture_inner`.
  // A capture's inner lambda callee speculates the inner arguments first.
  // `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "pub fn run(x, y) {
  fn(_unused, _value) {
    let _: t = y
    Nil
  }(fn(v: t) { v }(x), _)(0)
  #(x, y)
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a, a) -> #(b, c)")
  annotations(source, modules, "fn(v: t) { v }(x)", 1)
  |> should.equal(["a"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pipe_literal_callee_is_not_speculated_test() {
  // Probe `k_r5_pipe_literal`.
  // A pipe types its call step's literal callee with no call context, so
  // its explicit argument is not speculated. `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "pub fn run(x, y) {
  0 |> fn(_f) {
    let _: t = y
    fn(_i: Int) { Nil }
  }(fn(z: t) { z }(x))
  #(x, y)
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a, b) -> #(a, c)")
  annotations(source, modules, "fn(z: t) { z }(x)", 1)
  |> should.equal(["a"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn pipe_reads_the_left_value_at_its_slot_test() {
  // Probe `k_r5_pipe_late_read`.
  // The piped value is read at the slot the reorder gives it, after the
  // labelled argument placed before it. `main`: `fn(Int) -> Int`.
  let source =
    "fn take(first _first: Nil, value v: Int) { v }
pub fn run(x) {
  x |> take(first: {
    let _: t = x
    Nil
  })
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(a) -> Int")
  annotations(source, modules, "x", 2)
  |> should.equal(["a"])
  callee_annotations(source, modules, "take(first:", 1)
  |> should.equal(["fn(Nil, Int) -> Int"])
  repeated_spans(source, modules) |> should.equal([])
}

pub fn guard_uses_an_annotated_constant_generic_test() {
  // Probe `k_r5_const_guard`.
  // A guard reads the annotated constant's own generic, which later reads
  // of `x` copy. `main`: `fn(List(a)) -> List(a)`.
  let source =
    "const xs: List(a) = []
pub fn run(x) {
  case x {
    _ if x == xs -> x
    _ -> x
  }
}
"
  let modules = []
  signature(source, modules, "run") |> should.equal("fn(List(a)) -> List(b)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn failed_speculative_callback_leaves_names_to_the_real_pass_test() {
  // Probe `k_r6_spec_stmt`.
  // The speculated callback's `r.field + 1` fails and recovers, and its body
  // ties `x` and `y` through `t`; `t` is created inside the callback's body,
  // so it leaves scope with it, and the real pass creates it again.
  // `main`: `fn(a, b) -> #(a, b)`.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

fn pick(x, f, _field: Int) { f(x) }

pub fn run(x, y) {
  fn(callback) { callback(Row(0)) }(fn(r) {
    pick(x, fn(v: t) { v }, r.field + 1)
    let _: t = y
    Nil
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
  signature(source, modules, "run") |> should.equal("fn(a, a) -> #(b, c)")
  repeated_spans(source, modules) |> should.equal([])
}

pub fn failed_speculative_header_leaves_names_to_the_real_pass_test() {
  // Probe `k_r7_spec_header`.
  // The speculated lambda's header stops at `_i: Int`, which the module's
  // `String` fails, before `v: t`, so its `t` is created by the real pass and
  // ties `x`; the callee's body generic on `y` leaves scope. `main`:
  // `fn(a, b, Row) -> #(a, b)`.
  let source =
    "import helper as r

pub type Row {
  Row(field: Int)
}

fn use_row(_row: Row) { Nil }

pub fn run(x, y, r) {
  fn(_argument) {
    use_row(r)
    let _: t = y
    Nil
  }(fn(_i: Int, v: t) { v }(r.field, x))
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

pub fn imported_constant_literal_survives_a_cache_hit_test() {
  // Probe `k_c2_import_constant_variant`, once inferring `helper` and once
  // reusing its interface from the cache, with a resolver that no longer has
  // it: a reused interface carries the literal's variant too.
  let source =
    "import helper.{value}

pub fn run(x) {
  case x {
    _ if value.field == 0 -> 1
    _ -> 0
  }
}
"
  let helper = [
    #(
      "helper",
      "pub type Row {
  A(field: Int)
  B
}

pub const value: Row = A(0)
",
    ),
  ]
  let #(fresh, cache) =
    girard.annotate_with_cache(
      source,
      probe_support.options_with(helper),
      girard.new_cache(),
    )
  let assert Ok(fresh) = fresh
  scheme_of(fresh.functions, "run") |> should.equal("fn(a) -> Int")
  let #(cached, _) =
    girard.annotate_with_cache(source, probe_support.options_with([]), cache)
  let assert Ok(cached) = cached
  scheme_of(cached.functions, "run") |> should.equal("fn(a) -> Int")
}

pub fn imported_constant_generic_survives_a_cache_hit_test() {
  // Probe `k_r6_import_const`, once inferring `helper` and once reusing its
  // interface from the cache: a guard's unqualified `xs` ties `x` to the
  // literal's own generic, which later reads copy, while the qualified
  // `helper.xs` is an ordinary read. `main` tied both.
  let source =
    "import helper.{xs}

pub fn run(x) {
  case x {
    _ if x == xs -> x
    _ -> x
  }
}

pub fn qualified(x) {
  case x {
    _ if x == helper.xs -> x
    _ -> x
  }
}
"
  let helper = [
    #(
      "helper",
      "pub const xs: List(a) = []
",
    ),
  ]
  let #(fresh, cache) =
    girard.annotate_with_cache(
      source,
      probe_support.options_with(helper),
      girard.new_cache(),
    )
  let assert Ok(fresh) = fresh
  scheme_of(fresh.functions, "run") |> should.equal("fn(List(a)) -> List(b)")
  scheme_of(fresh.functions, "qualified")
  |> should.equal("fn(List(a)) -> List(a)")
  let #(cached, _) =
    girard.annotate_with_cache(source, probe_support.options_with([]), cache)
  let assert Ok(cached) = cached
  scheme_of(cached.functions, "run") |> should.equal("fn(List(a)) -> List(b)")
  scheme_of(cached.functions, "qualified")
  |> should.equal("fn(List(a)) -> List(a)")
}

pub fn constant_literal_is_a_snapshot_across_modules_test() {
  // Probe `k_r7_constant_shared_import`, in dependency order through
  // `annotate_package`. 1.19.2 shares a constant's literal across a package
  // build, so `pinning`'s guard pins `xs` to `List(Int)` for the consumer too:
  // `fn(List(Int)) -> List(Int)`. girard's literal is a snapshot taken when
  // `helper` is inferred, so the consumer keeps `fn(List(a)) -> List(a)`, as
  // `main` does. Sharing it live is left to the follow-up on speculation
  // recovery and live constant literals (PR L).
  let helper =
    "pub const xs = []
"
  let pinning =
    "import helper.{xs}

pub fn pin() {
  case True {
    _ if xs == [1] -> Nil
    _ -> Nil
  }
}
"
  let consumer =
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
  let assert Ok(helper_module) = glance.module(helper)
  let assert Ok(pinning_module) = glance.module(pinning)
  let assert Ok(consumer_module) = glance.module(consumer)
  let results =
    girard.annotate_package(
      [
        #("helper", helper_module),
        #("pinning", pinning_module),
        #("consumer", consumer_module),
      ],
      probe_support.options_with([#("helper", helper), #("pinning", pinning)]),
    )
  list.each(["helper", "pinning", "consumer"], fn(path) {
    let assert Ok(result) = dict.get(results, path)
    girard.is_complete(result) |> should.be_true
  })
  let assert Ok(result) = dict.get(results, "consumer")
  scheme_of(result.annotated.functions, "run")
  |> should.equal("fn(List(a)) -> List(a)")
}
