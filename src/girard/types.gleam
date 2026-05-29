//// The internal type representation, mirroring Gleam's compiler `Type` enum
//// (compiler-core/src/type_.rs). Unlike the real compiler we don't use mutable
//// `Arc<RefCell<TypeVar>>`; instead a `Var` carries an integer id that is looked
//// up in a substitution table threaded through inference (see `infer.gleam`).

/// The prelude module name shared by all built-in types (Int, List, ...).
pub const prelude_module = "gleam"

pub type Type {
  /// A named, nominal type such as `Int`, `List(a)`, `Result(a, e)` or a
  /// user-defined custom type. `module` is `"gleam"` for prelude types.
  Named(module: String, name: String, arguments: List(Type))
  /// A function type `fn(a, b) -> c`.
  Fn(arguments: List(Type), return: Type)
  /// A type variable. Its state (unbound / bound / generic) lives in the
  /// substitution table keyed by `id`.
  Var(id: Int)
  /// A tuple type `#(a, b, c)`.
  Tuple(elements: List(Type))
}

/// A polymorphic type scheme: `forall vars. type`. Module-level functions and
/// constants are generalized into schemes; monomorphic bindings (lambda
/// parameters, local lets) use `Scheme([], type)`.
pub type Scheme {
  Scheme(vars: List(Int), type_: Type)
}

// --- Prelude type constructors -------------------------------------------

pub fn int() -> Type {
  Named(prelude_module, "Int", [])
}

pub fn float() -> Type {
  Named(prelude_module, "Float", [])
}

pub fn string() -> Type {
  Named(prelude_module, "String", [])
}

pub fn bool() -> Type {
  Named(prelude_module, "Bool", [])
}

pub fn nil() -> Type {
  Named(prelude_module, "Nil", [])
}

pub fn list(element: Type) -> Type {
  Named(prelude_module, "List", [element])
}

pub fn result(ok: Type, error: Type) -> Type {
  Named(prelude_module, "Result", [ok, error])
}

pub fn bit_array() -> Type {
  Named(prelude_module, "BitArray", [])
}
