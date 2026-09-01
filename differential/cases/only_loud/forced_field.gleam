
pub type Solo {
  Solo(println: fn(String) -> Nil)
}

pub fn only_loud(io: Solo) {
  io.println("hi")
}
