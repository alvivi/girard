import differential/io

pub type Solo {
  Solo(println: fn(String) -> Nil)
}

pub fn pipe_lambda(l: Solo) {
  l |> fn(rec_0) { io.println("hi") }
}
