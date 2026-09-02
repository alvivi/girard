
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn record_update_result(l: Logger, f: fn(String) -> Nil) {
  let assert Loud(..) = l
  let io = Loud(..l, println: f)
  io.println("hi")
}
