pub type Box(a) {
  Box(a)
}

pub type Color {
  Red
  Green
  Blue
}

pub fn wrap(x) {
  Box(x)
}

pub fn unwrap(b) {
  case b {
    Box(x) -> x
  }
}

pub fn favourite() {
  Green
}
