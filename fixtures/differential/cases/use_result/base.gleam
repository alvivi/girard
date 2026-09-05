import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn use_result(f: fn(String) -> Nil) {
  let with = fn(k: fn() -> Nil) {
    k()
    Loud(f)
  }
  let io = {
    use <- with
    Nil
  }
  io.println("hi")
}
