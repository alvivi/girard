import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_rebound_by_sibling(left: Logger, rec_0: Logger) {
  case left, rec_0 {
    rec_0, Loud(..) -> io.println("hi")
    _, _ -> panic
  }
}
