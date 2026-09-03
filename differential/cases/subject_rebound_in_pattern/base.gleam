import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_rebound_in_pattern(io: Logger) {
  case io {
    Loud(..) as io -> io.println("hi")
    Quiet(..) -> panic
  }
}
