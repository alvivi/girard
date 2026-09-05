
pub type Solo {
  Solo(println: fn(String) -> Nil)
}

pub fn pipe_lambda(l: Solo) {
  l |> fn(io) { io.println("hi") }
}
