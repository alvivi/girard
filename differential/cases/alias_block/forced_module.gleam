import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn alias_block(l: Logger) {
  let rec_0 = {
    let assert Loud(..) = l
    l
  }
  io.println("hi")
}
