
pub type Logger {
  Loud(println: fn(String) -> Nil, level: Int)
  Quiet(n: Int)
}

pub fn alternatives_agree(l: Logger) {
  case l {
    Loud(_, 0) as io | Loud(_, 1) as io -> io.println("hi")
    _ -> panic
  }
}
