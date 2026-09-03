import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn saturated_pipe_closure(f: fn(String) -> Nil) {
  let mk = fn() { Loud }
  let io = f |> mk()
  io.println("hi")
}
