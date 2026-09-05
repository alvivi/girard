pub fn unreachable(reason: String) -> Int {
  panic as { "unreachable: " <> reason }
}

pub fn crash() -> Int {
  panic
}

pub fn not_yet(name) -> String {
  todo as { "not implemented for " <> name }
}

pub fn later() -> String {
  todo
}
