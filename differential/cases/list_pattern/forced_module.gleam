import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn list_pattern(f: fn(String) -> Nil) {
  let assert [rec_0] = [Loud(f)]
  io.println("hi")
}
