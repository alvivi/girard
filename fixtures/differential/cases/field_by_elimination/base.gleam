pub type Solo {
  Solo(println: fn(String) -> Nil)
}

pub fn field_by_elimination(io: Solo) {
  io.println("hi")
}
