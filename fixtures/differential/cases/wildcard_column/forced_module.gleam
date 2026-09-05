import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn wildcard_column(l: Logger, flag: Bool) {
  case l, flag {
    rec_0, True -> io.println("hi")
    _, False -> panic
  }
}
