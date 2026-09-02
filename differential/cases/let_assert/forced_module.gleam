import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn let_assert(l: Logger) {
  let assert Loud(..) as rec_0 = l
  io.println("hi")
}
