
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn alias_block(l: Logger) {
  let io = {
    let assert Loud(..) = l
    l
  }
  io.println("hi")
}
