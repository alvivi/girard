import differential/io
import differential/kinds.{type Remote, Far, Near as Close}

pub fn renamed_alternatives(r: Remote) {
  case r {
    Close(..) as io | kinds.Near(..) as io -> io.println("hi")
    Far(..) -> panic
  }
}
