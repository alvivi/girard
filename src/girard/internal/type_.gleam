//// The types inference works on.
////
//// `girard.Type` is the vocabulary consumers pattern-match on, and it is
//// frozen: adding a field to it would break every exhaustive match against
//// it. Inference needs one more thing than consumers do — the variant a
//// value has been narrowed to, as the compiler carries on its own named
//// types — so it works on this parallel type and converts at the boundary
//// where a result is published. `variant` is always `None` today; it is the
//// slot that narrowing will fill.

import gleam/option.{type Option}

/// A type as inference sees it. Mirrors `girard.Type` field for field, plus
/// `variant` on `Named`.
pub type Type {
  /// A named, nominal type. `variant` is the source-order index of the
  /// constructor a value is known to have been built with, when it is known.
  Named(
    module: String,
    name: String,
    arguments: List(Type),
    variant: Option(Int),
  )
  /// A function type `fn(a, b) -> c`.
  Fn(arguments: List(Type), return: Type)
  /// A type variable. The substitution in the inference state may bind it.
  Var(id: Int)
  /// A tuple type `#(a, b, c)`.
  Tuple(elements: List(Type))
}

/// A polymorphic type scheme `forall vars. type_`, over the inference-side
/// `Type`. Mirrors `girard.Scheme`.
pub type Scheme {
  Scheme(vars: List(Int), type_: Type)
}
