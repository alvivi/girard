import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_rebound_in_pattern(rec_0: Logger) {
  case rec_0 {
    Loud(..) as rec_0 -> io.println("hi")
    Quiet(..) -> panic
  }
}
