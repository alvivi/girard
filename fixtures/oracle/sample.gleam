pub fn double(x: Int) -> Int {
  x + x
}

pub fn id(x) {
  x
}

pub fn apply(f, x) {
  f(x)
}

pub fn pair(a, b) {
  #(a, b)
}

pub fn singleton(x) {
  [x]
}

pub const answer = 42
