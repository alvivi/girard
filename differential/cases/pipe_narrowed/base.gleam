import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn pipe_narrowed(l: Logger) {
  case l {
    Loud(..) as io -> "hi" |> io.println
    Quiet(..) -> panic
  }
}
