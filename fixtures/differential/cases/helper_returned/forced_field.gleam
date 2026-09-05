
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

fn make() -> Logger {
  Quiet(0)
}

pub fn helper_returned() {
  let io = make()
  io.println("hi")
}
