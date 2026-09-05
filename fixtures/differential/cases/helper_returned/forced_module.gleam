import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

fn make() -> Logger {
  Quiet(0)
}

pub fn helper_returned() {
  let rec_0 = make()
  io.println("hi")
}
