//// A third shadow module, for the labelled probe: its `println` takes a
//// *labelled* argument, so a call written `io.println(message: "hi")` can
//// only be accepted if the module's field map applies. It is imported by that
//// probe alone, `import differential/labelled as io`, so adding it moved no
//// other row's inputs.
////
//// It imports nothing, for the same reason `differential/io` does not.

/// Contests the `println` field of a record variant, which is
/// `fn(String) -> Nil` and, being a field, accepts no labels.
pub fn println(message message: String) -> Int {
  case message {
    "" -> 0
    _ -> 1
  }
}
