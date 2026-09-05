import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn capture_call(f: fn(String) -> Nil) {
  let mk = Loud(_)
  let rec_0 = mk(f)
  io.println("hi")
}
