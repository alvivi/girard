import differential/labelled as io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn narrowed_labelled(l: Logger) {
  case l {
    Loud(..) as io -> io.println(message: "hi")
    Quiet(..) -> panic
  }
}
