
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn let_assert(l: Logger) {
  let assert Loud(..) as io = l
  io.println("hi")
}
