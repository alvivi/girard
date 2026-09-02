import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn after_case(l: Logger) {
  let rec_0 = l
  let _ = case rec_0 {
    Loud(..) -> Nil
    Quiet(..) -> Nil
  }
  io.println("hi")
}
