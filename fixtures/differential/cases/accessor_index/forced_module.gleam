import differential/io

pub type Rec {
  A(x: Int, y: String)
  B(y: String)
}

pub fn accessor_index(rec_0: Rec) {
  io.y
}
