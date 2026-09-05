pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn alias_no_module(l: Logger) {
  let assert Loud(..) = l
  let rec_0 = l
  io.println("hi")
}
