import differential/io

pub type Logger {
  Loud(println: fn(String) -> Nil)
  Quiet(n: Int)
}

pub fn as_passes_subject(rec_0: Logger) {
  case rec_0 {
    Loud(..) as l -> {
      let _ = l
      io.println("hi")
    }
    Quiet(..) -> panic
  }
}
