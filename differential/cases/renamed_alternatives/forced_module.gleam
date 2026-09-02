import differential/io
import differential/kinds.{type Remote, Far, Near as Close}

pub fn renamed_alternatives(r: Remote) {
  case r {
    Close(..) as rec_0 | kinds.Near(..) as rec_0 -> io.println("hi")
    Far(..) -> panic
  }
}
