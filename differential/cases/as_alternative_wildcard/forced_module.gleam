import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn as_alternative_wildcard(l: Logger) {
  case l {
    Loud(..) as rec_0 | _ as rec_0 -> io.println("hi")
  }
}
