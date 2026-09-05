
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

fn build(f: fn(String) -> Nil) -> Logger {
  Loud(f)
}

pub fn factory_result(f: fn(String) -> Nil) {
  let io = build(f)
  io.println("hi")
}
