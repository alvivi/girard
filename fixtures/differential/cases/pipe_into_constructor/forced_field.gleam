
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn pipe_into_constructor(f: fn(String) -> Nil) {
  let io = f |> Loud
  io.println("hi")
}
