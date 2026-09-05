
pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn as_alternative_wildcard(l: Logger) {
  case l {
    Loud(..) as io | _ as io -> io.println("hi")
  }
}
