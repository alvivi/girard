import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_narrowed_then_rebound(left: Logger, rec_0: Logger) {
  case rec_0, left {
    Loud(..), rec_0 -> io.println("hi")
    _, _ -> panic
  }
}
