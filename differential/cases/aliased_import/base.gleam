import differential/shadow as printer

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn aliased_import(l: Logger) {
  case l {
    Loud(..) as printer -> printer.println("hi")
    Quiet(..) -> panic
  }
}
