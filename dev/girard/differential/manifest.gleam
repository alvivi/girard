//// The differential manifest: its schema, its JSON encoding and decoding, and
//// the canonical serialization the two committed digests are taken over.
////
//// The manifest (`differential/expected.json`) holds, per case, the compiler's
//// answer and girard's, with the disagreements flagged. It is written by
//// `girard/differential` (the driver) and read by `test/differential_test`,
//// which re-derives girard's half and asserts it still matches.
////
//// Two rules the rest of the suite leans on:
////
//// - **Every field is always present; absence is JSON `null`, recursively.**
////   A missing key is a malformed manifest at any depth, so every decoder
////   below uses `decode.field` with an optional value rather than
////   `decode.optional_field`.
//// - **One implementation of the framing.** The driver shells out to this
////   module rather than reimplementing 64-bit big-endian framing in `printf`,
////   and the test calls it directly. A second implementation is a divergence
////   waiting to surface as a mystery hash mismatch.

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string

// Schema
//
// The row and its nested objects. The vocabularies (`kind`, `access`,
// `syntax_site`, `expect`, the availabilities and `reason`) are plain
// strings with the constants below; `row_decoder` rejects anything outside
// them, so no reader downstream has to.

/// A line/column position in a compiler diagnostic.
pub type At {
  At(line: Int, column: Int)
}

/// A byte range in a fixture's source.
pub type Span {
  Span(start: Int, end: Int)
}

/// One side's answer for one compile. Every outcome object — `compiler`,
/// `girard`, `forced_field`, `forced_module` — has the same five keys.
///
/// `return` is non-null exactly when `status` is `"ok"`. On an error,
/// *which* of the remaining fields carries the localisation depends on the
/// side: a compiler-side outcome carries `diagnostic` and `at`, a girard
/// outcome carries `error_variant`.
pub type Outcome {
  Outcome(
    status: String,
    return: Option(String),
    diagnostic: Option(String),
    at: Option(At),
    error_variant: Option(String),
  )
}

/// A declaration of the receiver's name, recorded for review and for the
/// non-vacuity check on `renamed_spans`. It does not define the rename.
pub type Binding {
  Binding(name: String, span: Span)
}

/// The import that puts a colliding module in scope, where there is one.
pub type TargetImport {
  TargetImport(module: String, alias: Option(String))
}

/// One variant declaring the contested label, where no accessor exists.
/// `return` is what an answer taking *this* declaration would be observed as,
/// which is how an `unavailable` row's field branch is decoded.
pub type Candidate {
  Candidate(variant: String, index: Int, member: String, return: String)
}

/// One case: what the fixture contests, what each side answered, and whether
/// they disagree.
pub type Row {
  Row(
    fixture: String,
    function: String,
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
    forced_field: Option(Outcome),
    forced_module: Option(Outcome),
    target_import: Option(TargetImport),
    label: String,
    target_bindings: List(Binding),
    target_access: Span,
    renamed_to: Option(String),
    renamed_spans: List(Span),
    inputs_hash: String,
    evidence_hash: String,
    compiler: Outcome,
    girard: Outcome,
    expect_girard_error_variant: Option(String),
    divergent: Bool,
    why: String,
  )
}

/// The whole manifest: the pinned compiler version, when it was generated, and
/// every case.
pub type Manifest {
  Manifest(gleam: String, generated: String, cases: List(Row))
}

// Vocabularies

pub const kind_resolution = "resolution"

pub const kind_probe = "probe"

pub const access_call = "call"

pub const access_projection = "projection"

pub const site_call = "call"

pub const site_pipe = "pipe"

pub const site_bare = "bare"

pub const expect_field = "field"

pub const expect_module = "module"

/// A probe contests no branch, so its `expect` is whether the program was
/// accepted, compared against the compiler's `status` directly. Spelled
/// separately from `status_ok` and `status_error` even though the two share
/// their spellings: `kind` selects which of the two vocabularies `expect` is
/// read against, and collapsing them would hide that.
pub const expect_ok = "ok"

pub const expect_error = "error"

pub const shared = "shared"

pub const variant = "variant"

pub const unavailable = "unavailable"

pub const undeclared = "undeclared"

pub const unknown_receiver = "unknown_receiver"

pub const available = "available"

pub const reason_partial = "partial"

pub const reason_index = "index"

pub const reason_type = "type"

pub const status_ok = "ok"

pub const status_error = "error"

/// The third decoded answer: an `ok` return matching neither the module's nor
/// any candidate's. Always a divergence, and a broken fixture far more often
/// than a discovery.
pub const branch_unknown = "unknown"

// Decoding a branch
//
// Which reading an answer represents, for this row. An answer matching
// `module_return` is the module; one matching `field_return` — or, where the
// field is `unavailable`, *any* `field_candidates[].return` — is the field.

/// Decode one `ok` answer into `"field"`, `"module"` or `"unknown"`.
pub fn decode_branch(row: Row, answer: String) -> String {
  let module_match = row.module_return == Some(answer)
  let field_match =
    row.field_return == Some(answer)
    || list.any(option.unwrap(row.field_candidates, []), fn(candidate) {
      candidate.return == answer
    })
  case module_match, field_match {
    True, False -> expect_module
    False, True -> expect_field
    _, _ -> branch_unknown
  }
}

/// Recompute `divergent` from the committed compiler outcome and a girard
/// outcome. A derived value, so the test derives it rather than trusting the
/// stored flag.
///
/// For a resolution row the two disagree when their statuses differ, when both
/// are `ok` and decode to different branches, or when either side decodes
/// `unknown`. For a probe they disagree when the statuses differ, or — where an
/// error is the intended answer — when girard's constructor tag is not the
/// hand-authored one.
pub fn is_divergent(row: Row, girard: Outcome) -> Bool {
  case row.kind == kind_probe {
    True ->
      row.compiler.status != girard.status
      || {
        row.expect == expect_error
        && girard.error_variant != row.expect_girard_error_variant
      }
    False ->
      case
        row.compiler.status == girard.status,
        row.compiler.return,
        girard.return
      {
        False, _, _ -> True
        True, Some(theirs), Some(ours) -> {
          let theirs = decode_branch(row, theirs)
          let ours = decode_branch(row, ours)
          theirs != ours || theirs == branch_unknown || ours == branch_unknown
        }
        // Both errored: no branch to decode, and the statuses agree.
        True, _, _ -> False
      }
  }
}

// Canonical serialization
//
// Every string is UTF-8 bytes; every length is an unsigned 64-bit big-endian
// integer; an entry is `len(key) ‖ key ‖ len(value) ‖ value`, and a nested
// object is the same rule applied recursively, its framed bytes becoming the
// outer value. A null is the explicit one-byte marker `\x00`, never an omitted
// entry — omission and emptiness must not collide. The digest is SHA-256.

const null_marker = <<0>>

fn u64(n: Int) -> BitArray {
  <<n:big-size(64)>>
}

fn entry(key: String, value: BitArray) -> BitArray {
  let key = bit_array.from_string(key)
  <<
    u64(bit_array.byte_size(key)):bits,
    key:bits,
    u64(bit_array.byte_size(value)):bits,
    value:bits,
  >>
}

fn text(value: Option(String)) -> BitArray {
  case value {
    Some(value) -> bit_array.from_string(value)
    None -> null_marker
  }
}

fn nested(value: Option(BitArray)) -> BitArray {
  case value {
    Some(bits) -> bits
    None -> null_marker
  }
}

fn sha256(bits: BitArray) -> BitArray {
  crypto.hash(crypto.Sha256, bits)
}

/// Render a digest the one way it is ever stored or compared as text: 64
/// lowercase hex characters, with no prefix or other adornment.
pub fn hex(digest: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(digest))
}

// `at`: line, column — as decimal strings.
fn at_bits(at: At) -> BitArray {
  bit_array.concat([
    entry("line", bit_array.from_string(int.to_string(at.line))),
    entry("column", bit_array.from_string(int.to_string(at.column))),
  ])
}

// An outcome: status, return, diagnostic, at, error_variant.
fn outcome_bits(outcome: Outcome) -> BitArray {
  bit_array.concat([
    entry("status", bit_array.from_string(outcome.status)),
    entry("return", text(outcome.return)),
    entry("diagnostic", text(outcome.diagnostic)),
    entry("at", nested(option.map(outcome.at, at_bits))),
    entry("error_variant", text(outcome.error_variant)),
  ])
}

/// The digest over what came out of the compiler for one row: its `compiler`,
/// `forced_field` and `forced_module` outcomes, in that order.
pub fn evidence_hash(
  compiler: Outcome,
  forced_field: Option(Outcome),
  forced_module: Option(Outcome),
) -> String {
  hex(evidence_digest(compiler, forced_field, forced_module))
}

/// The raw 32-byte digest behind `evidence_hash`. The aggregate frames these
/// bytes, not their hex rendering, so no question of case or width arises.
pub fn evidence_digest(
  compiler: Outcome,
  forced_field: Option(Outcome),
  forced_module: Option(Outcome),
) -> BitArray {
  bit_array.concat([
    entry("compiler", outcome_bits(compiler)),
    entry("forced_field", nested(option.map(forced_field, outcome_bits))),
    entry("forced_module", nested(option.map(forced_module, outcome_bits))),
  ])
  |> sha256
}

/// The digest over what was compiled for one row: the pinned compiler version,
/// which companions the row has (by repository-relative path, so a present
/// companion's identity is bound into the hash), and the bytes of every file in
/// its compiler input closure, keyed by repository-relative path and sorted
/// bytewise ascending.
pub fn inputs_hash(
  gleam: String,
  forced_field: Option(String),
  forced_module: Option(String),
  files: List(#(String, BitArray)),
) -> String {
  let companions =
    bit_array.concat([
      entry("forced_field", text(forced_field)),
      entry("forced_module", text(forced_module)),
    ])
  let files =
    files
    |> list.sort(fn(a, b) { bytewise(a.0, b.0) })
    |> list.map(fn(file) { entry(file.0, file.1) })
    |> bit_array.concat
  bit_array.concat([
    entry("gleam", bit_array.from_string(gleam)),
    entry("companions", companions),
    entry("files", files),
  ])
  |> sha256
  |> hex
}

/// The aggregate over every row's **recomputed** evidence digest, keyed by
/// fixture name in sorted order. Aggregating the stored hash strings would
/// defeat the mechanism: an edited outcome and an adjusted row hash would
/// reproduce the same aggregate.
pub fn evidence_aggregate(entries: List(#(String, BitArray))) -> String {
  entries
  |> list.sort(fn(a, b) { bytewise(a.0, b.0) })
  |> list.map(fn(pair) { entry(pair.0, pair.1) })
  |> bit_array.concat
  |> sha256
  |> hex
}

// Compare two strings by their bytes, so the sort does not depend on a locale
// or on a collation the framing cannot reproduce.
fn bytewise(a: String, b: String) -> order.Order {
  bit_array.compare(bit_array.from_string(a), bit_array.from_string(b))
}

// Decoding
//
// Every field is decoded with `decode.field` over an optional value, so an
// explicitly-null entry decodes to `None` while a *missing* key fails — the
// distinction the schema depends on.

/// Decode a manifest from its JSON text.
pub fn decode(source: String) -> Result(Manifest, json.DecodeError) {
  json.parse(source, manifest_decoder())
}

fn manifest_decoder() -> Decoder(Manifest) {
  use gleam <- decode.field("gleam", decode.string)
  use generated <- decode.field("generated", decode.string)
  use cases <- decode.field("cases", decode.list(row_decoder()))
  decode.success(Manifest(gleam:, generated:, cases:))
}

// One member of a closed vocabulary. Without this the enumerated fields are
// unrestricted strings, and a typo in one sails through the whole suite: every
// non-`probe` kind reads as a resolution row, and a misspelled `reason` is
// just a divergence with a different story, so `"resoluton"` and `"partal"`
// would both show green.
fn one_of(field: String, vocabulary: List(String)) -> Decoder(String) {
  use raw <- decode.then(decode.string)
  case list.contains(vocabulary, raw) {
    True -> decode.success(raw)
    False ->
      decode.failure("", field <> ", one of " <> string.join(vocabulary, " | "))
  }
}

// Which vocabulary `expect` is read against — the one thing `kind` selects at
// decode time. A resolution row names a branch; a probe names an acceptance,
// which is why an `"ok"` expectation is legal on one and meaningless on the
// other.
fn expect_vocabulary(kind: String) -> List(String) {
  case kind == kind_probe {
    True -> [expect_ok, expect_error]
    False -> [expect_field, expect_module]
  }
}

fn digest_decoder() -> Decoder(String) {
  use raw <- decode.then(decode.string)
  case is_digest(raw) {
    True -> decode.success(raw)
    False -> decode.failure("", "64 lowercase hex characters")
  }
}

// Whether a string is the one spelling a digest is ever stored in: exactly 64
// lowercase hex characters, no `sha256:` prefix and no other adornment.
fn is_digest(raw: String) -> Bool {
  use <- bool.guard(string.length(raw) != 64, False)
  string.to_graphemes(raw)
  |> list.all(fn(c) { string.contains("0123456789abcdef", c) })
}

fn row_decoder() -> Decoder(Row) {
  use fixture <- decode.field("fixture", decode.string)
  use function <- decode.field("function", decode.string)
  use kind <- decode.field(
    "kind",
    one_of("kind", [kind_resolution, kind_probe]),
  )
  use access <- decode.field(
    "access",
    one_of("access", [access_call, access_projection]),
  )
  use syntax_site <- decode.field(
    "syntax_site",
    one_of("syntax_site", [site_call, site_pipe, site_bare]),
  )
  use expect <- decode.field(
    "expect",
    one_of("expect", expect_vocabulary(kind)),
  )
  use field_availability <- decode.field(
    "field_availability",
    decode.optional(
      one_of("field_availability", [
        shared,
        variant,
        unavailable,
        undeclared,
        unknown_receiver,
      ]),
    ),
  )
  use narrowed_to <- decode.field("narrowed_to", decode.optional(decode.string))
  use module_availability <- decode.field(
    "module_availability",
    decode.optional(one_of("module_availability", [available, undeclared])),
  )
  use field_member <- decode.field(
    "field_member",
    decode.optional(decode.string),
  )
  use module_member <- decode.field(
    "module_member",
    decode.optional(decode.string),
  )
  use field_return <- decode.field(
    "field_return",
    decode.optional(decode.string),
  )
  use module_return <- decode.field(
    "module_return",
    decode.optional(decode.string),
  )
  use field_candidates <- decode.field(
    "field_candidates",
    decode.optional(decode.list(candidate_decoder())),
  )
  use missing_variants <- decode.field(
    "missing_variants",
    decode.optional(decode.list(decode.string)),
  )
  use reason <- decode.field(
    "reason",
    decode.optional(
      one_of("reason", [reason_partial, reason_index, reason_type]),
    ),
  )
  use derivable <- decode.field("derivable", decode.optional(decode.bool))
  use forced_field <- decode.field(
    "forced_field",
    decode.optional(outcome_decoder()),
  )
  use forced_module <- decode.field(
    "forced_module",
    decode.optional(outcome_decoder()),
  )
  use target_import <- decode.field(
    "target_import",
    decode.optional(import_decoder()),
  )
  use label <- decode.field("label", decode.string)
  use target_bindings <- decode.field(
    "target_bindings",
    decode.list(binding_decoder()),
  )
  use target_access <- decode.field("target_access", span_decoder())
  use renamed_to <- decode.field("renamed_to", decode.optional(decode.string))
  use renamed_spans <- decode.field(
    "renamed_spans",
    decode.list(pair_span_decoder()),
  )
  use inputs_hash <- decode.field("inputs_hash", digest_decoder())
  use evidence_hash <- decode.field("evidence_hash", digest_decoder())
  use compiler <- decode.field("compiler", outcome_decoder())
  use girard <- decode.field("girard", outcome_decoder())
  use expect_girard_error_variant <- decode.field(
    "expect_girard_error_variant",
    decode.optional(decode.string),
  )
  use divergent <- decode.field("divergent", decode.bool)
  use why <- decode.field("why", decode.string)
  decode.success(Row(
    fixture:,
    function:,
    kind:,
    access:,
    syntax_site:,
    expect:,
    field_availability:,
    narrowed_to:,
    module_availability:,
    field_member:,
    module_member:,
    field_return:,
    module_return:,
    field_candidates:,
    missing_variants:,
    reason:,
    derivable:,
    forced_field:,
    forced_module:,
    target_import:,
    label:,
    target_bindings:,
    target_access:,
    renamed_to:,
    renamed_spans:,
    inputs_hash:,
    evidence_hash:,
    compiler:,
    girard:,
    expect_girard_error_variant:,
    divergent:,
    why:,
  ))
}

fn outcome_decoder() -> Decoder(Outcome) {
  use status <- decode.field("status", decode.string)
  use return <- decode.field("return", decode.optional(decode.string))
  use diagnostic <- decode.field("diagnostic", decode.optional(decode.string))
  use at <- decode.field("at", decode.optional(at_decoder()))
  use error_variant <- decode.field(
    "error_variant",
    decode.optional(decode.string),
  )
  decode.success(Outcome(status:, return:, diagnostic:, at:, error_variant:))
}

fn at_decoder() -> Decoder(At) {
  use line <- decode.field("line", decode.int)
  use column <- decode.field("column", decode.int)
  decode.success(At(line:, column:))
}

fn span_decoder() -> Decoder(Span) {
  use start <- decode.field("start", decode.int)
  use end <- decode.field("end", decode.int)
  decode.success(Span(start:, end:))
}

// `renamed_spans` entries are two-element arrays rather than objects: they are
// a set of byte ranges, read as a block in review, not individually named.
fn pair_span_decoder() -> Decoder(Span) {
  use pair <- decode.then(decode.list(decode.int))
  case pair {
    [start, end] -> decode.success(Span(start:, end:))
    _ -> decode.failure(Span(0, 0), "[start, end]")
  }
}

fn binding_decoder() -> Decoder(Binding) {
  use name <- decode.field("name", decode.string)
  use span <- decode.field("span", span_decoder())
  decode.success(Binding(name:, span:))
}

fn import_decoder() -> Decoder(TargetImport) {
  use module <- decode.field("module", decode.string)
  use alias <- decode.field("alias", decode.optional(decode.string))
  decode.success(TargetImport(module:, alias:))
}

fn candidate_decoder() -> Decoder(Candidate) {
  use variant <- decode.field("variant", decode.string)
  use index <- decode.field("index", decode.int)
  use member <- decode.field("member", decode.string)
  use return <- decode.field("return", decode.string)
  decode.success(Candidate(variant:, index:, member:, return:))
}

// Encoding
//
// Hand-rolled rather than `json.to_string`, for two reasons the manifest
// depends on: the field order below is the documented one, and every row is
// laid out one field per line so that flipping `divergent` is a reviewable
// diff.

/// Render a manifest as the JSON committed to `differential/expected.json`.
pub fn encode(manifest: Manifest) -> String {
  let rows =
    manifest.cases
    |> list.map(encode_row)
    |> string.join(",\n")
  "{\n"
  <> "  \"gleam\": "
  <> quote(manifest.gleam)
  <> ",\n"
  <> "  \"generated\": "
  <> quote(manifest.generated)
  <> ",\n"
  <> "  \"cases\": [\n"
  <> rows
  <> "\n  ]\n}\n"
}

fn encode_row(row: Row) -> String {
  let fields = [
    #("fixture", quote(row.fixture)),
    #("function", quote(row.function)),
    #("kind", quote(row.kind)),
    #("access", quote(row.access)),
    #("syntax_site", quote(row.syntax_site)),
    #("expect", quote(row.expect)),
    #("field_availability", opt_string(row.field_availability)),
    #("narrowed_to", opt_string(row.narrowed_to)),
    #("module_availability", opt_string(row.module_availability)),
    #("field_member", opt_string(row.field_member)),
    #("module_member", opt_string(row.module_member)),
    #("field_return", opt_string(row.field_return)),
    #("module_return", opt_string(row.module_return)),
    #("field_candidates", encode_candidates(row.field_candidates)),
    #("missing_variants", encode_strings(row.missing_variants)),
    #("reason", opt_string(row.reason)),
    #("derivable", opt_bool(row.derivable)),
    #("forced_field", encode_optional_outcome(row.forced_field)),
    #("forced_module", encode_optional_outcome(row.forced_module)),
    #("target_import", encode_import(row.target_import)),
    #("label", quote(row.label)),
    #("target_bindings", encode_bindings(row.target_bindings)),
    #("target_access", encode_span(row.target_access)),
    #("renamed_to", opt_string(row.renamed_to)),
    #("renamed_spans", encode_pairs(row.renamed_spans)),
    #("inputs_hash", quote(row.inputs_hash)),
    #("evidence_hash", quote(row.evidence_hash)),
    #("compiler", encode_outcome(row.compiler)),
    #("girard", encode_outcome(row.girard)),
    #(
      "expect_girard_error_variant",
      opt_string(row.expect_girard_error_variant),
    ),
    #("divergent", bool_json(row.divergent)),
    #("why", quote(row.why)),
  ]
  let body =
    fields
    |> list.map(fn(field) { "      " <> quote(field.0) <> ": " <> field.1 })
    |> string.join(",\n")
  "    {\n" <> body <> "\n    }"
}

fn encode_outcome(outcome: Outcome) -> String {
  "{ \"status\": "
  <> quote(outcome.status)
  <> ", \"return\": "
  <> opt_string(outcome.return)
  <> ", \"diagnostic\": "
  <> opt_string(outcome.diagnostic)
  <> ", \"at\": "
  <> encode_optional_at(outcome.at)
  <> ", \"error_variant\": "
  <> opt_string(outcome.error_variant)
  <> " }"
}

fn encode_optional_outcome(outcome: Option(Outcome)) -> String {
  case outcome {
    Some(outcome) -> encode_outcome(outcome)
    None -> "null"
  }
}

fn encode_optional_at(at: Option(At)) -> String {
  case at {
    Some(at) ->
      "{ \"line\": "
      <> int.to_string(at.line)
      <> ", \"column\": "
      <> int.to_string(at.column)
      <> " }"
    None -> "null"
  }
}

fn encode_span(span: Span) -> String {
  "{ \"start\": "
  <> int.to_string(span.start)
  <> ", \"end\": "
  <> int.to_string(span.end)
  <> " }"
}

fn encode_pairs(spans: List(Span)) -> String {
  "["
  <> string.join(
    list.map(spans, fn(span) {
      "[" <> int.to_string(span.start) <> ", " <> int.to_string(span.end) <> "]"
    }),
    ", ",
  )
  <> "]"
}

fn encode_bindings(bindings: List(Binding)) -> String {
  "["
  <> string.join(
    list.map(bindings, fn(binding) {
      "{ \"name\": "
      <> quote(binding.name)
      <> ", \"span\": "
      <> encode_span(binding.span)
      <> " }"
    }),
    ", ",
  )
  <> "]"
}

fn encode_import(target: Option(TargetImport)) -> String {
  case target {
    Some(target) ->
      "{ \"module\": "
      <> quote(target.module)
      <> ", \"alias\": "
      <> opt_string(target.alias)
      <> " }"
    None -> "null"
  }
}

fn encode_candidates(candidates: Option(List(Candidate))) -> String {
  case candidates {
    None -> "null"
    Some(candidates) ->
      "["
      <> string.join(
        list.map(candidates, fn(candidate) {
          "{ \"variant\": "
          <> quote(candidate.variant)
          <> ", \"index\": "
          <> int.to_string(candidate.index)
          <> ", \"member\": "
          <> quote(candidate.member)
          <> ", \"return\": "
          <> quote(candidate.return)
          <> " }"
        }),
        ", ",
      )
      <> "]"
  }
}

fn encode_strings(values: Option(List(String))) -> String {
  case values {
    None -> "null"
    Some(values) -> "[" <> string.join(list.map(values, quote), ", ") <> "]"
  }
}

fn opt_string(value: Option(String)) -> String {
  case value {
    Some(value) -> quote(value)
    None -> "null"
  }
}

fn opt_bool(value: Option(Bool)) -> String {
  case value {
    Some(value) -> bool_json(value)
    None -> "null"
  }
}

fn bool_json(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

// Escaping is `gleam_json`'s, so a control character in a `why` or `diagnostic`
// cannot be emitted raw and make the manifest unreadable on the way back.
fn quote(value: String) -> String {
  json.to_string(json.string(value))
}
