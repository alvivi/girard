// `name.member` in a constant initializer, or in a guard subtree the compiler
// parses as a constant, is module access: every `cfg.empty` below is
// `gleam/uri`'s `empty`, a `Uri`, although a local `const cfg` record has an
// `empty` field, whichever way the constants are declared. A direct guard
// field access stays record-first.

import gleam/uri as cfg

pub type Config {
  Config(empty: String)
}

pub const before = cfg.empty

pub const cfg = Config("local")

pub const after = cfg.empty

pub fn expose() -> Config {
  cfg
}

pub fn guarded(x: #(cfg.Uri)) -> Int {
  case x {
    _ if x == #(cfg.empty) -> 1
    _ -> 0
  }
}

pub fn direct(x: String) -> Int {
  case x {
    _ if x == cfg.empty -> 1
    _ -> 0
  }
}
