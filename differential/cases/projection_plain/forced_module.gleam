import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn projection_plain(rec_0: Logger) {
  io.n
}
