
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn rebound_in_branch(io: Logger, flag: Bool) {
  case flag {
    True -> {
      let io = Quiet(0)
      io.println("hi")
    }
    False -> panic
  }
}
