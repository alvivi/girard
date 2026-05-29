import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import girard

pub fn main() {
  gleeunit.main()
}

// --- Helpers ---------------------------------------------------------------

/// The inferred signature of the named top-level function.
fn signature(source: String, name: String) -> String {
  let annotated = girard.annotate(source)
  case list.key_find(annotated.functions, name) {
    Ok(sig) -> sig
    Error(_) -> panic as { "no function named " <> name }
  }
}

/// The inferred signature of `name` in `source`, resolving imports from the
/// given in-memory modules (path -> source).
fn signature_with(
  source: String,
  modules: List(#(String, String)),
  name: String,
) -> String {
  let table = dict.from_list(modules)
  let resolver = fn(path) { dict.get(table, path) }
  let annotated = girard.annotate_with(source, resolver)
  case list.key_find(annotated.functions, name) {
    Ok(sig) -> sig
    Error(_) -> panic as { "no function named " <> name }
  }
}

/// The inferred type of the named top-level constant.
fn constant_type(source: String, name: String) -> String {
  let annotated = girard.annotate(source)
  case list.key_find(annotated.constants, name) {
    Ok(type_) -> type_
    Error(_) -> panic as { "no constant named " <> name }
  }
}

/// The inferred type of the first occurrence of `snippet` in `source`,
/// matched by its exact byte span.
fn type_of(source: String, snippet: String) -> String {
  let assert Ok(start) = first_index(source, snippet)
  let end = start + string.byte_size(snippet)
  let annotated = girard.annotate(source)
  let matches =
    list.filter_map(annotated.expressions, fn(a) {
      case a.span.start == start && a.span.end == end {
        True -> Ok(a.type_)
        False -> Error(Nil)
      }
    })
  case matches {
    [type_, ..] -> type_
    [] -> panic as { "no expression with span for: " <> snippet }
  }
}

fn first_index(haystack: String, needle: String) -> Result(Int, Nil) {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> Ok(string.byte_size(before))
    Error(_) -> Error(Nil)
  }
}

// --- Function signature inference ------------------------------------------

pub fn identity_test() {
  signature("pub fn id(x) { x }", "id")
  |> should.equal("fn(a) -> a")
}

pub fn double_test() {
  signature("pub fn double(x) { x + x }", "double")
  |> should.equal("fn(Int) -> Int")
}

pub fn string_literal_test() {
  signature("pub fn greet() { \"hi\" }", "greet")
  |> should.equal("fn() -> String")
}

pub fn singleton_list_test() {
  signature("pub fn singleton(x) { [x] }", "singleton")
  |> should.equal("fn(a) -> List(a)")
}

pub fn higher_order_test() {
  signature("pub fn apply(f, x) { f(x) }", "apply")
  |> should.equal("fn(fn(a) -> b, a) -> b")
}

pub fn tuple_test() {
  signature("pub fn pair(a, b) { #(a, b) }", "pair")
  |> should.equal("fn(a, b) -> #(a, b)")
}

pub fn float_op_test() {
  signature("pub fn g(x) { x +. 1.0 }", "g")
  |> should.equal("fn(Float) -> Float")
}

pub fn comparison_test() {
  signature("pub fn lt(a, b) { a < b }", "lt")
  |> should.equal("fn(Int, Int) -> Bool")
}

pub fn concat_test() {
  signature("pub fn cat(a, b) { a <> b }", "cat")
  |> should.equal("fn(String, String) -> String")
}

pub fn let_binding_test() {
  signature("pub fn f() { let x = 1\nx + 1 }", "f")
  |> should.equal("fn() -> Int")
}

pub fn case_bool_test() {
  signature("pub fn is_zero(n) { case n { 0 -> True\n_ -> False } }", "is_zero")
  |> should.equal("fn(Int) -> Bool")
}

pub fn list_pattern_test() {
  signature(
    "pub fn head(xs) { case xs { [x, ..] -> Ok(x)\n[] -> Error(Nil) } }",
    "head",
  )
  |> should.equal("fn(List(a)) -> Result(a, Nil)")
}

pub fn capture_test() {
  signature("pub fn add(a, b) { a + b }\npub fn inc() { add(1, _) }", "inc")
  |> should.equal("fn() -> fn(Int) -> Int")
}

// --- Custom types ----------------------------------------------------------

pub fn custom_type_unbox_test() {
  let source =
    "pub type Box(a) { Box(a) }\npub fn unbox(b) { case b { Box(x) -> x } }"
  signature(source, "unbox")
  |> should.equal("fn(Box(a)) -> a")
}

pub fn custom_type_construct_test() {
  let source = "pub type Box(a) { Box(a) }\npub fn wrap(x) { Box(x) }"
  signature(source, "wrap")
  |> should.equal("fn(a) -> Box(a)")
}

pub fn enum_test() {
  let source = "pub type Color { Red\nGreen\nBlue }\npub fn pick() { Red }"
  signature(source, "pick")
  |> should.equal("fn() -> Color")
}

// --- Per-expression annotations --------------------------------------------

pub fn expression_annotation_test() {
  let source = "pub fn double(x) { x + x }"
  type_of(source, "x + x")
  |> should.equal("Int")
}

pub fn pipe_test() {
  let source =
    "pub fn double(x) { x + x }\npub fn quad(n) { n |> double |> double }"
  signature(source, "quad")
  |> should.equal("fn(Int) -> Int")
}

// --- Module-level polymorphism (M2: dependency-ordered inference) -----------

pub fn polymorphic_helper_test() {
  // `id` must stay generic so it can be used at two different types.
  let source = "pub fn id(x) { x }\npub fn use_it() { #(id(1), id(\"a\")) }"
  signature(source, "use_it")
  |> should.equal("fn() -> #(Int, String)")
}

pub fn dependency_does_not_pollute_test() {
  let source = "pub fn id(x) { x }\npub fn one() { id(1) }"
  signature(source, "id")
  |> should.equal("fn(a) -> a")
}

pub fn mutual_recursion_test() {
  let source =
    "pub fn is_even(n) { case n { 0 -> True\n_ -> is_odd(n - 1) } }\n"
    <> "pub fn is_odd(n) { case n { 0 -> False\n_ -> is_even(n - 1) } }"
  signature(source, "is_even")
  |> should.equal("fn(Int) -> Bool")
}

// --- Annotations, constants, type aliases (M3) ------------------------------

pub fn shared_type_variable_test() {
  // The `a` in the return must be the same variable as the parameter `a`.
  signature("pub fn first(x: a, y: b) -> a { x }", "first")
  |> should.equal("fn(a, b) -> a")
}

pub fn constant_test() {
  constant_type("pub const answer = 42", "answer")
  |> should.equal("Int")
}

pub fn constant_list_test() {
  constant_type("pub const names = [\"a\", \"b\"]", "names")
  |> should.equal("List(String)")
}

pub fn constant_references_function_test() {
  let source = "pub fn double(x) { x + x }\npub const four = double(2)"
  constant_type(source, "four")
  |> should.equal("Int")
}

pub fn type_alias_test() {
  let source = "pub type Id = Int\npub fn identity(x: Id) -> Id { x }"
  signature(source, "identity")
  |> should.equal("fn(Int) -> Int")
}

pub fn parametric_alias_test() {
  let source = "pub type Pair(a) = #(a, a)\npub fn mk(x: a) -> Pair(a) { #(x, x) }"
  signature(source, "mk")
  |> should.equal("fn(a) -> #(a, a)")
}

// --- Record field access and update (M3) ------------------------------------

pub fn field_access_test() {
  let source =
    "pub type User { User(name: String, age: Int) }\n"
    <> "pub fn get_age(u: User) { u.age }"
  signature(source, "get_age")
  |> should.equal("fn(User) -> Int")
}

pub fn generic_field_access_test() {
  // Field access needs a known type — Gleam itself requires the annotation.
  let source =
    "pub type Box(a) { Box(value: a) }\npub fn unwrap(b: Box(a)) { b.value }"
  signature(source, "unwrap")
  |> should.equal("fn(Box(a)) -> a")
}

pub fn record_update_test() {
  let source =
    "pub type User { User(name: String, age: Int) }\n"
    <> "pub fn birthday(u: User) { User(..u, age: 0) }"
  signature(source, "birthday")
  |> should.equal("fn(User) -> User")
}

// --- Labelled arguments (M3) ------------------------------------------------

pub fn labelled_constructor_test() {
  // Labels supplied out of declaration order must still type-check.
  let source =
    "pub type User { User(name: String, age: Int) }\n"
    <> "pub fn make() { User(age: 1, name: \"a\") }"
  signature(source, "make")
  |> should.equal("fn() -> User")
}

pub fn labelled_function_call_test() {
  let source =
    "pub fn divide(a a: Int, b b: Int) { a / b }\n"
    <> "pub fn half(n) { divide(b: 2, a: n) }"
  signature(source, "half")
  |> should.equal("fn(Int) -> Int")
}

pub fn spread_pattern_test() {
  let source =
    "pub type User { User(name: String, age: Int) }\n"
    <> "pub fn name_of(u: User) { case u { User(name:, ..) -> name } }"
  signature(source, "name_of")
  |> should.equal("fn(User) -> String")
}

// --- use expressions (M3) ---------------------------------------------------

pub fn use_test() {
  let source =
    "pub fn with(x, f) { f(x) }\npub fn run() { use a <- with(5)\na + 1 }"
  signature(source, "run")
  |> should.equal("fn() -> Int")
}

pub fn use_chain_test() {
  let source =
    "pub type Res(a) { Good(a)\nBad }\n"
    <> "pub fn try(r, f) { case r { Good(x) -> f(x)\nBad -> Bad } }\n"
    <> "pub fn chain() { use x <- try(Good(1))\nGood(x + 1) }"
  signature(source, "chain")
  |> should.equal("fn() -> Res(Int)")
}

// --- Bit arrays (M3) --------------------------------------------------------

pub fn bit_array_test() {
  signature("pub fn bytes() { <<1, 2, 3>> }", "bytes")
  |> should.equal("fn() -> BitArray")
}

pub fn bit_array_string_segment_test() {
  signature("pub fn encode(s) { <<s:utf8>> }", "encode")
  |> should.equal("fn(String) -> BitArray")
}

pub fn bit_array_pattern_test() {
  let source =
    "pub fn first_byte(b) { case b { <<x, _:bytes>> -> x\n_ -> 0 } }"
  signature(source, "first_byte")
  |> should.equal("fn(BitArray) -> Int")
}

// --- Imports (M4) -----------------------------------------------------------

pub fn qualified_import_test() {
  let other = "pub fn double(x: Int) -> Int { x + x }"
  let source = "import other\npub fn use_it() { other.double(21) }"
  signature_with(source, [#("other", other)], "use_it")
  |> should.equal("fn() -> Int")
}

pub fn unqualified_value_import_test() {
  let other = "pub fn double(x: Int) -> Int { x + x }"
  let source = "import other.{double}\npub fn use_it() { double(21) }"
  signature_with(source, [#("other", other)], "use_it")
  |> should.equal("fn() -> Int")
}

pub fn cross_module_polymorphism_test() {
  // An imported generic helper stays polymorphic and is usable at two types.
  let other = "pub fn id(x) { x }"
  let source = "import other.{id}\npub fn use_it() { #(id(1), id(\"a\")) }"
  signature_with(source, [#("other", other)], "use_it")
  |> should.equal("fn() -> #(Int, String)")
}

pub fn imported_type_and_constructor_test() {
  let opt = "pub type Maybe(a) { Just(a)\nNothing }"
  let source = "import opt.{type Maybe, Just}\npub fn get() { Just(5) }"
  signature_with(source, [#("opt", opt)], "get")
  |> should.equal("fn() -> Maybe(Int)")
}

pub fn qualified_type_annotation_test() {
  let opt = "pub type Maybe(a) { Just(a)\nNothing }"
  let source =
    "import opt\npub fn wrap(x: a) -> opt.Maybe(a) { opt.Just(x) }"
  signature_with(source, [#("opt", opt)], "wrap")
  |> should.equal("fn(a) -> Maybe(a)")
}

pub fn qualified_constructor_pattern_test() {
  // Match on `ord.Gt` etc. — a module-qualified constructor in a pattern.
  let ord = "pub type Order { Lt\nEq\nGt }"
  let source =
    "import ord\n"
    <> "pub fn is_gt(o) { case o { ord.Gt -> True\nord.Lt -> False\nord.Eq -> False } }"
  signature_with(source, [#("ord", ord)], "is_gt")
  |> should.equal("fn(Order) -> Bool")
}

pub fn labelled_reorder_with_pipe_test() {
  // Positional args fill the slots not claimed by labels (a pipe prepends the
  // subject as the first positional argument).
  let m = "pub fn at(in list: List(a), get index: Int) -> a { todo }"
  let source = "import m\npub fn third(xs) { xs |> m.at(get: 2) }"
  signature_with(source, [#("m", m)], "third")
  |> should.equal("fn(List(a)) -> a")
}

pub fn transitive_import_test() {
  // `mid` re-exports a function that itself depends on `base`.
  let base = "pub fn inc(x: Int) -> Int { x + 1 }"
  let mid = "import base\npub fn inc2(x) { base.inc(base.inc(x)) }"
  let source = "import mid\npub fn run() { mid.inc2(0) }"
  signature_with(source, [#("base", base), #("mid", mid)], "run")
  |> should.equal("fn() -> Int")
}
