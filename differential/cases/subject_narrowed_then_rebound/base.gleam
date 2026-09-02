import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_narrowed_then_rebound(left: Logger, io: Logger) {
  case io, left {
    Loud(..), io -> io.println("hi")
    _, _ -> panic
  }
}
