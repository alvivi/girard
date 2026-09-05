import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn wildcard_alternative_first(io: Logger) {
  case io {
    _ | Loud(..) -> io.println("hi")
  }
}
