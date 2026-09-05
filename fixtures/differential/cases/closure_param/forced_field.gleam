
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn closure_param(l: Logger) {
  let assert Loud(..) = l
  let apply = fn(io: Logger) { io.println("hi") }
  apply(l)
}
