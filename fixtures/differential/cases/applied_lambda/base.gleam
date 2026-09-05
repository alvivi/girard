import differential/io

pub type Solo {
  Solo(println: fn(String) -> Nil)
}

pub fn applied_lambda(l: Solo) {
  fn(io) { io.println("hi") }(l)
}
