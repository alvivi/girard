//// Internal: constructors for the built-in prelude types (`Int`, `List`, …),
//// shared across the inference engine. Qualified (`prelude.list`) so the names
//// don't collide with the `gleam/list`/`gleam/result` modules that import this.

import girard/types.{type Type, Named}

/// The prelude module name shared by all built-in types.
pub const prelude_module = "gleam"

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

pub fn utf_codepoint() -> Type {
  Named(prelude_module, "UtfCodepoint", [])
}
