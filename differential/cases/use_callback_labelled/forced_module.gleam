import differential/io

pub type Solo {
  Solo(println: fn(String) -> Nil)
}

fn with_logger_then(f: fn(Solo) -> a, times times: Int) -> a {
  let _ = times
  f(Solo(fn(_) { Nil }))
}

pub fn use_callback_labelled() {
  use rec_0 <- with_logger_then(times: 1)
  io.println("hi")
}
