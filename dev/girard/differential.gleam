//// The differential driver: it authors `differential/expected.json`.
////
////     gleam run -m girard/differential plan
////     gleam run -m girard/differential build <staging-dir> <date>
////     gleam run -m girard/differential aggregate
////     gleam run -m girard/differential answer <path> <function>
////
//// `scripts/gen-differential.sh` drives it. `plan` writes any missing
//// forced-branch companion and prints, one line per compile, what the shell
//// must stage into a fresh project; `build` reads back what the compiler said,
//// re-runs girard, and writes the manifest; `aggregate` prints the two literals
//// `test/differential_test` pins.
////
//// The **case table** below is the hand-authored half of the manifest: what
//// each fixture contests, which reading the compiler is expected to take, and
//// who owns each divergence. Everything else in a row is derived — from the
//// fixture's source, from the compiler's export, or from running girard. The
//// split is what makes the assertions worth running: a regenerated column
//// cannot be its own expectation.

import argv
import girard
import girard/differential/manifest.{
  type Binding, type Candidate, type Outcome, type Row, type Span,
  type TargetImport, Binding, Candidate, Manifest, Row, Span, TargetImport,
}
import girard/differential/runner
import girard/differential/source
import glance
import gleam/bool
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

// Paths and pins

const cases_dir = "differential/cases"

const support_dir = "differential/support"

const manifest_path = "differential/expected.json"

const plain_template = "differential/gleam.toml"

const pinned_template = "differential/pinned/gleam.toml"

const pinned_lock = "differential/pinned/manifest.toml"

/// The compiler the whole corpus is measured against. Pinned here as well as in
/// `differential/.tool-versions`, because the version is a hash input.
pub const gleam_version = "1.18.0"

/// The stdlib version the one dependency-taking row is pinned to, matching
/// `differential/pinned/manifest.toml`. The test asserts girard's own
/// `build/packages` agrees, so a skew fails loudly instead of reading as a
/// resolution divergence.
pub const stdlib_version = "1.0.3"

// The case table
//
// Hand-authored: `expect` is what the compiler is expected to answer, and does
// not change as girard's resolution is corrected; `why` names the mechanism,
// and for a divergence, the change that must remove it.

/// One case's hand-authored claims.
pub type Spec {
  Spec(
    fixture: String,
    receiver: String,
    label: String,
    kind: String,
    access: String,
    syntax_site: String,
    expect: String,
    field_availability: Option(String),
    narrowed_to: Option(String),
    module_availability: Option(String),
    field_member: Option(String),
    module_member: Option(String),
    field_return: Option(String),
    module_return: Option(String),
    field_candidates: Option(List(Candidate)),
    missing_variants: Option(List(String)),
    reason: Option(String),
    derivable: Option(Bool),
    expect_girard_error_variant: Option(String),
    why: String,
  )
}

// The corpus's default row: a call in return position of an unannotated
// function, contesting `println` on the two-variant `Logger` against the shadow
// module's `fn(String) -> Int`. Only `Loud` declares the label, so with an
// un-narrowed receiver no accessor exists and the module is the only reading
// that type-checks.
fn logger(fixture: String, why: String) -> Spec {
  Spec(
    fixture:,
    receiver: "io",
    label: "println",
    kind: manifest.kind_resolution,
    access: manifest.access_call,
    syntax_site: manifest.site_call,
    expect: manifest.expect_module,
    field_availability: Some(manifest.unavailable),
    narrowed_to: None,
    module_availability: Some(manifest.available),
    field_member: None,
    module_member: Some("fn(String) -> Int"),
    field_return: None,
    module_return: Some("Int"),
    field_candidates: Some([
      Candidate(
        variant: "Loud",
        index: 0,
        member: "fn(String) -> Nil",
        return: "Nil",
      ),
    ]),
    missing_variants: Some(["Quiet"]),
    reason: Some(manifest.reason_partial),
    derivable: Some(True),
    expect_girard_error_variant: None,
    why:,
  )
}

// The same contest with the receiver narrowed to `Loud`, so both readings
// type-check and the fixture measures resolution rather than unification.
fn narrowed(fixture: String, why: String) -> Spec {
  Spec(
    ..logger(fixture, why),
    expect: manifest.expect_field,
    field_availability: Some(manifest.variant),
    narrowed_to: Some("Loud"),
    field_member: Some("fn(String) -> Nil"),
    field_return: Some("Nil"),
    field_candidates: None,
    missing_variants: None,
    reason: None,
  )
}

// The same contest read as a projection of `n`, which only `Quiet` declares:
// an un-narrowed receiver grants no accessor, so the module's `String` is the
// only reading that type-checks.
fn projected_n(fixture: String, why: String) -> Spec {
  Spec(
    ..logger(fixture, why),
    label: "n",
    access: manifest.access_projection,
    syntax_site: manifest.site_bare,
    module_member: Some("String"),
    module_return: Some("String"),
    field_candidates: Some([
      Candidate(variant: "Quiet", index: 0, member: "Int", return: "Int"),
    ]),
    missing_variants: Some(["Loud"]),
  )
}

// A single-variant receiver, so a real accessor exists with no narrowing at
// all. The rows that use it put the receiver somewhere its type is only known
// if the expected type reached it before the access was walked, so the field
// branch must not also depend on a narrowing to be in reach.
fn solo(fixture: String, why: String) -> Spec {
  Spec(
    ..narrowed(fixture, why),
    field_availability: Some(manifest.shared),
    narrowed_to: None,
  )
}

// A probe: it asks only whether the program was accepted, so it contests no
// branch and records no availability, member or return.
fn probe(
  fixture: String,
  receiver: String,
  label: String,
  variant: String,
  why: String,
) -> Spec {
  Spec(
    fixture:,
    receiver:,
    label:,
    kind: manifest.kind_probe,
    access: manifest.access_call,
    syntax_site: manifest.site_call,
    expect: manifest.expect_error,
    field_availability: None,
    narrowed_to: None,
    module_availability: None,
    field_member: None,
    module_member: None,
    field_return: None,
    module_return: None,
    field_candidates: None,
    missing_variants: None,
    reason: None,
    derivable: None,
    expect_girard_error_variant: Some(variant),
    why:,
  )
}

// Every row whose field branch is out of reach wants the module, on both sides.
// What keeps that from being an accident is the forced-field companion, which
// must fail to compile - so the field really is unreachable, and the narrowing
// that follows the value must not over-narrow it back into reach.
const unreachable = ". The field branch is genuinely out of reach here, which the forced-field companion failing to compile is what proves, so agreement is not an accident of under-narrowing: these are the rows that keep narrowing carried on the value's type from over-narrowing it back into reach"

// What the alias rows share: the value is re-bound under another name, and the
// narrowing comes with it because it lives on the value's own type rather than
// under the name it happened to be bound to.
const rebinding = "the narrowing survives the re-binding because it lives on the value's type rather than under the name it was bound to"

// What the rows that flip when a field access selects by variant share: the
// constructed value reaches the receiver carrying the variant it was built
// with, and the accessor lookup reads it off the type.
const on_the_type = ". girard agrees because the value's type carries the variant it was constructed with, and a field access selects that variant's own accessors"

// The mechanism the narrowed rows share: the receiver's own type says which
// variant it was built with, and that reading is taken in call position the
// way projection always took it.
const field_first = "narrowing carried on the value's type, read field-first in call position since `infer_callee` resolves through `infer_field_access`"

// What the rows contesting a seeded lambda parameter share: the expected
// function type reaches the lambda before its body is walked, so the receiver
// is a bound record at the access rather than the unbound variable that would
// send the lookup to the module export of its name.
const seeded = ". The parameter is bound before the body is walked, so the access reads the record it was seeded with rather than falling through to the module export of the parameter's name"

/// Every case, in the order they appear in the manifest.
pub fn specs() -> List(Spec) {
  [
    Spec(
      ..logger(
        "greet",
        "no variant declares `greet`, so every reading is the module: the one-sided control that stops the corpus reading as `the field always wins`",
      ),
      label: "greet",
      field_availability: Some(manifest.undeclared),
      field_candidates: None,
      missing_variants: None,
      reason: None,
      module_member: Some("fn() -> Int"),
    ),
    logger(
      "plain_param",
      "an un-narrowed parameter grants no accessor, since `println` is on one variant of two, so both sides read the module"
        <> unreachable,
    ),
    logger(
      "helper_returned",
      "a value returned by an annotated helper carries no variant, so the receiver is un-narrowed exactly as in `plain_param`"
        <> unreachable,
    ),
    projected_n(
      "projection_plain",
      "the projection twin of `plain_param`: no accessor, so both sides read the module const"
        <> unreachable,
    ),
    Spec(
      ..narrowed(
        "projection_narrowed",
        "the projection path reads the receiver's own type, so `Ctor(..) as v` narrowing reaches projections; its call-position twin `narrowed_case` resolves through the same path and agrees too",
      ),
      label: "n",
      access: manifest.access_projection,
      syntax_site: manifest.site_bare,
      narrowed_to: Some("Quiet"),
      field_member: Some("Int"),
      field_return: Some("Int"),
      module_member: Some("String"),
      module_return: Some("String"),
    ),
    narrowed(
      "narrowed_case",
      field_first
        <> ": a reachable variant field wins over the module export exactly as it does in projection",
    ),
    narrowed(
      "direct_construction",
      "construction narrowing: a constructor's return type carries the variant it builds, so `let io = Loud(f)` needs nothing else. "
        <> field_first,
    ),
    narrowed(
      "alias_let",
      "`let assert Loud(..) = l` narrows `l` itself, and `let io = l` binds `io` to `l`'s type: "
        <> rebinding,
    ),
    Spec(
      ..narrowed(
        "alias_no_module",
        "the same shape with the module removed, so the field is the only reading and there is nothing to fall through to. It was the worked example of a status divergence - girard errored outright where the compiler read the field - and is now what proves the other alias rows are answered rather than defaulted to the module",
      ),
      module_availability: Some(manifest.undeclared),
      module_member: None,
      module_return: None,
    ),
    Spec(
      ..logger(
        "accessor_index",
        "both variants declare `y` at one type but different positions, so no accessor exists and both sides read the module: `shared_accessors` compares position as well as label and type, as the compiler's `get_compatible_record_fields` does. Live in projection position, so it is independent of call-position precedence",
      ),
      label: "y",
      access: manifest.access_projection,
      syntax_site: manifest.site_bare,
      module_member: Some("Float"),
      module_return: Some("Float"),
      field_candidates: Some([
        Candidate(variant: "A", index: 1, member: "String", return: "String"),
        Candidate(variant: "B", index: 0, member: "String", return: "String"),
      ]),
      missing_variants: Some([]),
      reason: Some(manifest.reason_index),
    ),
    Spec(
      ..logger(
        "accessor_type",
        "the regression guard for the accessor fix: same label and index, different types, so no accessor exists and the module must win - and must keep winning now that a reachable field beats the module",
      ),
      label: "f",
      access: manifest.access_projection,
      syntax_site: manifest.site_bare,
      module_return: Some("fn(String) -> Int"),
      field_candidates: Some([
        Candidate(
          variant: "E",
          index: 0,
          member: "fn(String) -> Nil",
          return: "fn(String) -> Nil",
        ),
        Candidate(
          variant: "G",
          index: 0,
          member: "fn(Int) -> Nil",
          return: "fn(Int) -> Nil",
        ),
      ]),
      missing_variants: Some([]),
      reason: Some(manifest.reason_type),
    ),
    Spec(
      ..logger(
        "accessor_shared",
        "the positive control for the accessor fix: same label, index and type, so the accessor is real and the field must win - the positional rule must not be written as `never share anything`",
      ),
      label: "y",
      access: manifest.access_projection,
      syntax_site: manifest.site_bare,
      expect: manifest.expect_field,
      field_availability: Some(manifest.shared),
      field_member: Some("String"),
      field_return: Some("String"),
      field_candidates: None,
      missing_variants: None,
      reason: None,
      module_member: Some("Float"),
      module_return: Some("Float"),
    ),
    solo(
      "only_loud",
      "a single-variant type grants a real accessor, so the field is in reach with no narrowing at all",
    ),
    narrowed(
      "narrowed_subject",
      "the subject of the `case` is the receiver itself and no `as` rebinds it: "
        <> field_first,
    ),
    narrowed(
      "alias_block",
      "the narrowed value leaves a block through its final expression, and a block's type is that expression's, so `let io = { .. l }` is `alias_let` with a block in the way: "
        <> rebinding,
    ),
    narrowed(
      "let_assert",
      "`let assert Loud(..) as io = l` narrows and binds in one pattern, the shortest path from a pattern to a narrowed receiver: "
        <> field_first,
    ),
    narrowed(
      "alternatives_agree",
      "both alternatives of the pattern are `Loud`, so the narrowing is to a single variant and the field stays in reach through an alternative pattern: `agree_variants` keeps a variant every alternative gives the name, and it is read field-first in call position since `infer_callee` resolves through `infer_field_access`",
    ),
    logger(
      "closure_param",
      "the closure's parameter is a fresh, annotated binding, so the narrowing outside it does not reach the receiver: passes today for the right reason, and narrowing that follows the value must not make it over-narrow",
    ),
    logger(
      "factory_result",
      "construction narrowing must not survive a call boundary: `Loud(f)` is constructed inside `build`, whose annotated return carries no variant"
        <> unreachable,
    ),
    logger(
      "alternatives_disagree",
      "the alternatives are `Loud` and `Quiet`, so no single variant is narrowed to and the field is out of reach: `agree_variants` erases a variant the alternatives disagree on before the body is checked under each of them, so neither alternative reads the first one's field"
        <> unreachable,
    ),
    logger(
      "through_generic",
      "a constructed value passed through `fn(x: a) -> a` loses its variant at the generic boundary, matching the compiler's erase"
        <> unreachable,
    ),
    logger(
      "wildcard_column",
      "the receiver's column of the `case` is a plain binding, which constrains no variant, so the pattern narrows nothing"
        <> unreachable,
    ),
    logger(
      "after_case",
      "the narrowing inside a `case` must not leak past it: the access is after the `case`, on the same binding the `case` matched on"
        <> unreachable,
    ),
    logger(
      "rebound_in_branch",
      "the name is bound twice - a parameter and a `let` inside the branch - and the inner binding is `Quiet`, which declares no `println`, so the field is out of reach. The row whose forced-module companion needs both declarations renamed"
        <> unreachable,
    ),
    Spec(
      ..narrowed(
        "pipe_narrowed",
        "a bare pipe target is inferred through `infer_expr` into `infer_field_access`, the one resolver a call also reaches through `infer_callee`, so a pipe target and a call read the same field",
      ),
      syntax_site: manifest.site_pipe,
    ),
    Spec(
      ..logger(
        "pipe_plain",
        "the un-narrowed polarity of the pipe row: no accessor, so the module is the only reading either path can take"
          <> unreachable,
      ),
      syntax_site: manifest.site_pipe,
    ),
    Spec(
      ..narrowed(
        "use_guard",
        "a `use` target is the callee of a `Call` in glance, resolved through `infer_callee` like any call, so the same field-first derivation applies. The shadow module's `guard` is deliberately monomorphic, unlike `gleam/bool.guard`, which is what keeps this row derivable",
      ),
      label: "guard",
      narrowed_to: Some("Wrapped"),
      field_member: Some("fn(Bool, Int, fn() -> Int) -> Nil"),
      field_return: Some("Nil"),
      module_member: Some("fn(Bool, Int, fn() -> Int) -> Int"),
      module_return: Some("Int"),
    ),
    Spec(
      ..logger(
        "result_try",
        "the corpus's one intended `derivable: false` row: a callback parameter named `result` shadowing the real `gleam/result`, whose generic `try` cannot have its specialized return read off its declaration without performing unification in the test. The forced compile measures it instead",
      ),
      receiver: "result",
      label: "try",
      field_availability: Some(manifest.undeclared),
      field_candidates: None,
      missing_variants: None,
      reason: None,
      module_member: Some(
        "fn(Result(a, e), fn(a) -> Result(b, e)) -> Result(b, e)",
      ),
      module_return: Some("Result(Int, Nil)"),
      derivable: Some(False),
    ),
    Spec(
      ..narrowed(
        "aliased_import",
        "the collision is with an import alias rather than a module path's final segment: "
          <> field_first
          <> ". Assertion 8 is that extension: girard now reports the resolution itself, and every row with a colliding import in scope pins the canonical module path - here `differential/shadow`, which no type answer can tell apart from the alias `printer`",
      ),
      receiver: "printer",
    ),
    Spec(
      ..narrowed(
        "imported_narrowed",
        "the narrowed type is declared in a second module, pinning that variant narrowing - and the field index the narrowed variant grants - agree across a module boundary: "
          <> field_first
          <> ", and the module boundary costs nothing",
      ),
      narrowed_to: Some("Near"),
    ),
    Spec(
      ..narrowed(
        "renamed_alternatives",
        "the alternatives name one variant two ways - a renamed unqualified import `Near as Close` and the qualified `kinds.Near` - so the narrowing survives `agree_variants`, which compares the variant each alternative's type carries rather than the constructor's spelling, exactly as the compiler compares variant indices: "
          <> field_first,
      ),
      narrowed_to: Some("Near"),
    ),
    Spec(
      ..narrowed(
        "field_by_elimination",
        "no colliding module is in scope at all, so the field wins by elimination: the control that shows the module branch, not the field one, is what the other rows contest",
      ),
      field_availability: Some(manifest.shared),
      narrowed_to: None,
      module_availability: Some(manifest.undeclared),
      module_member: None,
      module_return: None,
    ),
    Spec(
      ..logger(
        "unbound_fallback",
        "an unbound receiver whose name is a module in scope that exports the label does not error: the compiler falls through to the module export, and girard's current behaviour is correct. A resolution row rather than a probe, so a regression that read some other type moves the ratchet instead of passing a status comparison",
      ),
      field_availability: Some(manifest.unknown_receiver),
      field_candidates: None,
      missing_variants: None,
      reason: None,
    ),
    // Where the compiler seeds a lambda's parameter
    //
    // Each row puts the receiver in a lambda parameter whose type the caller
    // supplies. The compiler fixes every parameter type before it walks the
    // body — `infer_fn_with_known_types` opens the scope with the arguments
    // already typed — so the receiver is a bound `Solo` at the access and the
    // field is in reach. These are the rows that keep girard doing the same:
    // a receiver whose type only arrives after the body is walked is unbound
    // at the access, and the module export of its name wins instead, which is
    // the over-permissive direction — the compiler *can* type this receiver.
    solo(
      "pipe_lambda",
      "the compiler rewrites `left |> fn(..) { .. }` as a call of the lambda on the piped value, so the parameter is seeded from that value's type before the body is walked"
        <> seeded,
    ),
    solo(
      "applied_lambda",
      "a lambda in callee position is seeded from its own call's arguments: the compiler infers them speculatively, seeds the parameters from what it learned, and then infers them again for real"
        <> seeded,
    ),
    solo(
      "use_callback",
      "a `use` callback is an ordinary trailing argument to the call the `use` desugars to, so it is checked against the callee's parameter type like any other lambda argument — which means the callee is inferred before the block is walked, not after"
        <> seeded,
    ),
    solo(
      "use_callback_labelled",
      "the callback is *not* the callee's final declared parameter here: a labelled `times:` occupies the later slot, so the reorder places the callback in slot 0 and the arguments are inferred in declared order. The row that separates seeding the callback from its declared parameter from seeding it from the last one"
        <> seeded,
    ),
    // Where the compiler keeps a narrowing
    //
    // Each row hands the receiver a value that is already known to be `Loud`,
    // by a route that never passes through a type variable.
    narrowed(
      "tuple_pattern",
      "a tuple pattern is structural, so `let #(io, _) = #(Loud(f), 1)` binds `io` to the first element's own type, variant and all"
        <> on_the_type,
    ),
    narrowed(
      "generic_constant_subject",
      "a module constant is a subject like any other name, and a generic one is generalized: `const io = Quiet(0)` is bound at `Logger(a)`, so narrowing has to stamp under the quantifier rather than monomorphize the binding, which would reject the constant's other instantiations",
    ),
    narrowed(
      "wildcard_alternative_keeps",
      "a later alternative can only take the subject's narrowing away, and only by naming a *different* variant: `Loud(..) | _` names none in the second alternative, so the first alternative's narrowing stands and the field is in reach. The rule is the compiler's alternative-mode `set_subject_variable_variant`, which returns early rather than erasing when nothing was recorded",
    ),
    narrowed(
      "use_result",
      "`use` is the fourth call shape, after the call, the pipe and the capture: it desugars to a call of the right-hand side with the callback as its last argument, so the block's value is the callee's own return and keeps the variant that return was stamped with. `use_bound` pins the callback's parameter; this row pins the result"
        <> on_the_type,
    ),
    narrowed(
      "capture_call",
      "a capture is a lambda whose body is the call it wraps, so `Loud(_)` returns the constructor's own stamped type and calling it keeps the variant"
        <> on_the_type,
    ),
    narrowed(
      "closure_returned",
      "a closure is not generalized, and a call's type is the callee's own return type, so `mk()` hands back the `Loud` the closure built"
        <> on_the_type,
    ),
    narrowed(
      "constructor_in_variable",
      "`let mk = Loud` binds the constructor itself, so calling it returns the type `Loud(f)` would have had"
        <> on_the_type,
    ),
    narrowed(
      "pipe_into_constructor_call",
      "a call-form pipe is a call: `f |> Loud()` is `Loud(f)`, whose type is the constructor's own"
        <> on_the_type,
    ),
    narrowed(
      "saturated_pipe_closure",
      "a saturated pipe applies the piped value to the call's result, and that application is structural too, so `f |> mk()` is `mk()(f)` and keeps the variant"
        <> on_the_type,
    ),
    narrowed(
      "record_update_result",
      "a record update's result is the named constructor's instantiated return, so `Loud(..l, println: f)` is known to be `Loud`"
        <> on_the_type,
    ),
    narrowed(
      "as_passes_subject",
      "an assignment pattern hands the subject variable on to the pattern inside it, so `Loud(..) as l` narrows the subject `io` as well as binding `l`. girard threads the subject through `PatternAssignment` for the same reason",
    ),
    narrowed(
      "echo_subject",
      "`echo` is transparent to the subject rule, so `case echo io` narrows `io` exactly as `case io` does: `subject_of` looks through it as the compiler's `subject_variable` does",
    ),
    narrowed(
      "echo_let_assert",
      "the same transparency on the `let assert` path, where the subject is the assigned value rather than a `case` subject",
    ),
    narrowed(
      "annotated_let",
      "an annotation is unified against the value's type rather than substituted for it, so `let io: Logger = Loud(f)` keeps the variant the constructor built and the annotation never displaces it",
    ),
    narrowed(
      "let_assert_as",
      "the `as` name takes the constructor pattern's own type, which carries the variant. The subject here is a call rather than a bare variable, so no subject narrowing is available and the `as` binding is the only route to the field - which is what separates this row from `let_assert`",
    ),
    narrowed(
      "unannotated_param_subject",
      "an unannotated parameter is bound first and narrowed second, so `let assert Loud(..) = io` reaches the field on the parameter itself: the row that guards binding a parameter's type against erasing what the pattern then narrows",
    ),
    narrowed(
      "subject_alternatives_agree",
      "both alternatives narrow the subject to `Loud`, so the agreement rule keeps it: the subject-variable twin of `alternatives_agree`, which narrows through `as` bindings instead",
    ),
    narrowed(
      "subject_rebound_in_pattern",
      "`Loud(..) as io` on the subject `io` rebinds the subject, so the subject is not narrowed - and need not be, because the `as` binding takes the constructor's own type. The row that keeps the rule about a rebound subject from also suppressing the `as` binding's own variant",
    ),
    // Where the compiler drops a narrowing
    //
    // Each row puts the constructed value somewhere the compiler forgets which
    // variant it was: a type variable, a generalized definition, or two
    // alternatives that disagree. They pin the erase, and a wrong erase fails
    // in the silent direction.
    logger(
      "unannotated_helper",
      "an unannotated top-level function is generalized at the module boundary, which erases every variant in its type, so `make(f)` hands back a plain `Logger` where `factory_result`'s annotation does the same job explicitly"
        <> unreachable,
    ),
    projected_n(
      "constant_receiver",
      "a module constant is generalized the way a function is, so `const quiet = Quiet(0)` reaches the receiver un-narrowed. Live in projection position, so it is independent of call-position precedence"
        <> unreachable,
    ),
    logger(
      "pipe_into_constructor",
      "a bare-function pipe applies through a fresh type variable, and binding a variable erases the variant: `f |> Loud` is where the pipe rows part from `pipe_into_constructor_call`"
        <> unreachable,
    ),
    logger(
      "case_result",
      "a `case` result is a fresh type variable every arm is bound into, so a `case` returning `Loud(f)` from every arm still yields an un-narrowed `Logger`"
        <> unreachable,
    ),
    logger(
      "subject_alternatives_disagree",
      "the alternatives narrow the subject to `Loud` and to `Quiet`, so it is narrowed to nothing under both: the subject-variable twin of `alternatives_disagree`"
        <> unreachable,
    ),
    logger(
      "wildcard_alternative_first",
      "the other order of `wildcard_alternative_keeps`, and why that rule has to be order-sensitive rather than a set comparison: only the *first* alternative may set the subject's variant, so a leading `_` narrows nothing and the `Loud(..)` after it is not allowed to put it back"
        <> unreachable,
    ),
    logger(
      "as_alternative_wildcard",
      "the pattern-bound analogue of `wildcard_alternative_keeps`, measured because the two classes turn out not to share a rule: a name the alternatives *bind* is unified through `unify_constructor_variants`, which keeps a variant only where every alternative gives the same one, so the `_ as io` alternative erases what `Loud(..) as io` narrowed - where the subject form keeps it"
        <> unreachable,
    ),
    logger(
      "list_pattern",
      "a list literal's elements are bound into the list's element variable, which erases the variant before the pattern binds `io`"
        <> unreachable,
    ),
    logger(
      "generic_constructor_arg",
      "a constructed value put into `Box(a)` is bound into a type variable and comes back out of the pattern un-narrowed: the erase reaches through a constructor's argument as `through_generic` shows it reaching through a function's"
        <> unreachable,
    ),
    logger(
      "use_bound",
      "a `use` callback's parameter is a fresh type variable the caller binds, so a value the caller constructs arrives un-narrowed"
        <> unreachable,
    ),
    logger(
      "subject_rebound_by_sibling",
      "a subject the multi-pattern itself rebinds is not narrowed: `io` in the first column binds `left`'s value, and that binding wins. girard asks which names the whole multi-pattern binds before narrowing any column's subject, so the sibling's binding is left alone"
        <> unreachable,
    ),
    logger(
      "subject_narrowed_then_rebound",
      "the other order of `subject_rebound_by_sibling`: the subject is narrowed by the first column and rebound by the second, and the pattern's binding still wins. The rule is about the whole multi-pattern, so it holds in both orders"
        <> unreachable,
    ),
    probe(
      "unbound_no_module",
      "thing",
      "println",
      "NotARecord",
      "an unbound receiver whose name is not a module in scope: record access fails, module access is unavailable, and both sides reject it - girard at NotARecord where the compiler reaches `Unknown type for record access`",
    ),
    probe(
      "unbound_no_export",
      "io",
      "nosuch",
      "NotARecord",
      "an unbound receiver whose name is a module in scope that does not export the label: the module branch is unavailable too, so the fallback has nothing to fall through to and both sides reject it",
    ),
    probe(
      "narrowed_labelled",
      "io",
      "println",
      "AmbiguousCall",
      "a record-selected callee has no field map, so a same-named module's labels must not apply: the narrowed receiver reads the field, and `message:` is then an unexpected labelled argument on both sides - girard at AmbiguousCall where the compiler reports `Unexpected labelled argument`",
    ),
    probe(
      "shadowed_callee_labels",
      "println",
      "println",
      "AmbiguousCall",
      "a `let` shadowing an imported labelled function takes its labels with it: the compiler reads a bare-name callee's field map off whatever the name resolves to, and a local binding has none, so `message:` is an unexpected labelled argument - girard reorders by the shadowed import's labels and accepts, which `shadowed-callee-labels` fixes",
    ),
  ]
}

// Deriving the rest of a row
//
// Where the contested access is, which occurrences of the receiver's name the
// forced-module companion replaces, and which files a row's compile reads.

/// Everything about a case that is read off its source rather than authored.
pub type Derived {
  Derived(
    text: String,
    module: glance.Module,
    target_import: Option(TargetImport),
    target_access: Span,
    bindings: List(Binding),
    renamed_to: Option(String),
    renamed_spans: List(Span),
    has_forced_field: Bool,
    has_forced_module: Bool,
  )
}

/// Read a fixture and derive its source metadata.
///
/// Companion existence follows two independent conditions, and `kind` overrides
/// both: a probe has neither companion whatever its source looks like, while a
/// resolution row takes a forced-field companion only where a colliding module
/// is in scope, and a forced-module companion only where a local binding
/// shadows the name.
pub fn read_fixture(spec: Spec) -> Derived {
  let path = base_path(spec.fixture)
  let assert Ok(text) = simplifile.read(path)
  let assert Ok(module) = source.parse(text)

  let accesses =
    source.accesses(module)
    |> list.filter(fn(access) {
      access.receiver == spec.receiver && access.label == spec.label
    })
  let assert [access] = accesses

  let target_import =
    source.import_binding(module, spec.receiver)
    |> option.map(fn(found) { TargetImport(module: found.0, alias: found.1) })

  let bindings =
    source.declaration_spans(module, text, spec.receiver)
    |> list.map(fn(span) {
      Binding(name: spec.receiver, span: Span(span.start, span.end))
    })

  let contested = spec.kind != manifest.kind_probe
  let has_forced_field = contested && option.is_some(target_import)
  let has_forced_module = contested && bindings != []

  let renamed_to = case has_forced_module {
    True -> Some(fresh_name(module, text))
    False -> None
  }
  let renamed_spans = case has_forced_module {
    True ->
      source.rename_spans(module, text, spec.receiver, access.container)
      |> list.map(fn(span) { Span(span.start, span.end) })
    False -> []
  }

  Derived(
    text:,
    module:,
    target_import:,
    target_access: Span(access.span.start, access.span.end),
    bindings:,
    renamed_to:,
    renamed_spans:,
    has_forced_field:,
    has_forced_module:,
  )
}

// A name no identifier in the module already uses and no imported module is
// bound to, so the rename cannot create a collision of its own.
fn fresh_name(module: glance.Module, text: String) -> String {
  let taken = source.identifiers(text)
  let modules = source.imported_modules(module)
  next_fresh(taken, modules, 0)
}

fn next_fresh(taken: List(String), modules: List(String), n: Int) -> String {
  let candidate = "rec_" <> int.to_string(n)
  case
    list.contains(taken, candidate)
    || list.any(modules, fn(path) { string.ends_with(path, "/" <> candidate) })
  {
    True -> next_fresh(taken, modules, n + 1)
    False -> candidate
  }
}

/// The forced-field companion's source: the base with the target import's line
/// removed, so the receiver's name cannot denote a module.
pub fn forced_field_source(derived: Derived) -> Option(String) {
  use <- bool.guard(!derived.has_forced_field, None)
  let assert Some(target) = derived.target_import
  let assert Ok(#(text, _start, _length)) =
    source.remove_import(derived.module, derived.text, target.module)
  Some(text)
}

/// The forced-module companion's source: the base with every occurrence of the
/// receiver's name replaced except inside the imports and except the container
/// at the contested access, so the name denotes only the module.
pub fn forced_module_source(derived: Derived) -> Option(String) {
  use <- bool.guard(!derived.has_forced_module, None)
  let assert Some(replacement) = derived.renamed_to
  let spans =
    list.map(derived.renamed_spans, fn(span) {
      glance.Span(span.start, span.end)
    })
  Some(source.apply_rename(derived.text, spans, replacement))
}

// The compiler input closure
//
// Every part of it is a byte sequence committed in the tree, so the
// compiler-free test can reconstruct it: the fixture and whichever companions
// the row has, every support module they transitively import, and the template
// the row is actually built from.

/// Whether a row reaches outside `differential/support` and so needs the pinned
/// template and its committed lock rather than the zero-dependency one.
pub fn uses_dependencies(paths: List(String)) -> Bool {
  list.any(paths, fn(path) {
    let assert Ok(text) = simplifile.read(path)
    let assert Ok(module) = source.parse(text)
    list.any(source.imported_modules(module), fn(imported) {
      !string.starts_with(imported, "differential/")
    })
  })
}

/// The support modules a set of sources transitively imports, as
/// repository-relative paths.
pub fn support_closure(paths: List(String)) -> List(String) {
  close_support(paths, [])
}

fn close_support(pending: List(String), seen: List(String)) -> List(String) {
  case pending {
    [] -> list.sort(seen, string.compare)
    [path, ..rest] -> {
      let assert Ok(text) = simplifile.read(path)
      let assert Ok(module) = source.parse(text)
      let next =
        source.imported_modules(module)
        |> list.filter(string.starts_with(_, "differential/"))
        |> list.map(fn(imported) { support_dir <> "/" <> imported <> ".gleam" })
        |> list.filter(fn(candidate) { !list.contains(seen, candidate) })
      close_support(list.append(rest, next), list.append(seen, next))
    }
  }
}

/// Which template a row compiles against: the zero-dependency one, or the
/// pinned one and its committed lock.
pub fn template_files(sources: List(String)) -> List(String) {
  case uses_dependencies(sources) {
    True -> [pinned_template, pinned_lock]
    False -> [plain_template]
  }
}

/// Every file in a row's compiler input closure, as repository-relative paths:
/// the fixture and whichever companions it has, every support module they
/// transitively import, and the template the row is actually built from.
///
/// The driver derives the two flags from a `Derived`, the test from a `Row`.
/// Only the derivation differs, so the closure itself lives here once — the
/// digest is meaningless unless both halves compute it identically.
pub fn input_files(
  fixture: String,
  has_forced_field: Bool,
  has_forced_module: Bool,
) -> List(String) {
  let sources =
    [
      Some(base_path(fixture)),
      case has_forced_field {
        True -> Some(forced_field_path(fixture))
        False -> None
      },
      case has_forced_module {
        True -> Some(forced_module_path(fixture))
        False -> None
      },
    ]
    |> option.values
  list.flatten([sources, support_closure(sources), template_files(sources)])
}

/// Where each of a case's files lives.
pub fn base_path(fixture: String) -> String {
  cases_dir <> "/" <> fixture <> "/base.gleam"
}

/// The forced-field companion's path.
pub fn forced_field_path(fixture: String) -> String {
  cases_dir <> "/" <> fixture <> "/forced_field.gleam"
}

/// The forced-module companion's path.
pub fn forced_module_path(fixture: String) -> String {
  cases_dir <> "/" <> fixture <> "/forced_module.gleam"
}

// Commands

pub fn main() -> Nil {
  case argv.load().arguments {
    ["plan"] -> plan()
    ["build", staging, date] -> build(staging, date)
    ["aggregate"] -> aggregate()
    ["answer", path, function] -> answer(path, function)
    _ ->
      io.println_error(
        "usage: gleam run -m girard/differential plan | build <staging-dir> <date> | aggregate | answer <path> <function>",
      )
  }
}

// `plan` writes any missing companion and then prints, one line per compile,
// what the shell has to stage: the case, which module it is, its source path,
// which template it builds against, and its support closure.
fn plan() -> Nil {
  list.each(specs(), fn(spec) {
    let derived = read_fixture(spec)
    write_companion(
      forced_field_path(spec.fixture),
      forced_field_source(derived),
    )
    write_companion(
      forced_module_path(spec.fixture),
      forced_module_source(derived),
    )

    let sources = [
      #("base", base_path(spec.fixture)),
      ..list.flatten([
        case derived.has_forced_field {
          True -> [#("forced_field", forced_field_path(spec.fixture))]
          False -> []
        },
        case derived.has_forced_module {
          True -> [#("forced_module", forced_module_path(spec.fixture))]
          False -> []
        },
      ])
    ]
    // One template for the whole row, not one per file: `inputs_hash` covers
    // *the* template the row is built from, so a companion compiled against a
    // different one would be evidence produced from an uncovered input.
    let template = case uses_dependencies(list.map(sources, fn(e) { e.1 })) {
      True -> "pinned"
      False -> "plain"
    }
    list.each(sources, fn(entry) {
      let #(variant, path) = entry
      io.println(string.join(
        [
          spec.fixture,
          variant,
          path,
          template,
          string.join(support_closure([path]), ","),
        ],
        "\t",
      ))
    })
  })
}

// Companions are committed source, so a first generation writes them and every
// later run leaves the committed bytes exactly as they are: what the compiler
// reads must be what the test reconstructs.
fn write_companion(path: String, text: Option(String)) -> Nil {
  case text, simplifile.read(path) {
    Some(text), Error(_) -> {
      let assert Ok(_) = simplifile.write(path, text)
      io.println_error("wrote " <> path)
    }
    None, Ok(_) -> {
      let assert Ok(_) = simplifile.delete(path)
      io.println_error("removed " <> path)
    }
    _, _ -> Nil
  }
}

// `build` reads back what the compiler said for each staged compile, re-runs
// girard, and writes the manifest.
fn build(staging: String, date: String) -> Nil {
  let rows = list.map(specs(), fn(spec) { row(spec, staging) })
  let assert Ok(_) =
    simplifile.write(
      manifest_path,
      manifest.encode(Manifest(
        gleam: gleam_version,
        generated: date,
        cases: rows,
      )),
    )
  io.println("wrote " <> manifest_path)
  report(rows)
}

fn row(spec: Spec, staging: String) -> Row {
  let derived = read_fixture(spec)
  let compiler = outcome(staging, spec.fixture, "base", spec.fixture)
  let forced_field = case derived.has_forced_field {
    True -> Some(outcome(staging, spec.fixture, "forced_field", spec.fixture))
    False -> None
  }
  let forced_module = case derived.has_forced_module {
    True -> Some(outcome(staging, spec.fixture, "forced_module", spec.fixture))
    False -> None
  }
  let girard = runner.girard_outcome(derived.text, spec.fixture)

  let files =
    input_files(
      spec.fixture,
      derived.has_forced_field,
      derived.has_forced_module,
    )
    |> list.map(fn(path) {
      let assert Ok(bytes) = simplifile.read_bits(path)
      #(path, bytes)
    })
  let inputs_hash =
    manifest.inputs_hash(
      gleam_version,
      case derived.has_forced_field {
        True -> Some(forced_field_path(spec.fixture))
        False -> None
      },
      case derived.has_forced_module {
        True -> Some(forced_module_path(spec.fixture))
        False -> None
      },
      files,
    )

  let draft =
    Row(
      fixture: spec.fixture,
      function: spec.fixture,
      kind: spec.kind,
      access: spec.access,
      syntax_site: spec.syntax_site,
      expect: spec.expect,
      field_availability: spec.field_availability,
      narrowed_to: spec.narrowed_to,
      module_availability: spec.module_availability,
      field_member: spec.field_member,
      module_member: spec.module_member,
      field_return: spec.field_return,
      module_return: spec.module_return,
      field_candidates: spec.field_candidates,
      missing_variants: spec.missing_variants,
      reason: spec.reason,
      derivable: spec.derivable,
      forced_field:,
      forced_module:,
      target_import: derived.target_import,
      label: spec.label,
      target_bindings: derived.bindings,
      target_access: derived.target_access,
      renamed_to: derived.renamed_to,
      renamed_spans: derived.renamed_spans,
      inputs_hash:,
      evidence_hash: manifest.evidence_hash(
        compiler,
        forced_field,
        forced_module,
      ),
      compiler:,
      girard:,
      expect_girard_error_variant: spec.expect_girard_error_variant,
      divergent: False,
      why: spec.why,
    )
  Row(..draft, divergent: manifest.is_divergent(draft, girard))
}

fn outcome(
  staging: String,
  fixture: String,
  variant: String,
  function: String,
) -> Outcome {
  let stem = staging <> "/" <> fixture <> "/" <> variant
  let assert Ok(status) = simplifile.read(stem <> ".status")
  case string.trim(status) {
    "ok" -> {
      let assert Ok(interface) = simplifile.read(stem <> ".json")
      let assert Ok(outcome) = runner.compiler_ok(interface, function)
      outcome
    }
    _ -> {
      let assert Ok(output) = simplifile.read(stem <> ".err")
      runner.compiler_error(output)
    }
  }
}

// `aggregate` recomputes the two literals `test/differential_test` pins, from
// the committed manifest, so updating them is a mechanical step rather than a
// transcription.
fn aggregate() -> Nil {
  let assert Ok(text) = simplifile.read(manifest_path)
  let assert Ok(loaded) = manifest.decode(text)
  report(loaded.cases)
}

// `answer` prints girard's reading of one file, with the corpus resolver. It is
// how a divergence is diagnosed: run it on the forced-field companion, where
// no colliding module is in scope, and girard's answer says whether the field
// is in reach at all — an error there means the receiver's type never carried
// the variant, so the narrowing is lost upstream of the resolution.
//
// The return type comes first, because it is what the corpus compares; the
// resolution at every reference follows, so a divergence can be read directly
// rather than decoded from a type.
fn answer(path: String, function: String) -> Nil {
  let assert Ok(text) = simplifile.read(path)
  let #(outcome, references) = runner.girard_analysis(text, function)
  io.println(describe(outcome))
  list.each(references, fn(reference) {
    io.println(
      "  "
      <> int.to_string(reference.span.start)
      <> "-"
      <> int.to_string(reference.span.end)
      <> " "
      <> describe_resolution(reference.resolution),
    )
  })
}

fn describe_resolution(resolution: girard.Resolution) -> String {
  case resolution {
    girard.RecordField(record, label) ->
      girard.type_to_string(record) <> "." <> label
    girard.ModuleFn(module, name) -> module <> "." <> name <> "()"
    girard.ModuleConstant(module, name) -> module <> "." <> name
    girard.Constructor(module, name) -> module <> "." <> name <> "{}"
    girard.LocalVariable(name) -> "local " <> name
    girard.Unresolved(_) -> "unresolved"
  }
}

fn report(rows: List(Row)) -> Nil {
  let digests =
    list.map(rows, fn(row) {
      #(
        row.fixture,
        manifest.evidence_digest(
          row.compiler,
          row.forced_field,
          row.forced_module,
        ),
      )
    })
  let divergences = list.filter(rows, fn(row) { row.divergent })
  io.println("cases: " <> int.to_string(list.length(rows)))
  io.println("divergences: " <> int.to_string(list.length(divergences)))
  io.println("aggregate: " <> manifest.evidence_aggregate(digests))
  list.each(divergences, fn(row) {
    io.println(
      "  "
      <> row.fixture
      <> " compiler="
      <> describe(row.compiler)
      <> " girard="
      <> describe(row.girard),
    )
  })
}

fn describe(outcome: Outcome) -> String {
  case outcome.status {
    "ok" -> option.unwrap(outcome.return, "?")
    _ ->
      "error("
      <> option.unwrap(
        outcome.error_variant,
        option.unwrap(outcome.diagnostic, "?"),
      )
      <> ")"
  }
}
