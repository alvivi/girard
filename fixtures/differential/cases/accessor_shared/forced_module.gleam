import differential/io

pub type Both {
  P(y: String)
  Q(y: String)
}

pub fn accessor_shared(rec_0: Both) {
  io.y
}
