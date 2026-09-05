import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn closure_returned(f: fn(String) -> Nil) {
  let mk = fn() { Loud(f) }
  let rec_0 = mk()
  io.println("hi")
}
