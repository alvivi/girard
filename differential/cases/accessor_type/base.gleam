import differential/io

pub type Handler {
  E(f: fn(String) -> Nil)
  G(f: fn(Int) -> Nil)
}

pub fn accessor_type(io: Handler) {
  io.f
}
