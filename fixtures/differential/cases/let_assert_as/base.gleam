import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

fn build(f: fn(String) -> Nil) -> Logger {
  Loud(f)
}

pub fn let_assert_as(f: fn(String) -> Nil) {
  let assert Loud(..) as io = build(f)
  io.println("hi")
}
