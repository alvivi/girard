import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn alternatives_disagree(l: Logger) {
  case l {
    Loud(..) as rec_0 | Quiet(..) as rec_0 -> io.println("hi")
  }
}
