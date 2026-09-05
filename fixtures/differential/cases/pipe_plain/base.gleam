import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn pipe_plain(io: Logger) {
  "hi" |> io.println
}
