
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn tuple_pattern(f: fn(String) -> Nil) {
  let #(io, _) = #(Loud(f), 1)
  io.println("hi")
}
