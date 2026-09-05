import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn echo_let_assert(rec_0: Logger) {
  let assert Loud(..) = echo rec_0
  io.println("hi")
}
