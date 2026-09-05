//// A record type declared in a second module, for the imported-narrowed case:
//// it pins that variant narrowing — and the field index the narrowed variant
//// grants — agree across a module boundary.
////
//// It imports nothing, for the same reason `differential/io` does not.

pub type Remote {
  Near(println: fn(String) -> Nil)
  Far(n: Int)
}
