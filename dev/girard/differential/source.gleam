//// Reading a differential fixture's source: where the contested access is,
//// which byte ranges are occurrences of the receiver's name, what each variant
//// declares, and how the two forced-branch companions are derived from the
//// base.
////
//// Two tools, for two different questions. `glance` answers *what kind of node
//// is this* — the shape at `target_access`, a variant's declared field type, a
//// pattern's binding. `glexer` answers *which byte ranges are identifier
//// tokens*, which is what stops a span covering `io` inside a string literal or
//// a `// io` comment from passing for an occurrence.
////
//// Neither answers *which declaration binds this reference*: `glance` is a
//// syntax tree with no scope links, and writing a scope walker here would be a
//// second implementation of the analysis the suite exists to adjudicate. So the
//// rename is defined exhaustively — every occurrence outside the imports and
//// outside the contested access — and its completeness is read off the
//// companion by counting surviving tokens.

import glance
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import glexer
import glexer/token

/// A byte range, in the same spelling the manifest uses.
pub type Span =
  glance.Span

/// One `x.label` in the source whose container is a plain variable, with the
/// syntactic position that decides how the row's return derives from its
/// member.
pub type Access {
  Access(
    span: Span,
    container: Span,
    receiver: String,
    label: String,
    site: String,
  )
}

/// Parse a fixture. Every fixture must parse; a parse failure is a broken
/// fixture, not a measurement.
pub fn parse(source: String) -> Result(glance.Module, glance.Error) {
  glance.module(source)
}

// Tokens
//
// Identifier occurrences, with byte offsets. Comments and whitespace are
// discarded, so a name inside a comment is not a token and a name inside a
// string literal is part of a `String` token rather than a `Name` one.

/// Every token in `source`, paired with its byte offset.
pub fn tokens(source: String) -> List(#(token.Token, Int)) {
  glexer.new(source)
  |> glexer.discard_comments
  |> glexer.discard_whitespace
  |> glexer.lex
  |> list.map(fn(pair) {
    let #(tok, glexer.Position(offset)) = pair
    #(tok, offset)
  })
}

/// Every identifier-token occurrence of `name`, as a byte range.
pub fn name_spans(source: String, name: String) -> List(Span) {
  let width = byte_size(name)
  tokens(source)
  |> list.filter_map(fn(pair) {
    case pair.0 {
      token.Name(found) if found == name ->
        Ok(glance.Span(pair.1, pair.1 + width))
      _ -> Error(Nil)
    }
  })
}

/// Every identifier spelled anywhere in the source — names and upper names
/// alike — so a replacement name can be checked fresh against all of them.
pub fn identifiers(source: String) -> List(String) {
  tokens(source)
  |> list.filter_map(fn(pair) {
    case pair.0 {
      token.Name(name) | token.UpperName(name) -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

// Imports
//
// The import declarations, as byte ranges. The receiver's name is also the
// final segment of the module path (`import differential/io`) — and, for an
// aliased import, the alias itself — so rewriting it there would corrupt the
// import rather than rename a variable. Import declarations are excluded from
// the rewrite entirely.

/// The byte range of every import declaration in the module.
pub fn import_spans(module: glance.Module) -> List(Span) {
  list.map(module.imports, fn(definition) { definition.definition.location })
}

/// The imports' module paths, in source order.
pub fn imported_modules(module: glance.Module) -> List(String) {
  list.map(module.imports, fn(definition) { definition.definition.module })
}

/// The import that binds `name` — by its path's final segment, or by an
/// explicit alias.
pub fn import_binding(
  module: glance.Module,
  name: String,
) -> Option(#(String, Option(String))) {
  module.imports
  |> list.map(fn(definition) { definition.definition })
  |> list.find_map(fn(import_) {
    case import_.alias {
      Some(glance.Named(alias)) if alias == name ->
        Ok(#(import_.module, Some(alias)))
      Some(_) -> Error(Nil)
      None ->
        case last_segment(import_.module) == name {
          True -> Ok(#(import_.module, None))
          False -> Error(Nil)
        }
    }
  })
  |> option.from_result
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(segment) -> segment
    Error(_) -> path
  }
}

/// Whether `span` falls inside any import declaration.
pub fn in_imports(imports: List(Span), span: Span) -> Bool {
  list.any(imports, fn(import_) {
    span.start >= import_.start && span.end <= import_.end
  })
}

// The contested access
//
// Every `x.label` whose container is a plain variable, with its syntactic
// position. `glance` answers the position from the syntax tree alone, with no
// scope analysis.

/// Every field access in the module whose container is a plain variable.
pub fn accesses(module: glance.Module) -> List(Access) {
  let from_functions =
    list.flat_map(module.functions, fn(definition) {
      walk_statements(definition.definition.body, site_bare)
    })
  let from_constants =
    list.flat_map(module.constants, fn(definition) {
      walk(definition.definition.value, site_bare)
    })
  list.append(from_functions, from_constants)
}

const site_bare = "bare"

const site_call = "call"

const site_pipe = "pipe"

// `site` is the position to attribute to `expression` if it is itself a field
// access. Only a `Call` and a pipe override it for their own child.
fn walk(expression: glance.Expression, site: String) -> List(Access) {
  case expression {
    glance.FieldAccess(location, container, label) -> {
      let here = case container {
        glance.Variable(container_location, name) -> [
          Access(
            span: location,
            container: container_location,
            receiver: name,
            label:,
            site:,
          ),
        ]
        _ -> []
      }
      list.append(here, walk(container, site_bare))
    }
    glance.Call(_, function, arguments) ->
      list.append(
        walk(function, site_call),
        list.flat_map(arguments, fn(field) {
          walk(field_item(field), site_bare)
        }),
      )
    glance.BinaryOperator(_, glance.Pipe, left, right) ->
      list.append(walk(left, site_bare), walk(right, site_pipe))
    glance.BinaryOperator(_, _, left, right) ->
      list.append(walk(left, site_bare), walk(right, site_bare))
    glance.FnCapture(_, _, function, before, after) ->
      list.flatten([
        walk(function, site_call),
        list.flat_map(before, fn(field) { walk(field_item(field), site_bare) }),
        list.flat_map(after, fn(field) { walk(field_item(field), site_bare) }),
      ])
    glance.Block(_, statements) -> walk_statements(statements, site_bare)
    glance.Fn(_, _, _, body) -> walk_statements(body, site_bare)
    glance.Case(_, subjects, clauses) ->
      list.append(
        list.flat_map(subjects, fn(subject) { walk(subject, site_bare) }),
        list.flat_map(clauses, fn(clause) {
          let glance.Clause(_, guard, body) = clause
          list.append(walk_option(guard), walk(body, site_bare))
        }),
      )
    glance.Tuple(_, elements) ->
      list.flat_map(elements, fn(element) { walk(element, site_bare) })
    glance.List(_, elements, rest) ->
      list.append(
        list.flat_map(elements, fn(element) { walk(element, site_bare) }),
        walk_option(rest),
      )
    glance.RecordUpdate(_, _, _, record, fields) ->
      list.append(
        walk(record, site_bare),
        list.flat_map(fields, fn(field) { walk_option(field.item) }),
      )
    glance.TupleIndex(_, tuple, _) -> walk(tuple, site_bare)
    glance.NegateInt(_, value) -> walk(value, site_bare)
    glance.NegateBool(_, value) -> walk(value, site_bare)
    glance.Panic(_, message) -> walk_option(message)
    glance.Todo(_, message) -> walk_option(message)
    glance.Echo(_, expression, message) ->
      list.append(walk_option(expression), walk_option(message))
    glance.BitString(_, segments) ->
      list.flat_map(segments, fn(segment) { walk(segment.0, site_bare) })
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> []
  }
}

fn walk_option(expression: Option(glance.Expression)) -> List(Access) {
  case expression {
    Some(expression) -> walk(expression, site_bare)
    None -> []
  }
}

fn walk_statements(
  statements: List(glance.Statement),
  site: String,
) -> List(Access) {
  list.flat_map(statements, fn(statement) {
    case statement {
      glance.Use(_, _, function) -> walk(function, site)
      glance.Assignment(_, _, _, _, value) -> walk(value, site_bare)
      glance.Assert(_, expression, message) ->
        list.append(walk(expression, site_bare), walk_option(message))
      glance.Expression(expression) -> walk(expression, site_bare)
    }
  })
}

fn field_item(field: glance.Field(glance.Expression)) -> glance.Expression {
  case field {
    glance.LabelledField(_, _, item) -> item
    glance.ShorthandField(label, location) -> glance.Variable(location, label)
    glance.UnlabelledField(item) -> item
  }
}

// Declarations of the receiver's name
//
// Recorded as metadata — for review, and for the check that a companion is a
// different program from its base. It is not what defines the rename.

/// Every declaration of `name` in the module: function and anonymous-function
/// parameters, and pattern bindings.
pub fn declaration_spans(
  module: glance.Module,
  source: String,
  name: String,
) -> List(Span) {
  let tokens = tokens(source)
  let headers =
    list.append(
      list.map(module.functions, fn(definition) {
        definition.definition.location.start
      }),
      fn_locations(module),
    )
  let parameters =
    list.flat_map(headers, fn(start) { parameter_spans(tokens, start, name) })
  list.append(parameters, pattern_spans(module, tokens, name))
  |> list.sort(by_start)
  |> dedupe
}

fn by_start(a: Span, b: Span) -> order.Order {
  int.compare(a.start, b.start)
}

fn dedupe(spans: List(Span)) -> List(Span) {
  case spans {
    [a, b, ..rest] if a == b -> dedupe([b, ..rest])
    [a, ..rest] -> [a, ..dedupe(rest)]
    [] -> []
  }
}

// Every anonymous function's location, so its parameter list can be scanned the
// same way a top-level function's is.
fn fn_locations(module: glance.Module) -> List(Int) {
  list.flat_map(module.functions, fn(definition) {
    fn_locations_in_statements(definition.definition.body)
  })
}

fn fn_locations_in_statements(statements: List(glance.Statement)) -> List(Int) {
  list.flat_map(statements, fn(statement) {
    case statement {
      glance.Use(_, _, function) -> fn_locations_in(function)
      glance.Assignment(_, _, _, _, value) -> fn_locations_in(value)
      glance.Assert(_, expression, message) ->
        list.append(fn_locations_in(expression), option_locations(message))
      glance.Expression(expression) -> fn_locations_in(expression)
    }
  })
}

fn option_locations(expression: Option(glance.Expression)) -> List(Int) {
  case expression {
    Some(expression) -> fn_locations_in(expression)
    None -> []
  }
}

fn fn_locations_in(expression: glance.Expression) -> List(Int) {
  case expression {
    glance.Fn(location, _, _, body) -> [
      location.start,
      ..fn_locations_in_statements(body)
    ]
    glance.Block(_, statements) -> fn_locations_in_statements(statements)
    glance.Call(_, function, arguments) ->
      list.append(
        fn_locations_in(function),
        list.flat_map(arguments, fn(field) {
          fn_locations_in(field_item(field))
        }),
      )
    glance.FnCapture(_, _, function, before, after) ->
      list.flatten([
        fn_locations_in(function),
        list.flat_map(before, fn(field) { fn_locations_in(field_item(field)) }),
        list.flat_map(after, fn(field) { fn_locations_in(field_item(field)) }),
      ])
    glance.BinaryOperator(_, _, left, right) ->
      list.append(fn_locations_in(left), fn_locations_in(right))
    glance.Case(_, subjects, clauses) ->
      list.append(
        list.flat_map(subjects, fn_locations_in),
        list.flat_map(clauses, fn(clause) {
          let glance.Clause(_, guard, body) = clause
          list.append(option_locations(guard), fn_locations_in(body))
        }),
      )
    glance.Tuple(_, elements) -> list.flat_map(elements, fn_locations_in)
    glance.List(_, elements, rest) ->
      list.append(
        list.flat_map(elements, fn_locations_in),
        option_locations(rest),
      )
    glance.FieldAccess(_, container, _) -> fn_locations_in(container)
    glance.TupleIndex(_, tuple, _) -> fn_locations_in(tuple)
    glance.RecordUpdate(_, _, _, record, fields) ->
      list.append(
        fn_locations_in(record),
        list.flat_map(fields, fn(field) { option_locations(field.item) }),
      )
    glance.NegateInt(_, value) | glance.NegateBool(_, value) ->
      fn_locations_in(value)
    glance.Panic(_, message) | glance.Todo(_, message) ->
      option_locations(message)
    glance.Echo(_, expression, message) ->
      list.append(option_locations(expression), option_locations(message))
    glance.BitString(_, segments) ->
      list.flat_map(segments, fn(segment) { fn_locations_in(segment.0) })
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> []
  }
}

// A parameter list's names, at the top level of the list only: a name nested
// inside a `fn(..)` type annotation is a type variable, not a parameter.
fn parameter_spans(
  tokens: List(#(token.Token, Int)),
  from: Int,
  name: String,
) -> List(Span) {
  let rest = list.drop_while(tokens, fn(pair) { pair.1 < from })
  case list.drop_while(rest, fn(pair) { pair.0 != token.Fn }) {
    [_fn_keyword, ..after] -> {
      let after = case after {
        [#(token.Name(_), _), ..tail] -> tail
        other -> other
      }
      case after {
        [#(token.LeftParen, _), ..body] -> scan_parameters(body, 1, True, name)
        _ -> []
      }
    }
    [] -> []
  }
}

fn scan_parameters(
  tokens: List(#(token.Token, Int)),
  depth: Int,
  boundary: Bool,
  name: String,
) -> List(Span) {
  case tokens {
    [] -> []
    [#(tok, offset), ..rest] -> {
      let closing = closes(tok)
      let opening = opens(tok)
      let depth = depth + opening - closing
      use <- bool.guard(depth == 0, [])
      case depth == 1, boundary, tok {
        // A labelled parameter is `label name: Type`; the second name is the
        // parameter's own.
        True, True, token.Name(_) -> {
          let #(span, rest) = case rest {
            [#(token.Name(second), second_offset), ..tail] -> #(
              #(second, second_offset),
              tail,
            )
            _ -> #(#(token_name(tok), offset), rest)
          }
          let found = case span.0 == name {
            True -> [glance.Span(span.1, span.1 + byte_size(name))]
            False -> []
          }
          list.append(found, scan_parameters(rest, depth, False, name))
        }
        True, _, token.Comma -> scan_parameters(rest, depth, True, name)
        _, _, _ -> scan_parameters(rest, depth, False, name)
      }
    }
  }
}

fn token_name(tok: token.Token) -> String {
  case tok {
    token.Name(name) -> name
    _ -> ""
  }
}

fn opens(tok: token.Token) -> Int {
  case tok {
    token.LeftParen | token.LeftSquare | token.LeftBrace -> 1
    _ -> 0
  }
}

fn closes(tok: token.Token) -> Int {
  case tok {
    token.RightParen | token.RightSquare | token.RightBrace -> 1
    _ -> 0
  }
}

// Pattern bindings of `name`: a `PatternVariable` carries its own span; a
// `Loud(..) as name` alias carries only the whole pattern's span, so the alias
// token is the `Name` immediately after the `as` inside it.
fn pattern_spans(
  module: glance.Module,
  tokens: List(#(token.Token, Int)),
  name: String,
) -> List(Span) {
  list.flat_map(patterns(module), fn(pattern) {
    pattern_spans_in(pattern, tokens, name)
  })
}

fn pattern_spans_in(
  pattern: glance.Pattern,
  tokens: List(#(token.Token, Int)),
  name: String,
) -> List(Span) {
  case pattern {
    glance.PatternVariable(location, found) if found == name -> [location]
    glance.PatternAssignment(location, inner, found) -> {
      let here = case found == name {
        True -> alias_span(tokens, location, name)
        False -> []
      }
      list.append(here, pattern_spans_in(inner, tokens, name))
    }
    glance.PatternTuple(_, elements) ->
      list.flat_map(elements, fn(element) {
        pattern_spans_in(element, tokens, name)
      })
    glance.PatternList(_, elements, tail) ->
      list.append(
        list.flat_map(elements, fn(element) {
          pattern_spans_in(element, tokens, name)
        }),
        case tail {
          Some(tail) -> pattern_spans_in(tail, tokens, name)
          None -> []
        },
      )
    glance.PatternVariant(_, _, _, arguments, _) ->
      list.flat_map(arguments, fn(field) {
        pattern_spans_in(pattern_item(field), tokens, name)
      })
    glance.PatternBitString(_, segments) ->
      list.flat_map(segments, fn(segment) {
        pattern_spans_in(segment.0, tokens, name)
      })
    _ -> []
  }
}

fn pattern_item(field: glance.Field(glance.Pattern)) -> glance.Pattern {
  case field {
    glance.LabelledField(_, _, item) -> item
    glance.ShorthandField(label, location) ->
      glance.PatternVariable(location, label)
    glance.UnlabelledField(item) -> item
  }
}

fn alias_span(
  tokens: List(#(token.Token, Int)),
  location: Span,
  name: String,
) -> List(Span) {
  let inside =
    list.filter(tokens, fn(pair) {
      pair.1 >= location.start && pair.1 < location.end
    })
  after_as(inside, name)
}

fn after_as(tokens: List(#(token.Token, Int)), name: String) -> List(Span) {
  case tokens {
    [#(token.As, _), #(token.Name(found), offset), ..rest] if found == name -> [
      glance.Span(offset, offset + byte_size(name)),
      ..after_as(rest, name)
    ]
    [_, ..rest] -> after_as(rest, name)
    [] -> []
  }
}

/// Every pattern in the module, in source order.
pub fn patterns(module: glance.Module) -> List(glance.Pattern) {
  list.flat_map(module.functions, fn(definition) {
    patterns_in_statements(definition.definition.body)
  })
}

fn patterns_in_statements(
  statements: List(glance.Statement),
) -> List(glance.Pattern) {
  list.flat_map(statements, fn(statement) {
    case statement {
      glance.Use(_, use_patterns, function) ->
        list.append(
          list.map(use_patterns, fn(use_pattern) { use_pattern.pattern }),
          patterns_in(function),
        )
      glance.Assignment(_, _, pattern, _, value) -> [
        pattern,
        ..patterns_in(value)
      ]
      glance.Assert(_, expression, _) -> patterns_in(expression)
      glance.Expression(expression) -> patterns_in(expression)
    }
  })
}

fn patterns_in(expression: glance.Expression) -> List(glance.Pattern) {
  case expression {
    glance.Case(_, subjects, clauses) ->
      list.append(
        list.flat_map(subjects, patterns_in),
        list.flat_map(clauses, fn(clause) {
          let glance.Clause(clause_patterns, _, body) = clause
          list.append(list.flatten(clause_patterns), patterns_in(body))
        }),
      )
    glance.Block(_, statements) -> patterns_in_statements(statements)
    glance.Fn(_, _, _, body) -> patterns_in_statements(body)
    glance.Call(_, function, arguments) ->
      list.append(
        patterns_in(function),
        list.flat_map(arguments, fn(field) { patterns_in(field_item(field)) }),
      )
    glance.FnCapture(_, _, function, before, after) ->
      list.flatten([
        patterns_in(function),
        list.flat_map(before, fn(field) { patterns_in(field_item(field)) }),
        list.flat_map(after, fn(field) { patterns_in(field_item(field)) }),
      ])
    glance.BinaryOperator(_, _, left, right) ->
      list.append(patterns_in(left), patterns_in(right))
    glance.Tuple(_, elements) -> list.flat_map(elements, patterns_in)
    glance.List(_, elements, rest) ->
      list.append(list.flat_map(elements, patterns_in), case rest {
        Some(rest) -> patterns_in(rest)
        None -> []
      })
    glance.FieldAccess(_, container, _) -> patterns_in(container)
    glance.TupleIndex(_, tuple, _) -> patterns_in(tuple)
    glance.RecordUpdate(_, _, _, record, fields) ->
      list.append(
        patterns_in(record),
        list.flat_map(fields, fn(field) {
          case field.item {
            Some(item) -> patterns_in(item)
            None -> []
          }
        }),
      )
    glance.NegateInt(_, value) | glance.NegateBool(_, value) ->
      patterns_in(value)
    glance.Panic(_, message) | glance.Todo(_, message) ->
      case message {
        Some(message) -> patterns_in(message)
        None -> []
      }
    glance.Echo(_, expression, message) ->
      list.append(
        case expression {
          Some(expression) -> patterns_in(expression)
          None -> []
        },
        case message {
          Some(message) -> patterns_in(message)
          None -> []
        },
      )
    glance.BitString(_, segments) ->
      list.flat_map(segments, fn(segment) { patterns_in(segment.0) })
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> []
  }
}

// The rewrite
//
// The forced-module companion is an alpha-renaming: every identifier-token
// occurrence of the receiver's name, except inside an import declaration and
// except the container at the contested access. The forced-field companion is
// the base with the target import's line removed.

/// The byte ranges the forced-module companion replaces: every occurrence of
/// `name`, minus the container at `container`, minus every occurrence inside an
/// import declaration.
pub fn rename_spans(
  module: glance.Module,
  source: String,
  name: String,
  container: Span,
) -> List(Span) {
  let imports = import_spans(module)
  name_spans(source, name)
  |> list.filter(fn(span) { span != container && !in_imports(imports, span) })
}

/// Replace each span with `replacement`, in descending offset order so earlier
/// offsets stay valid.
pub fn apply_rename(
  source: String,
  spans: List(Span),
  replacement: String,
) -> String {
  let bits = bit_array.from_string(source)
  let replacement = bit_array.from_string(replacement)
  spans
  |> list.sort(fn(a, b) { int.compare(b.start, a.start) })
  |> list.fold(bits, fn(acc, span) {
    let size = bit_array.byte_size(acc)
    let assert Ok(before) = bit_array.slice(acc, 0, span.start)
    let assert Ok(after) = bit_array.slice(acc, span.end, size - span.end)
    <<before:bits, replacement:bits, after:bits>>
  })
  |> to_string
}

fn to_string(bits: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bits)
  text
}

/// The forced-field companion, and what the deletion did to the coordinates:
/// the companion's source, the byte offset the deleted line started at, and how
/// many bytes it took with it.
pub fn remove_import(
  module: glance.Module,
  source: String,
  path: String,
) -> Result(#(String, Int, Int), Nil) {
  use import_ <- result.try(
    module.imports
    |> list.map(fn(definition) { definition.definition })
    |> list.find(fn(import_) { import_.module == path }),
  )
  let start = line_start(source, import_.location.start)
  let length = line_length(source, start)
  let bits = bit_array.from_string(source)
  let size = bit_array.byte_size(bits)
  let assert Ok(before) = bit_array.slice(bits, 0, start)
  let assert Ok(after) =
    bit_array.slice(bits, start + length, size - start - length)
  Ok(#(to_string(<<before:bits, after:bits>>), start, length))
}

fn line_start(source: String, offset: Int) -> Int {
  let bits = bit_array.from_string(source)
  scan_back(bits, offset - 1)
}

fn scan_back(bits: BitArray, at: Int) -> Int {
  case at < 0 {
    True -> 0
    False ->
      case bit_array.slice(bits, at, 1) {
        Ok(<<10>>) -> at + 1
        _ -> scan_back(bits, at - 1)
      }
  }
}

fn line_length(source: String, start: Int) -> Int {
  let bits = bit_array.from_string(source)
  let size = bit_array.byte_size(bits)
  scan_forward(bits, size, start) - start
}

fn scan_forward(bits: BitArray, size: Int, at: Int) -> Int {
  case at >= size {
    True -> size
    False ->
      case bit_array.slice(bits, at, 1) {
        Ok(<<10>>) -> at + 1
        _ -> scan_forward(bits, size, at + 1)
      }
  }
}

/// The byte offset of a 1-based line and column, as the compiler reports them.
pub fn offset_of(source: String, line: Int, column: Int) -> Int {
  let lines = string.split(source, "\n")
  let before =
    lines
    |> list.take(line - 1)
    |> list.fold(0, fn(acc, text) { acc + byte_size(text) + 1 })
  before + column - 1
}

// The `unknown_receiver` restriction
//
// Absence of an annotation is not evidence of an unconstrained type: an
// unannotated parameter can be constrained anywhere before the access — passed
// to an annotated function, used in an operator, unified through another
// binding — and such a fixture is an ordinary record receiver wearing the label.
// Enumerating the permitted occurrences is the only form of the check the test
// can decide without inference of its own.

/// The occurrences of `name` that sit on the right of a `let _ = name` discard.
/// The discard constrains nothing and is what keeps the compiler's unused-
/// parameter warning quiet, so it is a permitted occurrence.
pub fn discard_reads(module: glance.Module, name: String) -> List(Span) {
  list.flat_map(module.functions, fn(definition) {
    discard_reads_in(definition.definition.body, name)
  })
}

fn discard_reads_in(
  statements: List(glance.Statement),
  name: String,
) -> List(Span) {
  list.flat_map(statements, fn(statement) {
    case statement {
      glance.Assignment(
        _,
        glance.Let,
        glance.PatternDiscard(..),
        _,
        glance.Variable(location, found),
      )
        if found == name
      -> [location]
      glance.Assignment(_, _, _, _, value) -> discard_reads_nested(value, name)
      glance.Expression(expression) -> discard_reads_nested(expression, name)
      _ -> []
    }
  })
}

fn discard_reads_nested(
  expression: glance.Expression,
  name: String,
) -> List(Span) {
  case expression {
    glance.Block(_, statements) -> discard_reads_in(statements, name)
    glance.Fn(_, _, _, body) -> discard_reads_in(body, name)
    glance.Case(_, _, clauses) ->
      list.flat_map(clauses, fn(clause) {
        let glance.Clause(_, _, body) = clause
        discard_reads_nested(body, name)
      })
    _ -> []
  }
}

/// Whether every declaration of `name` — function and anonymous-function
/// parameters, and `let` bindings — carries no type annotation.
pub fn unannotated(module: glance.Module, name: String) -> Bool {
  let parameters =
    list.flat_map(module.functions, fn(definition) {
      list.filter_map(definition.definition.parameters, fn(parameter) {
        case parameter.name {
          glance.Named(found) if found == name -> Ok(parameter.type_)
          _ -> Error(Nil)
        }
      })
    })
  let assignments =
    list.flat_map(module.functions, fn(definition) {
      annotations_in(definition.definition.body, name)
    })
  list.all(list.append(parameters, assignments), option.is_none)
}

fn annotations_in(
  statements: List(glance.Statement),
  name: String,
) -> List(Option(glance.Type)) {
  list.flat_map(statements, fn(statement) {
    case statement {
      glance.Assignment(
        _,
        _,
        glance.PatternVariable(_, found),
        annotation,
        value,
      )
        if found == name
      -> [annotation, ..annotations_nested(value, name)]
      glance.Assignment(_, _, _, _, value) -> annotations_nested(value, name)
      glance.Expression(expression) -> annotations_nested(expression, name)
      _ -> []
    }
  })
}

fn annotations_nested(
  expression: glance.Expression,
  name: String,
) -> List(Option(glance.Type)) {
  case expression {
    glance.Block(_, statements) -> annotations_in(statements, name)
    glance.Fn(_, parameters, _, body) ->
      list.append(
        list.filter_map(parameters, fn(parameter) {
          case parameter.name {
            glance.Named(found) if found == name -> Ok(parameter.type_)
            _ -> Error(Nil)
          }
        }),
        annotations_in(body, name),
      )
    glance.Case(_, _, clauses) ->
      list.flat_map(clauses, fn(clause) {
        let glance.Clause(_, _, body) = clause
        annotations_nested(body, name)
      })
    _ -> []
  }
}

// Declared types
//
// What the fixture and the shadow module actually declare, rendered in the same
// spelling girard's printer produces, so a manifest member can be compared to a
// source declaration as a string.

/// Render a `glance` type annotation the way girard renders an inferred one.
pub fn render_type(type_: glance.Type) -> String {
  case type_ {
    glance.NamedType(_, name, _, []) -> name
    glance.NamedType(_, name, _, parameters) ->
      name <> "(" <> render_list(parameters) <> ")"
    glance.FunctionType(_, parameters, return) ->
      "fn(" <> render_list(parameters) <> ") -> " <> render_type(return)
    glance.TupleType(_, elements) -> "#(" <> render_list(elements) <> ")"
    glance.VariableType(_, name) -> name
    glance.HoleType(_, name) -> name
  }
}

fn render_list(types: List(glance.Type)) -> String {
  types
  |> list.map(render_type)
  |> string.join(", ")
}

/// The custom types declared in a module.
pub fn custom_types(module: glance.Module) -> List(glance.CustomType) {
  list.map(module.custom_types, fn(definition) { definition.definition })
}

/// Where a variant declares `label`, and at what type.
pub fn variant_field(
  variant: glance.Variant,
  label: String,
) -> Option(#(Int, glance.Type)) {
  variant.fields
  |> list.index_map(fn(field, index) { #(index, field) })
  |> list.find_map(fn(entry) {
    case entry.1 {
      glance.LabelledVariantField(item, found) if found == label ->
        Ok(#(entry.0, item))
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// The declared type of a module's public value named `label` — a function's
/// signature, or a constant's annotation. An unannotated constant has no
/// declared type and is rejected rather than guessed at.
pub fn module_member(
  module: glance.Module,
  label: String,
) -> Result(glance.Type, Nil) {
  let function =
    module.functions
    |> list.map(fn(definition) { definition.definition })
    |> list.find(fn(function) {
      function.name == label && function.publicity == glance.Public
    })
  case function {
    Ok(function) -> function_type(function)
    Error(_) ->
      module.constants
      |> list.map(fn(definition) { definition.definition })
      |> list.find(fn(constant) {
        constant.name == label && constant.publicity == glance.Public
      })
      |> result.try(fn(constant) { option.to_result(constant.annotation, Nil) })
  }
}

fn function_type(function: glance.Function) -> Result(glance.Type, Nil) {
  use return <- result.try(option.to_result(function.return, Nil))
  use parameters <- result.try(
    function.parameters
    |> list.try_map(fn(parameter) { option.to_result(parameter.type_, Nil) }),
  )
  Ok(glance.FunctionType(function.location, parameters, return))
}

/// The arity of a declared function type, for the one row whose member is
/// generic and therefore checked by existence and arity alone.
pub fn arity(type_: glance.Type) -> Result(Int, Nil) {
  case type_ {
    glance.FunctionType(_, parameters, _) -> Ok(list.length(parameters))
    _ -> Error(Nil)
  }
}

/// What a member is observed as at a given access: the member itself for a
/// projection, its return for a call.
pub fn observed_return(
  type_: glance.Type,
  access: String,
) -> Result(String, Nil) {
  case access, type_ {
    "projection", _ -> Ok(render_type(type_))
    "call", glance.FunctionType(_, _, return) -> Ok(render_type(return))
    _, _ -> Error(Nil)
  }
}
