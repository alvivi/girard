import differential/io

pub type Guarded {
  Wrapped(guard: fn(Bool, Int, fn() -> Int) -> Nil)
  Plain(n: Int)
}

pub fn use_guard(l: Guarded, cond: Bool) {
  case l {
    Wrapped(..) as io -> {
      use <- io.guard(cond, 0)
      1
    }
    Plain(..) -> panic
  }
}
