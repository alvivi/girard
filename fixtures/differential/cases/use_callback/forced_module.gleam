import differential/io

pub type Solo {
  Solo(println: fn(String) -> Nil)
}

fn with_logger(l: Solo, f: fn(Solo) -> a) -> a {
  f(l)
}

pub fn use_callback(l: Solo) {
  use rec_0 <- with_logger(l)
  io.println("hi")
}
