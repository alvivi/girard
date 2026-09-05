import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn narrowed_case(l: Logger) {
  case l {
    Loud(..) as rec_0 -> io.println("hi")
    Quiet(..) -> panic
  }
}
