import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn narrowed_case(l: Logger) {
  case l {
    Loud(..) as io -> io.println("hi")
    Quiet(..) -> panic
  }
}
