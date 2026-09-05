import differential/io
import differential/kinds

pub fn imported_narrowed(r: kinds.Remote) {
  case r {
    kinds.Near(..) as rec_0 -> io.println("hi")
    kinds.Far(..) -> panic
  }
}
