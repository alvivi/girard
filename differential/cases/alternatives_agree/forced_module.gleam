import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil, level: Int)
  Quiet(n: Int)
}

pub fn alternatives_agree(l: Logger) {
  case l {
    Loud(_, 0) as rec_0 | Loud(_, 1) as rec_0 -> io.println("hi")
    _ -> panic
  }
}
