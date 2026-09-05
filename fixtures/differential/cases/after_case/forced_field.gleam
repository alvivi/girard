
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn after_case(l: Logger) {
  let io = l
  let _ = case io {
    Loud(..) -> Nil
    Quiet(..) -> Nil
  }
  io.println("hi")
}
