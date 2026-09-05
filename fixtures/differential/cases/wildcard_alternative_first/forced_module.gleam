import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn wildcard_alternative_first(rec_0: Logger) {
  case rec_0 {
    _ | Loud(..) -> io.println("hi")
  }
}
