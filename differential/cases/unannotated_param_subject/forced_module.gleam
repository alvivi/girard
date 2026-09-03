import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn unannotated_param_subject(rec_0) {
  let assert Loud(..) = rec_0
  io.println("hi")
}
