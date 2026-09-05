pub type Box(a) {
  Box(value: a, tag: String)
}

pub fn replace(b: Box(a), v: c) -> Box(c) {
  Box(..b, value: v)
}

pub fn retag(b: Box(a)) -> Box(a) {
  Box(..b, tag: "x")
}
