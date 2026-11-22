// The dependency order of a module's top-level definitions, and the call
// graph it is computed from, against Gleam 1.19.2's
// `compiler-core/src/call_graph.rs`.
//
// The first section ports the compiler's own dependency-order tests. The
// second pins `reference.dependency_edges`, each node's neighbour list, on
// cases where the groups alone could hide an extra, a missing or a
// deduplicated edge. Every expected value there is what the compiler's
// builder printed for the same source: a dump compiled from the checked-out
// `call_graph.rs`, printing `into_dependency_order`'s groups and each node's
// `neighbors()`. Where girard intentionally answers differently, the test pins
// girard's answer and its comment gives the compiler's. The last section
// checks that target filtering reaches the order through `girard.annotate`.

import girard
import girard/internal/reference
import glance
import gleam/list
import gleam/set
import gleam/string
import gleeunit/should

// The compiler's dependency-order tests
//
// The 50 successful cases of
// `compiler-core/src/call_graph/into_dependency_order_tests.rs`, each named
// after its Rust test (`use_` loses its keyword underscore). A case gives its
// functions as (name, argument names, body) and its constants as (name,
// value); `order` renders them as a module, parses it with glance and returns
// `reference.dependency_order`, which must match the compiler's groups and the
// order of the members inside each.
//
// The two duplicate-name cases (`duplicate_external_function_name` and
// `duplicate_function_name`) are not ported: girard takes code the compiler
// accepts and does not diagnose a duplicate definition.

pub fn empty_test() {
  order([], [])
  |> should.equal([])
}

pub fn no_deps_test() {
  order(
    [
      #("a", [], "1"),
      #("b", [], "\"ok\""),
      #("c", [], "1"),
      #("d", [], "1.0"),
      #("e", [], "todo"),
    ],
    [],
  )
  |> should.equal([["a"], ["b"], ["c"], ["d"], ["e"]])
}

pub fn one_dep_test() {
  order([#("a", [], "1"), #("b", [], "c"), #("c", [], "0")], [])
  |> should.equal([["a"], ["c"], ["b"]])
}

pub fn unknown_vars_test() {
  order([#("a", [], "1"), #("b", [], "Nil"), #("c", [], "Ok")], [])
  |> should.equal([["a"], ["b"], ["c"]])
}

pub fn calling_function_test() {
  order([#("a", [], "b()"), #("b", [], "c(1, 2)"), #("c", [], "1")], [])
  |> should.equal([["c"], ["b"], ["a"]])
}

pub fn ref_in_call_argument_test() {
  order([#("a", [], "c(1, b())"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["b"], ["c"], ["a"]])
}

pub fn sequence_test() {
  order([#("a", [], "c({ 1 2 b })"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["b"], ["c"], ["a"]])
}

pub fn tuple_test() {
  order([#("a", [], "#(b, c, 1)"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["c"], ["b"], ["a"]])
}

pub fn pipeline_test() {
  order([#("a", [], "1 |> b |> c"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["c"], ["b"], ["a"]])
}

pub fn list_test() {
  order([#("a", [], "[b, b, c, 1]"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["c"], ["b"], ["a"]])
}

pub fn list_spread_test() {
  order([#("a", [], "[b, b, ..c]"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["c"], ["b"], ["a"]])
}

pub fn record_access_test() {
  order([#("a", [], "1"), #("b", [], "b().wibble"), #("c", [], "123")], [])
  |> should.equal([["a"], ["b"], ["c"]])
}

pub fn binop_test() {
  order(
    [
      #("a", [], "1 + a() + 2 / b() * 4"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn bit_arrays_test() {
  order([#("a", [], "<<b, c>>"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["c"], ["b"], ["a"]])
}

pub fn tuple_index_test() {
  order([#("a", [], "b.0"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn record_update_test() {
  order(
    [
      #("a", [], "Wibble(..b, wobble: c())"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["c"], ["b"], ["a"]])
}

pub fn negate_test() {
  order([#("a", [], "!c()"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["c"], ["a"], ["b"]])
}

pub fn use_test() {
  order([#("a", [], "use x <- c"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["c"], ["a"], ["b"]])
}

pub fn use_shadowing_test() {
  order(
    [#("a", [], "123"), #("b", [], "{ use c <- a c }"), #("c", [], "1")],
    [],
  )
  |> should.equal([["a"], ["b"], ["c"]])
}

pub fn fn_argument_shadowing_test() {
  order([#("a", [], "fn(b) { c b }"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["c"], ["a"], ["b"]])
}

pub fn fn_argument_shadowing_then_not_test() {
  order(
    [#("a", [], "{ fn(b) { c b } b }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["b"], ["c"], ["a"]])
}

pub fn let_var_test() {
  order([#("a", [], "{ let c = b c }"), #("b", [], "123"), #("c", [], "1")], [])
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn pattern_int_test() {
  order([#("a", [], "{ let 1 = x }")], [])
  |> should.equal([["a"]])
}

pub fn pattern_float_test() {
  order([#("a", [], "{ let 1.0 = x }")], [])
  |> should.equal([["a"]])
}

pub fn pattern_string_test() {
  order([#("a", [], "{ let \"1.0\" = x }")], [])
  |> should.equal([["a"]])
}

pub fn pattern_underscore_test() {
  order([#("a", [], "{ let _ = x }")], [])
  |> should.equal([["a"]])
}

pub fn pattern_concat_test() {
  order(
    [
      #("a", [], "{ let \"a\" <> c = b c }"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn pattern_tuple_test() {
  order(
    [#("a", [], "{ let #(a, c) = b a c }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn pattern_list_test() {
  order(
    [#("a", [], "{ let [a, c] = b a c }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn pattern_list_spread_test() {
  order(
    [
      #("a", [], "{ let [a, ..c] = b a c }"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn pattern_bit_array_segment_size_var_usage_test() {
  order(
    [
      #("a", [], "{ let <<y:size(b), _:unit(3)>> = c y }"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["b"], ["c"], ["a"]])
}

pub fn pattern_assign_test() {
  order(
    [#("a", [], "{ let 1 as b = c b }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["c"], ["a"], ["b"]])
}

pub fn pattern_constructor_test() {
  order(
    [#("a", [], "{ let Ok(b) = c b }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["c"], ["a"], ["b"]])
}

pub fn scope_reset_test() {
  order(
    [
      #("a", [], "{ let x = { let b = 1 b } b }"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn case_subject_test() {
  order(
    [#("a", [], "case b { _ -> 1 }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn case_subjects_test() {
  order(
    [#("a", [], "case b, c { _, _ -> 1 }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["c"], ["b"], ["a"]])
}

pub fn case_pattern_shadow_test() {
  order(
    [#("a", [], "case 1 { b -> b }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["a"], ["b"], ["c"]])
}

pub fn case_use_in_clause_test() {
  order(
    [#("a", [], "case 1 { _ -> b }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn case_clause_doesnt_shadow_later_clauses_test() {
  order(
    [
      #("a", [], "case 1 { b -> 1 _ -> b }"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn case_clause_doesnt_shadow_after_test() {
  order(
    [
      #("a", [], "{ case 1 { b -> 1 } b }"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn guard_test() {
  order(
    [#("a", [], "case 1 { _ if b -> 1 }"), #("b", [], "123"), #("c", [], "1")],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn big_guard_test() {
  order(
    [
      #("a", [], "case 1 { _ if 1 == 2 || x != #(Ok(b), 123) -> 1 }"),
      #("b", [], "123"),
      #("c", [], "1"),
    ],
    [],
  )
  |> should.equal([["b"], ["a"], ["c"]])
}

pub fn more_complex_cycle_test() {
  order(
    [
      #("a1", [], "{ a2 }"),
      #("a2", [], "{ a3 a1 }"),
      #("a3", [], "{ a1 }"),
    ],
    [],
  )
  |> should.equal([["a3", "a2", "a1"]])
}

pub fn function_argument_shadowing_test() {
  order([#("a", ["b"], "b"), #("b", [], "Nil")], [])
  |> should.equal([["a"], ["b"]])
}

pub fn constants_and_functions_test() {
  order([#("a", ["b"], "b"), #("b", [], "c")], [#("d", "c"), #("c", "a")])
  |> should.equal([["a"], ["c"], ["b"], ["d"]])
}

// https://github.com/gleam-lang/gleam/issues/2275
pub fn bug_2275_test() {
  order([#("one", [], "two one"), #("two", [], "two")], [])
  |> should.equal([["two"], ["one"]])
}

pub fn let_assert_message_test() {
  order(
    [#("a", [], "{ let assert True = False as b() }"), #("b", [], "a()")],
    [],
  )
  |> should.equal([["b", "a"]])
}

pub fn assert_subject_test() {
  order([#("a", [], "{ assert b() }"), #("b", [], "a()")], [])
  |> should.equal([["b", "a"]])
}

pub fn assert_message_test() {
  order([#("a", [], "{ assert False as b() }"), #("b", [], "a()")], [])
  |> should.equal([["b", "a"]])
}

pub fn multiple_two_cycles_test() {
  order(
    [
      #("a", [], "{ b }"),
      #("b", [], "{ c1 }"),
      #("c1", [], "{ c2 }"),
      #("c2", [], "{ c1 d1 }"),
      #("d1", [], "{ d2 }"),
      #("d2", [], "{ d1 }"),
    ],
    [],
  )
  |> should.equal([["d2", "d1"], ["c2", "c1"], ["b"], ["a"]])
}

// The compiler's call graph, edge by edge
//
// `dependency_edges` lists every node, functions in source order and then
// constants in source order, with its neighbours newest reference first and
// duplicates kept: the order petgraph's `neighbors()` yields them in, which is
// the order its Tarjan visits them in. The D numbers are the differences
// between girard's old collector and the compiler that PR H closed, the Q
// numbers the compiler's quirks girard mirrors (PR H §3 and §2.6).

pub fn branching_component_keeps_every_edge_newest_first_test() {
  // `a` references `b`, `c`, `b` in walk order, and both reference `a` back.
  // The raw list `[b, c, b]` keeps the duplicate, and the members come out in
  // finish order, root last: `b, c, a`. Reversed discovery order, or a list
  // deduplicated by first or by newest occurrence, gives another answer.
  let source =
    "pub fn a() -> Int { b() + c() + b() }\n"
    <> "pub fn b() -> Int { a() }\n"
    <> "pub fn c() -> Int { a() }\n"
  edges_of(source)
  |> should.equal([#("a", ["b", "c", "b"]), #("b", ["a"]), #("c", ["a"])])
  order_of(source)
  |> should.equal([["b", "c", "a"]])
}

pub fn d1_nodes_are_functions_then_constants_in_source_order_test() {
  // D1: the compiler numbers the functions in source order, then the
  // constants in source order, whatever the interleaving, and tries Tarjan's
  // roots in that order. The old collector took glance's order, which
  // reverses each list, and gave `fourth|third|second|first`.
  let source =
    "pub const first = 1\n"
    <> "pub fn second() -> Int { third }\n"
    <> "pub const third = 3\n"
    <> "pub fn fourth() -> Int { 4 }\n"
  edges_of(source)
  |> should.equal([
    #("second", ["third"]),
    #("fourth", []),
    #("first", []),
    #("third", []),
  ])
  order_of(source)
  |> should.equal([["third"], ["second"], ["fourth"], ["first"]])
}

pub fn d2_members_are_in_finish_order_root_last_test() {
  // D2: petgraph's Tarjan (Pearce's variant) pushes a node when it finishes,
  // so a component lists its members in finish order with the root last,
  // `c, b, a`, not in discovery order, `a, b, c`.
  let source =
    "pub fn a() { b() }\n" <> "pub fn b() { c() }\n" <> "pub fn c() { a() }\n"
  edges_of(source)
  |> should.equal([#("a", ["b"]), #("b", ["c"]), #("c", ["a"])])
  order_of(source)
  |> should.equal([["c", "b", "a"]])
}

pub fn d5_qualifier_is_an_edge_in_walk_order_test() {
  // D5: `m.label` is module access to `helper`, but the compiler walks a
  // field access's container like any expression, so it references the
  // top-level `m` (Q1), in walk order between the two calls. The old
  // collector kept qualifiers in a separate list, appended after the values.
  let source =
    "import helper as m\n"
    <> "pub fn run() { #(first(), m.label, last()) }\n"
    <> "pub fn first() { 1 }\n"
    <> "pub fn m() { 2 }\n"
    <> "pub fn last() { 3 }\n"
  edges_of(source)
  |> should.equal([
    #("run", ["last", "m", "first"]),
    #("first", []),
    #("m", []),
    #("last", []),
  ])
  order_of(source)
  |> should.equal([["last"], ["m"], ["first"], ["run"]])
}

pub fn d7_let_assert_walks_value_pattern_then_message_test() {
  // D7: the compiler walks a `let assert` as value, pattern, message
  // (`call_graph.rs:155-166`), so the pattern's `size(width)` is referenced
  // before the message's `message()`. The old collector walked value,
  // message, pattern.
  let source =
    "pub fn run() -> Int {\n"
    <> "  let assert <<v:size(width)>> = bits() as message()\n"
    <> "  v\n"
    <> "}\n"
    <> "pub fn bits() -> BitArray { <<1>> }\n"
    <> "pub fn message() -> String { \"no match\" }\n"
    <> "pub const width = 8\n"
  edges_of(source)
  |> should.equal([
    #("run", ["message", "width", "bits"]),
    #("bits", []),
    #("message", []),
    #("width", []),
  ])
  order_of(source)
  |> should.equal([["message"], ["width"], ["bits"], ["run"]])
}

pub fn d8_case_clause_walks_patterns_guard_then_body_test() {
  // D8: the compiler walks a clause's patterns, then its guard, then its
  // body (`call_graph.rs:306-323`). The old collector walked the body before
  // the guard.
  let source =
    "pub fn run(x: BitArray) -> Int {\n"
    <> "  case x {\n"
    <> "    <<v:size(width)>> if v > limit -> body()\n"
    <> "    _ -> 0\n"
    <> "  }\n"
    <> "}\n"
    <> "pub fn body() -> Int { 1 }\n"
    <> "pub const width = 8\n"
    <> "pub const limit = 0\n"
  edges_of(source)
  |> should.equal([
    #("run", ["body", "limit", "width"]),
    #("body", []),
    #("width", []),
    #("limit", []),
  ])
  order_of(source)
  |> should.equal([["body"], ["limit"], ["width"], ["run"]])
}

pub fn d11_constant_bit_array_walks_each_segment_test() {
  // D11: the compiler walks a constant bit array's segments in order, each
  // segment's options and then its value (`call_graph.rs:511-518`); the old
  // collector walked the values only. The options cannot show it from source
  // the compiler accepts: its constant parser takes only an int literal in
  // `size` (`expect_const_int`, `parse.rs:4168`), and rejects
  // `<<value:size(width)>>`, which glance parses. So this pins the segment
  // values in walk order.
  let source =
    "pub const bits = <<low:size(8), high:size(8)>>\n"
    <> "pub const low = 1\n"
    <> "pub const high = 2\n"
  edges_of(source)
  |> should.equal([#("bits", ["high", "low"]), #("low", []), #("high", [])])
  order_of(source)
  |> should.equal([["high"], ["low"], ["bits"]])
}

pub fn d13_guard_constant_subtrees_reference_nothing_test() {
  // D13: the compiler parses a guard's `#(m.value)` and `m.Box(42)` as
  // constants (`parse_case_clause_guard_unit`), where a qualified name or
  // constructor is never a reference, while a direct `m.value` is a guard
  // field access whose container `m` is referenced (Q1). The old collector
  // walked all three as expressions.
  let source =
    "import helper as m\n"
    <> "pub fn direct(x: Int) -> Int { case x { _ if x == m.value -> 1 _ -> 0 } }\n"
    <> "pub fn tuple(x: #(Int)) -> Int { case x { _ if x == #(m.value) -> 1 _ -> 0 } }\n"
    <> "pub fn record(x: m.Box) -> Int { case x { _ if x == m.Box(42) -> 1 _ -> 0 } }\n"
    <> "pub fn m() -> Int { 4 }\n"
  edges_of(source)
  |> should.equal([
    #("direct", ["m"]),
    #("tuple", []),
    #("record", []),
    #("m", []),
  ])
  order_of(source)
  |> should.equal([["m"], ["direct"], ["tuple"], ["record"]])
}

pub fn d14_pattern_segment_walks_options_then_its_pattern_test() {
  // D14: per segment, the compiler walks a bit-array pattern's options and
  // then the segment's own pattern. The first `size(width)` is read before
  // that segment binds `width`, so it is an edge to the constant; the second
  // reads the local. The old collector never descended the segment's pattern.
  let source =
    "pub fn run(x: BitArray) -> Int {\n"
    <> "  let assert <<width:size(width), rest:size(width)>> = x\n"
    <> "  rest\n"
    <> "}\n"
    <> "pub const width = 8\n"
  edges_of(source)
  |> should.equal([#("run", ["width"]), #("width", [])])
  order_of(source)
  |> should.equal([["width"], ["run"]])
}

pub fn q1_module_access_references_a_same_named_definition_test() {
  // Q1: `list.map` is module access to `gleam/list`, but the compiler walks
  // the container, so it references the top-level `fn list`.
  let source =
    "import gleam/list\n"
    <> "pub fn run(xs: List(Int)) -> List(Int) { list.map(xs, double) }\n"
    <> "pub fn double(x: Int) -> Int { x * 2 }\n"
    <> "pub fn list() -> List(Int) { [] }\n"
  edges_of(source)
  |> should.equal([
    #("run", ["double", "list"]),
    #("double", []),
    #("list", []),
  ])
  order_of(source)
  |> should.equal([["double"], ["list"], ["run"]])
}

pub fn q2_only_the_first_alternative_is_walked_test() {
  // Q2: the compiler walks a clause's first alternative only, so the second
  // alternative's `size(width)` is no edge. The typer reads whatever `width`
  // is in scope when `run` is inferred: here the unqualified import, since the
  // constant is inferred after `run`.
  let source =
    "import helper.{width}\n"
    <> "pub fn run(bits: BitArray) -> Int {\n"
    <> "  case bits {\n"
    <> "    <<1, v>> | <<2, v:size(width)>> -> v\n"
    <> "    _ -> 0\n"
    <> "  }\n"
    <> "}\n"
    <> "pub const width = 16\n"
  edges_of(source)
  |> should.equal([#("run", []), #("width", [])])
  order_of(source)
  |> should.equal([["run"], ["width"]])
}

pub fn q3_string_prefix_name_does_not_shadow_test() {
  // Q3: the compiler does not define a string prefix's `as` name, so the
  // body's `prefix`, the local variable to the typer, references the
  // top-level constant.
  let source =
    "pub fn run(x: String) -> String {\n"
    <> "  case x {\n"
    <> "    \"a\" as prefix <> rest -> prefix <> rest\n"
    <> "    _ -> \"\"\n"
    <> "  }\n"
    <> "}\n"
    <> "pub const prefix = \"p\"\n"
  edges_of(source)
  |> should.equal([#("run", ["prefix"]), #("prefix", [])])
  order_of(source)
  |> should.equal([["prefix"], ["run"]])
}

pub fn q5_as_name_shadows_its_own_pattern_test() {
  // Q5: the compiler defines an `as` name before it walks the inner pattern,
  // so the inner `size(width)` is no edge, although the typer reads the
  // module-level `width` there: the import, since the constant is inferred
  // after `run`.
  let source =
    "import helper.{width}\n"
    <> "pub fn run(x: BitArray) -> BitArray {\n"
    <> "  let assert <<_:size(width)>> as width = x\n"
    <> "  width\n"
    <> "}\n"
    <> "pub const width = 16\n"
  edges_of(source)
  |> should.equal([#("run", []), #("width", [])])
  order_of(source)
  |> should.equal([["run"], ["width"]])
}

pub fn q6_constructor_arguments_are_walked_in_written_order_test() {
  // Q6: the compiler walks a constructor pattern's arguments as written, so
  // the shorthand `width:` defines `width` before `bits`' `size(width)` is
  // read, and that size is no edge. The typer checks the fields in
  // declaration order, `bits` first, and reads the module-level `width`: the
  // import, since the constant is inferred after `run`.
  let source =
    "import helper.{width}\n"
    <> "pub type Box {\n"
    <> "  Box(bits: BitArray, width: Int)\n"
    <> "}\n"
    <> "pub fn run(box: Box) -> Int {\n"
    <> "  let assert Box(width:, bits: <<v:size(width)>>) = box\n"
    <> "  v\n"
    <> "}\n"
    <> "pub const width = 16\n"
  edges_of(source)
  |> should.equal([#("run", []), #("width", [])])
  order_of(source)
  |> should.equal([["run"], ["width"]])
}

pub fn q4_unshadowed_message_is_an_edge_test() {
  // Q4, unshadowed: nothing the pattern binds is named in the message, so
  // `message()` is an ordinary edge, after the pattern's `size(width)`.
  let source =
    "pub fn run(x: BitArray) {\n"
    <> "  let assert <<v:size(width)>> = x as message()\n"
    <> "  v\n"
    <> "}\n"
    <> "fn message() { \"\" }\n"
    <> "const width = 8\n"
  edges_of(source)
  |> should.equal([
    #("run", ["message", "width"]),
    #("message", []),
    #("width", []),
  ])
  order_of(source)
  |> should.equal([["message"], ["width"], ["run"]])
}

pub fn q4_shadowed_function_is_no_edge_test() {
  // Q4, a shadowed function: the compiler walks the message after the
  // pattern has defined `message`, so `message(0)` is no edge: `run>` and
  // `message>`, order `run|message`. The typer infers the message before the
  // pattern binds, so it calls the top-level function, which inference finds
  // through its module-wide registration, as the compiler does.
  let source =
    "pub fn run(x) {\n"
    <> "  let assert Ok(message) = x as message(0)\n"
    <> "  message\n"
    <> "}\n"
    <> "pub fn message(_x) { \"\" }\n"
  edges_of(source)
  |> should.equal([#("run", []), #("message", [])])
  order_of(source)
  |> should.equal([["run"], ["message"]])
}

pub fn q4_shadowed_constant_is_no_edge_test() {
  // Q4, a shadowed constant: no edge, as in the compiler. The rule adds edges
  // to functions only, the definitions the compiler pre-registers. The
  // compiler infers `run` before the constant, so its message reads the
  // unqualified import; without that import the compiler rejects the module.
  let source =
    "import helper.{message}\n"
    <> "pub fn run(x) {\n"
    <> "  let assert Ok(message) = x as message\n"
    <> "  message\n"
    <> "}\n"
    <> "pub const message = \"error\"\n"
  edges_of(source)
  |> should.equal([#("run", []), #("message", [])])
  order_of(source)
  |> should.equal([["run"], ["message"]])
}

pub fn q4_bare_receiver_is_no_edge_test() {
  // Q4, a bare field receiver: in the message, `m.reason` is module access to
  // `helper`, since a function has no fields, so the Q4 rule never records
  // the `m` of `m.reason`. No edge, as in the compiler, whose walk sees `m`
  // shadowed by the pattern.
  let source =
    "import helper as m\n"
    <> "pub fn run(x) {\n"
    <> "  let assert Ok(m) = x as m.reason\n"
    <> "  m\n"
    <> "}\n"
    <> "pub fn m() { #(run(Ok(1)), run(Ok(\"s\"))) }\n"
  edges_of(source)
  |> should.equal([#("run", []), #("m", ["run", "run"])])
  order_of(source)
  |> should.equal([["run"], ["m"]])
}

pub fn q4_nested_message_is_no_edge_test() {
  // Q4, nested: the compiler's walk sees `message` shadowed by both patterns,
  // so the inner `message()` is no edge: `run>` and `message>`, order
  // `run|message`. The typer reads the top-level function there, through its
  // registration.
  let source =
    "pub fn run(x: Result(Int, Nil), y: Result(String, Nil)) -> Int {\n"
    <> "  let assert Ok(message) = x as {\n"
    <> "    let assert Ok(message) = y as message()\n"
    <> "    message\n"
    <> "  }\n"
    <> "  message\n"
    <> "}\n"
    <> "fn message() -> String { \"failed\" }\n"
  edges_of(source)
  |> should.equal([#("run", []), #("message", [])])
  order_of(source)
  |> should.equal([["run"], ["message"]])
}

pub fn q4_after_string_prefix_is_no_edge_test() {
  // Q4 after Q3: the first `let assert` binds `message` as a string prefix's
  // `as` name, which the compiler's walk does not define but the typer does.
  // The second message reads that local, so the Q4 rule adds nothing, and the
  // edges are the compiler's.
  let source =
    "pub fn run(s, x) {\n"
    <> "  let assert \"a\" as message <> _ = s\n"
    <> "  let assert Ok(message) = x as message\n"
    <> "  message\n"
    <> "}\n"
    <> "pub fn message() { #(run(\"a\", Ok(1)), run(\"a\", Ok(\"s\"))) }\n"
  edges_of(source)
  |> should.equal([#("run", []), #("message", ["run", "run"])])
  order_of(source)
  |> should.equal([["run"], ["message"]])
}

pub fn q4_call_shorthand_is_no_edge_test() {
  // Q4, a call's shorthand argument: `invoke(message:)` passes the variable
  // `message`, which the compiler's walk sees shadowed by the pattern, so it
  // records `invoke` alone: `run>invoke`, order `invoke|run|message`. The
  // typer reads the top-level function, through its registration.
  let source =
    "pub fn run(x: Result(Int, Nil)) -> Int {\n"
    <> "  let assert Ok(message) = x as invoke(message:)\n"
    <> "  message\n"
    <> "}\n"
    <> "fn invoke(message message: fn() -> String) -> String { message() }\n"
    <> "fn message() -> String { \"failed\" }\n"
  edges_of(source)
  |> should.equal([#("run", ["invoke"]), #("invoke", []), #("message", [])])
  order_of(source)
  |> should.equal([["invoke"], ["run"], ["message"]])
}

// Target filtering feeds the order
//
// The compiler builds its graph from the definitions kept for the build
// target, so two same-named definitions for different targets are never
// both nodes.

pub fn target_filtered_pair_orders_the_kept_definition_test() {
  // `run` is written first, so it is inferred after `helper` only if the
  // order sees the edge to the `helper` kept for the target, and the Erlang
  // `helper` reads `seed`, a constant declared after it, which is in scope
  // only if the order puts it first. Fed the module before target filtering,
  // the order would see the JavaScript `helper`'s edges for both and Erlang
  // would fail with `UnboundVariable("seed")`. The compiler orders
  // `seed|helper|run` on Erlang and `helper|run|seed` on JavaScript.
  let source =
    "pub fn run() { helper() }\n"
    <> "@target(erlang)\n"
    <> "fn helper() -> Int { seed + 1 }\n"
    <> "@target(javascript)\n"
    <> "fn helper() -> String { \"one\" }\n"
    <> "const seed = 1\n"

  let assert Ok(erlang) =
    girard.annotate(
      source,
      girard.default_options() |> girard.with_target(girard.Erlang),
    )
  signature(erlang, "run") |> should.equal("fn() -> Int")

  let assert Ok(javascript) =
    girard.annotate(
      source,
      girard.default_options() |> girard.with_target(girard.JavaScript),
    )
  signature(javascript, "run") |> should.equal("fn() -> String")
}

// Strict edges
//
// Best-effort annotation re-splits a failed group along the edges the typer
// follows (`reference.strict_edges`), which walk a `let assert` message
// before its pattern binds, as the typer checks it.

pub fn strict_edges_keep_a_message_read_the_pattern_shadows_test() {
  // The compiler's walk binds `later` before the message, so `early` has no
  // edge to it (Q4); the typer reads the top-level `later` there.
  let source =
    "pub fn early() -> String {\n"
    <> "  let assert [later] = [1] as later()\n"
    <> "  \"ok\"\n"
    <> "}\n\n"
    <> "pub fn later() -> String {\n"
    <> "  early()\n"
    <> "}\n"
  edges_of(source) |> should.equal([#("early", []), #("later", ["early"])])
  strict_edges_of(source)
  |> should.equal([#("early", ["later"]), #("later", ["early"])])
}

pub fn strict_edges_read_a_message_before_a_prefix_name_test() {
  // The strict walk lets a string prefix's `as` name shadow (Q3), but only
  // once the pattern binds it: the message reads the top-level `bad`.
  let source =
    "pub fn good(s: String) -> String {\n"
    <> "  let assert \"x\" as bad <> rest = s as bad(s)\n"
    <> "  rest\n"
    <> "}\n\n"
    <> "pub fn bad(s: String) -> String {\n"
    <> "  let _ = good(s)\n"
    <> "  s\n"
    <> "}\n"
  strict_edges_of(source)
  |> should.equal([#("bad", ["good"]), #("good", ["bad"])])
}

// Helpers

// Render the compiler test's functions and constants as a module and order
// it.
fn order(
  functions: List(#(String, List(String), String)),
  constants: List(#(String, String)),
) -> List(List(String)) {
  order_of(render(functions, constants))
}

// `pub fn name(arguments) { body }` for each function, then
// `pub const name = value` for each constant.
fn render(
  functions: List(#(String, List(String), String)),
  constants: List(#(String, String)),
) -> String {
  let functions =
    list.map(functions, fn(function) {
      let #(name, arguments, body) = function
      "pub fn "
      <> name
      <> "("
      <> string.join(arguments, ", ")
      <> ") {\n  "
      <> body
      <> "\n}\n"
    })
  let constants =
    list.map(constants, fn(constant) {
      "pub const " <> constant.0 <> " = " <> constant.1 <> "\n"
    })
  string.concat(list.append(functions, constants))
}

// The groups of a module's top-level definitions, dependencies first.
fn order_of(source: String) -> List(List(String)) {
  let #(functions, constants) = definitions(source)
  reference.dependency_order(functions, constants)
}

// Each node of a module's call graph with its neighbours, newest first.
fn edges_of(source: String) -> List(#(String, List(String))) {
  let #(functions, constants) = definitions(source)
  reference.dependency_edges(functions, constants)
}

// The edges `strict_edges` gives between all of a module's definitions, with
// no import aliases, by definition name: it keeps the order it is given.
fn strict_edges_of(source: String) -> List(#(String, List(String))) {
  let #(functions, constants) = definitions(source)
  reference.strict_edges(functions, constants, set.new())
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

// The functions and constants glance parses from `source`, in glance's order:
// the reference API sorts them by position itself.
fn definitions(
  source: String,
) -> #(List(glance.Function), List(glance.Constant)) {
  let assert Ok(module) = glance.module(source)
  #(
    list.map(module.functions, fn(definition) { definition.definition }),
    list.map(module.constants, fn(definition) { definition.definition }),
  )
}

// The rendered signature of the named top-level function.
fn signature(annotated: girard.AnnotatedModule, name: String) -> String {
  case list.key_find(annotated.functions, name) {
    Ok(scheme) -> girard.type_to_string(scheme.type_)
    Error(_) -> panic as { "no function named " <> name }
  }
}
