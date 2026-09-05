import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn rebound_in_branch(rec_0: Logger, flag: Bool) {
  case flag {
    True -> {
      let rec_0 = Quiet(0)
      io.println("hi")
    }
    False -> panic
  }
}
