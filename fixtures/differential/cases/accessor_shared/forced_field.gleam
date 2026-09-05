
pub type Both {
  P(y: String)
  Q(y: String)
}

pub fn accessor_shared(io: Both) {
  io.y
}
