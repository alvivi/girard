import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_alternatives_agree(rec_0: Logger) {
  case rec_0 {
    Loud(..) | Loud(..) -> io.println("hi")
    Quiet(..) -> panic
  }
}
