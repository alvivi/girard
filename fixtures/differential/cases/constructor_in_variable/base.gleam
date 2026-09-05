import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn constructor_in_variable(f: fn(String) -> Nil) {
  let mk = Loud
  let io = mk(f)
  io.println("hi")
}
