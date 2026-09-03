
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn wildcard_alternative_keeps(io: Logger) {
  case io {
    Loud(..) | _ -> io.println("hi")
  }
}
