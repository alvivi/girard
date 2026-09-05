import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn tuple_pattern(f: fn(String) -> Nil) {
  let #(rec_0, _) = #(Loud(f), 1)
  io.println("hi")
}
