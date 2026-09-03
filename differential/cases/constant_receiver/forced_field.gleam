
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

const quiet = Quiet(0)

pub fn constant_receiver() {
  let io = quiet
  io.n
}
