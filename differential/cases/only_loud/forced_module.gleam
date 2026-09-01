import differential/io

pub type Solo {
  Solo(println: fn(String) -> Nil)
}

pub fn only_loud(rec_0: Solo) {
  io.println("hi")
}
