import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

fn make(f) {
  Loud(f)
}

pub fn unannotated_helper(f: fn(String) -> Nil) {
  let rec_0 = make(f)
  io.println("hi")
}
