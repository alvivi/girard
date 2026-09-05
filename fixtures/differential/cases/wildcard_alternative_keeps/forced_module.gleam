import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn wildcard_alternative_keeps(rec_0: Logger) {
  case rec_0 {
    Loud(..) | _ -> io.println("hi")
  }
}
