import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn greet(rec_0: Logger) {
  io.greet()
}
