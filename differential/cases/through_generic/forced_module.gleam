import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

fn identity(x: a) -> a {
  x
}

pub fn through_generic(f: fn(String) -> Nil) {
  let rec_0 = identity(Loud(f))
  io.println("hi")
}
