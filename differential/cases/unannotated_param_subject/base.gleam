import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn unannotated_param_subject(io) {
  let assert Loud(..) = io
  io.println("hi")
}
