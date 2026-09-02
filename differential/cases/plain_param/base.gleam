import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn plain_param(io: Logger) {
  io.println("hi")
}
