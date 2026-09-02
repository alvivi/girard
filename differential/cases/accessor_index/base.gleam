import differential/io

pub type Rec {
  A(x: Int, y: String)
  B(y: String)
}

pub fn accessor_index(io: Rec) {
  io.y
}
