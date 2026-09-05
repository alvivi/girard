import differential/box

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn generic_constructor_arg(f: fn(String) -> Nil) {
  let box.Box(io) = box.Box(Loud(f))
  io.println("hi")
}
