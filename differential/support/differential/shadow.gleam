//// A second shadow module, for the aliased-import case: `import
//// differential/shadow as printer` binds `printer`, so the collision is with
//// the alias rather than with the module path's final segment.
////
//// It imports nothing, for the same reason `differential/io` does not.

/// Contests the `println` field of a record variant, which is
/// `fn(String) -> Nil`.
pub fn println(message: String) -> Int {
  case message {
    "" -> 0
    _ -> 1
  }
}
