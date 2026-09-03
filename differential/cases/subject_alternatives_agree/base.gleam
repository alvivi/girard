import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_alternatives_agree(io: Logger) {
  case io {
    Loud(..) | Loud(..) -> io.println("hi")
    Quiet(..) -> panic
  }
}
