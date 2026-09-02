import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_alternatives_disagree(rec_0: Logger) {
  case rec_0 {
    Loud(..) | Quiet(..) -> io.println("hi")
  }
}
