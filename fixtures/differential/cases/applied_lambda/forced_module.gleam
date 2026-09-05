import differential/io

pub type Solo {
  Solo(println: fn(String) -> Nil)
}

pub fn applied_lambda(l: Solo) {
  fn(rec_0) { io.println("hi") }(l)
}
