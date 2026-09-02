import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn use_bound(f: fn(String) -> Nil) {
  let apply = fn(k: fn(Logger) -> Int) { k(Loud(f)) }
  use rec_0 <- apply
  io.println("hi")
}
