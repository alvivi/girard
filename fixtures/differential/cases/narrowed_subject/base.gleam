import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn narrowed_subject(io: Logger) {
  case io {
    Loud(..) -> io.println("hi")
    Quiet(..) -> panic
  }
}
