import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn annotated_let(f: fn(String) -> Nil) {
  let rec_0: Logger = Loud(f)
  io.println("hi")
}
