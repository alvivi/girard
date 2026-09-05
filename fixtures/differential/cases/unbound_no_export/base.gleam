import differential/io

pub fn unbound_no_export(io) {
  let _ = io
  io.nosuch("hi")
}
