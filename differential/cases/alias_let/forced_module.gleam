import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn alias_let(l: Logger) {
  let assert Loud(..) = l
  let rec_0 = l
  io.println("hi")
}
