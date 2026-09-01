import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn direct_construction(f: fn(String) -> Nil) {
  let rec_0 = Loud(f)
  io.println("hi")
}
