//// The girard half of the resolution differential suite: it re-derives girard's
//// answer for every case under `differential/` and asserts it still matches
//// `differential/expected.json`, which the compiler half
//// (`scripts/gen-differential.sh`) wrote with a pinned gleam 1.18.0.
////
//// **The suite is green and the divergences are data.** The manifest records
//// each disagreement as *expected*, with the mechanism and the change that must
//// remove it in `why`; that change has to edit the manifest to land, and the
//// flip is a reviewable diff. What stops the ratchet being walked around is that nothing
//// here trusts a stored value it could have recomputed: `divergent` is derived
//// from the committed compiler column and a live girard run, both digests are
//// recomputed from the tree and the outcome objects, and the aggregate and the
//// divergence count are pinned as literals *in this file* — so the manifest and
//// the test have to change together, in one diff.
////
//// All seven read the manifest through `manifest.decode`, which is where the
//// enumerated fields are checked against their vocabularies — a typo in `kind`
//// or `reason` is invisible to every assertion below, so the rejection itself
//// is tested first.
////
//// The seven assertions:
////
//// 1. `expect` is what the compiler actually says.
//// 2. The discriminator is intact, at the right level.
//// 3. Each reading is reachable exactly when the row says it is.
//// 4. girard still answers as expected.
//// 5. The recorded compiler evidence still belongs to the source in the tree.
//// 6. Divergence is recomputed per row, then counted.
//// 7. The recomputed count equals the literal below.

import girard/differential
import girard/differential/manifest.{
  type Manifest, type Outcome, type Row, type Span, Span,
}
import girard/differential/runner
import girard/differential/source
import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glexer/token
import simplifile

// The ratchet
//
// A change that removes a divergence lowers the count; nothing else may touch
// it. Nobody can quietly widen it, and nobody can edit a committed compiler
// result without moving the aggregate.

/// How many rows the compiler and girard currently disagree on. Recomputed from
/// the committed compiler column and a live girard run, never counted off the
/// stored flags.
const expected_divergences = 1

/// The digest over every row's recomputed evidence digest, keyed by fixture
/// name. Pinned here rather than only in the manifest, because a hash stored
/// beside the data it protects is edited in the same keystroke.
const evidence_aggregate = "794606dbb917ca21c952cb52dde11c0686d03c8030ad8d29e70bd661e5eda4a3"

// The vocabularies are closed
//
// Nothing below can catch a misspelled enumerated value: every non-`probe` kind
// reads as a resolution row, and a misspelled `reason` is just a divergence
// with a different story, so `"resoluton"` and `"partal"` would both show
// green. The decoder rejects them instead, and this is the test that it does.

pub fn manifest_vocabularies_are_closed_test() {
  use #(field, from, to) <- list.each([
    #("kind", "\"kind\": \"resolution\"", "\"kind\": \"resoluton\""),
    #("access", "\"access\": \"projection\"", "\"access\": \"projecton\""),
    #("syntax_site", "\"syntax_site\": \"bare\"", "\"syntax_site\": \"bear\""),
    #("expect", "\"expect\": \"module\"", "\"expect\": \"modul\""),
    #(
      "expect on a resolution row",
      "\"expect\": \"module\"",
      "\"expect\": \"ok\"",
    ),
    #(
      "field_availability",
      "\"field_availability\": \"variant\"",
      "\"field_availability\": \"varient\"",
    ),
    #(
      "module_availability",
      "\"module_availability\": \"available\"",
      "\"module_availability\": \"availible\"",
    ),
    #("reason", "\"reason\": \"partial\"", "\"reason\": \"partal\""),
  ])
  let text = manifest_text()
  let mutated = string.replace(text, from, to)
  case mutated == text {
    False -> Nil
    True ->
      panic as {
        "the manifest no longer spells `"
        <> from
        <> "`, so this case tests nothing"
      }
  }
  case manifest.decode(mutated) {
    Error(_) -> Nil
    Ok(_) ->
      panic as {
        "the decoder accepted `"
        <> to
        <> "`: the "
        <> field
        <> " vocabulary is open"
      }
  }
}

// A probe's `expect` is an acceptance, not a branch: `kind` selects which
// vocabulary it is read against, so `"ok"` is legal on a probe and rejected on a
// resolution row (the case above). The corpus holds only error probes today, so
// nothing else exercises the legal `"ok"` spelling — without this, closing the
// vocabulary would have quietly outlawed the first successful probe anyone adds.

pub fn probe_may_expect_ok_test() {
  let text = manifest_text()
  let mutated =
    string.replace(text, "\"expect\": \"error\"", "\"expect\": \"ok\"")
  case mutated == text {
    False -> Nil
    True -> panic as "no probe expects an error, so this case tests nothing"
  }
  case manifest.decode(mutated) {
    Ok(_) -> Nil
    Error(_) ->
      panic as "the decoder rejected `\"expect\": \"ok\"` on a probe, which the schema allows"
  }
}

// Assertion 1
//
// `expect` is what the compiler actually says. Without it a fixture that is
// over-constrained, or whose `case` arms pin the branch type, can make both
// sides agree on the wrong branch and show green.

pub fn compiler_answers_expect_test() {
  use row <- each_row()
  case row.kind == manifest.kind_probe {
    True ->
      case row.compiler.status == row.expect {
        True -> Nil
        False ->
          fail(
            row,
            "expects "
              <> row.expect
              <> " but the compiler "
              <> row.compiler.status
              <> "ed",
          )
      }
    False ->
      case row.compiler.return {
        None ->
          fail(
            row,
            "is a resolution row but the compiler reported no type: "
              <> describe(row.compiler),
          )
        Some(answer) -> {
          let branch = manifest.decode_branch(row, answer)
          case branch == row.expect, branch == manifest.branch_unknown {
            True, _ -> Nil
            _, True ->
              fail(
                row,
                "broken fixture: the compiler answered `"
                  <> answer
                  <> "`, which is neither the module's reading nor any candidate field's",
              )
            _, _ ->
              fail(
                row,
                "expects the "
                  <> row.expect
                  <> " but the compiler read the "
                  <> branch
                  <> " (`"
                  <> answer
                  <> "`)",
              )
          }
        }
      }
  }
}

// Assertion 4
//
// girard still answers as expected. Every row compares `status`; an error probe
// also compares girard's constructor tag, never the rendered diagnostic, which
// is girard's own vocabulary and will never match the compiler's.
//
// Which tag it is compared against is what `divergent` means. A row girard
// answers the way the compiler does is held to the *hand-authored* expectation,
// never the machine-written one — that is the assertion. A row it does not is
// held to the machine-written record of what it does instead, because a
// divergent row's hand-authored tag is by definition not what girard reaches
// yet; the drift stays pinned live, and the change named in `why` hands the row
// back to its hand-authored tag.

pub fn girard_answers_as_expected_test() {
  use row <- each_row()
  let live = live_girard(row)
  case live.status == row.girard.status {
    True -> Nil
    False ->
      fail(
        row,
        "girard now "
          <> live.status
          <> "s where the manifest records "
          <> row.girard.status
          <> ": "
          <> describe(live),
      )
  }
  case row.kind == manifest.kind_probe && row.expect == manifest.expect_error {
    False -> Nil
    True -> {
      let #(expected, source) = case row.divergent {
        False -> #(row.expect_girard_error_variant, "the row expects")
        True -> #(row.girard.error_variant, "the manifest records")
      }
      case live.error_variant == expected {
        True -> Nil
        False ->
          fail(
            row,
            "girard reached "
              <> option.unwrap(live.error_variant, "no error")
              <> " where "
              <> source
              <> " "
              <> option.unwrap(expected, "none"),
          )
      }
    }
  }
}

// Assertion 6 and 7
//
// Divergence is recomputed per row from the committed compiler result and the
// girard result just produced, then counted. Counting stored flags alone is a
// ratchet that can be walked around: a flag left stale after a behaviour change
// passes, and so does trading a fixed row for a newly broken one.

// Both halves run off one girard pass over the corpus: the per-row recomputation
// and the total are the same derivation read at two scopes, so running girard
// twice for them could only ever produce the same answer more slowly.
pub fn divergence_is_recomputed_and_counted_test() {
  let divergences =
    load().cases
    |> list.filter(fn(row) {
      let divergent = manifest.is_divergent(row, live_girard(row))
      case divergent == row.divergent {
        True -> Nil
        False ->
          fail(
            row,
            "is recorded divergent="
              <> bool_text(row.divergent)
              <> " but recomputes to "
              <> bool_text(divergent),
          )
      }
      divergent
    })
    |> list.length
  case divergences == expected_divergences {
    True -> Nil
    False ->
      panic as {
        "the corpus now has "
        <> int.to_string(divergences)
        <> " divergences, not "
        <> int.to_string(expected_divergences)
        <> ". The change that removes a divergence lowers this literal; nothing else may raise it"
      }
  }
}

// Assertion 2
//
// The discriminator is intact, at the right level. Availability, members and
// returns are resolution-row metadata: a probe records none of them, because it
// contests no branch and observes no type. The AST and source checks that
// follow — the `target_access` validation, the companion checks, the rename
// conditions — apply to every row, probe included.

pub fn discriminator_is_intact_test() {
  use row <- each_row()
  let fixture = read(row)
  check_field_presence(row)
  case row.kind == manifest.kind_probe {
    True -> Nil
    False -> {
      check_field_side(fixture)
      check_module_side(fixture)
      check_returns_distinct(row)
    }
  }
  check_target_access(fixture)
  check_companions_match(fixture)
}

// The shape of the row itself: every field that is conditional is present
// exactly where its condition holds. A decoder must not have to infer whether a
// field is conditionally absent or nullable — it is nullable, always.
fn check_field_presence(row: Row) -> Nil {
  let resolution = row.kind != manifest.kind_probe
  require(
    row,
    "resolution metadata",
    option.is_some(row.field_availability) == resolution,
  )
  require(
    row,
    "module availability",
    option.is_some(row.module_availability) == resolution,
  )
  require(row, "derivable", option.is_some(row.derivable) == resolution)
  require(
    row,
    "narrowed_to only where the receiver is narrowed to a variant",
    option.is_some(row.narrowed_to)
      == { row.field_availability == Some(manifest.variant) },
  )
  let unavailable = row.field_availability == Some(manifest.unavailable)
  require(
    row,
    "field_candidates",
    option.is_some(row.field_candidates) == unavailable,
  )
  require(
    row,
    "missing_variants",
    option.is_some(row.missing_variants) == unavailable,
  )
  require(row, "reason", option.is_some(row.reason) == unavailable)
  require(
    row,
    "expect_girard_error_variant only on an error probe",
    option.is_some(row.expect_girard_error_variant)
      == {
      row.kind == manifest.kind_probe && row.expect == manifest.expect_error
    },
  )
  require(
    row,
    "renamed_to exactly where the forced-module companion exists",
    option.is_some(row.renamed_to) == option.is_some(row.forced_module),
  )
  require(
    row,
    "renamed_spans empty where there is no forced-module companion",
    option.is_some(row.renamed_to) || row.renamed_spans == [],
  )
  check_outcome(row, "compiler", row.compiler, True)
  check_outcome(row, "girard", row.girard, False)
  case row.forced_field {
    Some(outcome) -> check_outcome(row, "forced_field", outcome, True)
    None -> Nil
  }
  case row.forced_module {
    Some(outcome) -> check_outcome(row, "forced_module", outcome, True)
    None -> Nil
  }
}

// Three keys are side-specific and always null on one side: `diagnostic` and
// `at` on girard, whose text is advisory and whose `Error` carries no spans;
// and `error_variant` on every compiler-side outcome, which has no such thing.
fn check_outcome(
  row: Row,
  name: String,
  outcome: Outcome,
  compiler_side: Bool,
) -> Nil {
  let ok = outcome.status == manifest.status_ok
  require(row, name <> ".status", ok || outcome.status == manifest.status_error)
  require(
    row,
    name <> ".return non-null exactly when ok",
    option.is_some(outcome.return) == ok,
  )
  case compiler_side {
    True -> {
      require(
        row,
        name <> ".diagnostic on error",
        option.is_some(outcome.diagnostic) == !ok,
      )
      require(row, name <> ".at on error", option.is_some(outcome.at) == !ok)
      require(
        row,
        name <> ".error_variant is a girard-only field",
        option.is_none(outcome.error_variant),
      )
    }
    False -> {
      require(
        row,
        name <> ".diagnostic is never compared and never recorded",
        option.is_none(outcome.diagnostic),
      )
      require(
        row,
        name <> ".at: girard's Error carries no spans",
        option.is_none(outcome.at),
      )
      require(
        row,
        name <> ".error_variant on error",
        option.is_some(outcome.error_variant) == !ok,
      )
    }
  }
}

// Each side is checked according to its recorded availability, against what the
// fixture and the shadow module actually declare.
fn check_field_side(fixture: Fixture) -> Nil {
  let row = fixture.row
  let declared = declaring_type(fixture)
  case option.unwrap(row.field_availability, "") {
    "shared" -> {
      let type_ = require_type(fixture, declared)
      let members =
        list.map(type_.variants, fn(variant) {
          source.variant_field(variant, row.label)
        })
      case option.all(members) {
        None ->
          fail(
            row,
            "is recorded `shared` but some variant does not declare `"
              <> row.label
              <> "`",
          )
        Some(found) -> {
          let indices = list.unique(list.map(found, fn(pair) { pair.0 }))
          let rendered =
            list.unique(
              list.map(found, fn(pair) { source.render_type(pair.1) }),
            )
          require(
            row,
            "a shared accessor needs one position",
            list.length(indices) == 1,
          )
          require(
            row,
            "a shared accessor needs one type",
            list.length(rendered) == 1,
          )
          check_member(
            fixture,
            row.field_member,
            row.field_return,
            list.first(list.map(found, fn(pair) { pair.1 })),
          )
        }
      }
    }
    "variant" -> {
      let type_ = require_type(fixture, declared)
      let name = option.unwrap(row.narrowed_to, "")
      case list.find(type_.variants, fn(variant) { variant.name == name }) {
        Error(_) ->
          fail(
            row,
            "narrows to `"
              <> name
              <> "`, which "
              <> type_.name
              <> " does not declare",
          )
        Ok(variant) ->
          case source.variant_field(variant, row.label) {
            None ->
              fail(
                row,
                "narrows to `"
                  <> name
                  <> "`, which declares no `"
                  <> row.label
                  <> "`",
              )
            Some(#(_, member)) ->
              check_member(
                fixture,
                row.field_member,
                row.field_return,
                Ok(member),
              )
          }
      }
    }
    "unavailable" -> {
      let type_ = require_type(fixture, declared)
      check_candidates(fixture, type_)
      require(
        row,
        "an unavailable field has no single member",
        option.is_none(row.field_member),
      )
      require(
        row,
        "an unavailable field has no single return",
        option.is_none(row.field_return),
      )
    }
    "undeclared" -> {
      let declares = case declared {
        None -> False
        Some(type_) ->
          list.any(type_.variants, fn(variant) {
            option.is_some(source.variant_field(variant, row.label))
          })
      }
      require(
        row,
        "`" <> row.label <> "` is recorded undeclared but a variant declares it",
        !declares,
      )
      require(
        row,
        "an undeclared field has no member",
        option.is_none(row.field_member),
      )
      require(
        row,
        "an undeclared field has no return",
        option.is_none(row.field_return),
      )
    }
    "unknown_receiver" -> {
      require(
        row,
        "an unknown receiver has no member",
        option.is_none(row.field_member),
      )
      require(
        row,
        "an unknown receiver has no return",
        option.is_none(row.field_return),
      )
      require(
        row,
        "an unknown receiver has no candidates",
        option.is_none(row.field_candidates),
      )
      check_unknown_receiver(fixture)
    }
    other ->
      fail(row, "records the unknown field availability `" <> other <> "`")
  }
}

// `unavailable` records *why* no accessor exists, and the candidates carry the
// observable result an answer taking each declaration would have — which is the
// only way an over-permissive accessor can be decoded as the field at all.
fn check_candidates(fixture: Fixture, type_: glance.CustomType) -> Nil {
  let row = fixture.row
  let candidates = option.unwrap(row.field_candidates, [])
  let missing = option.unwrap(row.missing_variants, [])
  let names = list.map(type_.variants, fn(variant) { variant.name })
  let partition =
    list.sort(
      list.append(list.map(candidates, fn(c) { c.variant }), missing),
      string.compare,
    )
  require(
    row,
    "candidates and missing variants must partition the type's variants",
    partition == list.sort(names, string.compare),
  )

  list.each(candidates, fn(candidate) {
    case
      list.find(type_.variants, fn(variant) {
        variant.name == candidate.variant
      })
    {
      Error(_) ->
        fail(
          row,
          "names candidate variant `"
            <> candidate.variant
            <> "`, which does not exist",
        )
      Ok(variant) ->
        case source.variant_field(variant, row.label) {
          None ->
            fail(
              row,
              "names candidate `"
                <> candidate.variant
                <> "`, which declares no `"
                <> row.label
                <> "`",
            )
          Some(#(index, member)) -> {
            require(
              row,
              "candidate " <> candidate.variant <> " position",
              index == candidate.index,
            )
            require(
              row,
              "candidate " <> candidate.variant <> " member",
              source.render_type(member) == candidate.member,
            )
            case source.observed_return(member, row.access) {
              Ok(observed) ->
                require(
                  row,
                  "candidate " <> candidate.variant <> " return",
                  observed == candidate.return,
                )
              Error(_) ->
                fail(
                  row,
                  "candidate "
                    <> candidate.variant
                    <> " is not a function, but the access is a call",
                )
            }
          }
        }
    }
  })
  list.each(missing, fn(name) {
    case list.find(type_.variants, fn(variant) { variant.name == name }) {
      Error(_) ->
        fail(
          row,
          "names missing variant `" <> name <> "`, which does not exist",
        )
      Ok(variant) ->
        require(
          row,
          "missing variant " <> name <> " must not declare the label",
          option.is_none(source.variant_field(variant, row.label)),
        )
    }
  })

  let indices = list.unique(list.map(candidates, fn(c) { c.index }))
  let members = list.unique(list.map(candidates, fn(c) { c.member }))
  case option.unwrap(row.reason, "") {
    "partial" ->
      require(
        row,
        "`partial` means some variant does not declare the label",
        missing != [],
      )
    "index" ->
      require(
        row,
        "`index` means every variant declares it, at differing positions",
        missing == [] && list.length(indices) > 1 && list.length(members) == 1,
      )
    "type" ->
      require(
        row,
        "`type` means every variant declares it at one position, at differing types",
        missing == [] && list.length(indices) == 1 && list.length(members) > 1,
      )
    other -> fail(row, "records the unknown reason `" <> other <> "`")
  }

  // Where the module's answer coincides with a candidate's, the row cannot
  // discriminate at all: it is a broken fixture, not a silent decode to
  // whichever branch is checked first.
  case row.module_return {
    None -> Nil
    Some(module_return) ->
      require(
        row,
        "the module's return must differ from every candidate's",
        !list.any(candidates, fn(c) { c.return == module_return }),
      )
  }
}

fn check_module_side(fixture: Fixture) -> Nil {
  let row = fixture.row
  case option.unwrap(row.module_availability, "") {
    "available" -> {
      let assert Some(target) = row.target_import
      let assert Ok(text) = runner.resolver()(target.module)
      let assert Ok(module) = source.parse(text)
      case source.module_member(module, row.label) {
        Error(_) ->
          fail(
            row,
            "reads `"
              <> row.label
              <> "` from "
              <> target.module
              <> ", which exports no such value",
          )
        Ok(member) ->
          check_member(
            fixture,
            row.module_member,
            row.module_return,
            Ok(member),
          )
      }
    }
    "undeclared" -> {
      require(
        row,
        "an undeclared module side has no member",
        option.is_none(row.module_member),
      )
      require(
        row,
        "an undeclared module side has no return",
        option.is_none(row.module_return),
      )
      case row.target_import {
        None -> Nil
        Some(target) -> {
          let assert Ok(text) = runner.resolver()(target.module)
          let assert Ok(module) = source.parse(text)
          require(
            row,
            target.module <> " must export nothing named `" <> row.label <> "`",
            source.module_member(module, row.label) == Error(Nil),
          )
        }
      }
    }
    other ->
      fail(row, "records the unknown module availability `" <> other <> "`")
  }
}

// The member is cross-checked against the declaration; the return is checked to
// be the member itself for a projection, or the member's return for a call.
// A `derivable: false` row stops at the member: its specialized return cannot be
// read off a generic declaration without performing unification here, which
// would mean reimplementing the thing under test.
fn check_member(
  fixture: Fixture,
  recorded: Option(String),
  recorded_return: Option(String),
  declared_type: Result(glance.Type, Nil),
) -> Nil {
  let row = fixture.row
  let assert Ok(declared_type) = declared_type
  let declared = source.render_type(declared_type)
  case recorded {
    Some(member) ->
      require(
        row,
        "records the member `"
          <> member
          <> "` where the source declares `"
          <> declared
          <> "`",
        member == declared,
      )
    None -> fail(row, "records no member for a branch it says is available")
  }
  case row.derivable {
    Some(False) -> Nil
    _ ->
      case source.observed_return(declared_type, row.access) {
        Error(_) ->
          fail(
            row,
            "records `"
              <> declared
              <> "` as a member under a call access, but it is not a function",
          )
        Ok(observed) ->
          require(
            row,
            "records the return `"
              <> option.unwrap(recorded_return, "null")
              <> "` where `"
              <> declared
              <> "` observes as `"
              <> observed
              <> "`",
            recorded_return == Some(observed),
          )
      }
  }
}

// Where both sides are present the two returns must differ, or the fixture
// cannot tell them apart. Members may coincide.
fn check_returns_distinct(row: Row) -> Nil {
  case row.field_return, row.module_return {
    Some(field), Some(module) ->
      require(
        row,
        "the two branches observe the same type, so the fixture discriminates nothing",
        field != module,
      )
    _, _ -> Nil
  }
}

// `target_access` is the access the row claims. Every other check leans on that
// span — assertion 3 blesses a compiler error by containment in it, and the
// rename preserves exactly the occurrence it names — so a span left behind by an
// edit, or nudged by a few bytes, must not silently bless an error about
// something else.
fn check_target_access(fixture: Fixture) -> Nil {
  let row = fixture.row
  let access = fixture.access
  require(
    row,
    "the access at target_access must be labelled `" <> row.label <> "`",
    access.label == row.label,
  )
  require(
    row,
    "every recorded binding must name the receiver",
    list.all(row.target_bindings, fn(binding) {
      binding.name == fixture.receiver
    }),
  )
  require(
    row,
    "records syntax_site `"
      <> row.syntax_site
      <> "` where the node is a "
      <> access.site,
    access.site == row.syntax_site,
  )
  // A fixture contests one access. Without this, a second projection of the same
  // name would be silently rewritten by the forced-module companion, turning a
  // module access into a variable access while every byte check still passed.
  let same_receiver =
    list.filter(source.accesses(fixture.module), fn(other) {
      other.receiver == fixture.receiver
    })
  require(
    row,
    "exactly one field access may have the receiver as its container",
    list.length(same_receiver) == 1,
  )
  // `access` drives the derivations; `syntax_site` drives the node shape. They
  // are two different questions, and a pipe target is a call whose node is not
  // a `Call` at all.
  let consistent = case row.access, row.syntax_site {
    "call", "call" | "call", "pipe" | "projection", "bare" -> True
    _, _ -> False
  }
  require(
    row,
    "access `"
      <> row.access
      <> "` cannot sit at syntax site `"
      <> row.syntax_site
      <> "`",
    consistent,
  )
}

// An occurrence of the receiver's name that is neither a container nor a
// binding nor a bare reference is not something the rename may touch. Token
// adjacency decides it: a name after a dot is a label, a name after `fn` is a
// function's, and a name before a colon is a labelled argument unless it is one
// of the declarations the row already records.
fn check_occurrence_roles(fixture: Fixture) -> Nil {
  let row = fixture.row
  let imports = source.import_spans(fixture.module)
  let tokens = source.tokens(fixture.text)
  let declarations = list.map(row.target_bindings, fn(binding) { binding.span })
  list.each(neighbourhoods(tokens, fixture.receiver), fn(entry) {
    let #(span, before, after) = entry
    let inside = source.in_imports(imports, glance.Span(span.start, span.end))
    let is_container = span.start == fixture.access.container.start
    case inside || is_container {
      True -> Nil
      False -> {
        require(
          row,
          "an occurrence of `"
            <> fixture.receiver
            <> "` sits after a `.`, so it is a label rather than a variable",
          before != Some(token.Dot),
        )
        require(
          row,
          "an occurrence of `" <> fixture.receiver <> "` names a function",
          before != Some(token.Fn),
        )
        let labelled =
          after == Some(token.Colon) && !list.contains(declarations, span)
        require(
          row,
          "an occurrence of `"
            <> fixture.receiver
            <> "` is an argument label rather than a binding",
          !labelled,
        )
      }
    }
  })
}

// Each identifier-token occurrence of `name`, with the tokens either side.
fn neighbourhoods(
  tokens: List(#(token.Token, Int)),
  name: String,
) -> List(#(Span, Option(token.Token), Option(token.Token))) {
  let width = string.byte_size(name)
  scan_neighbourhoods(tokens, None, name, width)
}

fn scan_neighbourhoods(
  tokens: List(#(token.Token, Int)),
  previous: Option(token.Token),
  name: String,
  width: Int,
) -> List(#(Span, Option(token.Token), Option(token.Token))) {
  case tokens {
    [] -> []
    [#(tok, offset), ..rest] -> {
      let following = case rest {
        [#(next, _), ..] -> Some(next)
        [] -> None
      }
      let here = case tok {
        token.Name(found) if found == name -> [
          #(Span(offset, offset + width), previous, following),
        ]
        _ -> []
      }
      list.append(here, scan_neighbourhoods(rest, Some(tok), name, width))
    }
  }
}

// The receiver's shape is mechanically restricted, not merely unannotated:
// every occurrence, after subtracting the import token and the declarations, is
// either the container under test or a `let _ = name` discard.
fn check_unknown_receiver(fixture: Fixture) -> Nil {
  let row = fixture.row
  require(
    row,
    "an unknown receiver must carry no type annotation",
    source.unannotated(fixture.module, fixture.receiver),
  )
  let imports = source.import_spans(fixture.module)
  let declarations = list.map(row.target_bindings, fn(binding) { binding.span })
  let discards =
    source.discard_reads(fixture.module, fixture.receiver)
    |> list.map(fn(span) { Span(span.start, span.end) })
  source.name_spans(fixture.text, fixture.receiver)
  |> list.map(fn(span) { Span(span.start, span.end) })
  |> list.filter(fn(span) {
    !list.contains(declarations, span)
    && !source.in_imports(imports, glance.Span(span.start, span.end))
  })
  |> list.each(fn(span) {
    let permitted =
      span.start == fixture.access.container.start
      || list.contains(discards, span)
    require(
      row,
      "an unknown receiver may only occur as its declaration, the contested container, or a `let _ =` discard, but one occurs at "
        <> int.to_string(span.start),
      permitted,
    )
  })
}

// Each companion is what it claims, by mechanical rewrite of the base's bytes.
// A companion that has drifted into a different program is caught here rather
// than quietly answering for the base.
//
// Where a companion is absent, the row is checked to *deserve* its absence —
// and what justifies absence depends on `kind`. Source metadata and companion
// existence are independent: every row, probe included, records its real
// import, bindings and access, and every row's metadata is validated the same
// way; only companion *existence* is decided by `kind`.
fn check_companions_match(fixture: Fixture) -> Nil {
  let row = fixture.row
  let probe = row.kind == manifest.kind_probe
  check_occurrence_roles(fixture)

  case row.forced_field {
    Some(_) -> {
      require(
        row,
        "a probe contests no branch, so it may have no companions",
        !probe,
      )
      require(
        row,
        "a forced-field companion needs a colliding module to remove",
        option.is_some(row.target_import),
      )
      let assert Some(target) = row.target_import
      case source.remove_import(fixture.module, fixture.text, target.module) {
        Error(_) ->
          fail(
            row,
            "records an import of "
              <> target.module
              <> " the source does not have",
          )
        Ok(#(expected, _, _)) ->
          require(
            row,
            "the forced-field companion is not the base with the `"
              <> target.module
              <> "` import removed",
            read_file(differential.forced_field_path(row.fixture)) == expected,
          )
      }
    }
    None ->
      require(
        row,
        "has no forced-field companion but a colliding module is in scope",
        probe || option.is_none(row.target_import),
      )
  }

  case row.forced_module {
    Some(_) -> {
      require(
        row,
        "a probe contests no branch, so it may have no companions",
        !probe,
      )
      require(
        row,
        "a forced-module companion needs a local binding to rename",
        row.target_bindings != [],
      )
      check_rename(fixture)
    }
    None ->
      require(
        row,
        "has no forced-module companion but a local binding shadows the module name",
        probe || row.target_bindings == [],
      )
  }
}

// Six conditions make the rewrite deterministic, non-vacuous, and actually a
// renaming rather than an arbitrary patch.
fn check_rename(fixture: Fixture) -> Nil {
  let row = fixture.row
  let assert Some(replacement) = row.renamed_to

  // Fresh, so the rename cannot create a collision of its own.
  require(
    row,
    "`" <> replacement <> "` already occurs in the fixture",
    !list.contains(source.identifiers(fixture.text), replacement),
  )
  require(
    row,
    "`" <> replacement <> "` is a module in scope",
    !list.any(source.imported_modules(fixture.module), fn(path) {
      string.ends_with(path, "/" <> replacement)
    }),
  )

  // Pairwise non-overlapping, and disjoint from the whole of the contested
  // access — not merely unequal to it, since a span covering the container alone
  // would rename the one occurrence the row exists to leave untouched.
  let spans =
    list.sort(row.renamed_spans, fn(a, b) { int.compare(a.start, b.start) })
  require(row, "renamed spans overlap", non_overlapping(spans))
  list.each(spans, fn(span) {
    require(
      row,
      "a renamed span overlaps the contested access",
      span.end <= row.target_access.start || span.start >= row.target_access.end,
    )
  })

  // Equal, as a set, to the spans the test derives itself: every occurrence of
  // the receiver's name minus the container and minus the imports. Equality in
  // both directions, so the manifest can neither omit an occurrence nor add one.
  let derived =
    source.rename_spans(
      fixture.module,
      fixture.text,
      fixture.receiver,
      fixture.access.container,
    )
    |> list.map(fn(span) { Span(span.start, span.end) })
    |> list.sort(fn(a, b) { int.compare(a.start, b.start) })
  require(
    row,
    "renamed_spans is not the set of occurrences the source actually holds",
    spans == derived,
  )

  // Every declaration must move. On a module-expected row the base already
  // resolves to the module, so a companion that leaves the declaration behind is
  // equivalent to the base: it compiles, reports the expected result, and has
  // forced nothing.
  list.each(row.target_bindings, fn(binding) {
    require(
      row,
      "the declaration at "
        <> int.to_string(binding.span.start)
        <> " is not renamed, so the companion forces nothing",
      list.contains(spans, binding.span),
    )
  })

  // The rewrite itself, byte for byte.
  let companion = read_file(differential.forced_module_path(row.fixture))
  let expected =
    source.apply_rename(
      fixture.text,
      list.map(spans, fn(span) { glance.Span(span.start, span.end) }),
      replacement,
    )
  require(
    row,
    "the forced-module companion is not the base with exactly those spans renamed",
    companion == expected,
  )

  // Completeness is read off the companion rather than argued: the surviving
  // occurrences are the contested access, plus the import declaration where the
  // row has one. A missed reference makes it one too many — and would not fail
  // the compile, since an in-scope receiver the compiler cannot use falls
  // through to the module export rather than erroring.
  let survivors = source.name_spans(companion, fixture.receiver)
  let expected_survivors = case row.target_import {
    Some(_) -> 2
    None -> 1
  }
  require(
    row,
    "the companion holds "
      <> int.to_string(list.length(survivors))
      <> " occurrences of `"
      <> fixture.receiver
      <> "`, not "
      <> int.to_string(expected_survivors),
    list.length(survivors) == expected_survivors,
  )
}

fn non_overlapping(spans: List(Span)) -> Bool {
  case spans {
    [a, b, ..rest] ->
      case a.end <= b.start {
        True -> non_overlapping([b, ..rest])
        False -> False
      }
    _ -> True
  }
}

// Assertion 3
//
// Each reading is reachable exactly when the row says it is — the
// counterfactual check. A fixture has to type-check under either resolution;
// nothing else confirms the branch the compiler did *not* take was even
// possible. A fixture whose other `case` arms constrain the result
// silently measures unification instead of resolution, and shows up green.
//
// What a companion must do is set by that side's availability, not fixed at
// "must compile". The corpus deliberately contains branches that do not exist,
// and forcing an absent branch must fail. That half is the stronger check: it
// proves the availability metadata empirically instead of trusting assertion
// 2's reading of the declarations.

pub fn each_reading_is_reachable_test() {
  use row <- each_row()
  let fixture = read(row)
  case row.kind == manifest.kind_probe {
    True -> {
      require(
        row,
        "a probe has no branch companions at all",
        option.is_none(row.forced_field),
      )
      require(
        row,
        "a probe has no branch companions at all",
        option.is_none(row.forced_module),
      )
    }
    False -> {
      check_forced(
        fixture,
        ForcedField,
        row.forced_field,
        must_compile(option.unwrap(row.field_availability, "")),
        row.field_return,
      )
      check_forced(
        fixture,
        ForcedModule,
        row.forced_module,
        option.unwrap(row.module_availability, "") == manifest.available,
        row.module_return,
      )
    }
  }
}

// A field branch is reachable only where the receiver actually grants it: a
// shared accessor, or narrowing to a variant that declares it. `unavailable`,
// `undeclared` and `unknown_receiver` all mean the forced compile must fail.
fn must_compile(availability: String) -> Bool {
  availability == manifest.shared || availability == manifest.variant
}

// Which companion is under check. A value rather than the display name, because
// the coordinate transform in `check_error_position` dispatches on it: keyed off
// the message text, rewording the message would silently switch a forced-field
// companion onto the forced-module transform, which still yields a plausible
// offset and so fails or passes for reasons unrelated to the fixture.
type Companion {
  ForcedField
  ForcedModule
}

fn companion_name(companion: Companion) -> String {
  case companion {
    ForcedField -> "forced-field"
    ForcedModule -> "forced-module"
  }
}

fn companion_source_path(companion: Companion, fixture: String) -> String {
  case companion {
    ForcedField -> differential.forced_field_path(fixture)
    ForcedModule -> differential.forced_module_path(fixture)
  }
}

fn check_forced(
  fixture: Fixture,
  companion: Companion,
  outcome: Option(Outcome),
  compiles: Bool,
  expected_return: Option(String),
) -> Nil {
  let row = fixture.row
  let name = companion_name(companion)
  case outcome {
    None -> Nil
    Some(outcome) ->
      case compiles {
        True -> {
          require(
            row,
            "the "
              <> name
              <> " companion must compile, but "
              <> describe(outcome),
            outcome.status == manifest.status_ok,
          )
          require(
            row,
            "the "
              <> name
              <> " companion returns "
              <> option.unwrap(outcome.return, "nothing")
              <> " where the row records "
              <> option.unwrap(expected_return, "nothing"),
            outcome.return == expected_return,
          )
        }
        False -> {
          require(
            row,
            "the "
              <> name
              <> " companion forces an absent branch and must fail, but it compiled to "
              <> option.unwrap(outcome.return, "?"),
            outcome.status == manifest.status_error,
          )
          check_error_position(fixture, companion, outcome)
        }
      }
  }
}

// "Did not compile" is far too easy to satisfy by accident: a missed reference
// leaves a name unbound, and deleting an import breaks any *other* use of that
// module in the file. Either passes a bare failure check while proving nothing
// about the branch under test. So the failure has to land inside the contested
// access, mapped into that companion's own coordinates — each companion by its
// own transform, because each edits the base differently.
//
// Inside, not equal to: the diagnostic may anchor on the receiver, the label or
// the whole access, so requiring equality would pin the check to a detail of the
// compiler's error rendering.
fn check_error_position(
  fixture: Fixture,
  companion: Companion,
  outcome: Outcome,
) -> Nil {
  let row = fixture.row
  let assert Some(at) = outcome.at
  let text = read_file(companion_source_path(companion, row.fixture))
  let offset = source.offset_of(text, at.line, at.column)
  let target = case companion {
    ForcedField -> {
      let assert Some(import_) = row.target_import
      let assert Ok(#(_, _, removed)) =
        source.remove_import(fixture.module, fixture.text, import_.module)
      Span(row.target_access.start - removed, row.target_access.end - removed)
    }
    ForcedModule -> {
      let assert Some(replacement) = row.renamed_to
      let delta =
        string.byte_size(replacement) - string.byte_size(fixture.receiver)
      Span(
        shift(row.target_access.start, row.renamed_spans, delta),
        shift(row.target_access.end, row.renamed_spans, delta),
      )
    }
  }
  require(
    row,
    "the "
      <> companion_name(companion)
      <> " companion failed at "
      <> int.to_string(at.line)
      <> ":"
      <> int.to_string(at.column)
      <> ", outside the contested access",
    offset >= target.start && offset < target.end,
  )
}

fn shift(position: Int, spans: List(Span), delta: Int) -> Int {
  position
  + delta
  * list.length(list.filter(spans, fn(span) { span.start < position }))
}

// Assertion 5
//
// The recorded compiler evidence still belongs to the source in the tree, and
// has not been edited since. CI re-runs only girard — the compiler columns and
// both companions are committed evidence, produced by a driver that needs the
// pinned toolchain and does not run here — so editing a fixture would otherwise
// invalidate that evidence while every other assertion kept passing.
//
// The verification order is load-bearing: recompute each row's evidence digest
// from its own outcome objects *first*, then aggregate over the recomputed
// values. Aggregating the stored strings would reproduce the same aggregate for
// an edited outcome with an adjusted row hash, which is precisely the edit this
// assertion exists to catch.

pub fn inputs_hash_covers_the_tree_test() {
  let gleam = load().gleam
  use row <- each_row()
  let files =
    differential.input_files(
      row.fixture,
      option.is_some(row.forced_field),
      option.is_some(row.forced_module),
    )
    |> list.map(fn(path) {
      let assert Ok(bytes) = simplifile.read_bits(path)
      #(path, bytes)
    })
  let recomputed =
    manifest.inputs_hash(
      gleam,
      companion_path(row.forced_field, ForcedField, row.fixture),
      companion_path(row.forced_module, ForcedModule, row.fixture),
      files,
    )
  case recomputed == row.inputs_hash {
    True -> Nil
    False ->
      fail(
        row,
        "was compiled from different bytes than the tree now holds — rerun `scripts/gen-differential.sh`",
      )
  }
}

pub fn evidence_hash_is_recomputed_test() {
  use row <- each_row()
  let recomputed =
    manifest.evidence_hash(row.compiler, row.forced_field, row.forced_module)
  case recomputed == row.evidence_hash {
    True -> Nil
    False ->
      fail(
        row,
        "records an evidence hash that does not match its own compiler results — rerun `scripts/gen-differential.sh`",
      )
  }
}

pub fn evidence_aggregate_is_pinned_test() {
  let digests =
    load().cases
    |> list.map(fn(row) {
      #(
        row.fixture,
        manifest.evidence_digest(
          row.compiler,
          row.forced_field,
          row.forced_module,
        ),
      )
    })
  let aggregate = manifest.evidence_aggregate(digests)
  case aggregate == evidence_aggregate {
    True -> Nil
    False ->
      panic as {
        "the committed compiler evidence aggregates to "
        <> aggregate
        <> ", not "
        <> evidence_aggregate
        <> ". The manifest and this literal must change together"
      }
  }
}

// girard's side of the one row that reaches real stdlib: the disk half of the
// composite resolver reads `build/packages`, which must match the version the
// row's compile was pinned to.

pub fn stdlib_pin_matches_test() {
  let assert Ok(lock) = simplifile.read("differential/pinned/manifest.toml")
  case
    string.contains(
      lock,
      "gleam_stdlib = { version = \"" <> differential.stdlib_version <> "\" }",
    )
  {
    True -> Nil
    False ->
      panic as {
        "differential/pinned/manifest.toml no longer pins gleam_stdlib "
        <> differential.stdlib_version
      }
  }
  let assert Ok(installed) =
    simplifile.read("build/packages/gleam_stdlib/gleam.toml")
  case
    string.contains(
      installed,
      "version = \"" <> differential.stdlib_version <> "\"",
    )
  {
    True -> Nil
    False ->
      panic as {
        "build/packages/gleam_stdlib is not "
        <> differential.stdlib_version
        <> ", which the `result_try` control is pinned to. girard would resolve a"
        <> " different stdlib than the compiler compiled against, and the skew"
        <> " would read as a resolution divergence"
      }
  }
}

fn companion_path(
  outcome: Option(Outcome),
  companion: Companion,
  fixture: String,
) -> Option(String) {
  option.map(outcome, fn(_) { companion_source_path(companion, fixture) })
}

// Reading a case
//
// The manifest, the fixture it names, and the access it claims — resolved once
// so every assertion works from the same reading of the tree.

/// A case, as the assertions see it: the committed row, the fixture's bytes and
/// parse, and the access at `target_access`.
type Fixture {
  Fixture(
    row: Row,
    text: String,
    module: glance.Module,
    access: source.Access,
    receiver: String,
  )
}

fn load() -> Manifest {
  case manifest.decode(manifest_text()) {
    Ok(loaded) -> loaded
    Error(_) ->
      panic as "differential/expected.json is not a well-formed manifest — every field must be present, with absence spelled `null`, and every enumerated field within its vocabulary"
  }
}

fn manifest_text() -> String {
  let assert Ok(text) = simplifile.read("differential/expected.json")
  text
}

fn each_row(continue: fn(Row) -> Nil) -> Nil {
  list.each(load().cases, continue)
}

fn read(row: Row) -> Fixture {
  let text = read_file(differential.base_path(row.fixture))
  let assert Ok(module) = source.parse(text)
  let access =
    source.accesses(module)
    |> list.find(fn(candidate) {
      candidate.span.start == row.target_access.start
      && candidate.span.end == row.target_access.end
    })
  case access {
    Error(_) ->
      fail(
        row,
        "records target_access "
          <> int.to_string(row.target_access.start)
          <> "-"
          <> int.to_string(row.target_access.end)
          <> ", where there is no field access on a variable",
      )
    Ok(access) ->
      Fixture(row:, text:, module:, access:, receiver: access.receiver)
  }
}

fn read_file(path: String) -> String {
  case simplifile.read(path) {
    Ok(text) -> text
    Error(_) -> panic as { "missing file: " <> path }
  }
}

fn live_girard(row: Row) -> Outcome {
  runner.girard_outcome(
    read_file(differential.base_path(row.fixture)),
    row.function,
  )
}

// The type whose variants a row's field metadata is checked against: the one
// the fixture declares, or — where the fixture declares none, as when the
// narrowed type crosses a module boundary — the one its support imports do.
fn declaring_type(fixture: Fixture) -> Option(glance.CustomType) {
  case source.custom_types(fixture.module) {
    [one] -> Some(one)
    [_, _, ..] ->
      fail(
        fixture.row,
        "declares more than one custom type, so which one the receiver has is ambiguous",
      )
    [] ->
      case
        source.imported_modules(fixture.module)
        |> list.filter(string.starts_with(_, "differential/"))
        |> list.flat_map(fn(path) {
          let assert Ok(text) = runner.resolver()(path)
          let assert Ok(module) = source.parse(text)
          source.custom_types(module)
        })
      {
        [one] -> Some(one)
        _ -> None
      }
  }
}

fn require_type(
  fixture: Fixture,
  declared: Option(glance.CustomType),
) -> glance.CustomType {
  case declared {
    Some(type_) -> type_
    None ->
      fail(
        fixture.row,
        "records a field branch but no custom type is in reach to declare it",
      )
  }
}

fn require(row: Row, message: String, condition: Bool) -> Nil {
  case condition {
    True -> Nil
    False -> fail(row, message)
  }
}

fn fail(row: Row, message: String) -> a {
  panic as { "differential/" <> row.fixture <> ": " <> message }
}

fn describe(outcome: Outcome) -> String {
  case outcome.status {
    "ok" -> "returned " <> option.unwrap(outcome.return, "?")
    _ ->
      "failed with "
      <> option.unwrap(
        outcome.error_variant,
        option.unwrap(outcome.diagnostic, "an error"),
      )
  }
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
