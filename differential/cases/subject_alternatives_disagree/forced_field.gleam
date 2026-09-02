
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn subject_alternatives_disagree(io: Logger) {
  case io {
    Loud(..) | Quiet(..) -> io.println("hi")
  }
}
