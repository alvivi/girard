import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn case_result(f: fn(String) -> Nil, flag: Bool) {
  let io = case flag {
    True -> Loud(f)
    False -> Loud(f)
  }
  io.println("hi")
}
