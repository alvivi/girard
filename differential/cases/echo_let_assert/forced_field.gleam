
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn echo_let_assert(io: Logger) {
  let assert Loud(..) = echo io
  io.println("hi")
}
