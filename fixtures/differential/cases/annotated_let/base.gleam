import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn annotated_let(f: fn(String) -> Nil) {
  let io: Logger = Loud(f)
  io.println("hi")
}
