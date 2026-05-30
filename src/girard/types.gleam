//// The public type vocabulary girard reports: the inferred `Type` model and the
//// `Error` describing why a module could not be typed. The inference engine and
//// its helpers are implementation detail and live under `girard/internal/*`.

import glance

pub type Type {
  /// A named, nominal type such as `Int`, `List(a)`, `Result(a, e)` or a
  /// user-defined custom type. `module` is `"gleam"` for prelude types.
  Named(module: String, name: String, arguments: List(Type))
  /// A function type `fn(a, b) -> c`.
  Fn(arguments: List(Type), return: Type)
  /// A type variable. Its state (unbound / bound / generic) lives in the
  /// substitution table keyed by `id` during inference.
  Var(id: Int)
  /// A tuple type `#(a, b, c)`.
  Tuple(elements: List(Type))
}

/// Why a module could not be typed. Variants describe the failure in terms of
/// the type system and the offending source construct.
pub type Error {
  TypeMismatch(left: Type, right: Type)
  ArityMismatch
  RecursiveType(id: Int, type_: Type)
  UnboundVariable(name: String)
  UnknownConstructor(name: String)
  UnknownModule(alias: String)
  NoSuchExport(module: String, name: String)
  NoSuchField(type_name: String, label: String)
  NotARecord
  NotATuple
  TupleIndexOutOfRange(index: Int)
  UnknownLabel(label: String)
  AmbiguousCall
  MissingArgument
  Unsupported(feature: String)
  ParseFailed(glance.Error)
}
