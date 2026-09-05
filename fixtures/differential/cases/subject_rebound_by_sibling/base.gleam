import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_rebound_by_sibling(left: Logger, io: Logger) {
  case left, io {
    io, Loud(..) -> io.println("hi")
    _, _ -> panic
  }
}
