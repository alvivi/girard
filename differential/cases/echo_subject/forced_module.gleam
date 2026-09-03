import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn echo_subject(rec_0: Logger) {
  case echo rec_0 {
    Loud(..) -> io.println("hi")
    Quiet(..) -> panic
  }
}
