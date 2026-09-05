import differential/io

pub type Logger(a) {
  Loud(println: fn(String) -> Nil, extra: a)
  Quiet(n: Int)
}

const io = Quiet(0)

pub fn generic_constant_subject() {
  case io {
    Loud(..) -> io.println("hi")
    Quiet(..) -> panic
  }
}
