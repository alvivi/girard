import girard
import glance
import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// --- Helpers ---------------------------------------------------------------

/// The inferred signature of the named top-level function.
fn signature(source: String, name: String) -> String {
  let assert Ok(annotated) = girard.annotate(source, girard.default_options())
  case list.key_find(annotated.functions, name) {
    Ok(sig) -> girard.type_to_string(sig.type_)
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
  let options = girard.default_options() |> girard.with_resolver(resolver)
  let assert Ok(annotated) = girard.annotate(source, options)
  case list.key_find(annotated.functions, name) {
    Ok(sig) -> girard.type_to_string(sig.type_)
    Error(_) -> panic as { "no function named " <> name }
  }
}

/// The inferred type of the named top-level constant.
fn constant_type(source: String, name: String) -> String {
  let assert Ok(annotated) = girard.annotate(source, girard.default_options())
  case list.key_find(annotated.constants, name) {
    Ok(type_) -> girard.type_to_string(type_.type_)
    Error(_) -> panic as { "no constant named " <> name }
  }
}

/// The inferred type of the first occurrence of `snippet` in `source`,
/// matched by its exact byte span.
fn type_of(source: String, snippet: String) -> String {
  let assert Ok(start) = first_index(source, snippet)
  let end = start + string.byte_size(snippet)
  let assert Ok(annotated) = girard.annotate(source, girard.default_options())
  let matches =
    list.filter_map(annotated.expressions, fn(a) {
      case a.span.start == start && a.span.end == end {
        True -> Ok(a.type_)
        False -> Error(Nil)
      }
    })
  case matches {
    [type_, ..] -> girard.type_to_string(type_)
    [] -> panic as { "no expression with span for: " <> snippet }
  }
}

fn first_index(haystack: String, needle: String) -> Result(Int, Nil) {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> Ok(string.byte_size(before))
    Error(_) -> Error(Nil)
  }
}

// --- Ill-typed input is reported, not crashed -------------------------------

pub fn unbound_variable_is_error_test() {
  let assert Error(girard.UnboundVariable("x")) =
    girard.annotate("pub fn f() { x }", girard.default_options())
}

pub fn type_mismatch_is_error_test() {
  // `+.` is float addition, so an Int operand does not unify.
  let assert Error(girard.TypeMismatch(_, _)) =
    girard.annotate("pub fn f() { 1 +. 2.0 }", girard.default_options())
}

pub fn unknown_field_is_error_test() {
  let source =
    "pub type User { User(name: String) }\npub fn f(u: User) { u.age }"
  let assert Error(girard.NoSuchField("User", "age")) =
    girard.annotate(source, girard.default_options())
}

pub fn occurs_check_is_error_test() {
  // `fn(f) { f(f) }` has no finite type.
  let assert Error(girard.RecursiveType(_, _)) =
    girard.annotate("pub fn f(g) { g(g) }", girard.default_options())
}

// --- printer ----------------------------------------------------------------

pub fn printer_skips_reserved_words_test() {
  // Type-variable names must never collide with a Gleam keyword (e.g. the 169th
  // name would otherwise be `fn`), or the type reads ambiguously.
  let vars = list.index_map(list.repeat(Nil, 200), fn(_, i) { girard.Var(i) })
  let rendered = girard.type_to_string(girard.Tuple(vars))
  let names =
    rendered
    |> string.drop_start(2)
    |> string.drop_end(1)
    |> string.split(", ")
  ["fn", "as", "if", "let", "use", "type", "case", "pub", "todo", "panic"]
  |> list.each(fn(keyword) { should.be_false(list.contains(names, keyword)) })
}

// --- report (the CLI's rendered report) -------------------------------------

pub fn report_test() {
  girard.report("pub fn double(x) { x + x }")
  |> should.equal("double: fn(Int) -> Int\n19-20: Int\n19-24: Int\n23-24: Int")
}

pub fn report_error_test() {
  girard.report("pub fn f() { 1 +. 2 }")
  |> should.equal("// error: type mismatch: Int vs Float")
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

pub fn string_prefix_binding_test() {
  // `"a" as c <> rest` binds both the matched prefix (`c`) and the remainder
  // (`rest`) to String — the prefix `as` binding must be in scope (jot's
  // `take_symbol_chars`).
  let source =
    "pub fn lead(s: String) -> String {\n"
    <> "  case s {\n    \"a\" as c <> rest -> c <> rest\n    _ -> s\n  }\n}"
  signature(source, "lead")
  |> should.equal("fn(String) -> String")
}

pub fn capture_test() {
  signature("pub fn add(a, b) { a + b }\npub fn inc() { add(1, _) }", "inc")
  |> should.equal("fn() -> fn(Int) -> Int")
}

pub fn labelled_capture_test() {
  // A labelled capture hole (`z: _`) written out of declared order must land in
  // its labelled parameter, not its source position. Here the hole is `z`
  // (Float) though it appears where `y` (String) sits positionally — mirrors
  // squirrel's `QueryFileHasInvalidName(file:, reason: _, suggested_name:)`.
  let source =
    "pub type R {\n  R(x: Int, y: String, z: Float)\n}\n"
    <> "pub fn make() { R(x: 1, z: _, y: \"a\") }"
  signature(source, "make")
  |> should.equal("fn() -> fn(Float) -> R")
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

pub fn pipe_into_saturated_call_test() {
  // `make(\"a\")` is a saturated call returning a function, so `x |> make(\"a\")`
  // applies `x` to the result — `make(\"a\")(x)` — rather than inserting `x` as a
  // second argument (which would be the wrong arity). (cors_builder's
  // `res |> set_allowed_origin(cors, origin)`.)
  let source =
    "fn make(prefix: String) -> fn(String) -> String {\n"
    <> "  fn(s) { prefix <> s }\n"
    <> "}\n"
    <> "pub fn go(x: String) -> String { x |> make(\"a\") }"
  signature(source, "go")
  |> should.equal("fn(String) -> String")
}

// --- Module-level polymorphism (M2: dependency-ordered inference) -----------

pub fn polymorphic_helper_test() {
  // `id` must stay generic so it can be used at two different types.
  let source = "pub fn id(x) { x }\npub fn use_it() { #(id(1), id(\"a\")) }"
  signature(source, "use_it")
  |> should.equal("fn() -> #(Int, String)")
}

pub fn qualified_access_not_a_dependency_test() {
  // `string.trim` is qualified access to the `gleam/string` module, not a
  // reference to the local `string` function. Treating it as one would group
  // `flag` and `string` into one mutually-recursive component, monomorphising
  // `flag`'s type variable so `other` (using it at `Bool`) would clash with the
  // `Int` from `string`. `flag` must stay generic. (lustre_dev_tools' cli.)
  let source =
    "import gleam/string\n"
    <> "fn flag(make: fn(String) -> a) -> a { make(string.trim(\"x\")) }\n"
    <> "pub fn string() -> Int { flag(fn(_) { 1 }) }\n"
    <> "pub fn other() -> Bool { flag(fn(_) { True }) }"
  signature(source, "other")
  |> should.equal("fn() -> Bool")
}

pub fn qualified_local_constant_is_a_dependency_test() {
  // `config.value` is field access on the local constant `config` (defined
  // after `get`) — a real dependency that must order `config` first, unlike a
  // module qualifier. (cigogne's `default_migrations_config.dependencies`.)
  let source =
    "pub fn get() -> Int { config.value }\n"
    <> "pub type Config {\n  Config(value: Int)\n}\n"
    <> "pub const config = Config(value: 1)"
  signature(source, "get")
  |> should.equal("fn() -> Int")
}

pub fn prelude_module_import_test() {
  // `import gleam.{...}` imports from the implicit prelude module, which has no
  // source file; the prelude's constructors must still resolve, even aliased
  // (polly's `import gleam.{Error as Err}`).
  let source =
    "import gleam.{Error as Err, Ok as Yes}\n"
    <> "pub fn f(b: Bool) -> Result(Int, String) {\n"
    <> "  case b {\n    True -> Yes(1)\n    False -> Err(\"x\")\n  }\n}"
  signature(source, "f")
  |> should.equal("fn(Bool) -> Result(Int, String)")
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
  let source =
    "pub type Pair(a) = #(a, a)\npub fn mk(x: a) -> Pair(a) { #(x, x) }"
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

pub fn record_update_unannotated_record_test() {
  // `b` is unannotated, so its type is only fixed by the update's constructor;
  // copying the kept `value` field must resolve through that binding.
  let source =
    "pub type Box(a) { Box(value: a, tag: String) }\n"
    <> "pub fn retag(b, t) { Box(..b, tag: t) }"
  signature(source, "retag")
  |> should.equal("fn(Box(a), String) -> Box(a)")
}

pub fn record_update_changes_type_parameter_test() {
  // `Box(..b, value:)` replaces the only field using `a`, so the result type's
  // parameter changes (a -> c), like gleam_http's `set_body`.
  let source =
    "pub type Box(a) { Box(value: a) }\n"
    <> "pub fn replace(b: Box(a), v: c) -> Box(c) { Box(..b, value: v) }"
  signature(source, "replace")
  |> should.equal("fn(Box(a), b) -> Box(b)")
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

pub fn bit_array_string_literal_test() {
  signature("pub fn dot() { <<\".\">> }", "dot")
  |> should.equal("fn() -> BitArray")
}

pub fn bit_array_string_literal_pattern_test() {
  // `"."` is a string-literal segment (utf8), not an Int segment.
  let source =
    "pub fn rest(b) { case b { <<\".\", tail:bytes>> -> tail\n_ -> b } }"
  signature(source, "rest")
  |> should.equal("fn(BitArray) -> BitArray")
}

pub fn bit_array_pattern_test() {
  let source = "pub fn first_byte(b) { case b { <<x, _:bytes>> -> x\n_ -> 0 } }"
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
  let source = "import opt\npub fn wrap(x: a) -> opt.Maybe(a) { opt.Just(x) }"
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

pub fn shared_variant_field_test() {
  // `name` appears in both variants with type String, so it is accessible.
  let source =
    "pub type Shape { Circle(radius: Float, name: String)\n"
    <> "Square(side: Float, name: String) }\n"
    <> "pub fn name_of(s: Shape) { s.name }"
  signature(source, "name_of")
  |> should.equal("fn(Shape) -> String")
}

pub fn unshared_variant_field_is_error_test() {
  // `radius` is only in Circle, so it is not an accessor on Shape.
  let source =
    "pub type Shape { Circle(radius: Float, name: String)\n"
    <> "Square(side: Float, name: String) }\n"
    <> "pub fn get(s: Shape) { s.radius }"
  let assert Error(girard.NoSuchField("Shape", "radius")) =
    girard.annotate(source, girard.default_options())
}

pub fn inconsistent_variant_field_is_error_test() {
  // `value` exists in both variants but with different types, so no accessor.
  let source =
    "pub type Mix { A(value: Int)\nB(value: String) }\n"
    <> "pub fn get(m: Mix) { m.value }"
  let assert Error(girard.NoSuchField("Mix", "value")) =
    girard.annotate(source, girard.default_options())
}

pub fn deferred_tuple_index_test() {
  // `p.0` is indexed before the `use` desugaring fixes `p`'s type to the list's
  // element type (like gleam_community/maths' weighted_sum over tuples).
  let source =
    "pub fn fold(list: List(a), init: b, f: fn(b, a) -> b) -> b { init }\n"
    <> "pub fn run(pairs: List(#(Int, String))) {\n"
    <> "  use acc, p <- fold(pairs, 0)\n"
    <> "  acc + p.0\n"
    <> "}"
  signature(source, "run")
  |> should.equal("fn(List(#(Int, String))) -> Int")
}

pub fn use_with_labelled_callback_test() {
  // `use <- guard(when:, return:)` — the callback fills the trailing
  // `otherwise` slot even though the explicit args are labelled.
  let m =
    "pub fn guard(when req: Bool, return cons: a, otherwise alt: fn() -> a) -> a { cons }"
  let source = "import m\npub fn f(c) { use <- m.guard(when: c, return: 0)\n1 }"
  signature_with(source, [#("m", m)], "f")
  |> should.equal("fn(Bool) -> Int")
}

pub fn deferred_field_access_test() {
  // `p` is accessed before the call that fixes its type to `P`; the field
  // accesses are deferred and resolved once `p`'s type is known.
  let source =
    "pub type P { P(x: Int, y: Int) }\n"
    <> "pub fn use_p(p: P) { p }\n"
    // `p.x` is accessed before `use_p(p)` fixes `p`'s type to `P`.
    <> "pub fn go(p) { let first = p.x\nuse_p(p) }"
  signature(source, "go")
  |> should.equal("fn(P) -> P")
}

pub fn chained_field_access_test() {
  let source =
    "pub type Span { Span(start: Int, end: Int) }\n"
    <> "pub type Node { Node(span: Span) }\n"
    <> "pub fn finish(n: Node) { n.span.end }"
  signature(source, "finish")
  |> should.equal("fn(Node) -> Int")
}

pub fn transitive_field_access_test() {
  // `main` accesses `.start` on a `sp.Span` it receives via `mid`, without
  // importing `sp` directly — the accessor must be reachable transitively.
  let sp = "pub type Span { Span(start: Int, end: Int) }"
  let mid =
    "import sp\npub type Err { Err(loc: sp.Span) }\n"
    <> "pub fn loc(e: Err) -> sp.Span { e.loc }"
  let source = "import mid\npub fn start_of(e: mid.Err) { mid.loc(e).start }"
  signature_with(source, [#("sp", sp), #("mid", mid)], "start_of")
  |> should.equal("fn(Err) -> Int")
}

pub fn qualified_labelled_pattern_test() {
  // Matching an imported constructor by label (with a spread) needs the field
  // map from the imported module.
  let ast = "pub type Node { Node(name: String, line: Int) }"
  let source =
    "import ast\n"
    <> "pub fn name_of(n: ast.Node) { case n { ast.Node(name: nm, ..) -> nm } }"
  signature_with(source, [#("ast", ast)], "name_of")
  |> should.equal("fn(Node) -> String")
}

pub fn bidirectional_lambda_field_access_test() {
  // The lambda parameter `x` has no annotation; its type is only known from the
  // call's expected argument type. Bidirectional checking seeds it so `x.value`
  // type-checks (this is the pattern that made list.map over records fail).
  let source =
    "pub type Box(a) { Box(value: a) }\n"
    <> "pub fn apply_to(b: Box(a), f) { f(b) }\n"
    <> "pub fn unwrap(b: Box(a)) { apply_to(b, fn(x) { x.value }) }"
  signature(source, "unwrap")
  |> should.equal("fn(Box(a)) -> a")
}

pub fn module_and_value_share_name_test() {
  // `m.thing` must resolve to the module export even though a value `m` also
  // exists in scope (mirrors gleam/dynamic's `dynamic` constant + module).
  let m = "pub fn thing(x: Int) -> String { todo }"
  let source =
    "import m\n" <> "pub const m = 1\n" <> "pub fn f() { m.thing(1) }"
  signature_with(source, [#("m", m)], "f")
  |> should.equal("fn() -> String")
}

pub fn alias_body_references_imported_type_test() {
  // `mid.Pair`'s body uses a type `mid` imported from `base`. Resolving the
  // alias must keep that type attributed to `base`, not the prelude (the bug
  // behind lustre's `Json vs Json`).
  let base = "pub type Colour { Red }"
  let mid = "import base.{type Colour}\npub type Pair =\n  #(Colour, Colour)"
  let source =
    "import mid\nimport base\npub fn first(p: mid.Pair) -> base.Colour { p.0 }"
  signature_with(source, [#("base", base), #("mid", mid)], "first")
  |> should.equal("fn(#(Colour, Colour)) -> Colour")
}

pub fn qualified_imported_alias_test() {
  // `mid.Ref` is an alias for `base.Id` in another module; used qualified it
  // must expand to the same type (like birl's `duration.Duration`).
  let base = "pub type Id { Id(Int) }"
  let mid = "import base\npub type Ref = base.Id"
  let source =
    "import mid\nimport base\npub fn same(x: mid.Ref) -> base.Id { x }"
  signature_with(source, [#("base", base), #("mid", mid)], "same")
  |> should.equal("fn(Id) -> Id")
}

pub fn renamed_type_import_test() {
  // `import sock.{type Socket as Internal}` brings the type into scope as
  // `Internal`, but it must hydrate to `sock`'s own `Socket`, not a phantom
  // `sock.Internal`. Otherwise a value of the renamed type fails to unify with
  // the same type named directly (glisten's `Socket` aliasing `InternalSocket`).
  let sock = "pub type Socket\npub fn make() -> Socket { todo }"
  let source =
    "import sock.{type Socket as Internal}\n"
    <> "pub fn use_it() -> Internal { sock.make() }"
  signature_with(source, [#("sock", sock)], "use_it")
  |> should.equal("fn() -> Socket")
}

pub fn discarded_import_does_not_shadow_test() {
  // `import b/http as _unused` is a discarded import: it brings nothing into
  // qualified scope and must not bind the module under its last segment
  // (`http`), where it would shadow a real `import a/http` sharing that name.
  // This is mist's `gleam/http as _ghttp` vs `mist/internal/http`.
  let real = "pub fn special() -> Int { 1 }"
  let discarded = "pub fn other() -> Int { 2 }"
  // The discarded import comes first in source; imports are processed in reverse
  // so it is handled last, where a stray last-segment binding would win and
  // shadow the real `a/http` (exactly mist's `gleam/http as _ghttp` ordering).
  let source =
    "import b/http as _unused\n"
    <> "import a/http\n"
    <> "pub fn run() -> Int { http.special() }"
  signature_with(source, [#("a/http", real), #("b/http", discarded)], "run")
  |> should.equal("fn() -> Int")
}

pub fn local_value_field_shadows_module_test() {
  // A local value named like an imported module: a bare `dep.value` reads the
  // record field (the value shadows the module here), since the field type fits
  // and it is not a call. This is mist's `compression.deflate`.
  let dep =
    "pub type Box(a) {\n  Box(value: a)\n}\npub fn value(b: Box(a)) -> a { b.value }"
  let source =
    "import dep.{type Box, Box}\n"
    <> "pub fn run() -> Int {\n  let dep = Box(1)\n  dep.value\n}"
  signature_with(source, [#("dep", dep)], "run")
  |> should.equal("fn() -> Int")
}

pub fn module_call_beats_field_test() {
  // The same name in *call position*: `dep.value(dep)` calls the module's
  // `value` function, not the (non-callable) `value` record field of the local
  // `dep` value. This is lustre's `cache.events(cache)`.
  let dep =
    "pub type Box(a) {\n  Box(value: a)\n}\npub fn value(b: Box(a)) -> a { b.value }"
  let source =
    "import dep.{type Box, Box}\n"
    <> "pub fn run() -> Int {\n  let dep = Box(1)\n  dep.value(dep)\n}"
  signature_with(source, [#("dep", dep)], "run")
  |> should.equal("fn() -> Int")
}

pub fn field_call_beats_module_test() {
  // The mirror of `module_call_beats_field_test`: when the local value's field
  // *is* a function, `components.hr()` calls that field, not the same-named
  // module export. A `components` parameter shadows the `components` module
  // alias (maud's `components.hr()`).
  let components =
    "pub type Comps(a) {\n  Comps(hr: fn() -> a)\n}\n"
    <> "pub fn hr(c: Comps(a), f: fn() -> a) -> Comps(a) { Comps(f) }"
  let source =
    "import components.{type Comps}\n"
    <> "pub fn render(components: Comps(a)) -> a {\n  components.hr()\n}"
  signature_with(source, [#("components", components)], "render")
  |> should.equal("fn(Comps(a)) -> a")
}

pub fn opaque_field_yields_to_module_call_test() {
  // An `opaque` type's field is private to its defining module, so a callable
  // field does NOT win over a same-named module function at an external call
  // site. A `schema` parameter shadows the `schema` module alias; `Schema` is
  // opaque, so `schema.decode(schema, v)` calls the module's 2-argument `decode`
  // function, not the (inaccessible) 1-argument `decode` field (kata's
  // `Schema`). Without honouring opacity this is `wrong number of arguments`.
  let schema =
    "pub opaque type Schema(a) {\n  Schema(decode: fn(Int) -> a)\n}\n"
    <> "pub fn decode(s: Schema(a), value: Int) -> a { s.decode(value) }"
  let source =
    "import schema.{type Schema}\n"
    <> "pub fn run(schema: Schema(a), v: Int) -> a {\n  schema.decode(schema, v)\n}"
  signature_with(source, [#("schema", schema)], "run")
  |> should.equal("fn(Schema(a), Int) -> a")
}

pub fn lambda_annotation_shares_type_var_names_test() {
  // An annotated lambda whose `a` appears in both a parameter and the return is
  // ONE variable across the whole signature, even when the body leaves the
  // returned value's parameter otherwise free (gs's par_map_actor handler,
  // `fn(state, msg: Message(a, b)) -> Next(_, Message(a, b))`). Without sharing,
  // the param's `a` and the return's `a` drift to distinct variables.
  let source =
    "pub type Box(a) {\n"
    <> "  Box(a)\n"
    <> "}\n"
    <> "pub fn make() {\n"
    <> "  fn(x: Box(a)) -> Box(a) { Box(todo) }\n"
    <> "}"
  signature(source, "make")
  |> should.equal("fn() -> fn(Box(a)) -> Box(a)")
}

pub fn let_pattern_variant_narrowing_test() {
  // `let assert Delim(..) = x` narrows `x` to the `Delim` variant, so `x.len`
  // (a field absent from `Text`) is reachable (maud's `let assert Inline(..)`).
  let source =
    "pub type Inline {\n"
    <> "  Text(String)\n"
    <> "  Delim(style: String, len: Int)\n"
    <> "}\n"
    <> "pub fn f(x: Inline) -> Int {\n"
    <> "  let assert Delim(..) = x\n"
    <> "  x.len\n"
    <> "}"
  signature(source, "f")
  |> should.equal("fn(Inline) -> Int")
}

pub fn transitive_import_test() {
  // `mid` re-exports a function that itself depends on `base`.
  let base = "pub fn inc(x: Int) -> Int { x + 1 }"
  let mid = "import base\npub fn inc2(x) { base.inc(base.inc(x)) }"
  let source = "import mid\npub fn run() { mid.inc2(0) }"
  signature_with(source, [#("base", base), #("mid", mid)], "run")
  |> should.equal("fn() -> Int")
}

pub fn mutually_recursive_unannotated_accumulator_test() {
  // shine_tree's `fold_l`/`fold_l_root`: mutually recursive, where `fold_l_root`
  // calls `fold_l` at the deeper `Tree(Node(u))` and `fold_l`'s accumulator is
  // unannotated. The provider (`fold_l`) is typed first; its body absorbs the
  // accumulator into the return variable, and a live reference from the consumer
  // then instantiates the resolved scheme. (Not polymorphic recursion — the
  // compiler accepts this and rejects true polymorphic recursion, as girard
  // does. This must type without a `type mismatch: a vs a`.)
  let source =
    "pub type Tree(u) {\n"
    <> "  Tip(u)\n"
    <> "  Deep(Tree(Node(u)))\n"
    <> "}\n"
    <> "pub type Node(u) {\n"
    <> "  One(u)\n"
    <> "}\n"
    <> "pub fn fold_l(tree: Tree(u), acc) -> v {\n"
    <> "  case tree {\n"
    <> "    Tip(_) -> acc\n"
    <> "    Deep(root) -> fold_l_root(acc, root)\n"
    <> "  }\n"
    <> "}\n"
    <> "fn fold_l_root(acc: v, root: Tree(Node(u))) -> v { fold_l(root, acc) }"
  signature(source, "fold_l")
  |> should.equal("fn(Tree(a), b) -> b")
}

// --- Inferred-variant field access and multi-variant records (M5) -----------

pub fn variant_narrowed_field_access_test() {
  // `kids` is present only in the `Branch` variant. Binding it with `as` after
  // a variant pattern narrows the value to that variant, so the field is
  // reachable (the compiler's inferred-variant narrowing).
  let source =
    "pub type Node(a) {\n"
    <> "  Branch(value: a, kids: List(Node(a)))\n"
    <> "  Leaf(value: a)\n"
    <> "}\n"
    <> "pub fn kids_of(n: Node(a)) -> List(Node(a)) {\n"
    <> "  case n {\n"
    <> "    Branch(..) as b -> b.kids\n"
    <> "    Leaf(..) -> []\n"
    <> "  }\n"
    <> "}"
  signature(source, "kids_of")
  |> should.equal("fn(Node(a)) -> List(Node(a))")
}

pub fn scrutinee_variant_narrowing_test() {
  // The bare subject variable `n` is narrowed to `Branch` inside that clause,
  // so `n.kids` (a field absent from `Leaf`) is reachable.
  let source =
    "pub type Node(a) {\n"
    <> "  Branch(value: a, kids: List(Node(a)))\n"
    <> "  Leaf(value: a)\n"
    <> "}\n"
    <> "pub fn kids_of(n: Node(a)) -> List(Node(a)) {\n"
    <> "  case n {\n"
    <> "    Branch(..) -> n.kids\n"
    <> "    Leaf(..) -> []\n"
    <> "  }\n"
    <> "}"
  signature(source, "kids_of")
  |> should.equal("fn(Node(a)) -> List(Node(a))")
}

pub fn constructed_variant_field_access_test() {
  // `let b = Branch(..)` narrows `b` to that variant, so `b.kids` (a field
  // absent from `Leaf`) is reachable without a pattern match (shore's
  // `let focused = FocusedInput(..)` then `focused.offset`).
  let source =
    "pub type Node(a) {\n"
    <> "  Branch(value: a, kids: List(Node(a)))\n"
    <> "  Leaf(value: a)\n"
    <> "}\n"
    <> "pub fn make(x: a) -> List(Node(a)) {\n"
    <> "  let b = Branch(value: x, kids: [])\n"
    <> "  b.kids\n"
    <> "}"
  signature(source, "make")
  |> should.equal("fn(a) -> List(Node(a))")
}

pub fn shadowing_binding_clears_variant_narrowing_test() {
  // `let x = Box(seed)` narrows the outer `x` to the `Box` variant. A nested
  // function whose parameter is *also* named `x` must NOT inherit that stale
  // narrowing: `x.item` inside it reads the parameter's field (tied to the
  // parameter's own type `b`), not the outer value's recorded field (`a`).
  // (search_algorithms_gleam's `get_steps` reading `search_state.paths`.)
  let source =
    "pub type Box(a) {\n"
    <> "  Box(item: a)\n"
    <> "}\n"
    <> "pub fn run(seed: a) {\n"
    <> "  let x = Box(seed)\n"
    <> "  let get = fn(x: Box(b)) { x.item }\n"
    <> "  #(x, get)\n"
    <> "}"
  signature(source, "run")
  |> should.equal("fn(a) -> #(Box(a), fn(Box(b)) -> b)")
}

pub fn record_update_non_shared_field_test() {
  // Updating via the `Branch` constructor copies the kept field `kids`, which
  // exists only in `Branch`. The kept field's type is derived from the named
  // constructor, not a field accessor shared by every variant.
  let source =
    "pub type Node(a) {\n"
    <> "  Branch(value: a, kids: List(Node(a)))\n"
    <> "  Leaf(value: a)\n"
    <> "}\n"
    <> "pub fn relabel(b: Node(a), v: a) -> Node(a) { Branch(..b, value: v) }"
  signature(source, "relabel")
  |> should.equal("fn(Node(a), a) -> Node(a)")
}

pub fn self_recursive_with_imports_generalizes_test() {
  // A self-recursive helper that pattern-matches imported constructors must
  // generalize, so a caller can apply it at more than one type. The helper's
  // own type variable is minted in this module yet collides with the ids the
  // imported `Opt` constructors quantify over; resolving those quantified ids
  // against this module's substitution (instead of treating them as opaque)
  // left the helper monomorphic and produced a spurious recursive-type error
  // when a caller used it at two types — the bug behind the `given` package's
  // `optionx.partition` / `all_some`.
  let opt = "pub type Opt(a) {\n  Som(a)\n  Non\n}"
  let source =
    "import opt.{type Opt, Non, Som}\n"
    <> "fn loop(xs: List(Opt(a)), acc: List(a), n: Int) {\n"
    <> "  let #(acc, n) = case xs {\n"
    <> "    [] -> #(acc, n)\n"
    <> "    [Som(x), ..rest] -> loop(rest, [x, ..acc], n)\n"
    <> "    [Non, ..rest] -> loop(rest, acc, n + 1)\n"
    <> "  }\n"
    <> "  #(acc, n)\n"
    <> "}\n"
    <> "pub fn partition(xs: List(Opt(a))) -> #(List(a), Int) {\n"
    <> "  loop(xs, [], 0)\n"
    <> "}\n"
    <> "pub fn use_twice(xs: List(Opt(a)), ns: List(Opt(Int))) {\n"
    <> "  #(partition(xs), partition(ns))\n"
    <> "}"
  signature_with(source, [#("opt", opt)], "use_twice")
  |> should.equal(
    "fn(List(Opt(a)), List(Opt(Int))) -> #(#(List(a), Int), #(List(Int), Int))",
  )
}

pub fn cross_module_accessor_survives_alias_collision_test() {
  // `rec.make()` returns a record defined in `thing/rec`, accessed via `ex/rec`
  // (both modules' last segment is `rec`, so they collide on the qualified
  // alias). Resolving `.decoder` must still find `thing/rec`'s accessor through
  // the transitive interface graph rather than only the alias-keyed top level —
  // the bug behind the `gloo` package (`schema.users().decoder`, where the
  // `Table` type lives in `gloo/schema` but is reached via `example/schema`).
  let inner = "pub type Rec(t) {\n  Rec(decoder: t)\n}"
  let mid =
    "import thing/rec\n"
    <> "pub fn make() -> rec.Rec(Int) {\n  rec.Rec(decoder: 1)\n}"
  let main = "import ex/rec\npub fn get() {\n  rec.make().decoder\n}"
  signature_with(main, [#("thing/rec", inner), #("ex/rec", mid)], "get")
  |> should.equal("fn() -> Int")
}

pub fn target_specific_definition_is_filtered_test() {
  // A `@target(javascript)` sibling must not shadow the Erlang definition.
  // girard types the Erlang target, so `do_thing` here is the Erlang external
  // returning `Result(Int, MyError)`, not the JS one returning
  // `Result(Int, String)` — the bug behind simplifile's `do_file_info` (and so
  // the `dot_env` package).
  let source =
    "pub type MyError {\n  Boom\n}\n"
    <> "@target(erlang)\n@external(erlang, \"m\", \"f\")\n"
    <> "fn do_thing(x: String) -> Result(Int, MyError)\n"
    <> "@target(javascript)\n@external(javascript, \"./m.mjs\", \"f\")\n"
    <> "fn do_thing(x: String) -> Result(Int, String)\n"
    <> "pub fn thing(x: String) {\n  do_thing(x)\n}"
  signature(source, "thing")
  |> should.equal("fn(String) -> Result(Int, MyError)")
}

pub fn signature_variable_stays_polymorphic_test() {
  // A fully-annotated function whose phantom parameter the body never forces
  // stays polymorphic, matching the compiler (`Expr(a)`, not `Expr(Dyn)`). The
  // recursion is reached through helpers/coercions, so the rigid `ty` is never
  // pinned. This is the gleamgen / pretty_diff / kicad_sexpr bug.
  let source =
    "pub type Dyn\n"
    <> "pub opaque type Expr(ty) {\n  Expr(internal: Internal(ty))\n}\n"
    <> "type Internal(ty) {\n  Lit(Int)\n  Pair(Expr(Dyn), Expr(Dyn))\n}\n"
    <> "fn render_pair(a: Expr(Dyn), b: Expr(Dyn)) -> Int {\n"
    <> "  render(a) + render(b)\n}\n"
    <> "pub fn render(e: Expr(ty)) -> Int {\n"
    <> "  case e.internal {\n    Lit(v) -> v\n    Pair(a, b) -> render_pair(a, b)\n  }\n}"
  signature(source, "render")
  |> should.equal("fn(Expr(a)) -> Int")
}

pub fn partial_annotation_variable_is_rigid_test() {
  // A type variable in a *parameter* annotation is rigid even when the return is
  // not annotated, so the function stays polymorphic over it rather than being
  // monomorphised by a sibling that passes a concrete type. This is gleamgen's
  // `render_operator(expr1: Expression(type_), ...)` with an inferred return.
  let source =
    "pub type Dyn\n"
    <> "pub opaque type Expr(ty) {\n  Expr(internal: Internal(ty))\n}\n"
    <> "type Internal(ty) {\n  Lit(Int)\n  Bin(Expr(Dyn), Expr(Dyn))\n}\n"
    <> "fn render_pair(a: Expr(t), b: Expr(t)) {\n  render(a) + render(b)\n}\n"
    <> "pub fn render(e: Expr(ty)) -> Int {\n"
    <> "  case e.internal {\n    Lit(v) -> v\n    Bin(a, b) -> render_pair(a, b)\n  }\n}"
  signature(source, "render_pair")
  |> should.equal("fn(Expr(a), Expr(a)) -> Int")
}

pub fn no_polymorphic_recursion_test() {
  // A self-recursive call at a different (concrete) type than the rigid
  // signature is rejected, exactly as the compiler rejects polymorphic
  // recursion — `render(a)` where `a : Expr(Dyn)` but `render` expects
  // `Expr(ty)` (rigid).
  let source =
    "pub type Dyn\n"
    <> "pub opaque type Expr(ty) {\n  Expr(internal: Internal(ty))\n}\n"
    <> "type Internal(ty) {\n  Lit(Int)\n  Pair(Expr(Dyn), Expr(Dyn))\n}\n"
    <> "pub fn render(e: Expr(ty)) -> Int {\n"
    <> "  case e.internal {\n    Lit(v) -> v\n    Pair(a, b) -> render(a) + render(b)\n  }\n}"
  case girard.annotate(source, girard.default_options()) {
    Error(_) -> Nil
    Ok(_) -> panic as "expected a type error (no polymorphic recursion)"
  }
}

pub fn annotated_local_function_generalizes_test() {
  // A `let`-bound function is generalized over the type variables written in
  // its annotation, so it may be used at several types (`id(1)` and `id("hi")`).
  // girard treated local bindings as monomorphic and unified the two uses —
  // the bug behind the `esdee` package's `try_find` helper.
  signature(
    "pub fn main() {\n  let id = fn(x: a) -> a { x }\n  #(id(1), id(\"hi\"))\n}",
    "main",
  )
  |> should.equal("fn() -> #(Int, String)")
}

pub fn local_function_generalizes_only_annotated_variables_test() {
  // Only the *annotated* variable (`a`) is generalized; the unannotated
  // parameter `x` stays monomorphic, matching Gleam (which rejects varying an
  // unannotated local parameter across uses).
  signature(
    "pub fn main() {\n  let pair = fn(x: Int, y: a) { #(x, y) }\n  #(pair(1, \"s\"), pair(2, 99))\n}",
    "main",
  )
  |> should.equal("fn() -> #(#(Int, String), #(Int, Int))")
}

pub fn parameter_shadowing_does_not_create_call_edge_test() {
  // A parameter named `pool` shadows the top-level `pool` function. Reference
  // collection must not record the parameter use as a dependency on the
  // top-level `pool`: doing so wrongly merged `worker_loop` into `pool`'s
  // recursive component (worker -> worker_loop -> pool -> worker), so it was
  // never generalized and `worker`'s call — which ties the pool and work
  // message types via the `Started` constructor — over-unified its parameters.
  // This is the bug behind the `crew` package's `worker_loop`.
  let source =
    "type Subject(a) {\n  Subj\n}\n"
    <> "type Pid {\n  APid\n}\n"
    <> "pub type PoolMsg(work, result) {\n"
    <> "  Started(send: Subject(Work(work, result)))\n"
    <> "  Idle(pid: Pid)\n"
    <> "}\n"
    <> "type Work(work, result) {\n  Work(work: work, result: result)\n}\n"
    <> "fn send(s: Subject(a), msg: a) -> Nil {\n  Nil\n}\n"
    <> "fn receive(s: Subject(a)) -> a {\n  panic\n}\n"
    <> "fn pool(seed: Subject(PoolMsg(Int, Int))) -> Nil {\n"
    <> "  worker(seed, 0, fn(s, w) { w })\n"
    <> "}\n"
    <> "fn worker_loop(pool, subject, state, do_work) -> Nil {\n"
    <> "  let Work(work:, result: _) = receive(subject)\n"
    <> "  let result = do_work(state, work)\n"
    <> "  send(pool, Idle(APid))\n"
    <> "  worker_loop(pool, subject, state, do_work)\n"
    <> "}\n"
    <> "fn worker(pool_subject, state, do_work) -> Nil {\n"
    <> "  let subject = Subj\n"
    <> "  send(pool_subject, Started(subject))\n"
    <> "  worker_loop(pool_subject, subject, state, do_work)\n"
    <> "}"
  // PoolMsg's and Work's parameters must stay independent.
  signature(source, "worker_loop")
  |> should.equal(
    "fn(Subject(PoolMsg(a, b)), Subject(Work(c, d)), e, fn(e, c) -> f) -> Nil",
  )
}

pub fn annotate_pre_parsed_module_test() {
  // A client can parse once with glance and hand girard the AST, avoiding a
  // second parse. The annotations carry glance spans, so they line up with the
  // client's own AST nodes.
  let source = "pub fn double(x) {\n  x + x\n}"
  let assert Ok(module) = glance.module(source)

  // Resolve no imports (this module has none).
  let options =
    girard.default_options() |> girard.with_resolver(fn(_) { Error(Nil) })
  let assert Ok(annotated) = girard.annotate_module(module, options)

  // The signature is a structured `Scheme` (here no quantified vars and a
  // `Fn([Int], Int)` type), not a string.
  let assert Ok(girard.Scheme(
    [],
    girard.Fn(
      [girard.Named("gleam", "Int", [])],
      girard.Named("gleam", "Int", []),
    ),
  )) = list.key_find(annotated.functions, "double")

  // Every annotation's span indexes into the client's source / AST. The whole
  // body `x + x` is recorded with its structured type, matching the glance node.
  let assert Ok(start) = first_index(source, "x + x")
  let span = #(start, start + string.byte_size("x + x"))
  list.filter_map(annotated.expressions, fn(a) {
    case #(a.span.start, a.span.end) == span {
      True -> Ok(girard.type_to_string(a.type_))
      False -> Error(Nil)
    }
  })
  |> should.equal(["Int"])
}

pub fn signature_scheme_exposes_quantified_vars_test() {
  // A generic function's scheme lists its quantified type variables...
  let assert Ok(annotated) =
    girard.annotate("pub fn id(x) { x }", girard.default_options())
  let assert Ok(scheme) = list.key_find(annotated.functions, "id")
  list.length(scheme.vars) |> should.equal(1)
  girard.type_to_string(scheme.type_) |> should.equal("fn(a) -> a")

  // ...while a monomorphic one has none.
  let assert Ok(annotated2) =
    girard.annotate("pub fn inc(x) { x + 1 }", girard.default_options())
  let assert Ok(mono) = list.key_find(annotated2.functions, "inc")
  mono.vars |> should.equal([])
}

// --- annotate_package ------------------------------------------------------

/// Parse each `#(path, source)` and pair the path with its `glance.Module`,
/// the shape `annotate_package` consumes.
fn parse_package(
  sources: List(#(String, String)),
) -> List(#(String, glance.Module)) {
  list.map(sources, fn(entry) {
    let #(path, source) = entry
    let assert Ok(module) = glance.module(source)
    #(path, module)
  })
}

/// Annotate `sources` as a package with no import resolution, returning the
/// `ModuleResult` for `path`.
fn package_result(
  sources: List(#(String, String)),
  path: String,
) -> girard.ModuleResult {
  let options =
    girard.default_options() |> girard.with_resolver(fn(_) { Error(Nil) })
  let assert Ok(result) =
    dict.get(girard.annotate_package(parse_package(sources), options), path)
  result
}

fn package_signature(result: girard.ModuleResult, name: String) -> String {
  let assert Ok(sig) = list.key_find(result.annotated.functions, name)
  girard.type_to_string(sig.type_)
}

pub fn annotate_package_annotates_every_module_test() {
  // Each module in the package is annotated and keyed by its path; nothing is
  // skipped, so each result's `skipped` list is empty.
  let sources = [
    #("app/a", "pub fn a() -> Int { 1 }"),
    #("app/b", "pub fn b() -> String { \"x\" }"),
  ]
  let options =
    girard.default_options() |> girard.with_resolver(fn(_) { Error(Nil) })
  let annotated = girard.annotate_package(parse_package(sources), options)

  dict.keys(annotated)
  |> list.sort(string.compare)
  |> should.equal(["app/a", "app/b"])
  let a = package_result(sources, "app/a")
  let b = package_result(sources, "app/b")
  a.skipped |> should.equal([])
  b.skipped |> should.equal([])
  package_signature(a, "a") |> should.equal("fn() -> Int")
  package_signature(b, "b") |> should.equal("fn() -> String")
}

pub fn annotate_package_resolves_cross_module_imports_test() {
  // A module that imports a sibling in the same package types correctly: the
  // sibling is resolved through the resolver (which here serves the same
  // package sources), so `b` sees `a.a`'s `Int` return.
  let sources = [
    #("app/a", "pub fn a() -> Int { 1 }"),
    #("app/b", "import app/a\n\npub fn b() { a.a() }"),
  ]
  let table = dict.from_list(sources)
  let resolver = fn(path) { dict.get(table, path) }
  let options = girard.default_options() |> girard.with_resolver(resolver)

  let assert Ok(b) =
    dict.get(girard.annotate_package(parse_package(sources), options), "app/b")
  package_signature(b, "b") |> should.equal("fn() -> Int")
}

pub fn annotate_package_skips_ill_typed_definition_test() {
  // Best-effort is per definition: an ill-typed function is reported in
  // `skipped` (with its error) and absent from the annotations, while a
  // well-typed sibling in the same module is still annotated.
  let sources = [
    #("app/m", "pub fn good() -> Int { 1 }\npub fn bad() { 1 + \"oops\" }"),
  ]
  let m = package_result(sources, "app/m")

  package_signature(m, "good") |> should.equal("fn() -> Int")
  list.key_find(m.annotated.functions, "bad") |> should.equal(Error(Nil))
  let assert Ok(error) = list.key_find(m.skipped, "bad")
  let assert girard.TypeMismatch(_, _) = error
}

pub fn annotate_package_cascades_to_dependents_test() {
  // A definition that depends on a skipped one cannot be typed either: `bad`
  // fails to type, so `uses_it` sees it as unbound and is skipped in turn. Both
  // are reported; neither is annotated.
  let sources = [
    #("app/m", "pub fn bad() { 1 + \"oops\" }\npub fn uses_it() { bad() }"),
  ]
  let m = package_result(sources, "app/m")

  m.annotated.functions |> should.equal([])
  list.key_find(m.skipped, "bad") |> should.be_ok
  let assert Ok(girard.UnboundVariable("bad")) =
    list.key_find(m.skipped, "uses_it")
}
