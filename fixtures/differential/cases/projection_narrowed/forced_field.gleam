
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn projection_narrowed(l: Logger) {
  case l {
    Quiet(..) as io -> io.n
    Loud(..) -> panic
  }
}
