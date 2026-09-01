import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn projection_narrowed(l: Logger) {
  case l {
    Quiet(..) as rec_0 -> io.n
    Loud(..) -> panic
  }
}
