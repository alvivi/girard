
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn echo_subject(io: Logger) {
  case echo io {
    Loud(..) -> io.println("hi")
    Quiet(..) -> panic
  }
}
