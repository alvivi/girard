import differential/kinds

pub fn imported_narrowed(r: kinds.Remote) {
  case r {
    kinds.Near(..) as io -> io.println("hi")
    kinds.Far(..) -> panic
  }
}
